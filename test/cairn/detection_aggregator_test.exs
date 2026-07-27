defmodule Cairn.DetectionAggregatorTest do
  use ExUnit.Case, async: false

  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.Config.Camera
  alias Cairn.{DetectionAggregator, Event, EventCheckpoint, Observation, StreamEpochs, Track}

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}

  setup do
    camera_id = "agg_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, event ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn pid, event ->
           send(test_pid, {:extractor_finalized, pid, event})
         end}
      )

    Event.subscribe()
    on_exit(fn -> EventCheckpoint.delete(camera_id) end)

    %{agg: agg, camera: camera, camera_id: camera_id}
  end

  defp detect(agg, camera, score \\ 0.9, bbox \\ [0.1, 0.1, 0.2, 0.4]) do
    observe(agg, camera, [object("person", score, bbox)])
  end

  defp observe(agg, camera, objects, opts \\ []) do
    DetectionAggregator.detections(agg, camera, @policy, observation(objects, opts))
  end

  defp observation(objects, opts) do
    %Observation{
      camera_id: Keyword.get(opts, :camera_id),
      epoch: Keyword.get(opts, :epoch),
      pts: 90_000,
      media_ms: Keyword.get(opts, :media_ms, 1_000.0),
      observed_at: Keyword.get(opts, :observed_at, DateTime.utc_now()),
      time_quality: :arrival,
      objects: objects,
      ended_tracks: Keyword.get(opts, :ended_tracks, []),
      tracking: Keyword.get(opts, :tracking, false),
      protocol: :v0
    }
  end

  defp object(label, score, bbox, kind \\ "detected", track_id \\ nil) do
    %{label: label, score: score, bbox: bbox, track_id: track_id, observation_kind: kind}
  end

  defp checkpoint(camera_id) do
    Enum.filter(EventCheckpoint.all(), fn {cid, _event, _tracks} -> cid == camera_id end)
  end

  defp token(agg, camera_id, kind), do: :sys.get_state(agg).cameras[camera_id][kind]

  defp live_tracks(agg, camera_id),
    do: Cairn.Tracker.live_tracks(:sys.get_state(agg).cameras[camera_id].tracker)

  defp fire(agg, kind, camera_id, event_id) do
    tk = token(agg, camera_id, if(kind == :post_window, do: :post_token, else: :max_token))
    send(agg, {kind, camera_id, event_id, tk})
  end

  test "detection starts an event with extractor and checkpoint", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)

    assert_receive {:extractor_started, %Event{camera_id: ^id} = event, _pid}
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}
    assert event.id == eid
    assert [%{label: "person", object_id: object_id}] = event.labels
    # object ids are public ULIDs now, not the old per-tracker integers
    assert is_binary(object_id) and String.length(object_id) == 26
    assert event.trigger.object_id == object_id
    assert event.max_scores == %{"person" => 0.9}

    assert [{^id, %Event{id: ^eid}, [%Track{object_id: ^object_id}]}] = checkpoint(id)
  end

  test "captures the highest-scoring detection as the snapshot trigger", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera, 0.6, [0.1, 0.1, 0.2, 0.4])
    assert_receive {:event_started, %Event{camera_id: ^id, trigger: t0}}
    assert %{label: "person", score: 0.6, bbox: [0.1, 0.1, 0.2, 0.4], t: +0.0} = t0

    # a stronger detection replaces the trigger, its bbox included
    detect(agg, camera, 0.92, [0.3, 0.2, 0.25, 0.5])
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92, bbox: [0.3, 0.2, 0.25, 0.5]}}}

    # a weaker one does not
    detect(agg, camera, 0.7)
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92}}}

    # a tie keeps the incumbent (earliest max wins) — the bbox does not change
    detect(agg, camera, 0.92, [0.9, 0.9, 0.05, 0.05])
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92, bbox: [0.3, 0.2, 0.25, 0.5]}}}
  end

  test "below min_score never starts an event", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera, 0.3)
    refute_receive {:event_started, %Event{camera_id: ^id}}, 200
  end

  test "detections during an event merge and update", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}

    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid} = event}
    refute_receive {:event_started, %Event{camera_id: ^id}}, 100

    assert length(event.labels) == 2
    assert event.max_scores == %{"person" => 0.95}
    # same physical object keeps its tracker id
    assert [%{object_id: oid}, %{object_id: oid}] = event.labels
  end

  test "a new stream epoch ends tracks: object ids are not inherited", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}
    assert_receive {:track_started, %Track{object_id: ^first}}

    # minted through the real server, so dropping StreamEpochs.subscribe/0 from
    # the aggregator fails here. new_epoch/2 returns only once the broadcast has
    # been delivered, and the barrier keeps the next batch behind it — the two
    # senders differ, so nothing else orders them.
    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(agg)

    # the outage owes every live track a final, self-contained summary
    assert_receive {:track_ended, %Track{object_id: ^first} = final}
    assert_self_contained(final)
    assert final.end_reason == :stream_reset
    assert final.camera_id == id
    assert final.label == "person"
    assert final.best_score == 0.9

    # identical bbox: only the epoch reset stops the tracker from matching it
    # onto the object from before the outage
    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    # A ULID is minted once and never handed out again, so "not inherited" is
    # the whole property: object ids no longer come from a counter, and two
    # minted in the same millisecond sort by their random halves (Cairn.ULID).
    refute second == first
  end

  test "a repeat of the current epoch does not end tracks", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    epoch = StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(agg)

    # positive control for the refute below: a real boundary *does* end the
    # track it cut, so an aggregator that never ended anything cannot pass
    assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :stream_reset}}

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    assert_receive {:track_started, %Track{object_id: ^second}}
    refute second == first

    # StreamEpochs may announce one mint twice (degraded caller-side broadcast
    # plus a late server broadcast of the same epoch) — the repeat must not cut
    # the tracks that the first announcement already started
    send(agg, {:stream_epoch, id, epoch, :source_lost})
    _ = :sys.get_state(agg)

    # both halves are load-bearing: no final summary went out, *and* the track
    # is still in the tracker. Ending it and starting a new one under the same
    # id would satisfy either one alone.
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^second}] = live_tracks(agg, id)

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, _, %{object_id: ^second}]}}
  end

  test "a repeat of an epoch announced before the first detection does not end tracks", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    # the real order of events for every camera: ffmpeg spawns and mints an
    # epoch, and only then does the plugin produce anything to track
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(agg)

    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}
    assert_receive {:track_started, %Track{object_id: ^first}}

    # the same mint announced a second time (degraded caller broadcast plus a
    # late server broadcast). No boundary was crossed, so the track that the
    # camera's very first epoch already covers must survive
    send(agg, {:stream_epoch, id, epoch, :started})
    _ = :sys.get_state(agg)

    refute_received {:track_ended, _}
    assert [%Track{object_id: ^first}] = live_tracks(agg, id)

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: ^first}]}}
  end

  test "an epoch announced before the first detection still yields to a new one", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(agg)

    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(agg)

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    refute second == first
  end

  test "an epoch older than the one already applied is ignored", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    current = StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(agg)

    # positive control, and it clears the mailbox for the refute below
    assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :stream_reset}}

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    assert_receive {:track_started, %Track{object_id: ^second}}
    refute second == first

    # A mint from an earlier millisecond, delivered late: a port's spawn-time
    # ETS pull racing a queued broadcast, or StreamEpochs' degraded
    # caller-side broadcast, which has no ordering relation to the server's.
    # Applying it would roll `current_epoch` back to a stream nothing decodes
    # under, and `stale?/3` would then drop every observation the ports still
    # forward — until the camera's *next* mint, hours away for a healthy one.
    send(agg, {:stream_epoch, id, Cairn.ULID.generate(1), :source_lost})
    _ = :sys.get_state(agg)

    assert :sys.get_state(agg).cameras[id].current_epoch == current

    # not a boundary, so the tracks it did not cut stay uncut — and nothing
    # was told they ended
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^second}] = live_tracks(agg, id)

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, _, %{object_id: ^second}]}}
  end

  test "an observation with no observed_at cannot take the aggregator down", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    # unreachable through the codec — both ports stamp it — but `detections/4`
    # is a public, @spec'd API whose type admits nil, and this is the
    # singleton holding every camera's in-flight event state
    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], observed_at: nil)

    assert_receive {:event_started, %Event{camera_id: ^id} = event}
    assert %DateTime{} = event.started_at
    assert [%{t: +0.0}] = event.labels
  end

  test "a stopped camera's epoch is forgotten", %{agg: agg, camera_id: id} do
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(agg)
    assert :sys.get_state(agg).epochs[id] == epoch

    # nothing decodes under a :camera_stopped epoch, so remembering it would
    # only retain a row for a camera that may never come back
    StreamEpochs.new_epoch(id, :camera_stopped)
    _ = :sys.get_state(agg)
    refute Map.has_key?(:sys.get_state(agg).epochs, id)
  end

  test "a :camera_stopped epoch ends the tracks but never becomes current_epoch", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(agg)

    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: epoch)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert_receive {:track_started, %Track{object_id: first}}

    # a camera's stop and its start are announced by different processes, and
    # on StreamEpochs' degraded caller-side path they have no ordering
    # relation: a stop epoch minted after a live start must not be adopted.
    StreamEpochs.new_epoch(id, :camera_stopped)
    _ = :sys.get_state(agg)

    # the stream that owned them is over, so the tracks are
    assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :stream_reset}}
    assert :sys.get_state(agg).cameras[id].current_epoch == epoch

    # ...and observations tagged with the epoch that is actually being decoded
    # are still accepted. Letting the stop epoch become current would drop
    # every one of them until an ffmpeg respawn that a healthy camera never has.
    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: epoch)
    assert_receive {:event_updated, %Event{camera_id: ^id}}
  end

  test "disabling detection ends the live tracks, once", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert_receive {:track_started, %Track{object_id: oid}}

    # nothing advances a track while detection is off, so leaving them live
    # would strand every consumer's entities indefinitely
    Cairn.CameraControl.set(id, %{detection_enabled: false})
    detect(agg, camera)

    assert_receive {:track_ended,
                    %Track{object_id: ^oid, end_reason: :detection_disabled} = final}

    assert_self_contained(final)
    assert live_tracks(agg, id) == []
    assert :sys.get_state(agg).cameras[id].track_updates == %{}

    # the next disabled batch has nothing left to end
    detect(agg, camera)
    _ = :sys.get_state(agg)
    refute_received {:track_ended, _}
  end

  test "an id the plugin ended is still known after a detection toggle", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    live = object("person", 0.9, [0.0, 0.0, 0.1, 0.1], "detected", "t1")
    other = object("person", 0.9, [0.8, 0.8, 0.1, 0.1], "detected", "t2")

    observe(agg, camera, [live, other], tracking: true)
    assert_receive {:track_started, %Track{object_id: ended_oid, plugin_track_id: "t1"}}
    assert_receive {:track_started, %Track{plugin_track_id: "t2"}}

    # "t1" is ended by the plugin; "t2" stays live so the toggle below has
    # something to end
    observe(agg, camera, [other], tracking: true, media_ms: 1_200.0, ended_tracks: ["t1"])
    assert_receive {:track_ended, %Track{object_id: ^ended_oid, end_reason: :plugin_ended}}

    Cairn.CameraControl.set(id, %{detection_enabled: false})
    observe(agg, camera, [other], tracking: true, media_ms: 1_400.0)
    assert_receive {:track_ended, %Track{plugin_track_id: "t2", end_reason: :detection_disabled}}
    Cairn.CameraControl.set(id, %{detection_enabled: true})

    # the toggle did not change the epoch, so reusing "t1" is the same contract
    # violation it was before it — reported, and given a fresh identity
    log =
      capture_log(fn ->
        observe(agg, camera, [live], tracking: true, media_ms: 1_600.0)
        _ = :sys.get_state(agg)
      end)

    assert log =~ ~s(reused track id "t1" after ending it)
    assert_receive {:track_started, %Track{object_id: new_oid, plugin_track_id: "t1"}}
    refute new_oid == ended_oid
  end

  test "checkpoint writes are throttled between an event's first and last", %{
    camera: camera,
    camera_id: id
  } do
    {:ok, clock} = start_supervised({Agent, fn -> 0 end})
    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         monotonic_ms: fn -> Agent.get(clock, & &1) end,
         start_extractor: fn _camera, ev ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, ev, pid})
           {:ok, pid}
         end},
        id: :agg_checkpoint
      )

    # the event's first frame is never throttled: restore has to see the row
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid}}
    assert [{^id, %Event{id: ^eid, labels: [_]}, _tracks}] = checkpoint(id)

    # inside the window the event grows and the ETS row does not — the copy is
    # the whole event plus the whole track list, per batch
    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{labels: [_, _]}}
    assert [{^id, %Event{labels: [_]}, _tracks}] = checkpoint(id)

    # a second of wall clock later it catches up in one write
    Agent.update(clock, &(&1 + 1_000))
    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{labels: [_, _, _]}}
    assert [{^id, %Event{labels: [_, _, _]}, _tracks}] = checkpoint(id)

    # and the other transition that matters for restore is the delete
    fire(agg, :post_window, id, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}
    assert checkpoint(id) == []
  end

  test "event times come from the observation, not from the clock", %{agg: agg, camera: camera} do
    # the plugin observed this 10s ago; the queue it sat in must not move the
    # event onto the wall clock of the moment it was finally processed
    past = DateTime.add(DateTime.utc_now(), -10, :second)
    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], observed_at: past)

    assert_receive {:event_started, %Event{} = event}
    assert DateTime.compare(event.started_at, past) == :eq
    assert [%{t: +0.0}] = event.labels
    assert event.trigger.t == +0.0

    # offsets are source-time deltas: 2s later in the stream is t = 2.0
    observe(agg, camera, [object("person", 0.95, [0.1, 0.1, 0.2, 0.4])],
      observed_at: DateTime.add(past, 2, :second)
    )

    assert_receive {:event_updated, %Event{labels: [_, %{t: 2.0}], trigger: %{t: 2.0}}}
  end

  test "predicted (tracked) objects are not evidence", %{agg: agg, camera: camera, camera_id: id} do
    observe(agg, camera, [object("person", 0.99, [0.1, 0.1, 0.2, 0.4], "tracked")])

    # the cast and its (synchronous) broadcast are done once the mailbox flushes
    :sys.get_state(agg)
    refute_received {:event_started, %Event{camera_id: ^id}}

    # it still updated the tracker: the detected object that overlaps it
    # inherits that track's id rather than opening a second one
    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])])
    assert_receive {:track_started, %Track{object_id: track_id, source: :host}}
    assert_receive {:event_started, %Event{labels: [%{object_id: ^track_id}]}}
  end

  test "an observation from a stale epoch is dropped", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    send(agg, {:stream_epoch, id, "epoch_two", :source_lost})

    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: "epoch_one")
    :sys.get_state(agg)
    refute_received {:event_started, %Event{camera_id: ^id}}

    observe(agg, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: "epoch_two")
    assert_receive {:event_started, %Event{camera_id: ^id}}
  end

  test "post-window timeout finalizes", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    fire(agg, :post_window, id, eid)

    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid, status: :finalized} = event}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert %DateTime{} = event.ended_at
    assert checkpoint(id) == []
  end

  test "max-cap finalizes and the next detection reopens", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: first}}

    fire(agg, :max_event, id, first)
    assert_receive {:event_ended, %Event{id: ^first}}

    detect(agg, camera)
    assert_receive {:event_started, %Event{id: second}}
    refute first == second
  end

  test "stale timer for an already-finalized event is ignored", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid}}

    old_token = token(agg, id, :post_token)
    fire(agg, :post_window, id, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}

    send(agg, {:post_window, id, eid, old_token})
    refute_receive {:event_ended, _}, 100
  end

  test "an already-delivered timer message from before a reschedule cannot finalize", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid}}
    stale_token = token(agg, id, :post_token)

    # a new detection cancels + reschedules the post window; the stale
    # message may already be in the mailbox — its token no longer matches
    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid}}

    send(agg, {:post_window, id, eid, stale_token})
    refute_receive {:event_ended, _}, 100

    # the current token still finalizes
    fire(agg, :post_window, id, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  test "extractor crash mid-event ends the event as partial", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:event_started, _}

    Process.exit(ex_pid, :kill)

    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert checkpoint(id) == []
  end

  test "orphaned checkpoint entries are ended as partial on restart", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    EventCheckpoint.put(id, event)

    start_supervised!({DetectionAggregator, name: nil}, id: :agg_restore)

    eid = event.id
    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert checkpoint(id) == []
  end

  test "restart re-attaches to a live extractor and can finalize it", %{camera_id: id} do
    test_pid = self()
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}

    extractor =
      spawn(fn ->
        Registry.register(Cairn.Registry, {id, {:extractor, event.id}}, nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    EventCheckpoint.put(id, event)

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         finalize_extractor: fn pid, ev -> send(test_pid, {:extractor_finalized, pid, ev}) end},
        id: :agg_reattach
      )

    eid = event.id
    refute_receive {:event_ended, %Event{id: ^eid}}, 100

    fire(agg, :post_window, id, eid)
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  test "restored tracks end as :host_restart and their ids are never reassigned", %{
    camera: camera,
    camera_id: id
  } do
    object_id = Cairn.ULID.generate()

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: id,
      started_at: DateTime.utc_now(),
      labels: [%{t: 0.0, label: "person", score: 0.9, object_id: object_id}]
    }

    track = %Track{
      object_id: object_id,
      camera_id: id,
      label: "person",
      score: 0.9,
      best_score: 0.9,
      bbox: [0.1, 0.1, 0.2, 0.4],
      source: :host,
      started_at: event.started_at,
      last_seen_at: event.started_at
    }

    EventCheckpoint.put(id, event, [track])

    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, ev ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, ev, pid})
           {:ok, pid}
         end},
        id: :agg_restore_tracks
      )

    # the tracker that owned it died with the aggregator: it owes a final,
    # self-contained summary
    # the summary is rebuilt from ETS, which is the end path most likely to
    # lose a field on the way through
    assert_receive {:track_ended, %Track{object_id: ^object_id} = final}
    assert_self_contained(final)
    assert final.end_reason == :host_restart
    assert final.label == "person"
    assert final.best_score == 0.9

    # a ULID is minted once, so the restored event's label id can never be
    # handed to a new object — the old integer-counter collision is gone
    detect(agg, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: fresh_id}]}}
    refute fresh_id == object_id
  end

  describe "track lifecycle" do
    test "started and ended always broadcast; updates are throttled", %{
      camera: camera,
      camera_id: id
    } do
      {:ok, clock} = start_supervised({Agent, fn -> 0 end})
      test_pid = self()

      agg =
        start_supervised!(
          {DetectionAggregator,
           name: nil,
           monotonic_ms: fn -> Agent.get(clock, & &1) end,
           start_extractor: fn _camera, ev ->
             pid = spawn(fn -> Process.sleep(:infinity) end)
             send(test_pid, {:extractor_started, ev, pid})
             {:ok, pid}
           end},
          id: :agg_throttle
        )

      detect(agg, camera, 0.6)
      assert_receive {:track_started, %Track{object_id: oid, camera_id: ^id}}

      # same score, no wall clock elapsed: nothing goes out
      detect(agg, camera, 0.6, [0.12, 0.1, 0.2, 0.4])
      :sys.get_state(agg)
      refute_received {:track_updated, %Track{object_id: ^oid}}

      # a better score is always worth sending
      detect(agg, camera, 0.8, [0.12, 0.1, 0.2, 0.4])
      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.8}}

      # ...and so is a second of wall clock, however dull the frame
      detect(agg, camera, 0.7, [0.12, 0.1, 0.2, 0.4])
      :sys.get_state(agg)
      refute_received {:track_updated, %Track{object_id: ^oid}}

      Agent.update(clock, &(&1 + 1_000))
      detect(agg, camera, 0.7, [0.12, 0.1, 0.2, 0.4])
      assert_receive {:track_updated, %Track{object_id: ^oid, score: 0.7, best_score: 0.8}}

      # expiry is media time: 3.1s after the last sighting the track ends
      observe(agg, camera, [], media_ms: 4_200.0)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :unseen}}
    end

    test "a plugin's own track ids are honoured when it declared the capability", %{
      agg: agg,
      camera: camera
    } do
      observe(agg, camera, [object("person", 0.9, [0.0, 0.0, 0.1, 0.1], "detected", "t1")],
        tracking: true
      )

      assert_receive {:track_started,
                      %Track{object_id: oid, source: :plugin, plugin_track_id: "t1"}}

      # nowhere near the previous box: only the plugin's id keeps it the same
      # object
      observe(agg, camera, [object("person", 0.95, [0.8, 0.8, 0.1, 0.1], "detected", "t1")],
        tracking: true,
        media_ms: 1_200.0
      )

      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.95}}

      observe(agg, camera, [], tracking: true, media_ms: 1_400.0, ended_tracks: ["t1"])
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :plugin_ended}}
    end

    test "predictions alone can neither open nor extend an event", %{
      agg: agg,
      camera: camera,
      camera_id: id
    } do
      predicted = [object("person", 0.99, [0.1, 0.1, 0.2, 0.4], "tracked")]

      observe(agg, camera, predicted, media_ms: 1_000.0)
      observe(agg, camera, predicted, media_ms: 2_000.0)
      :sys.get_state(agg)
      refute_received {:event_started, %Event{camera_id: ^id}}

      # a detection opens the event; the plugin then keeps predicting the same
      # object, which must not hold the event open
      detect(agg, camera)
      assert_receive {:event_started, %Event{camera_id: ^id}}

      observe(agg, camera, predicted, media_ms: 3_000.0)
      observe(agg, camera, predicted, media_ms: 4_500.0)
      :sys.get_state(agg)
      refute_received {:event_updated, %Event{camera_id: ^id}}
    end
  end
end
