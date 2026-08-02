defmodule Cairn.CameraTrackerTest do
  # DataCase, not ExUnit.Case: restore consults the event index before it
  # decides whether an interrupted event still owes an `event_ended`.
  use Cairn.DataCase, async: false

  import Cairn.RegistryHelpers, only: [stale_entry: 2]
  import Cairn.TrackAssertions
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.Config
  alias Cairn.Config.Camera

  alias Cairn.{
    CameraTracker,
    Event,
    EventArtifact,
    EventCheckpoint,
    Events,
    Observation,
    StreamEpochs,
    Track
  }

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}
  # The box every `detect/4` uses by default, and two the tracker cannot
  # confuse with it across a stream reset: `@drift_box` overlaps it at 1/3,
  # under the adoption floor, and `@far_box` not at all.
  @box [0.1, 0.1, 0.2, 0.4]
  @drift_box [0.2, 0.1, 0.2, 0.4]
  @far_box [0.6, 0.1, 0.2, 0.4]

  setup do
    camera_id = "trk_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: camera_id,
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

    %{tracker: tracker, camera: camera, camera_id: camera_id}
  end

  defp detect(tracker, camera, score \\ 0.9, bbox \\ @box) do
    observe(tracker, camera, [object("person", score, bbox)])
  end

  defp observe(tracker, camera, objects, opts \\ []) do
    CameraTracker.detections(tracker, camera, @policy, observation(objects, opts))
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
      protocol: :v0
    }
  end

  defp object(label, score, bbox, kind \\ "detected", track_id \\ nil) do
    %{label: label, score: score, bbox: bbox, track_id: track_id, observation_kind: kind}
  end

  defp checkpoint(camera_id) do
    Enum.filter(EventCheckpoint.all(), fn {cid, _event, _tracks} -> cid == camera_id end)
  end

  defp token(tracker, kind), do: :sys.get_state(tracker)[kind]

  defp live_tracks(tracker),
    do: Cairn.Tracker.live_tracks(:sys.get_state(tracker).tracker)

  defp suspended_tracks(tracker),
    do: Cairn.Tracker.suspended_tracks(:sys.get_state(tracker).tracker)

  defp fire(tracker, kind, event_id) do
    tk = token(tracker, if(kind == :post_window, do: :post_token, else: :max_token))
    send(tracker, {kind, event_id, tk})
  end

  defp window_ref(tracker), do: :sys.get_state(tracker).window_ref

  # A tracker that stamps every stream cut `ago` seconds in the past. The
  # adoption window is a wall-clock minute measured from the cut, so this is
  # what lets a test drive a suspension past it without sitting through one —
  # the sweep itself still reads the real clock. `opts` reaches the tracker
  # verbatim.
  defp tracker_cut_seconds_ago(camera_id, ago, opts \\ []) do
    test_pid = self()

    start_supervised!(
      {CameraTracker,
       Keyword.merge(
         [
           camera_id: camera_id,
           name: nil,
           cut_clock: fn -> DateTime.add(DateTime.utc_now(), -ago, :second) end,
           start_extractor: fn _camera, event ->
             pid = spawn(fn -> Process.sleep(:infinity) end)
             send(test_pid, {:extractor_started, event, pid})
             {:ok, pid}
           end
         ],
         opts
       )},
      id: :tracker_past_cut
    )
  end

  # -- stationary helpers -------------------------------------------------------

  # The default `stationary_after_ms` is 10s of media time; at one hand-fed
  # frame per simulated second that is ten frames before the edge under test.
  @stationary_policy Map.put(@policy, :stationary_after_ms, 2_000)
  @parked_box [0.1, 0.1, 0.2, 0.4]
  # Overlaps the parked box at 0.54 — under `@stationary_iou` (0.8), so it
  # reads as movement, and well over the match threshold, so it is the same
  # track that moved rather than a second one.
  @moved_box [0.16, 0.1, 0.2, 0.4]
  # The live failure's geometry: a car 0.17 by 0.09 of the frame with about
  # 0.02 of detector drift in *y*, which is IoU 0.636 against the anchor —
  # under `@stationary_iou` and nothing like motion. Small and drifting on its
  # short axis on purpose; @parked_box above is four times the area and
  # @moved_box displaces it in x. `@small_moved_box` is where the same car goes
  # when it really leaves: 0.385, low enough to fail stillness for as long as
  # it holds and high enough to stay the same track rather than mint a second.
  @small_parked_box [0.40, 0.50, 0.17, 0.09]
  @small_jitter_box [0.40, 0.52, 0.17, 0.09]
  @small_moved_box [0.40, 0.54, 0.17, 0.09]

  defp detect_at(tracker, camera, media_ms, bbox \\ @parked_box) do
    CameraTracker.detections(
      tracker,
      camera,
      @stationary_policy,
      observation([object("person", 0.9, bbox)], media_ms: media_ms)
    )
  end

  # Object arrives, holds still past the threshold, event finalizes: the state
  # the parked-car loop used to restart from. Returns `{event_id, object_id}`.
  defp park_and_finalize(tracker, camera, bbox \\ @parked_box) do
    detect_at(tracker, camera, 1_000, bbox)
    # the event-lifecycle messages are consumed here so a caller refuting a
    # *second* event is refuting one, not tripping over this one; the track
    # broadcasts (`track_started`, the flip's `track_updated`) are NOT drained
    # — a caller asserting on those must account for these batches

    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    detect_at(tracker, camera, 2_000, bbox)
    assert_receive {:event_updated, %Event{id: ^eid}}

    # read off the tracker rather than off the broadcast: what this asserts is
    # the evidence rule, not how the flip reaches a subscriber (below)
    detect_at(tracker, camera, 3_000, bbox)
    assert [%Track{object_id: oid, stationary: true}] = live_tracks(tracker)

    fire(tracker, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}

    {eid, oid}
  end

  test "detection starts an event with extractor and checkpoint", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)

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
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera, 0.6, [0.1, 0.1, 0.2, 0.4])
    assert_receive {:event_started, %Event{camera_id: ^id, trigger: t0}}
    assert %{label: "person", score: 0.6, bbox: [0.1, 0.1, 0.2, 0.4], t: +0.0} = t0

    # a stronger detection replaces the trigger, its bbox included
    detect(tracker, camera, 0.92, [0.3, 0.2, 0.25, 0.5])
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92, bbox: [0.3, 0.2, 0.25, 0.5]}}}

    # a weaker one does not
    detect(tracker, camera, 0.7)
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92}}}

    # a tie keeps the incumbent (earliest max wins) — the bbox does not change
    detect(tracker, camera, 0.92, [0.9, 0.9, 0.05, 0.05])
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92, bbox: [0.3, 0.2, 0.25, 0.5]}}}
  end

  test "below min_score never starts an event", %{tracker: tracker, camera: camera, camera_id: id} do
    detect(tracker, camera, 0.3)
    refute_receive {:event_started, %Event{camera_id: ^id}}, 200
  end

  test "detections during an event merge and update", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}

    detect(tracker, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid} = event}
    refute_receive {:event_started, %Event{camera_id: ^id}}, 100

    assert length(event.labels) == 2
    assert event.max_scores == %{"person" => 0.95}
    # same physical object keeps its tracker id
    assert [%{object_id: oid}, %{object_id: oid}] = event.labels
  end

  test "a new stream epoch suspends tracks: the object that comes back is itself", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    epoch_a = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(tracker)

    observe(tracker, camera, [object("person", 0.9, @box)], epoch: epoch_a)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}
    assert_receive {:track_started, %Track{object_id: ^first, epoch: ^epoch_a}}

    # minted through the real server, so dropping StreamEpochs.subscribe/0 from
    # the tracker fails here. new_epoch/2 returns only once the broadcast has
    # been delivered, and the barrier keeps the next batch behind it — the two
    # senders differ, so nothing else orders them.
    epoch_b = StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # nothing is owed a final yet: the track is suspended, and whether it died
    # is not yet known
    refute_received {:track_ended, _}
    assert live_tracks(tracker) == []
    assert [%Track{object_id: ^first, end_reason: nil}] = suspended_tracks(tracker)

    # the same box on the far side of a reconnect that took no time at all
    observe(tracker, camera, [object("person", 0.9, @box)], epoch: epoch_b)

    # the identity resumes, on the epoch that is now being decoded
    assert_receive {:track_updated, %Track{object_id: ^first, epoch: ^epoch_b}}
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: ^first}]}}
    refute_received {:track_started, _}
    assert [%Track{object_id: ^first}] = live_tracks(tracker)
    assert suspended_tracks(tracker) == []
  end

  test "a box the adoption floor refuses gets an identity of its own", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}
    assert_receive {:track_started, %Track{object_id: ^first}}

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # 1/3 overlap with the suspended track's last box — two objects side by
    # side, not one object seen slightly off — so nothing is adopted
    detect(tracker, camera, 0.9, @drift_box)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    # A ULID is minted once and never handed out again, so "not inherited" is
    # the whole property: object ids no longer come from a counter, and two
    # minted in the same millisecond sort by their random halves (Cairn.ULID).
    refute second == first
    assert_receive {:track_started, %Track{object_id: ^second}}
    # and the one that was cut is still waiting rather than ended or spent
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^first}] = suspended_tracks(tracker)
  end

  test "a suspension nothing adopts ends once, timestamped at the cut", %{
    camera: camera,
    camera_id: id
  } do
    # The adoption window runs from the cut, so it is the *cut* that has to be
    # far enough back for the sweep below to find anything — which is what the
    # tracker's own timer would have waited for. The last observation is
    # ten seconds further back still: a stream is not cut the instant it goes
    # quiet, and the final is timestamped at the sighting, not at the cut.
    tracker = tracker_cut_seconds_ago(id, 90)
    seen_at = DateTime.add(DateTime.utc_now(), -100, :second)

    observe(tracker, camera, [object("person", 0.9, @box)], observed_at: seen_at)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert_receive {:track_started, %Track{object_id: oid}}

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)
    refute_received {:track_ended, _}

    send(tracker, :adoption_window)
    _ = :sys.get_state(tracker)

    assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :stream_reset} = final}
    assert_self_contained(final)
    assert final.camera_id == id
    assert final.best_score == 0.9
    # the instant it was last actually seen, not the instant this process
    # stopped waiting for it
    assert DateTime.compare(final.last_seen_at, seen_at) == :eq

    # and once: the second sweep has nothing left to end
    assert suspended_tracks(tracker) == []
    send(tracker, :adoption_window)
    _ = :sys.get_state(tracker)
    refute_received {:track_ended, _}
  end

  test "a reset and the recovery after it are reported for the link-health log", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    test_pid = self()
    handler = "link-health-#{id}"

    :telemetry.attach_many(
      handler,
      [
        [:cairn, :tracker, :stream_reset],
        [:cairn, :tracker, :stream_gap],
        [:cairn, :tracker, :adopted]
      ],
      fn event, measurements, meta, _ ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    seen_at = DateTime.add(DateTime.utc_now(), -2, :second)
    observe(tracker, camera, [object("person", 0.9, @box)], observed_at: seen_at)
    assert_receive {:track_started, %Track{object_id: oid}}

    # Telemetry rather than the log lines emitted beside it: those are
    # `Logger.info` and this env runs the logger at `:warning`, so they are
    # dropped before any capture can see them. Every site here emits both.
    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    assert_receive {:telemetry, [:cairn, :tracker, :stream_reset], %{suspended: 1, ended: 0},
                    %{camera_id: ^id, reason: :source_lost}}

    # the gap can only be measured once the far side produces an observation,
    # and it is measured to the last one before the cut
    observe(tracker, camera, [object("person", 0.9, @box)], observed_at: DateTime.utc_now())
    _ = :sys.get_state(tracker)

    assert_receive {:telemetry, [:cairn, :tracker, :stream_gap], %{gap_ms: gap},
                    %{camera_id: ^id}}

    assert gap >= 2_000 and gap < 10_000
    assert_receive {:telemetry, [:cairn, :tracker, :adopted], %{count: 1}, %{camera_id: ^id}}
    assert_receive {:track_updated, %Track{object_id: ^oid}}

    # one report per reset, not one per batch
    observe(tracker, camera, [object("person", 0.9, @box)], observed_at: DateTime.utc_now())
    _ = :sys.get_state(tracker)

    refute_received {:telemetry, [:cairn, :tracker, :stream_gap], _, _}
    refute_received {:telemetry, [:cairn, :tracker, :adopted], _, _}
  end

  test "the sweep is armed by the reset itself, for a camera that never comes back", %{
    camera: camera,
    camera_id: id
  } do
    # the real delay is the adoption window plus slack; the window itself is
    # still the wall-clock one, which is why the cut is a minute and a half old
    tracker = tracker_cut_seconds_ago(id, 90, window_ms: 20)

    observe(tracker, camera, [object("person", 0.9, @box)],
      observed_at: DateTime.add(DateTime.utc_now(), -90, :second)
    )

    assert_receive {:track_started, %Track{object_id: oid}}

    # nothing is sent to this process by hand: the reset arms the timer, and
    # no observation ever arrives on the far side of it
    send(tracker, {:stream_epoch, id, Cairn.ULID.generate(), :source_lost})

    assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :stream_reset}}, 1_000

    # the sweep that collected the last suspension arms nothing further: there
    # is no camera left to sweep for, and a timer per reset that never drains
    # is a leak on exactly the flapping camera this path is for
    assert suspended_tracks(tracker) == []
    assert window_ref(tracker) == nil
  end

  test "a sweep that leaves suspensions behind re-arms itself", %{
    camera: camera,
    camera_id: id
  } do
    # The cut is recent, so the suspension it makes is nowhere near lapsing and
    # every sweep below finds nothing to end. That is the shape of the failure
    # this covers: a wall clock stepped backwards, or any sweep that misses,
    # on a camera whose stream never returns — nothing else is ever coming to
    # collect the suspension, so the sweep has to come back on its own.
    tracker = tracker_cut_seconds_ago(id, 0)

    observe(tracker, camera, [object("person", 0.9, @box)])
    assert_receive {:track_started, %Track{object_id: oid}}

    send(tracker, {:stream_epoch, id, Cairn.ULID.generate(), :source_lost})
    _ = :sys.get_state(tracker)
    armed = window_ref(tracker)
    assert armed != nil

    send(tracker, :adoption_window)
    _ = :sys.get_state(tracker)

    # nothing ended, and the sweep left a *new* timer rather than the one the
    # reset armed: a suspension that outlives one sweep still has a next one
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^oid}] = suspended_tracks(tracker)
    assert window_ref(tracker) != nil
    assert window_ref(tracker) != armed
  end

  test "a stale sweep after the tracker was emptied ends nothing and arms nothing", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    observe(tracker, camera, [object("person", 0.9, @box)])
    assert_receive {:track_started, %Track{object_id: oid}}

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)
    assert [%Track{object_id: ^oid}] = suspended_tracks(tracker)

    # detection off gives up on every suspension at once, so the sweep the
    # reset armed is left with nothing — and must not double-end or re-arm
    Cairn.CameraControl.set(id, %{detection_enabled: false})
    observe(tracker, camera, [object("person", 0.9, @box)])
    assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :stream_reset}}

    send(tracker, :adoption_window)
    _ = :sys.get_state(tracker)

    refute_received {:track_ended, _}
    assert window_ref(tracker) == nil
  end

  test "an adopted stationary track opens no event when it is detected again", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    {_eid, oid} = park_and_finalize(tracker, camera)

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # the parked car is detected again on the new stream. Adopted, it is still
    # parked — still not evidence — so nothing opens.
    detect_at(tracker, camera, 4_000)
    assert_receive {:track_updated, %Track{object_id: ^oid, stationary: true}}
    refute_receive {:event_started, %Event{camera_id: ^id}}, 100

    # the control for that refutation: the same detection under an identity the
    # reset really did sever is a new object, which is exactly what a
    # re-minted parked car looks like — and it opens an event on the spot
    detect_at(tracker, camera, 5_000, @far_box)
    assert_receive {:event_started, %Event{camera_id: ^id, labels: [%{object_id: other}]}}
    refute other == oid
  end

  test "a repeat of the current epoch does not end tracks", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    epoch = StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # positive control for the refute below: a real boundary *does* take the
    # track it cut out of the live set, so a tracker that ignored the
    # broadcast entirely cannot pass
    assert live_tracks(tracker) == []
    assert [%Track{object_id: ^first}] = suspended_tracks(tracker)

    # somewhere else in the frame, so this is a new object and not the
    # suspended one resuming
    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    assert_receive {:track_started, %Track{object_id: ^second}}
    refute second == first

    # StreamEpochs may announce one mint twice (degraded caller-side broadcast
    # plus a late server broadcast of the same epoch) — the repeat must not cut
    # the tracks that the first announcement already started
    send(tracker, {:stream_epoch, id, epoch, :source_lost})
    _ = :sys.get_state(tracker)

    # both halves are load-bearing: no final summary went out, *and* the track
    # is still in the tracker. Ending it and starting a new one under the same
    # id would satisfy either one alone.
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^second}] = live_tracks(tracker)

    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{labels: [_, _, %{object_id: ^second}]}}
  end

  test "a repeat of an epoch announced before the first detection does not end tracks", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    # the real order of events for every camera: ffmpeg spawns and mints an
    # epoch, and only then does the plugin produce anything to track
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(tracker)

    detect(tracker, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}
    assert_receive {:track_started, %Track{object_id: ^first}}

    # the same mint announced a second time (degraded caller broadcast plus a
    # late server broadcast). No boundary was crossed, so the track that the
    # camera's very first epoch already covers must survive
    send(tracker, {:stream_epoch, id, epoch, :started})
    _ = :sys.get_state(tracker)

    refute_received {:track_ended, _}
    assert [%Track{object_id: ^first}] = live_tracks(tracker)

    detect(tracker, camera)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: ^first}]}}
  end

  test "an epoch announced before the first detection still yields to a new one", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(tracker)

    detect(tracker, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # elsewhere in the frame: a new object, not the cut one coming back
    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    refute second == first
  end

  test "an epoch older than the one already applied is ignored", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{labels: [%{object_id: first}]}}

    current = StreamEpochs.new_epoch(id, :source_lost)
    _ = :sys.get_state(tracker)

    # positive control: the boundary that was crossed suspended the track it cut
    assert [%Track{object_id: ^first}] = suspended_tracks(tracker)

    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{labels: [_, %{object_id: second}]}}
    assert_receive {:track_started, %Track{object_id: ^second}}
    refute second == first

    # A mint from an earlier millisecond, delivered late: a port's spawn-time
    # ETS pull racing a queued broadcast, or StreamEpochs' degraded
    # caller-side broadcast, which has no ordering relation to the server's.
    # Applying it would roll `current_epoch` back to a stream nothing decodes
    # under, and `stale?/2` would then drop every observation the ports still
    # forward — until the camera's *next* mint, hours away for a healthy one.
    send(tracker, {:stream_epoch, id, Cairn.ULID.generate(1), :source_lost})
    _ = :sys.get_state(tracker)

    assert :sys.get_state(tracker).current_epoch == current

    # not a boundary, so the tracks it did not cut stay uncut — and nothing
    # was told they ended
    refute_received {:track_ended, _}
    assert [%Track{object_id: ^second}] = live_tracks(tracker)

    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{labels: [_, _, %{object_id: ^second}]}}
  end

  test "an observation with no observed_at cannot take the tracker down", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    # unreachable through the codec — both ports stamp it — but `detections/4`
    # is a public, @spec'd API whose type admits nil, and this process holds
    # its camera's whole in-flight event state
    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], observed_at: nil)

    assert_receive {:event_started, %Event{camera_id: ^id} = event}
    assert %DateTime{} = event.started_at
    assert [%{t: +0.0}] = event.labels
  end

  # The old aggregator kept two epochs per camera — a `cameras[id].current_epoch`
  # and a top-level `epochs` map seeding cameras it had no tracker state for.
  # One process per camera collapses them into `current_epoch`, seeded in
  # `init/1` from `Cairn.StreamEpochs`, so "the stopped camera's row is
  # dropped" is now "`current_epoch` is cleared".
  test "a stopped camera's epoch is forgotten", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(tracker)
    assert :sys.get_state(tracker).current_epoch == epoch

    # nothing decodes under a :camera_stopped epoch, so holding it would only
    # keep a dead stream's number for a camera that may never come back
    StreamEpochs.new_epoch(id, :camera_stopped)
    _ = :sys.get_state(tracker)
    assert :sys.get_state(tracker).current_epoch == nil

    # what clearing it buys: the first batch of a stream that came back before
    # its mint was announced is judged against nothing and accepted, where a
    # retained dead epoch would have made `stale?/2` drop it whole. That batch
    # re-seeds the field.
    fresh = Cairn.ULID.generate()
    observe(tracker, camera, [object("person", 0.9, @box)], epoch: fresh)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert :sys.get_state(tracker).current_epoch == fresh
  end

  test "a :camera_stopped epoch ends the tracks and clears current_epoch", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    epoch = StreamEpochs.new_epoch(id, :started)
    _ = :sys.get_state(tracker)

    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: epoch)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert_receive {:track_started, %Track{object_id: first}}

    # a camera's stop and its start are announced by different processes, and
    # on StreamEpochs' degraded caller-side path they have no ordering
    # relation: a stop epoch minted after a live start must not be adopted.
    StreamEpochs.new_epoch(id, :camera_stopped)
    _ = :sys.get_state(tracker)

    # the stream that owned them is over, so the tracks are
    assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :stream_reset}}
    # cleared rather than set to the stop epoch, which is the half that matters:
    # adopting it would make `stale?/2` drop every observation still in flight.
    assert :sys.get_state(tracker).current_epoch == nil

    # ...and observations tagged with the epoch that is actually being decoded
    # are still accepted, which they would not be had the stop epoch been
    # adopted: nothing would then match until an ffmpeg respawn that a healthy
    # camera never has. That batch re-seeds `current_epoch` with it.
    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: epoch)
    assert_receive {:event_updated, %Event{camera_id: ^id}}
    assert :sys.get_state(tracker).current_epoch == epoch
  end

  test "disabling detection ends the live tracks, once", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert_receive {:track_started, %Track{object_id: oid}}

    # nothing advances a track while detection is off, so leaving them live
    # would strand every consumer's entities indefinitely
    Cairn.CameraControl.set(id, %{detection_enabled: false})
    detect(tracker, camera)

    assert_receive {:track_ended,
                    %Track{object_id: ^oid, end_reason: :detection_disabled} = final}

    assert_self_contained(final)
    assert live_tracks(tracker) == []
    assert :sys.get_state(tracker).track_updates == %{}

    # the next disabled batch has nothing left to end
    detect(tracker, camera)
    _ = :sys.get_state(tracker)
    refute_received {:track_ended, _}
  end

  test "checkpoint writes are throttled between an event's first and last", %{
    camera: camera,
    camera_id: id
  } do
    {:ok, clock} = start_supervised({Agent, fn -> 0 end})
    test_pid = self()

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         name: nil,
         monotonic_ms: fn -> Agent.get(clock, & &1) end,
         start_extractor: fn _camera, ev ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, ev, pid})
           {:ok, pid}
         end},
        id: :tracker_checkpoint
      )

    # the event's first frame is never throttled: restore has to see the row
    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: eid}}
    assert [{^id, %Event{id: ^eid, labels: [_]}, _tracks}] = checkpoint(id)

    # inside the window the event grows and the ETS row does not — the copy is
    # the whole event plus the whole track list, per batch
    detect(tracker, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{labels: [_, _]}}
    assert [{^id, %Event{labels: [_]}, _tracks}] = checkpoint(id)

    # a second of wall clock later it catches up in one write
    Agent.update(clock, &(&1 + 1_000))
    detect(tracker, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{labels: [_, _, _]}}
    assert [{^id, %Event{labels: [_, _, _]}, _tracks}] = checkpoint(id)

    # and the other transition that matters for restore is the delete —
    # which `event_ended` does not announce: it is broadcast first, before the
    # extractor is even told, so the state call is the barrier here
    fire(tracker, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}
    _ = :sys.get_state(tracker)
    assert checkpoint(id) == []
  end

  test "a suspended track is checkpointed, and a restore ends it", %{
    camera: camera,
    camera_id: id
  } do
    {:ok, clock} = start_supervised({Agent, fn -> 0 end})
    test_pid = self()

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         name: nil,
         monotonic_ms: fn -> Agent.get(clock, & &1) end,
         start_extractor: fn _camera, ev ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, ev, pid})
           {:ok, pid}
         end},
        id: :tracker_suspended_checkpoint
      )

    detect(tracker, camera)
    assert_receive {:event_started, %Event{camera_id: ^id}}
    assert [{^id, _event, [%Track{object_id: first}]}] = checkpoint(id)

    send(tracker, {:stream_epoch, id, Cairn.ULID.generate(), :source_lost})
    _ = :sys.get_state(tracker)

    # past the checkpoint throttle, so this batch rewrites the row
    Agent.update(clock, &(&1 + 1_000))
    detect(tracker, camera, 0.9, @far_box)
    assert_receive {:event_updated, %Event{camera_id: ^id}}

    # a suspension is a track this process still owes a final summary for, so
    # a checkpoint that left it out would strand it on a crash — the restore
    # ends what the checkpoint holds and nothing else
    assert [{^id, _event, tracks}] = checkpoint(id)
    ids = Enum.map(tracks, & &1.object_id)
    assert first in ids
    assert length(ids) == 2
    assert ids == Enum.sort(ids)

    stop_supervised!(:tracker_suspended_checkpoint)

    start_supervised!(
      {CameraTracker,
       camera_id: id,
       name: nil,
       start_extractor: fn _camera, ev ->
         pid = spawn(fn -> Process.sleep(:infinity) end)
         send(test_pid, {:extractor_started, ev, pid})
         {:ok, pid}
       end},
      id: :tracker_suspended_restore
    )

    # the tracker that could have adopted it died with the process, so the
    # suspension dies here rather than waiting out a window nothing can end
    assert_receive {:track_ended, %Track{object_id: ^first, end_reason: :host_restart}}
  end

  test "event times come from the observation, not from the clock", %{
    tracker: tracker,
    camera: camera
  } do
    # the plugin observed this 10s ago; the queue it sat in must not move the
    # event onto the wall clock of the moment it was finally processed
    past = DateTime.add(DateTime.utc_now(), -10, :second)
    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], observed_at: past)

    assert_receive {:event_started, %Event{} = event}
    assert DateTime.compare(event.started_at, past) == :eq
    assert [%{t: +0.0}] = event.labels
    assert event.trigger.t == +0.0

    # offsets are source-time deltas: 2s later in the stream is t = 2.0
    observe(tracker, camera, [object("person", 0.95, [0.1, 0.1, 0.2, 0.4])],
      observed_at: DateTime.add(past, 2, :second)
    )

    assert_receive {:event_updated, %Event{labels: [_, %{t: 2.0}], trigger: %{t: 2.0}}}
  end

  test "predicted (tracked) objects are not evidence", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    observe(tracker, camera, [object("person", 0.99, [0.1, 0.1, 0.2, 0.4], "tracked")])

    # the cast and its (synchronous) broadcast are done once the mailbox flushes
    :sys.get_state(tracker)
    refute_received {:event_started, %Event{camera_id: ^id}}

    # it still updated the tracker: the detected object that overlaps it
    # inherits that track's id rather than opening a second one
    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])])
    assert_receive {:track_started, %Track{object_id: track_id, source: :host}}
    assert_receive {:event_started, %Event{labels: [%{object_id: ^track_id}]}}
  end

  test "an observation from a stale epoch is dropped", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    send(tracker, {:stream_epoch, id, "epoch_two", :source_lost})

    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: "epoch_one")
    :sys.get_state(tracker)
    refute_received {:event_started, %Event{camera_id: ^id}}

    observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], epoch: "epoch_two")
    assert_receive {:event_started, %Event{camera_id: ^id}}
  end

  test "post-window timeout finalizes", %{tracker: tracker, camera: camera, camera_id: id} do
    detect(tracker, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    fire(tracker, :post_window, eid)

    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid, status: :finalized} = event}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert %DateTime{} = event.ended_at

    # neither message is a barrier for the checkpoint: both are emitted from
    # inside the callback that deletes it, and `event_ended` deliberately goes
    # out first of all. The state call is what waits for the callback.
    _ = :sys.get_state(tracker)
    assert checkpoint(id) == []
  end

  # The extractor's `event_clip_ready` can only follow the finalize cast, so
  # the window closing has to be broadcast *before* the cast — otherwise an
  # extractor that finalizes fast enough announces the media before the event
  # it belongs to has ended. The stub announces from inside `maybe_finalize/3`'s
  # own call stack, which is stronger than reality (the real finalize is a
  # cast, so its latency is strictly positive) and is what makes swapping the
  # two lines a guaranteed failure rather than a race. Two things it cannot
  # cover: both messages come from one process, so it cannot tell "ordered by
  # the code" from "ordered by single-sender FIFO" (the end-to-end test in
  # `EventExtractorTest` does that), and each run pins one artifact kind.
  test "event_ended precedes the clip's readiness even when finalizing is instant", %{
    camera: camera,
    camera_id: id
  } do
    tracker =
      ordering_tracker(id, :tracker_ordering, fn event ->
        EventArtifact.broadcast(:event_clip_ready, %EventArtifact{
          event_id: event.id,
          camera_id: event.camera_id,
          path: "/clip.mp4",
          bytes: 1
        })
      end)

    detect(tracker, camera)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    fire(tracker, :post_window, eid)

    # arrival order, not mere presence: `assert_receive` would match either way
    assert [{:event_ended, %Event{id: ^eid}}, {:event_clip_ready, %EventArtifact{event_id: ^eid}}] =
             [next_lifecycle(id), next_lifecycle(id)]
  end

  # The failure kind takes the *other* branch in the extractor and is the one
  # a stuck consumer depends on most; it must not overtake `event_ended` either.
  test "event_ended precedes the clip's failure even when finalizing is instant", %{
    camera: camera,
    camera_id: id
  } do
    tracker =
      ordering_tracker(id, :tracker_ordering_failed, fn event ->
        EventArtifact.broadcast(:event_clip_failed, %EventArtifact{
          event_id: event.id,
          camera_id: event.camera_id,
          reason: :index_write_failed
        })
      end)

    detect(tracker, camera)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    fire(tracker, :post_window, eid)

    assert [
             {:event_ended, %Event{id: ^eid}},
             {:event_clip_failed, %EventArtifact{event_id: ^eid, reason: :index_write_failed}}
           ] = [next_lifecycle(id), next_lifecycle(id)]
  end

  # A tracker whose "extractor" announces the artifact synchronously, inside
  # the finalize call itself.
  defp ordering_tracker(camera_id, id, announce) do
    test_pid = self()

    start_supervised!(
      {CameraTracker,
       camera_id: camera_id,
       name: nil,
       start_extractor: fn _camera, event ->
         pid = spawn(fn -> Process.sleep(:infinity) end)
         send(test_pid, {:extractor_started, event, pid})
         {:ok, pid}
       end,
       finalize_extractor: fn _pid, event -> announce.(event) end},
      id: id
    )
  end

  # Scoped to this test's camera: the `"events"` topic is global, so another
  # test's leftover timer can drop a foreign lifecycle message between the two
  # this is comparing.
  defp next_lifecycle(camera_id, timeout \\ 2_000) do
    receive do
      {kind, %Event{camera_id: ^camera_id}} = msg
      when kind in [:event_started, :event_updated, :event_ended] ->
        msg

      {kind, %EventArtifact{camera_id: ^camera_id}} = msg
      when kind in [:event_clip_ready, :event_clip_failed] ->
        msg
    after
      timeout -> flunk("no event lifecycle message for #{camera_id} within #{timeout}ms")
    end
  end

  test "max-cap finalizes and the next detection reopens", %{
    tracker: tracker,
    camera: camera,
    camera_id: _id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: first}}

    fire(tracker, :max_event, first)
    assert_receive {:event_ended, %Event{id: ^first}}

    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: second}}
    refute first == second
  end

  test "stale timer for an already-finalized event is ignored", %{
    tracker: tracker,
    camera: camera,
    camera_id: _id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: eid}}

    old_token = token(tracker, :post_token)
    fire(tracker, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}

    send(tracker, {:post_window, eid, old_token})
    refute_receive {:event_ended, _}, 100
  end

  test "an already-delivered timer message from before a reschedule cannot finalize", %{
    tracker: tracker,
    camera: camera,
    camera_id: _id
  } do
    detect(tracker, camera)
    assert_receive {:event_started, %Event{id: eid}}
    stale_token = token(tracker, :post_token)

    # a new detection cancels + reschedules the post window; the stale
    # message may already be in the mailbox — its token no longer matches
    detect(tracker, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid}}

    send(tracker, {:post_window, eid, stale_token})
    refute_receive {:event_ended, _}, 100

    # the current token still finalizes
    fire(tracker, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  test "extractor crash mid-event ends the event as partial", %{
    tracker: tracker,
    camera: camera,
    camera_id: id
  } do
    detect(tracker, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:event_started, _}

    # The stub hands the extractor pid to the test *before* `start_event/5`
    # has monitored it, so a kill delivered inside that window makes
    # `Process.monitor/1` answer `:noproc` — which the DOWN handler reads as a
    # clean finish, and no `:partial` is ever announced. Draining the
    # tracker's mailbox first puts the kill unambiguously after the monitor,
    # which is the case under test.
    _ = :sys.get_state(tracker)
    Process.exit(ex_pid, :kill)

    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert checkpoint(id) == []
  end

  test "orphaned checkpoint entries are ended as partial on restart", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    EventCheckpoint.put(id, event)

    start_supervised!({CameraTracker, camera_id: id, name: nil}, id: :tracker_restore)

    eid = event.id
    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert checkpoint(id) == []
  end

  # The other half of that crash window: the finalize cast was already in the
  # extractor's mailbox, so the extractor finalized the row and announced
  # `event_clip_ready` before exiting. Re-announcing the event as `:partial`
  # here would invert the artifact ordering and mislabel a clean event.
  test "restore leaves an event the extractor already finalized alone", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    {:ok, _} = Events.create_active(event, "clip.mp4")
    {:ok, _} = Events.finalize(%{event | ended_at: DateTime.utc_now()}, 1_024)
    EventCheckpoint.put(id, event)

    start_supervised!({CameraTracker, camera_id: id, name: nil}, id: :tracker_restore_finalized)

    eid = event.id
    refute_receive {:event_ended, %Event{id: ^eid}}, 100
    assert checkpoint(id) == []
  end

  # The registry hands back a corpse for a moment after the extractor exits, so
  # restore can monitor a dead pid — `Process.monitor/1` answers `:noproc`
  # immediately. `:noproc` is not a crash: the event finalized cleanly and must
  # not be re-announced as `:partial`.
  test "restore over a stale extractor entry is a clean finish, not a crash", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    stale = stale_entry(id, {:extractor, event.id})
    refute Process.alive?(stale)
    EventCheckpoint.put(id, event)

    eid = event.id

    log =
      capture_log(fn ->
        start_supervised!({CameraTracker, camera_id: id, name: nil}, id: :tracker_restore_stale)
        refute_receive {:event_ended, %Event{id: ^eid}}, 200
      end)

    refute log =~ "extractor crashed"
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

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         name: nil,
         finalize_extractor: fn pid, ev -> send(test_pid, {:extractor_finalized, pid, ev}) end},
        id: :tracker_reattach
      )

    eid = event.id
    refute_receive {:event_ended, %Event{id: ^eid}}, 100

    fire(tracker, :post_window, eid)
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

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: id,
         name: nil,
         start_extractor: fn _camera, ev ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, ev, pid})
           {:ok, pid}
         end},
        id: :tracker_restore_tracks
      )

    # the tracker that owned it died with the previous process for this
    # camera: it owes a final,
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
    detect(tracker, camera)
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

      tracker =
        start_supervised!(
          {CameraTracker,
           camera_id: id,
           name: nil,
           monotonic_ms: fn -> Agent.get(clock, & &1) end,
           start_extractor: fn _camera, ev ->
             pid = spawn(fn -> Process.sleep(:infinity) end)
             send(test_pid, {:extractor_started, ev, pid})
             {:ok, pid}
           end},
          id: :tracker_throttle
        )

      detect(tracker, camera, 0.6)
      assert_receive {:track_started, %Track{object_id: oid, camera_id: ^id}}

      # same score, no wall clock elapsed: nothing goes out
      detect(tracker, camera, 0.6, [0.12, 0.1, 0.2, 0.4])
      :sys.get_state(tracker)
      refute_received {:track_updated, %Track{object_id: ^oid}}

      # a better score is always worth sending
      detect(tracker, camera, 0.8, [0.12, 0.1, 0.2, 0.4])
      assert_receive {:track_updated, %Track{object_id: ^oid, best_score: 0.8}}

      # ...and so is a second of wall clock, however dull the frame
      detect(tracker, camera, 0.7, [0.12, 0.1, 0.2, 0.4])
      :sys.get_state(tracker)
      refute_received {:track_updated, %Track{object_id: ^oid}}

      Agent.update(clock, &(&1 + 1_000))
      detect(tracker, camera, 0.7, [0.12, 0.1, 0.2, 0.4])
      assert_receive {:track_updated, %Track{object_id: ^oid, score: 0.7, best_score: 0.8}}

      # expiry is media time: 3.1s after the last sighting the track ends
      observe(tracker, camera, [], media_ms: 4_200.0)
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :unseen}}
    end

    test "predictions alone can neither open nor extend an event", %{
      tracker: tracker,
      camera: camera,
      camera_id: id
    } do
      predicted = [object("person", 0.99, [0.1, 0.1, 0.2, 0.4], "tracked")]

      observe(tracker, camera, predicted, media_ms: 1_000.0)
      observe(tracker, camera, predicted, media_ms: 2_000.0)
      :sys.get_state(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      # a detection opens the event; the plugin then keeps predicting the same
      # object, which must not hold the event open
      detect(tracker, camera)
      assert_receive {:event_started, %Event{camera_id: ^id}}

      observe(tracker, camera, predicted, media_ms: 3_000.0)
      observe(tracker, camera, predicted, media_ms: 4_500.0)
      :sys.get_state(tracker)
      refute_received {:event_updated, %Event{camera_id: ^id}}
    end
  end

  describe "stationary tracks" do
    test "a parked object stops holding its event open", %{
      tracker: tracker,
      camera: camera,
      camera_id: id
    } do
      detect_at(tracker, camera, 1_000)
      assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}

      # still moving as far as the tracker is concerned — it has not held the
      # box for `stationary_after_ms` yet — so this one still resets the window
      detect_at(tracker, camera, 2_000)
      assert_receive {:event_updated, %Event{id: ^eid}}
      armed = token(tracker, :post_token)

      detect_at(tracker, camera, 3_000)
      assert [%Track{stationary: true}] = live_tracks(tracker)

      # from here the detections keep coming and stop counting: no update, and
      # — the part that closes the event on schedule — the same post-window
      # timer as before, not a fresh one per frame
      detect_at(tracker, camera, 4_000)
      detect_at(tracker, camera, 5_000)
      :sys.get_state(tracker)
      refute_received {:event_updated, %Event{camera_id: ^id}}
      assert token(tracker, :post_token) == armed

      fire(tracker, :post_window, eid)
      assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    end

    test "a parked object cannot open a fresh event", %{
      tracker: tracker,
      camera: camera,
      camera_id: id
    } do
      {_eid, _oid} = park_and_finalize(tracker, camera)

      # the car is still there and still detected every frame. Before the
      # stationary rule this is where the loop was: evidence -> new event ->
      # post window -> finalize -> evidence, for as long as it stayed parked.
      for media_ms <- [4_000, 5_000, 6_000], do: detect_at(tracker, camera, media_ms)
      :sys.get_state(tracker)

      refute_received {:event_started, %Event{camera_id: ^id}}
      refute_received {:extractor_started, _event, _pid}
    end

    test "an object that starts moving is evidence again", %{
      tracker: tracker,
      camera: camera,
      camera_id: id
    } do
      {_eid, oid} = park_and_finalize(tracker, camera)

      # the smoothed box is the median of the last few detections, so a move
      # reaches it on the third frame at the new position — before that the
      # object is still, by the only measure the host has
      detect_at(tracker, camera, 4_000, @moved_box)
      detect_at(tracker, camera, 5_000, @moved_box)
      :sys.get_state(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      # and the tracker then wants the move *sustained*: the smoothed box
      # fails from 6_000, and the flag holds until that failure has run for
      # `Cairn.Tracker`'s exit window (2_500 ms of media time)
      detect_at(tracker, camera, 6_000, @moved_box)
      detect_at(tracker, camera, 7_000, @moved_box)
      detect_at(tracker, camera, 8_000, @moved_box)
      :sys.get_state(tracker)
      assert [%Track{object_id: ^oid, stationary: true}] = live_tracks(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      detect_at(tracker, camera, 9_000, @moved_box)
      assert [%Track{object_id: ^oid, stationary: false}] = live_tracks(tracker)
      assert_receive {:event_started, %Event{camera_id: ^id, labels: [%{object_id: ^oid}]}}
    end

    test "detector jitter on a parked car opens nothing; leaving still does", %{
      tracker: tracker,
      camera: camera,
      camera_id: id
    } do
      {_eid, oid} = park_and_finalize(tracker, camera, @small_parked_box)

      # The live failure, reproduced end to end. Three jittered frames put the
      # jitter in the median from 6_000 and the car back under it at 9_000 —
      # three failing evaluations, two seconds of them, on a car that has not
      # moved at all. Every one of them used to clear the flag, and clearing it
      # is what made the car evidence again and opened a clip; about ten of
      # them came out of one parked car in a 25-minute quiet window.
      detect_at(tracker, camera, 4_000, @small_jitter_box)
      detect_at(tracker, camera, 5_000, @small_jitter_box)
      detect_at(tracker, camera, 6_000, @small_jitter_box)
      detect_at(tracker, camera, 7_000, @small_parked_box)
      detect_at(tracker, camera, 8_000, @small_parked_box)
      detect_at(tracker, camera, 9_000, @small_parked_box)
      :sys.get_state(tracker)

      # the clip is the failure; the flag is the mechanism, asserted second
      refute_received {:event_started, %Event{camera_id: ^id}}
      refute_received {:extractor_started, _event, _pid}
      assert [%Track{object_id: ^oid, stationary: true}] = live_tracks(tracker)

      # and the quiet is not deafness: the same car actually leaving fails the
      # test from 12_000 and never passes again, so the flag goes at 15_000 and
      # the departure gets its clip — under the same identity, 2.5 s of media
      # later than it would have before, which is well inside the 5 s pre-roll
      # the clip opens with
      for media_ms <- [10_000, 11_000, 12_000, 13_000, 14_000],
          do: detect_at(tracker, camera, media_ms, @small_moved_box)

      :sys.get_state(tracker)
      assert [%Track{object_id: ^oid, stationary: true}] = live_tracks(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      detect_at(tracker, camera, 15_000, @small_moved_box)
      assert [%Track{object_id: ^oid, stationary: false}] = live_tracks(tracker)
      assert_receive {:event_started, %Event{camera_id: ^id, labels: [%{object_id: ^oid}]}}
    end

    test "a transition is published inside the update throttle's window", %{
      camera: camera,
      camera_id: id
    } do
      {:ok, clock} = start_supervised({Agent, fn -> 0 end})
      test_pid = self()

      tracker =
        start_supervised!(
          {CameraTracker,
           camera_id: id,
           name: nil,
           monotonic_ms: fn -> Agent.get(clock, & &1) end,
           start_extractor: fn _camera, ev ->
             pid = spawn(fn -> Process.sleep(:infinity) end)
             send(test_pid, {:extractor_started, ev, pid})
             {:ok, pid}
           end},
          id: :tracker_stationary_throttle
        )

      detect_at(tracker, camera, 1_000)
      assert_receive {:track_started, %Track{object_id: oid, camera_id: ^id}}

      # same score, no wall clock elapsed: the throttle is armed and swallows
      # this update
      detect_at(tracker, camera, 2_000)
      :sys.get_state(tracker)
      refute_received {:track_updated, %Track{object_id: ^oid}}

      # the flip arrives inside that same window and goes out anyway — a
      # consumer must not learn a second late that the object stopped counting
      detect_at(tracker, camera, 3_000)
      assert_receive {:track_updated, %Track{object_id: ^oid, stationary: true}}

      # and exactly once: the tracker pairs the transition with an `:updated`
      # carrying the same summary, which the throttle swallowed
      refute_received {:track_updated, %Track{object_id: ^oid}}
    end
  end

  describe "the record: tier" do
    # Everything over 0.4 reaches the host; only people, and only at 0.6, earn
    # video. No `track:` block: what is under test here is which detections may
    # open or extend an event, which is the `record:` tier's question alone.
    @wire_floor %{"default" => 0.4}
    @record_rules %{"person" => %{min_score: 0.6}}
    @record_policy Map.put(@policy, :record, @record_rules)

    defp record_detect(tracker, camera, score, policy) do
      CameraTracker.detections(
        tracker,
        camera,
        policy,
        observation([object("person", score, [0.1, 0.1, 0.2, 0.4])], [])
      )
    end

    test "opens and extends only at its own threshold",
         %{
           tracker: tracker,
           camera_id: id
         } = ctx do
      camera = %{ctx.camera | min_score: @wire_floor, record: @record_rules}

      # over the wire floor, under record.person: the plugin emitted it and it
      # buys nothing
      record_detect(tracker, camera, 0.5, @record_policy)
      :sys.get_state(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      record_detect(tracker, camera, 0.65, @record_policy)
      assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}
      armed = token(tracker, :post_token)

      # inside the event the same 0.5 detection still counts for nothing: no
      # update, and the post-window timer it would have rearmed is untouched
      record_detect(tracker, camera, 0.5, @record_policy)
      :sys.get_state(tracker)
      refute_received {:event_updated, %Event{camera_id: ^id}}
      assert token(tracker, :post_token) == armed

      record_detect(tracker, camera, 0.65, @record_policy)
      assert_receive {:event_updated, %Event{id: ^eid}}
      assert token(tracker, :post_token) != armed
    end

    test "an absent block is the pre-tier behaviour, and an empty block is not absent",
         %{
           tracker: tracker,
           camera_id: id
         } = ctx do
      camera = %{ctx.camera | min_score: @wire_floor}

      # `record: {}` is a *present* whitelist that lists nothing, so it excludes
      # every label — the opposite of leaving the block out
      empty = Map.put(@policy, :record, %{})
      record_detect(tracker, %{camera | record: %{}}, 0.99, empty)
      :sys.get_state(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      # no `record:` key at all: the floor decides alone, exactly as before the
      # tier existed — 0.5 clears the camera's 0.4 and opens an event
      record_detect(tracker, camera, 0.5, @policy)
      assert_receive {:event_started, %Event{camera_id: ^id, max_scores: %{"person" => 0.5}}}
    end

    test "a config-loaded camera's record tier is always reachable by the plugin", %{
      tracker: tracker,
      camera_id: id
    } do
      # The end-to-end half of the monotonicity rule Config enforces (its own
      # rejections are covered in Cairn.ConfigTest): a tier that resolves below
      # the wire floor names a band the plugin never emits in, so what a valid
      # config guarantees is that every number the record tier answers with is
      # one a detection can actually carry.
      {:ok, config, []} =
        Config.from_map(%{
          "data_dir" => "tmp/cfg_test",
          "udp" => %{"base_port" => 17_000, "range" => 20},
          "cameras" => [
            %{
              "id" => id,
              "rtsp_url" => "rtsp://h/1",
              "min_score" => %{"default" => 0.4},
              "track" => %{"person" => 0.4, "cat" => 0.5},
              "record" => %{"person" => 0.6}
            }
          ]
        })

      [cam] = config.cameras
      policy = Config.policy(config, cam)

      for label <- ["person", "cat", "car"] do
        floor = Map.get(cam.min_score, label) || cam.min_score["default"]

        case Config.tier_threshold(policy.record, label, cam.min_score) do
          # rows without video: no band to be reachable
          :excluded -> assert label in ["cat", "car"]
          threshold -> assert threshold >= floor
        end
      end

      # the plugin emits anywhere over 0.4, and the band between the floor and
      # the tier is the one that earns a row but no video
      record_detect(tracker, cam, 0.5, policy)
      :sys.get_state(tracker)
      refute_received {:event_started, %Event{camera_id: ^id}}

      # and the plugin does reach the tier: a detection exactly at its number
      # opens an event
      record_detect(tracker, cam, 0.6, policy)
      assert_receive {:event_started, %Event{camera_id: ^id}}
    end
  end

  describe "track boxes forwarded to the extractor" do
    # A tracker whose "extractor" is a relay: everything that reaches its
    # mailbox is forwarded to the test in arrival order, which is what makes a
    # refutation below provable rather than a race (see `probe/1`).
    defp relay_tracker(camera_id, id, opts \\ []) do
      test_pid = self()

      start_supervised!(
        {CameraTracker,
         Keyword.merge(
           [
             camera_id: camera_id,
             name: nil,
             start_extractor: fn _camera, event ->
               pid = spawn(fn -> relay(test_pid) end)
               send(test_pid, {:extractor_started, event, pid})
               {:ok, pid}
             end,
             finalize_extractor: fn pid, event ->
               send(test_pid, {:extractor_finalized, pid, event})
             end
           ],
           opts
         )},
        id: id
      )
    end

    defp relay(test_pid) do
      receive do
        msg ->
          send(test_pid, {:extractor_got, msg})
          relay(test_pid)
      end
    end

    # A barrier through the relay: it forwards in FIFO order, so once the probe
    # comes back, anything the camera tracker cast before it is already in this
    # mailbox. `refute_received` after this reads "nothing was sent up to here"
    # instead of "nothing has arrived yet".
    defp probe(extractor) do
      send(extractor, :probe)
      assert_receive {:extractor_got, :probe}
    end

    test "the batch that opens an event is forwarded, and carries what the event refused",
         %{camera: camera, camera_id: id} do
      tracker = relay_tracker(id, :tracker_boxes_open)

      observe(tracker, camera, [
        object("person", 0.9, [0.1, 0.1, 0.2, 0.4]),
        object("cat", 0.2, [0.6, 0.6, 0.1, 0.1])
      ])

      assert_receive {:extractor_started, %Event{camera_id: ^id}, _pid}
      assert_receive {:extractor_got, {:"$gen_cast", {:track_boxes, batch}}}

      # zero, because an event's `started_at` *is* the observed_at of the batch
      # that opened it — the opening batch is the first sample of the path
      assert batch.t_ms == 0

      assert [
               {person_id, "person", [0.1, 0.1, 0.2, 0.4], false},
               {cat_id, "cat", [0.6, 0.6, 0.1, 0.1], false}
             ] = batch.boxes

      assert is_binary(person_id) and String.length(person_id) == 26
      assert is_binary(cat_id) and cat_id != person_id

      # the cat is under `min_score`, so it is in no way this event's evidence
      # — the forwarded batch carrying it anyway is the dense-capture rule
      assert_receive {:event_started, %Event{labels: [%{object_id: ^person_id}]}}
    end

    # The flag the extractor's sidecar turns into a keyframe: `Cairn.TrackPath`
    # keeps every sample whose `stationary` differs from the last kept one, so
    # a `false` hardcoded anywhere on this path would silently cost the format
    # its stationary transitions. Driven through the real tracker rather than
    # asserted on a hand-built tuple — nothing else connects the two.
    test "a track the tracker judges stationary is forwarded with the flag set",
         %{camera: camera, camera_id: id} do
      tracker = relay_tracker(id, :tracker_boxes_stationary)
      # media time, not wall clock, is what the stillness rule measures
      policy = Map.put(@policy, :stationary_after_ms, 1_000)
      t0 = DateTime.utc_now()
      still = [0.1, 0.1, 0.2, 0.4]

      CameraTracker.detections(
        tracker,
        camera,
        policy,
        observation([object("person", 0.9, still)], observed_at: t0, media_ms: 1_000.0)
      )

      assert_receive {:extractor_started, %Event{camera_id: ^id}, _pid}

      assert_receive {:extractor_got,
                      {:"$gen_cast", {:track_boxes, %{boxes: [{oid, "person", ^still, false}]}}}}

      # the same box one `stationary_after_ms` of media time later: the tracker
      # flips the track, and the flip reaches the extractor
      CameraTracker.detections(
        tracker,
        camera,
        policy,
        observation([object("person", 0.9, still)],
          observed_at: DateTime.add(t0, 1, :second),
          media_ms: 2_000.0
        )
      )

      assert_receive {:extractor_got,
                      {:"$gen_cast", {:track_boxes, %{boxes: [{^oid, "person", ^still, true}]}}}}

      # the tracker's own publication of the same flip, so the `true` above is
      # tracker output reaching the extractor and not a shape this test built
      assert_receive {:track_updated, %Track{object_id: ^oid, stationary: true}}
    end

    test "no batch is forwarded before an event has opened",
         %{camera: camera, camera_id: id} do
      tracker = relay_tracker(id, :tracker_boxes_pre_event)

      # under `min_score`: `state.event` is nil and there is no extractor, which
      # is the same catch-all clause the post-event case below falls through
      observe(tracker, camera, [object("cat", 0.2, [0.6, 0.6, 0.1, 0.1])])
      _ = :sys.get_state(tracker)
      refute_received {:extractor_started, _event, _pid}

      # the next batch does open one, and the first thing the relay ever sees
      # is that batch — the idle one was dropped, not held back
      observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])])
      assert_receive {:extractor_started, %Event{camera_id: ^id}, extractor}
      assert_receive {:extractor_got, {:"$gen_cast", {:track_boxes, batch}}}
      assert [{_id, "person", [0.1, 0.1, 0.2, 0.4], false}] = batch.boxes

      probe(extractor)
      refute_received {:extractor_got, {:"$gen_cast", {:track_boxes, _}}}
    end

    test "batches stop at the event's end and none is sent after it",
         %{camera: camera, camera_id: id} do
      tracker = relay_tracker(id, :tracker_boxes_idle)
      t0 = DateTime.utc_now()

      observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])], observed_at: t0)
      assert_receive {:extractor_started, %Event{id: eid}, extractor}
      assert_receive {:extractor_got, {:"$gen_cast", {:track_boxes, %{t_ms: 0}}}}

      observe(tracker, camera, [object("person", 0.9, [0.12, 0.1, 0.2, 0.4])],
        observed_at: DateTime.add(t0, 2, :second)
      )

      assert_receive {:extractor_got, {:"$gen_cast", {:track_boxes, %{t_ms: 2_000}}}}

      fire(tracker, :post_window, eid)
      assert_receive {:event_ended, %Event{id: ^eid}}

      # the window is closed and `state.extractor` cleared, so a batch that would
      # have been forwarded a moment ago now goes nowhere. Under `min_score` so
      # that it opens no second event to forward to.
      observe(tracker, camera, [object("person", 0.2, [0.1, 0.1, 0.2, 0.4])])
      _ = :sys.get_state(tracker)
      probe(extractor)
      refute_received {:extractor_got, {:"$gen_cast", {:track_boxes, _}}}
    end

    # The ordering `forward_boxes/3` documents and the sidecar's completeness
    # rests on: the batch casts and the finalize cast share a sender *and* a
    # receiver, so the BEAM's per-pair FIFO puts every batch in the extractor's
    # mailbox ahead of the finalize. Nothing raises or logs if that stops being
    # true — the sidecar just loses however much of its tail the scheduler
    # decided to — so the arrival order is read back message by message here.
    #
    # `finalize_extractor` is left at the production default deliberately: what
    # is under test is that the real finalize is a cast from *this* process to
    # *that* pid, which a stub that sends to the test process cannot show.
    test "the finalize cast lands behind every batch already sent to the extractor",
         %{camera: camera, camera_id: id} do
      tracker =
        relay_tracker(id, :tracker_boxes_order,
          finalize_extractor: &Cairn.EventExtractor.finalize/2
        )

      t0 = DateTime.utc_now()

      for seconds <- 0..3 do
        observe(tracker, camera, [object("person", 0.9, [0.1, 0.1, 0.2, 0.4])],
          observed_at: DateTime.add(t0, seconds, :second)
        )
      end

      assert_receive {:extractor_started, %Event{id: eid}, _pid}
      fire(tracker, :post_window, eid)

      # every batch, in order, and only then the finalize — a truncation shows
      # up as a missing offset and a reorder as one after `:finalize`
      assert relayed_until_finalize() ==
               [{:boxes, 0}, {:boxes, 1_000}, {:boxes, 2_000}, {:boxes, 3_000}, :finalize]
    end

    # Flunks rather than returning what it has: a comparison against a
    # truncated list would otherwise pass whenever the finalize never arrived.
    defp relayed_until_finalize(acc \\ []) do
      receive do
        {:extractor_got, {:"$gen_cast", {:finalize, _event}}} ->
          Enum.reverse([:finalize | acc])

        {:extractor_got, {:"$gen_cast", {:track_boxes, batch}}} ->
          relayed_until_finalize([{:boxes, batch.t_ms} | acc])
      after
        2_000 ->
          flunk("the extractor was never told to finalize; it got #{inspect(Enum.reverse(acc))}")
      end
    end
  end

  # Everything above drives an unregistered process by hand. These start
  # trackers the way production does — registered in `Cairn.Registry`, under
  # `Cairn.TrackerSupervisor`, both of which the application tree already runs
  # in tests — because what they are about is the routing and the isolation
  # that registration and a process per camera buy. Camera ids are minted per
  # test, so two of them never collide on one registered name.
  #
  # Recording is off throughout: no event opens, so no test here drags a real
  # `Cairn.EventExtractor` (and the ring buffer and index writes behind it) in
  # with it. The checkpoints are seeded instead, which is what a tracker that
  # died mid-event leaves behind anyway.
  describe "one process per camera" do
    setup do
      %{camera_id: registered_camera_id()}
    end

    test "ensure/1 hands two callers the same process", %{camera_id: id} do
      assert {:ok, pid} = CameraTracker.ensure(id)
      # the second caller finds the registration rather than starting a rival:
      # two ports, or a port and the restore sweep, race here on every restart
      assert {:ok, ^pid} = CameraTracker.ensure(id)
      assert Cairn.Registry.whereis(id, :camera_tracker) == pid
    end

    # The reason the aggregator was dissolved. One process per camera means one
    # camera's crash is one camera's outage: nothing another camera is tracking
    # goes with it, and the dead camera recovers from its checkpoint.
    #
    # What it asserts about the recovery is only that it happens and what it
    # emits, never who triggered it — see the comment at `await_revived/2`.
    test "a killed tracker takes only its own camera down, and restores from its checkpoint",
         %{camera_id: dead_id} do
      live_id = registered_camera_id()
      dead_cam = tracked_camera(dead_id)
      live_cam = tracked_camera(live_id)

      assert {:ok, dead} = CameraTracker.ensure(dead_id)
      assert {:ok, live} = CameraTracker.ensure(live_id)

      CameraTracker.detections(dead_cam, @policy, observation([object("person", 0.9, @box)], []))
      CameraTracker.detections(live_cam, @policy, observation([object("person", 0.9, @box)], []))

      assert_receive {:track_started, %Track{camera_id: ^dead_id, object_id: dead_track}}
      assert_receive {:track_started, %Track{camera_id: ^live_id, object_id: live_track}}

      # exactly what the dead tracker was holding, checkpointed the way an open
      # event checkpoints it
      event = %Event{id: Ecto.UUID.generate(), camera_id: dead_id, started_at: DateTime.utc_now()}

      EventCheckpoint.put(
        dead_id,
        event,
        Cairn.Tracker.checkpoint_tracks(:sys.get_state(dead).tracker)
      )

      ref = Process.monitor(dead)
      Process.exit(dead, :kill)
      assert_receive {:DOWN, ^ref, :process, ^dead, :killed}

      # the other camera is untouched — same process, same registration, and
      # the identity it was tracking is still live in it
      assert Process.alive?(live)
      assert Cairn.Registry.whereis(live_id, :camera_tracker) == live

      assert [%Track{object_id: ^live_track}] =
               Cairn.Tracker.live_tracks(:sys.get_state(live).tracker)

      # ...and still answering: the next batch updates that same identity
      # rather than minting a second one
      CameraTracker.detections(live_cam, @policy, observation([object("person", 0.95, @box)], []))
      assert_receive {:track_updated, %Track{camera_id: ^live_id, object_id: ^live_track}}

      # The comeback, driven the way production drives it — through
      # `detections/3`, which routes on `ensure/1`. Nothing here asserts *what*
      # brought the process back: a `:transient` child is restarted by its
      # supervisor and a `:temporary` one by this very call, and the restore is
      # the same either way. The wait is for `ensure/1`'s stale-read window
      # (`.claude/solutions/registry-stale-read-at-decision-sites-20260728.md`):
      # while the registry still answers with the corpse, the batch that
      # follows is dropped by design.
      revived = await_revived(dead_id, dead)
      CameraTracker.detections(dead_cam, @policy, observation([object("person", 0.9, @box)], []))
      _ = :sys.get_state(revived)

      # the replacement restores the checkpoint: the tracker that owned those
      # identities died with the process, so each is ended with its last
      # summary, and the event nothing is extracting is announced partial
      eid = event.id
      assert_receive {:track_ended, %Track{object_id: ^dead_track, end_reason: :host_restart}}
      assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
      assert EventCheckpoint.get(dead_id) == nil

      # and none of that was said about the camera that never crashed
      refute_received {:track_ended, %Track{camera_id: ^live_id}}
    end

    test "a batch addressed to another camera is dropped and said out loud", %{camera_id: id} do
      assert {:ok, tracker} = CameraTracker.ensure(id)
      stranger = tracked_camera(registered_camera_id())

      log =
        capture_log(fn ->
          CameraTracker.detections(
            tracker,
            stranger,
            @policy,
            observation([object("person", 0.9, @box)], [])
          )

          _ = :sys.get_state(tracker)
        end)

      assert log =~ "dropped a batch addressed to #{inspect(stranger.id)}"
      # dropped whole, never folded into this camera's tracker
      refute_received {:track_started, _}
      assert live_tracks(tracker) == []
    end

    # The restore sweep, which exists so a restore does not wait for the camera's
    # next observation. Both branches of `restore_event/3` are covered: an
    # orphan the extractor did not outlive, and an extractor that did.
    test "restore_checkpointed/0 starts a tracker and ends the camera's orphan",
         %{camera_id: id} do
      event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
      track = restored_track(id)
      EventCheckpoint.put(id, event, [track])

      refute Cairn.Registry.whereis(id, :camera_tracker)
      assert :ok = CameraTracker.restore_checkpointed()
      assert is_pid(Cairn.Registry.whereis(id, :camera_tracker))

      eid = event.id
      oid = track.object_id
      assert_receive {:track_ended, %Track{object_id: ^oid, end_reason: :host_restart} = final}
      assert_self_contained(final)
      assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
      assert EventCheckpoint.get(id) == nil
    end

    test "restore_checkpointed/0 re-attaches to a live extractor and can finalize it",
         %{camera_id: id} do
      event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
      extractor = registered_relay(id, event.id)
      EventCheckpoint.put(id, event, [])

      assert :ok = CameraTracker.restore_checkpointed()
      assert tracker = Cairn.Registry.whereis(id, :camera_tracker)

      # re-attached, not orphaned: the event is still open, so the row stays
      # for the *next* restore to find and nothing was announced ended
      eid = event.id
      refute_receive {:event_ended, %Event{id: ^eid}}, 100
      assert {%Event{id: ^eid}, []} = EventCheckpoint.get(id)

      # and the timers it armed on the restored event still finalize it,
      # through the production `finalize_extractor` — a cast to that pid
      send(tracker, {:post_window, eid, :sys.get_state(tracker).post_token})
      assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
      assert_receive {:extractor_got, {:"$gen_cast", {:finalize, %Event{id: ^eid}}}}
      assert Process.alive?(extractor)
    end

    # A camera id no other test can be holding, whose tracker is stopped at the
    # end of this one: `Cairn.TrackerSupervisor.Pool` outlives the test, so a
    # child left running would answer a later `ensure/1` for the same id.
    defp registered_camera_id do
      id = "trkreg_#{System.unique_integer([:positive])}"
      Cairn.CameraControl.set(id, %{recording_enabled: false})

      on_exit(fn ->
        case Cairn.Registry.whereis(id, :camera_tracker) do
          nil -> :ok
          pid -> DynamicSupervisor.terminate_child(Cairn.TrackerSupervisor.Pool, pid)
        end
      end)

      id
    end

    defp tracked_camera(id),
      do: %Camera{id: id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}

    defp restored_track(camera_id) do
      at = DateTime.utc_now()

      %Track{
        object_id: Cairn.ULID.generate(),
        camera_id: camera_id,
        label: "person",
        score: 0.9,
        best_score: 0.9,
        bbox: @box,
        source: :host,
        started_at: at,
        last_seen_at: at
      }
    end

    # An extractor as far as the registry is concerned, and a relay as far as
    # the test is concerned: the real `Cairn.EventExtractor.finalize/2` is a
    # plain cast, so a plain process receives it verbatim.
    defp registered_relay(camera_id, event_id) do
      test_pid = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(Cairn.Registry, {camera_id, {:extractor, event_id}}, nil)
          send(test_pid, {:relay_registered, self()})
          relay(test_pid)
        end)

      assert_receive {:relay_registered, ^pid}
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    # A live tracker for `camera_id` that is not the one that just died.
    # Flunks rather than handing back the corpse: a caller that went on to cast
    # at it would be testing the dropped-batch path instead of the restore.
    defp await_revived(camera_id, dead, attempts \\ 200) do
      with {:ok, pid} <- CameraTracker.ensure(camera_id),
           true <- pid != dead and Process.alive?(pid) do
        pid
      else
        _ when attempts > 0 ->
          Process.sleep(5)
          await_revived(camera_id, dead, attempts - 1)

        other ->
          flunk("no live tracker for #{camera_id} after #{inspect(dead)} died: #{inspect(other)}")
      end
    end
  end
end
