defmodule Cairn.DetectionAggregatorTest do
  use ExUnit.Case, async: false

  alias Cairn.Config.Camera
  alias Cairn.{DetectionAggregator, Event, EventCheckpoint, Observation, StreamEpochs}

  @windows %{pre: 5, post: 10, max: 300}

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
    DetectionAggregator.detections(agg, camera, @windows, observation(objects, opts))
  end

  defp observation(objects, opts) do
    %Observation{
      camera_id: Keyword.get(opts, :camera_id),
      epoch: Keyword.get(opts, :epoch),
      pts: 90_000,
      media_ms: 1_000.0,
      observed_at: Keyword.get(opts, :observed_at, DateTime.utc_now()),
      time_quality: :arrival,
      objects: objects,
      protocol: :v0
    }
  end

  defp object(label, score, bbox, kind \\ "detected") do
    %{label: label, score: score, bbox: bbox, track_id: nil, observation_kind: kind}
  end

  defp token(agg, camera_id, kind), do: :sys.get_state(agg).cameras[camera_id][kind]

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
    assert [%{label: "person", object_id: 1}] = event.labels
    assert event.max_scores == %{"person" => 0.9}

    assert [{^id, %Event{id: ^eid}}] =
             Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end)
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

    # minted through the real server, so dropping StreamEpochs.subscribe/0 from
    # the aggregator fails here. new_epoch/2 returns only once the broadcast has
    # been delivered, and the barrier keeps the next batch behind it — the two
    # senders differ, so nothing else orders them.
    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(agg)

    # identical bbox: only the epoch reset stops the tracker from matching it
    # onto the object from before the outage
    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    refute second == first
    # Tracker.reset/1 keeps the id counter advancing; Tracker.new/0 would not
    assert second > first
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

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    refute second == first

    # StreamEpochs may announce one mint twice (degraded caller-side broadcast
    # plus a late server broadcast of the same epoch) — the repeat must not cut
    # the tracks that the first announcement already started
    send(agg, {:stream_epoch, id, epoch, :source_lost})
    _ = :sys.get_state(agg)

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

    # the same mint announced a second time (degraded caller broadcast plus a
    # late server broadcast). No boundary was crossed, so the track that the
    # camera's very first epoch already covers must survive
    send(agg, {:stream_epoch, id, epoch, :started})
    _ = :sys.get_state(agg)

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

    detect(agg, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
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

    # not a boundary, so the tracks it did not cut stay uncut
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
    assert_receive {:event_started, %Event{labels: [%{object_id: 1}]}}
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
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
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
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
  end

  test "orphaned checkpoint entries are ended as partial on restart", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    EventCheckpoint.put(id, event)

    start_supervised!({DetectionAggregator, name: nil}, id: :agg_restore)

    eid = event.id
    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
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
end
