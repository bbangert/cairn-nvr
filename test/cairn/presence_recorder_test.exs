defmodule Cairn.PresenceRecorderTest do
  # No `Cairn.DataCase`: the extractor is stubbed in every test here, so the
  # only things on this lane that reach the event index are restore's orphan
  # check and its stranded-extractor sweep — and with no sandbox connection
  # checked out, every Repo call from this module fails. That is this suite's
  # faithful stand-in for "the database is not answering", the condition
  # restore has to survive because it runs inside `init/1`. The
  # reachable-index answers are covered where an index answers, in
  # `Cairn.PresenceRecorderRestoreTest`.
  #
  # Not async, for two reasons that are the same reason: every case here
  # subscribes to the one `"events"` topic every other presence suite
  # broadcasts on, and several assert on a lifecycle message arriving inside
  # `assert_receive`'s default window — which a loaded scheduler can miss.
  use ExUnit.Case, async: false

  # Every recorder started here logs the sweep it could not run, once — the
  # unreachable index above, working as intended. Captured rather than printed,
  # and still shown for a test that fails; the cases that assert on a log take
  # `capture_log/1` around their own block regardless.
  @moduletag capture_log: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.Config.Camera
  alias Cairn.Pipeline.PresenceSink
  alias Cairn.PresenceFixtures

  import Cairn.PresenceFixtures, only: [frame: 1, object: 2, object: 4, relay: 1]

  alias Cairn.{
    CameraControl,
    Event,
    EventArtifact,
    EventCheckpoint,
    PresenceAggregator,
    PresenceCheckpoint,
    PresenceEvent,
    PresenceLedger,
    PresenceRecorder,
    Registry
  }

  @policy %{pre: 5, post: 10, max: 300, record: nil}
  @box PresenceFixtures.box()

  setup do
    camera_id = "prec_#{System.unique_integer([:positive])}"
    # The checkpoint owner drops a write for a camera the fleet does not name.
    Cairn.SnapshotHelpers.lend_cameras(camera_id)
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}

    # The lane will not open a clip without the ring the extractor drains
    # (`Cairn.PresenceRecorder.start_event/3`); on a real camera it is
    # `Cairn.Camera.Media`'s second child.
    start_supervised!({Cairn.RingBuffer, camera_id: camera_id, pre_window_seconds: 5}, id: :ring)

    Event.subscribe()

    on_exit(fn ->
      PresenceCheckpoint.delete(camera_id)
      EventCheckpoint.delete(camera_id)
    end)

    %{camera_id: camera_id, camera: camera}
  end

  # A recorder registered under the camera's real via-tuple — so the public
  # API, the aggregator and the sink all reach *this* one — with the extractor
  # stubbed out. `policy` overrides ride on top of `@policy`.
  defp recorder(ctx, overrides \\ %{}, id \\ :recorder, extra \\ []) do
    test_pid = self()
    camera = ctx.camera
    policy = Map.merge(@policy, overrides)

    start_supervised!(
      {PresenceRecorder,
       [
         camera_id: ctx.camera_id,
         resolve_policy: fn _camera_id -> {camera, policy} end,
         start_extractor: fn _camera, event, _config ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn pid, event ->
           send(test_pid, {:extractor_finalized, pid, event})
         end
       ] ++ extra},
      id: id
    )
  end

  # The camera's aggregator, started as `Cairn.Camera.Lane` starts it —
  # nothing on the data path creates one. Stopped with `:shutdown` at test end,
  # so its `terminate/2` clear is what closes out the suite's presence.
  defp aggregator(ctx) do
    start_supervised!({PresenceAggregator, camera_id: ctx.camera_id}, id: :aggregator)
  end

  # A clock the test moves by hand, for the seams that measure an age. Shared
  # by every reader in the recorder, which is what a monotonic clock is.
  defp fake_clock do
    counter = :counters.new(1, [])
    {counter, fn -> :counters.get(counter, 1) end}
  end

  defp started(ctx, label \\ "person", score \\ 0.9, zone \\ nil) do
    PresenceRecorder.presence(ctx.camera_id, :presence_started, presence(ctx, label, score, zone))
  end

  defp cleared(ctx, label \\ "person", score \\ 0.9, zone \\ nil) do
    PresenceRecorder.presence(ctx.camera_id, :presence_cleared, presence(ctx, label, score, zone))
  end

  # The ledger row the aggregator inserts before a `presence_started` goes out.
  # The segmenting cap asks the ledger whether a key this process believes
  # present is still announced (`resegment/2`), so a test driving transitions
  # directly has to leave the trace the aggregator would have.
  defp announce(ctx, label, score \\ 0.9, zone \\ nil) do
    PresenceLedger.announced(ctx.camera_id, zone, label, DateTime.utc_now(), score)
    on_exit(fn -> PresenceLedger.cleared(ctx.camera_id, zone, label) end)
  end

  defp presence(ctx, label, score, zone \\ nil) do
    now = DateTime.utc_now()

    %PresenceEvent{
      camera_id: ctx.camera_id,
      zone: zone,
      label: label,
      score: score,
      first_seen_at: now,
      at: now
    }
  end

  defp frames(ctx, objects) do
    PresenceRecorder.frames(ctx.camera_id, %{"default" => 0.5}, [frame(objects)])
  end

  defp fire_retry(recorder) do
    send(recorder, {:retry_open, :sys.get_state(recorder).retry_token})
  end

  defp fire(recorder, kind, event_id) do
    key = if kind == :post_window, do: :post_token, else: :max_token
    send(recorder, {kind, event_id, :sys.get_state(recorder)[key]})
  end

  # The recorder's state once the aggregator's cast for a transition has been
  # made *and* handled. The broadcast a test waits on goes out before that cast
  # (`emit/4`), and from a third process, so it is no barrier for either: the
  # aggregator's own sync proves the cast was sent, the recorder's that it
  # landed.
  defp drained(camera_id, recorder) do
    _ = :sys.get_state(Registry.whereis(camera_id, :presence))
    :sys.get_state(recorder)
  end

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

  test "a qualifying presence_started opens an event", ctx do
    id = ctx.camera_id
    recorder(ctx)

    started(ctx)

    assert_receive {:extractor_started, %Event{id: eid, camera_id: ^id} = event, _pid}
    assert_receive {:event_started, %Event{id: ^eid, status: :active}}
    assert event.max_scores == %{"person" => 0.9}
    assert [%{label: "person", t: +0.0}] = event.labels

    # D-E6: the row is in the recorder's own table and nowhere near the one
    # `CameraTracker.restore_checkpointed/0` spawns trackers from.
    _ = :sys.get_state(Registry.whereis(id, :presence_recorder))
    assert {%Event{id: ^eid}, [{nil, "person"}], extractor, _slots} = PresenceCheckpoint.get(id)
    # the row names the extractor writing the clip: what a restore re-attaches to
    assert is_pid(extractor)
    assert EventCheckpoint.get(id) == nil
  end

  test "a label the record: tier excludes neither opens nor extends", ctx do
    id = ctx.camera_id
    rec = recorder(ctx, %{record: %{"person" => %{min_score: 0.6}}})

    started(ctx, "cat", 0.95)
    _ = :sys.get_state(rec)
    refute_received {:event_started, %Event{camera_id: ^id}}
    assert PresenceCheckpoint.get(id) == nil

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    started(ctx, "cat", 0.95)
    _ = :sys.get_state(rec)
    refute_received {:event_updated, %Event{camera_id: ^id}}

    # …and the excluded label is not holding the event open either: the one
    # qualifying label clearing arms the post window.
    cleared(ctx, "person")
    assert :sys.get_state(rec).post_token != nil
    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}
  end

  # D-E4's third state, and the one `@policy` leaves implicit: no `record:`
  # block at all admits every label the wire floor already let through.
  test "an absent record: block admits everything above the wire floor", ctx do
    id = ctx.camera_id
    rec = recorder(ctx, %{record: nil})

    started(ctx, "cat", 0.6)
    assert_receive {:event_started, %Event{camera_id: ^id, max_scores: %{"cat" => 0.6}}}

    # The floor itself still refuses: the camera's `min_score` default is 0.5,
    # and a `record:`-less camera has nothing else to ask.
    frames(ctx, [object("dog", 0.4), object("fox", 0.55)])
    _ = :sys.get_state(rec)

    scores = :sys.get_state(rec).event.max_scores
    refute Map.has_key?(scores, "dog")
    assert scores["fox"] == 0.55
  end

  # Before any frames cast has landed, the recorder's floors fall back to what
  # the sink would compute — override included. Without that, a lowered
  # runtime min_score confirms presence in the aggregator and then records
  # nothing here.
  test "a confirm ahead of the first frames cast honors a lowered min_score override", ctx do
    id = ctx.camera_id
    CameraControl.put(id, %{min_score: 0.3})
    on_exit(fn -> CameraControl.put(id, %{min_score: nil}) end)

    recorder(ctx)

    # 0.4 is under the camera's configured 0.5 default; the override admits it.
    started(ctx, "person", 0.4)
    assert_receive {:event_started, %Event{camera_id: ^id, max_scores: %{"person" => 0.4}}}
  end

  test "a label below the record: tier's score does not open an event", ctx do
    id = ctx.camera_id
    rec = recorder(ctx, %{record: %{"person" => %{min_score: 0.8}}})

    started(ctx, "person", 0.7)
    _ = :sys.get_state(rec)
    refute_received {:event_started, %Event{camera_id: ^id}}

    started(ctx, "person", 0.85)
    assert_receive {:event_started, %Event{camera_id: ^id}}
  end

  test "a second qualifying label merges into the open event and announces it", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx, "person", 0.9)
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}

    started(ctx, "car", 0.7)

    assert_receive {:event_updated,
                    %Event{id: ^eid, max_scores: %{"person" => 0.9, "car" => 0.7}}}

    # The same label again is not a new one: no second announcement.
    started(ctx, "car", 0.75)
    _ = :sys.get_state(rec)
    refute_received {:event_updated, %Event{camera_id: ^id}}
  end

  test "the event closes a post window after the LAST qualifying label clears", ctx do
    rec = recorder(ctx)

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    started(ctx, "car", 0.7)

    cleared(ctx, "person")
    assert :sys.get_state(rec).post_token == nil

    # Every clear is a checkpoint edge, past the throttle: which keys are
    # left, and whether the close clock is running, is what a restore reads.
    assert {%Event{id: ^eid}, [{nil, "car"}], _extractor, _slots} =
             PresenceCheckpoint.get(ctx.camera_id)

    cleared(ctx, "car")
    assert :sys.get_state(rec).post_token != nil
    assert {%Event{id: ^eid}, [], _extractor, _slots} = PresenceCheckpoint.get(ctx.camera_id)

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized} = ended}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid, status: :finalized}}
    assert %DateTime{} = ended.ended_at

    _ = :sys.get_state(rec)
    assert PresenceCheckpoint.get(ctx.camera_id) == nil
    assert :sys.get_state(rec).event == nil
  end

  # Presence is per `{zone, label}` and the event is one per camera, keyed by
  # label: a second zone seeing a label the event already names extends that one
  # event and announces nothing, and the close clock waits for the last zone.
  test "two zones seeing one label hold a single event open until the last clears", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx, "person", 0.9, "drive")
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    started(ctx, "person", 0.95, "porch")
    state = :sys.get_state(rec)
    assert state.event.id == eid
    assert state.present_labels == MapSet.new([{"drive", "person"}, {"porch", "person"}])
    # the label was already on the event, so there is nothing new to say about it
    refute_received {:event_started, %Event{camera_id: ^id}}
    refute_received {:event_updated, %Event{camera_id: ^id}}
    assert state.event.max_scores == %{"person" => 0.95}

    cleared(ctx, "person", 0.9, "drive")
    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{"porch", "person"}])
    assert state.post_token == nil

    cleared(ctx, "person", 0.95, "porch")
    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  # `nil` — whole-frame presence on a camera with no zones — is a key like any
  # other to this process: the sink clears it the moment a camera gains its
  # first zone, and that cleared must remove only the `nil` key, never the
  # zoned one that may already stand beside it (a zoned confirm can land
  # ahead of the clear on this mailbox).
  test "a zoned key and the whole-frame key for one label are distinct", ctx do
    rec = recorder(ctx)

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    started(ctx, "person", 0.9, "drive")

    assert :sys.get_state(rec).present_labels ==
             MapSet.new([{nil, "person"}, {"drive", "person"}])

    cleared(ctx, "person", 0.9)
    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{"drive", "person"}])
    assert state.event.id == eid
    assert state.post_token == nil
  end

  # The frames the recorder folds are zone-filtered but zone-stripped, so a box
  # cannot be attributed to the zone it stood in: a detection lifts the score of
  # EVERY present key carrying its label. A zone-scoped merge would leave the
  # other zone sitting at its confirm score, which is the score the clip a cap
  # segments would then open at.
  test "a detection lifts the present score of every zone holding its label", ctx do
    rec = recorder(ctx)

    started(ctx, "person", 0.6, "drive")
    assert_receive {:extractor_started, %Event{}, _pid}
    started(ctx, "person", 0.7, "porch")

    assert :sys.get_state(rec).present_scores == %{
             {"drive", "person"} => 0.6,
             {"porch", "person"} => 0.7
           }

    frames(ctx, [object("person", 0.95)])

    assert :sys.get_state(rec).present_scores == %{
             {"drive", "person"} => 0.95,
             {"porch", "person"} => 0.95
           }
  end

  # The extractor's `event_clip_ready` can only follow the finalize cast, so
  # the window closing has to be broadcast *before* it. The stub announces
  # from inside the finalize call itself, which makes swapping the two lines a
  # guaranteed failure rather than a race.
  test "event_ended precedes the finalize even when finalizing is instant", ctx do
    id = ctx.camera_id
    test_pid = self()

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _id -> {ctx.camera, @policy} end,
         start_extractor: fn _camera, event, _config ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, event ->
           EventArtifact.broadcast(:event_clip_ready, %EventArtifact{
             event_id: event.id,
             camera_id: event.camera_id,
             path: "/clip.mp4",
             bytes: 1
           })
         end},
        id: :ordering_recorder
      )

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert {:event_started, %Event{id: ^eid}} = next_lifecycle(id)

    cleared(ctx)
    fire(rec, :post_window, eid)

    # arrival order, not mere presence: `assert_receive` would match either way
    assert [{:event_ended, %Event{id: ^eid}}, {:event_clip_ready, %EventArtifact{event_id: ^eid}}] =
             [next_lifecycle(id), next_lifecycle(id)]
  end

  test "a fresh qualifying start inside the post window cancels it and extends the event", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    cleared(ctx)
    stale = :sys.get_state(rec).post_token
    assert stale != nil

    started(ctx)
    assert :sys.get_state(rec).post_token == nil

    # The timer message that was already on its way is judged against the
    # cleared token and drops.
    send(rec, {:post_window, eid, stale})
    _ = :sys.get_state(rec)
    refute_received {:event_ended, %Event{camera_id: ^id}}
    assert :sys.get_state(rec).event.id == eid
  end

  # Nothing here is announced, so the cap closes and stops — the segmenting
  # half is the test below.
  test "max_event closes the event whether or not anything is still present", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    fire(rec, :max_event, eid)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
    assert :sys.get_state(rec).present_labels |> MapSet.member?({nil, "person"})
  end

  # Ben, 2026-08-20: the cap is segmentation, not a stop. A label that is still
  # present has nothing more to say — presence confirms once and then simply
  # is — so a cap that ended the recording would leave a scene still in front
  # of the camera with one clip and nothing after it.
  test "the cap segments: a presence that outlives it gets the next clip", ctx do
    rec = recorder(ctx)
    announce(ctx, "person")

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: first, started_at: first_at}, _pid}

    # the scene got better-looking while the first clip ran: the segment opens
    # at the best score the label has held, not at the confirm's
    frames(ctx, [object("person", 0.97)])
    assert_receive {:extractor_cast, {:track_boxes, _}}

    fire(rec, :max_event, first)

    assert_receive {:event_ended, %Event{id: ^first, status: :finalized}}
    assert_receive {:extractor_started, %Event{id: second}, _pid}
    assert_receive {:event_started, %Event{id: ^second, max_scores: %{"person" => 0.97}}}
    assert second != first

    state = :sys.get_state(rec)
    assert state.event.id == second
    # the new clip's zero is the boundary, not the original confirm
    assert DateTime.compare(state.event.started_at, first_at) == :gt
    assert [%{label: "person", t: +0.0, score: 0.97}] = state.event.labels
    # and the next cap is armed, so a presence that never leaves keeps segmenting
    assert state.max_token != nil

    assert {%Event{id: ^second}, [{nil, "person"}], _pid, _slots} =
             PresenceCheckpoint.get(ctx.camera_id)
  end

  # The mirror this process keeps of the aggregator's present set is maintained
  # by casts, and a cleared lost in a crash window leaves a label present here
  # forever. With a cap that reopens, that is a clip every max window for as
  # long as the camera streams — so the ledger, which is the aggregator's own
  # announced set, settles the disagreement.
  test "the cap does not segment on a label the ledger no longer announces", ctx do
    rec = recorder(ctx)

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    fire(rec, :max_event, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}

    state = :sys.get_state(rec)
    assert state.event == nil
    refute_received {:event_started, %Event{}}
  end

  # The seeds are re-judged at the boundary, not taken on the strength of the
  # confirm that admitted them a whole clip ago: an operator who raised the
  # floor in between gets no further clip.
  test "the cap does not segment a label the gate no longer admits", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    announce(ctx, "person")

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    CameraControl.put(id, %{min_score: 0.95})
    on_exit(fn -> CameraControl.put(id, %{min_score: nil}) end)

    fire(rec, :max_event, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}

    assert :sys.get_state(rec).event == nil
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  # A real extractor answers `{:ok, pid}` from its `start_link` and only then
  # opens its row and its file, so a failure there — or any death mid-clip —
  # arrives as a DOWN with the event already open. The label that opened it will
  # not confirm again, so without a retry the rest of the stay goes unrecorded.
  test "an extractor that dies mid-event is retried while the presence holds", ctx do
    rec = recorder(ctx)
    announce(ctx, "person")

    started(ctx)
    assert_receive {:extractor_started, %Event{id: first}, ex_pid}
    assert_receive {:event_started, %Event{id: ^first}}
    # the monitor is set once the open has been processed; only then is a kill
    # the case under test
    _ = :sys.get_state(rec)

    Process.exit(ex_pid, :kill)
    assert_receive {:event_ended, %Event{id: ^first, status: :partial}}, 2_000

    # the broadcast goes out inside the same handler that arms the retry, so
    # this read is the barrier for it
    assert :sys.get_state(rec).retry_token != nil
    fire_retry(rec)

    assert_receive {:extractor_started, %Event{id: second}, _pid}
    assert_receive {:event_started, %Event{id: ^second}}
    assert second != first
  end

  # Presence gives one trigger per stay: a confirmed label never confirms again
  # before it has cleared. So an open that fails takes the whole stay's
  # recording with it unless the lane comes back to it — Ben, 2026-08-20: as
  # long as a presence is there, it should keep recording.
  test "an open that failed is retried while the presence holds", ctx do
    id = ctx.camera_id
    test_pid = self()
    camera = ctx.camera
    failing = :counters.new(1, [])
    :counters.put(failing, 1, 1)

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id -> {camera, @policy} end,
         start_extractor: fn _camera, event, _config ->
           if :counters.get(failing, 1) == 1 do
             {:error, :no_event_supervisor}
           else
             pid = relay(test_pid)
             send(test_pid, {:extractor_started, event, pid})
             {:ok, pid}
           end
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :retrying_recorder
      )

    # announced after the start, so the label arrives as a transition rather
    # than as `init/1`'s adoption
    announce(ctx, "person")
    started(ctx, "person", 0.9)

    state = :sys.get_state(rec)
    assert state.event == nil
    assert state.retry_token != nil
    refute_received {:event_started, %Event{camera_id: ^id}}

    :counters.put(failing, 1, 0)
    fire_retry(rec)

    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid, max_scores: %{"person" => 0.9}}}

    state = :sys.get_state(rec)
    assert state.event.id == eid
    # the loop ends with the open it was owed
    assert state.retry_token == nil
  end

  test "the retry loop ends when the presence it was owed to clears", ctx do
    id = ctx.camera_id
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id -> {camera, @policy} end,
         start_extractor: fn _camera, _event, _config -> {:error, :no_event_supervisor} end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :retry_stop_recorder
      )

    announce(ctx, "person")
    started(ctx, "person", 0.9)
    stale = :sys.get_state(rec).retry_token
    assert stale != nil

    cleared(ctx, "person")
    assert :sys.get_state(rec).retry_token == nil

    # the timer message already on its way is judged against the cleared token
    send(rec, {:retry_open, stale})
    _ = :sys.get_state(rec)
    refute_received {:event_started, %Event{camera_id: ^id}}
    assert :sys.get_state(rec).event == nil
  end

  # A retry keeps no clip alive and holds nothing open, so a camera going away
  # takes the recorder with it at once — no timer is waited out.
  test "a graceful stop with only a retry armed exits at once", ctx do
    id = ctx.camera_id
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id -> {camera, @policy} end,
         start_extractor: fn _camera, _event, _config -> {:error, :no_event_supervisor} end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :retry_stop_recorder
      )

    announce(ctx, "person")
    started(ctx, "person", 0.9)
    assert :sys.get_state(rec).retry_token != nil

    ref = Process.monitor(rec)
    :ok = stop_supervised(:retry_stop_recorder)

    assert_receive {:DOWN, ^ref, :process, ^rec, _shutdown}
    refute_received {:event_ended, %Event{camera_id: ^id}}
  end

  # The other half of the boundary's re-read: an operator who narrowed
  # `record:` mid-clip. The policy seam answers from a flag the test flips, the
  # way the config server would answer differently after a reload.
  test "the cap does not segment a label record: no longer admits", ctx do
    id = ctx.camera_id
    test_pid = self()
    camera = ctx.camera
    narrowed = :counters.new(1, [])

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id ->
           record =
             if :counters.get(narrowed, 1) == 1, do: %{"car" => %{min_score: 0.5}}, else: nil

           {camera, %{@policy | record: record}}
         end,
         start_extractor: fn _camera, event, _config ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :narrowing_recorder
      )

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    # announced only now: a row written before the recorder starts would be
    # adopted in `init/1`, and the policy that adoption resolves is the one
    # this test needs to go stale
    announce(ctx, "person")
    :counters.put(narrowed, 1, 1)

    fire(rec, :max_event, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}

    assert :sys.get_state(rec).event == nil
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  # The exit that follows a finalize is expected and silent — but an abnormal
  # one is a clip that failed on its way out, and nothing else reports it. With
  # the cap segmenting, a camera holding presence hands over an extractor this
  # way every max window, so a recurring failure would otherwise be invisible.
  test "an extractor that dies badly after its finalize is reported, not swallowed", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    cleared(ctx)
    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}

    log =
      capture_log(fn ->
        Process.exit(ex_pid, :kill)
        assert await_finalizing_empty(rec) == %{}
      end)

    assert log =~ "extractor exited :killed after finalize"
    assert Process.alive?(rec)
    # the event was announced when it closed; its extractor's death is not a
    # second ending
    refute_received {:event_ended, %Event{camera_id: ^id}}
  end

  # The recorder's monitor and the test's are delivered independently, so the
  # test's own `:DOWN` is no barrier for the recorder having handled its one.
  defp await_finalizing_empty(rec, attempts \\ 100) do
    finalizing = :sys.get_state(rec).finalizing

    cond do
      finalizing == %{} -> finalizing
      attempts > 0 -> Process.sleep(10) && await_finalizing_empty(rec, attempts - 1)
      true -> finalizing
    end
  end

  test "the cap does not segment while recording is switched off", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    announce(ctx, "person")

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    CameraControl.put(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.put(id, %{recording_enabled: true}) end)

    fire(rec, :max_event, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}

    assert :sys.get_state(rec).event == nil
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  test "an extractor that crashes ends the event as partial", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    # The stub hands the pid to the test *before* `start_event/2` has monitored
    # it, so a kill inside that window makes `Process.monitor/1` answer
    # `:noproc` — which the DOWN handler reads as a clean finish. Draining the
    # recorder's mailbox first puts the kill after the monitor, which is the
    # case under test.
    _ = :sys.get_state(rec)
    Process.exit(ex_pid, :kill)

    # 2s like `next_lifecycle/2`: the kill→DOWN→broadcast chain crosses two
    # process deliveries and misses the 100ms default under full-suite load.
    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}, 2_000
    _ = :sys.get_state(rec)
    assert PresenceCheckpoint.get(id) == nil
    assert :sys.get_state(rec).event == nil
  end

  # The reason looks clean; the state says otherwise. CameraTracker's
  # noproc-is-clean rule belongs to an extractor ADOPTED from a checkpoint,
  # which this recorder reads that way too (`Cairn.PresenceRecorderRestoreTest`);
  # one it started itself and that exits :normal mid-event died before its work
  # was done, and a silent clear would strand the active row.
  test "an extractor that exits normally with the event open still ends it partial", ctx do
    id = ctx.camera_id
    test_pid = self()
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id -> {camera, @policy} end,
         start_extractor: fn _camera, event, _config ->
           pid = spawn(fn -> receive(do: (:finish -> :ok)) end)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :normal_exit_recorder
      )

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    # The monitor is set once the recorder has processed the open; only then
    # is the exit the case under test rather than a pre-monitor :noproc.
    _ = :sys.get_state(rec)
    send(ex_pid, :finish)

    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}, 2_000
    _ = :sys.get_state(rec)
    assert PresenceCheckpoint.get(id) == nil
    assert :sys.get_state(rec).event == nil
  end

  # Restore runs inside `init/1`, so an index that will not answer must not
  # cost a camera its lane — the event is announced `:partial` on the strength
  # of the checkpoint alone (`event_ended` is at-least-once, and consumers
  # dedupe on the id). `Cairn.CameraTrackerRestoreTest` proves the same for the
  # tracked lane, and `await_unreachable_index/1` is its guard against the test
  # passing vacuously against a working index.
  test "restore survives an index that will not answer and still ends the orphan", ctx do
    id = ctx.camera_id
    await_unreachable_index()

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: id,
      started_at: DateTime.utc_now(),
      status: :active,
      labels: [],
      max_scores: %{}
    }

    eid = event.id
    PresenceCheckpoint.put!(id, event, [{nil, "person"}], nil)

    log =
      capture_log(fn ->
        rec = recorder(ctx)
        assert Process.alive?(rec)
        assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}, 2_000
        assert PresenceCheckpoint.get(id) == nil
      end)

    assert log =~ "could not consult the event index"
  end

  # This module inherits the tail of an earlier suite's sandbox teardown: while
  # a shared owner is exiting, a Repo call *exits* rather than raising
  # `DBConnection.OwnershipError`. Both are "the index is not answering", but
  # only the second is stable — once the owner has been reaped every call
  # raises, and no owner can appear afterwards because this module never checks
  # one out.
  defp await_unreachable_index(attempts \\ 100) do
    case probe_index() do
      {:raised, %DBConnection.OwnershipError{}} ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(10)
        await_unreachable_index(attempts - 1)

      other ->
        flunk("the event index is still reachable from this test: #{inspect(other)}")
    end
  end

  defp probe_index do
    {:ok, Cairn.Events.get(Ecto.UUID.generate())}
  rescue
    e -> {:raised, e}
  catch
    :exit, reason -> {:exited, reason}
  end

  test "recording disabled refuses to open an event", ctx do
    id = ctx.camera_id
    CameraControl.put(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.put(id, %{recording_enabled: true}) end)

    rec = recorder(ctx)
    started(ctx)

    _ = :sys.get_state(rec)
    refute_received {:event_started, %Event{camera_id: ^id}}
    assert PresenceCheckpoint.get(id) == nil
    # The label is still tracked as present — it is presence state, not an
    # event decision — so the clear that follows is a no-op rather than a
    # stranded label.
    assert MapSet.member?(:sys.get_state(rec).present_labels, {nil, "person"})
  end

  # Switching recording off is a statement about the next event, not about the
  # clip being written: an event already open runs to its normal close.
  test "recording disabled mid-event leaves the open event running", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    CameraControl.put(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.put(id, %{recording_enabled: true}) end)

    frames(ctx, [object("person", 0.95)])
    assert_receive {:extractor_cast, {:track_boxes, _}}
    assert :sys.get_state(rec).event.id == eid

    cleared(ctx)
    fire(rec, :post_window, eid)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
  end

  test "two concurrent same-label boxes forward as two slots with scores", ctx do
    recorder(ctx)
    started(ctx)
    assert_receive {:extractor_started, %Event{}, _pid}

    left = [0.1, 0.2, 0.1, 0.3]
    right = [0.7, 0.2, 0.1, 0.3]

    frames(ctx, [
      object("person", 0.9, "detected", left),
      object("person", 0.6, "detected", right)
    ])

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes}}}

    assert Enum.sort(boxes) ==
             Enum.sort([
               {"person", "person", left, false, 0.9},
               {"person\u001F1", "person", right, false, 0.6}
             ])

    # The next frame flips which subject scores best; the slots must follow
    # POSITION, not rank — the sidecar path is render continuity, and a rank
    # swap would drag each path across the frame.
    frames(ctx, [
      object("person", 0.95, "detected", right),
      object("person", 0.5, "detected", left)
    ])

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes2}}}

    assert Enum.sort(boxes2) ==
             Enum.sort([
               {"person", "person", left, false, 0.5},
               {"person\u001F1", "person", right, false, 0.95}
             ])
  end

  test "a frame over the per-label cap forwards its best four boxes", ctx do
    recorder(ctx)
    started(ctx)
    assert_receive {:extractor_started, %Event{}, _pid}

    dets =
      for {score, i} <- Enum.with_index([0.9, 0.8, 0.7, 0.6, 0.55]),
          do: object("person", score, "detected", [0.15 * i, 0.2, 0.1, 0.3])

    frames(ctx, dets)

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes}}}
    assert length(boxes) == 4
    scores = boxes |> Enum.map(&elem(&1, 4)) |> Enum.sort(:desc)
    assert scores == [0.9, 0.8, 0.7, 0.6]
  end

  test "a slot follows a subject inside the match radius and mints past it", ctx do
    recorder(ctx)
    started(ctx)
    assert_receive {:extractor_started, %Event{}, _pid}

    frames(ctx, [object("person", 0.9, "detected", [0.1, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person", _, _, _, _}]}}}

    # Centre moved 0.2 — inside the 0.25 manhattan radius: same slot.
    frames(ctx, [object("person", 0.9, "detected", [0.3, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person", _, _, _, _}]}}}

    # A jump past the radius is deliberately a NEW path, not a yank: the
    # subject exits left and re-enters right, and dragging the old path
    # across the frame would draw motion that never happened.
    frames(ctx, [object("person", 0.9, "detected", [0.8, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person\u001F1", _, _, _, _}]}}}
  end

  # Greedy in score order would hand the high-score box the slot nearest it
  # and mint a new path for the other box even though a one-to-one match
  # existed for BOTH — the exact discontinuity slots exist to prevent.
  # Matching is maximum-cardinality, so both paths continue.
  test "matching keeps both paths when score order would steal a slot", ctx do
    recorder(ctx)
    started(ctx)
    assert_receive {:extractor_started, %Event{}, _pid}

    a = [0.15, 0.2, 0.1, 0.3]
    b = [0.5, 0.2, 0.1, 0.3]
    frames(ctx, [object("person", 0.9, "detected", a), object("person", 0.6, "detected", b)])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes}}}

    assert Enum.sort(boxes) ==
             Enum.sort([
               {"person", "person", a, false, 0.9},
               {"person\u001F1", "person", b, false, 0.6}
             ])

    # The high scorer at centre 0.35 is in radius of BOTH slots and nearer
    # slot 0 (0.20); the low scorer at centre 0.05 reaches only slot 0.
    a2 = [0.0, 0.2, 0.1, 0.3]
    b2 = [0.3, 0.2, 0.1, 0.3]
    frames(ctx, [object("person", 0.95, "detected", b2), object("person", 0.5, "detected", a2)])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes2}}}

    assert Enum.sort(boxes2) ==
             Enum.sort([
               {"person", "person", a2, false, 0.5},
               {"person\u001F1", "person", b2, false, 0.95}
             ])
  end

  test "frames are dropped on the floor while no event is open", ctx do
    rec = recorder(ctx)

    frames(ctx, [object("person", 0.9)])

    state = :sys.get_state(rec)
    assert state.event == nil
    refute_received {:extractor_cast, _}
  end

  # The batch that confirms presence reaches the recorder BEFORE the transition
  # it causes: the sink casts the frames here and the same batch's `observed`
  # to the aggregator, which only then confirms. Discarding it would leave an
  # event opened behind a closing motion gate with no trigger box and no
  # sidecar until motion resumed.
  test "the batch held while idle is replayed into the event it opens", ctx do
    rec = recorder(ctx)

    frames(ctx, [object("person", 0.95)])
    refute_received {:extractor_cast, _}

    started(ctx)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    # No frames call followed the open: these boxes are the retained batch's.
    assert_receive {:extractor_cast,
                    {:track_boxes, %{boxes: [{"person", "person", @box, false, 0.95}]}}}

    state = :sys.get_state(rec)
    assert %{label: "person", score: 0.95, bbox: @box} = state.event.trigger
    assert state.pending == nil
  end

  # The walk-through case, and the reason the trigger's `t` is signed. Presence
  # confirms on the SECOND sighting, so the event's t=0 is the confirm while
  # the batch that caused it was captured earlier — and that batch is usually
  # where the best-scoring detection is. Clamping its `t` to zero pointed the
  # snapshot at a frame up to a confirm-window later, drawing the box where the
  # person had already left.
  test "a trigger replayed from before the confirm keeps its negative time", ctx do
    rec = recorder(ctx)

    t_zero = DateTime.utc_now()
    captured_ms = DateTime.to_unix(t_zero, :millisecond) - 1_500

    PresenceRecorder.frames(ctx.camera_id, %{"default" => 0.5}, [
      %{
        pts: 0,
        observed_at_ms: captured_ms,
        inferred: true,
        infer_us: 0,
        objects: [object("person", 0.95)]
      }
    ])

    # `first_seen_at` is what a confirm dates the event from, so t=0 is exactly
    # `t_zero` and the replayed frame's offset is exactly -1.5 s.
    PresenceRecorder.presence(ctx.camera_id, :presence_started, %PresenceEvent{
      camera_id: ctx.camera_id,
      label: "person",
      score: 0.9,
      first_seen_at: t_zero,
      at: t_zero
    })

    assert_receive {:extractor_started, %Event{}, _pid}

    # The sidecar's axis was always signed; the trigger now agrees with it.
    assert_receive {:extractor_cast, {:track_boxes, %{t_ms: -1_500}}}

    assert %{label: "person", score: 0.95, t: -1.5} = :sys.get_state(rec).event.trigger
  end

  # The other half of the asymmetry: the panel's timeline is a percentage of
  # the clip's duration, so an entry before t=0 would render off the left edge.
  test "the label timeline still clamps where the trigger does not", ctx do
    rec = recorder(ctx)

    t_zero = DateTime.utc_now()
    captured_ms = DateTime.to_unix(t_zero, :millisecond) - 1_500

    PresenceRecorder.frames(ctx.camera_id, %{"default" => 0.5}, [
      %{
        pts: 0,
        observed_at_ms: captured_ms,
        inferred: true,
        infer_us: 0,
        objects: [object("person", 0.95)]
      }
    ])

    PresenceRecorder.presence(ctx.camera_id, :presence_started, %PresenceEvent{
      camera_id: ctx.camera_id,
      label: "person",
      score: 0.9,
      first_seen_at: t_zero,
      at: t_zero
    })

    assert_receive {:extractor_started, %Event{}, _pid}

    event = :sys.get_state(rec).event
    assert event.trigger.t == -1.5
    # Non-empty first: an empty list satisfies Enum.all?/2 vacuously, and the
    # replayed batch plus the confirm must have produced entries here.
    assert [_ | _] = event.labels
    assert Enum.all?(event.labels, &(&1.t >= 0))
  end

  test "a batch older than the replay bound is dropped, not replayed", ctx do
    {clock, monotonic_ms} = fake_clock()
    rec = recorder(ctx, %{}, :stale_pending_recorder, monotonic_ms: monotonic_ms)

    frames(ctx, [object("person", 0.95)])
    _ = :sys.get_state(rec)

    # Past the bound: whatever that batch saw, this event was not opened for it.
    :counters.put(clock, 1, 10_000)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    state = :sys.get_state(rec)
    refute_received {:extractor_cast, _}
    assert state.event.trigger == nil
    assert state.pending == nil
  end

  test "while an event is open, frames feed boxes, the trigger and the label timeline", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    frames(ctx, [object("person", 0.95), object("car", 0.6, "detected", [0.5, 0.5, 0.1, 0.1])])

    # Boxes are unfiltered and label-keyed (D-E5b), each carrying its score;
    # cross-label order is no contract now that slots key concurrent boxes.
    assert_receive {:extractor_cast, {:track_boxes, %{t_ms: t_ms, boxes: boxes}}}
    assert t_ms >= 0

    assert Enum.sort(boxes) ==
             Enum.sort([
               {"person", "person", @box, false, 0.95},
               {"car", "car", [0.5, 0.5, 0.1, 0.1], false, 0.6}
             ])

    # A new label rides in on the frame, so the event announces it…
    assert_receive {:event_updated, %Event{id: ^eid, max_scores: %{"car" => 0.6}}}

    event = :sys.get_state(rec).event
    assert event.max_scores == %{"person" => 0.95, "car" => 0.6}
    assert %{label: "person", score: 0.95, bbox: @box} = event.trigger
    assert Enum.any?(event.labels, &match?(%{label: "car", score: 0.6}, &1))
  end

  # The trigger is a box for `Cairn.Snapshot` to draw, so a detection without
  # one cannot hold it however well it scores — it still counts as evidence.
  test "a boxless detection joins the labels but never becomes the trigger", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    boxless = %{object("cat", 0.99) | bbox: nil}
    frames(ctx, [boxless, object("person", 0.6)])

    event = :sys.get_state(rec).event
    assert event.max_scores["cat"] == 0.99
    assert %{label: "person", score: 0.6, bbox: @box} = event.trigger
  end

  test "a frame's predicted objects are drawn but are not evidence", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    frames(ctx, [object("car", 0.95, "tracked", [0.5, 0.5, 0.1, 0.1])])

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"car", "car", _, false, nil}]}}}

    event = :sys.get_state(rec).event
    refute Map.has_key?(event.max_scores, "car")
    assert event.trigger == nil
  end

  test "a cleared for a label the tier never admitted does not arm the post window", ctx do
    rec = recorder(ctx, %{record: %{"person" => %{min_score: 0.6}}})

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    cleared(ctx, "cat", 0.99)
    assert :sys.get_state(rec).post_token == nil
  end

  # Decision 1 of the supervision design, and the contract the reaper risked:
  # the process that cast the boxes is the process that casts the finalize, so
  # BEAM per-pair ordering keeps every box ahead of it. Both casts go to the
  # one relay here, which is what makes the order observable.
  test "boxes cast before a supervisor shutdown reach the extractor ahead of the finalize", ctx do
    id = ctx.camera_id
    test_pid = self()

    rec =
      start_supervised!(
        {
          PresenceRecorder,
          # The real seam is `Cairn.EventExtractor.finalize/2`, a cast to the
          # same pid the boxes went to — stubbing it as anything else would
          # test a different ordering than the one that ships.
          camera_id: id,
          resolve_policy: fn _camera_id -> {ctx.camera, @policy} end,
          start_extractor: fn _camera, event, _config ->
            pid = relay(test_pid)
            send(test_pid, {:extractor_started, event, pid})
            {:ok, pid}
          end,
          finalize_extractor: fn pid, event -> GenServer.cast(pid, {:finalize, event}) end
        },
        id: :ordering_recorder
      )

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, _relay}

    frames(ctx, [object("person", 0.9)])
    frames(ctx, [object("person", 0.95)])
    # both casts handled before the shutdown, which comes from the supervisor
    # and not from this process: nothing orders the two otherwise
    _ = :sys.get_state(rec)

    ref = Process.monitor(rec)
    :ok = stop_supervised(:ordering_recorder)
    assert_receive {:DOWN, ^ref, :process, ^rec, _shutdown}

    assert_receive {:extractor_cast, {:track_boxes, _first}}
    assert_receive {:extractor_cast, {:track_boxes, _second}}
    assert_receive {:extractor_cast, {:finalize, %Event{id: ^eid, status: :finalized}}}
    # nothing after the finalize: the tail of the sidecar is not truncated,
    # and no box arrives behind it either
    refute_received {:extractor_cast, _anything}
  end

  # The post window is cut short deliberately (decision 2): a camera being
  # switched off or deleted ends its clip now rather than up to 600 s later.
  test "a graceful stop finalizes an open event at once, without waiting on the extractor", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    ref = Process.monitor(rec)
    :ok = stop_supervised(:recorder)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized, camera_id: ^id}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
    assert_receive {:DOWN, ^ref, :process, ^rec, _shutdown}
    # the row the replacement would have restored from is gone with the event
    assert PresenceCheckpoint.get(id) == nil
  end

  test "a graceful stop with nothing open ends no event", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    ref = Process.monitor(rec)

    :ok = stop_supervised(:recorder)

    assert_receive {:DOWN, ^ref, :process, ^rec, _shutdown}
    refute_received {:event_ended, %Event{camera_id: ^id}}
  end

  # A crash is not a stop: the replacement restores from the checkpoint and
  # re-adopts the extractor, so a crashing recorder must not finalize.
  test "a crash finalizes nothing", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    ref = Process.monitor(rec)
    Process.exit(rec, :kill)
    assert_receive {:DOWN, ^ref, :process, ^rec, :killed}

    refute_received {:extractor_finalized, ^ex_pid, _event}
  end

  # Decision 6: the refresh reaches the lane, and it lands at the next event
  # boundary — an in-flight event keeps the windows it opened with.
  test "a refresh gives the NEXT event the new policy, not the running one", ctx do
    id = ctx.camera_id
    test_pid = self()
    windows = :counters.new(1, [])
    :counters.add(windows, 1, 10)
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id ->
           {camera, %{@policy | post: :counters.get(windows, 1)}}
         end,
         start_extractor: fn _camera, event, _config ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :refresh_recorder
      )

    started(ctx)
    assert_receive {:extractor_started, %Event{id: first}, _pid}
    assert :sys.get_state(rec).policy.post == 10

    :counters.put(windows, 1, 42)
    PresenceRecorder.refresh(id, camera, %Cairn.Config{})
    assert :sys.get_state(rec).policy.post == 42

    # the open event keeps the window it armed with: closing it uses the
    # timer already scheduled, and only the event after it sees 42
    cleared(ctx)
    fire(rec, :post_window, first)
    assert_receive {:event_ended, %Event{id: ^first, status: :finalized}}

    started(ctx)
    assert_receive {:extractor_started, %Event{id: second}, _pid}
    assert second != first
    assert :sys.get_state(rec).policy.post == 42
  end

  # The same contract on a real timer, which is the only way to see it: the
  # test above fires the post window by hand, so it cannot tell which duration
  # was armed. The window an event closes on is the one it OPENED with, so a
  # refresh that lengthens it mid-clip must not stretch the clip.
  test "a refresh does not stretch the open event's post window", ctx do
    id = ctx.camera_id
    test_pid = self()
    windows = :counters.new(1, [])
    :counters.add(windows, 1, 1)
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id ->
           {camera, %{@policy | post: :counters.get(windows, 1)}}
         end,
         start_extractor: fn _camera, event, _config ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :window_recorder
      )

    started(ctx)
    assert_receive {:extractor_started, %Event{id: first}, _pid}
    assert :sys.get_state(rec).event_policy.post == 1

    # thirty times longer, landing while the clip is being written
    :counters.put(windows, 1, 30)
    PresenceRecorder.refresh(id, camera, %Cairn.Config{})
    assert :sys.get_state(rec).policy.post == 30
    assert :sys.get_state(rec).event_policy.post == 1

    cleared(ctx)
    # the real timer, unfired by this test: one second, not thirty
    assert_receive {:event_ended, %Event{id: ^first, status: :finalized}}, 3_000

    # and the event after it opens under the refreshed window
    started(ctx)
    assert_receive {:extractor_started, %Event{id: second}, _pid}
    assert second != first
    assert :sys.get_state(rec).event_policy.post == 30
  end

  # The floors ride in with the frames, from a different sender than the
  # transitions: a confirm can land ahead of the batch that produced it. An
  # operator LOWERING the runtime floor mid-scene would otherwise have the
  # confirm judged against the floor that was in force one batch ago — and a
  # refusal there loses the event, not a frame, because a label already
  # `:present` never confirms again until it clears.
  test "a transition is judged against the live override, not the last batch's floors", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    frames(ctx, [object("person", 0.9)])
    assert :sys.get_state(rec).floors == %{"default" => 0.5}

    CameraControl.put(id, %{min_score: 0.3})
    on_exit(fn -> CameraControl.put(id, %{min_score: nil}) end)

    started(ctx, "person", 0.4)

    assert_receive {:event_started, %Event{camera_id: ^id, max_scores: %{"person" => 0.4}}}
  end

  # -- wiring -----------------------------------------------------------------

  test "the aggregator's confirm and clear reach the recorder", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    aggregator(ctx)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{{nil, "person"} => 0.6})
    PresenceAggregator.observed(id, base + 500, %{{nil, "person"} => 0.9})

    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id}}
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    PresenceAggregator.observed(id, base + 1_000, %{})
    PresenceAggregator.observed(id, base + 7_000, %{})

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}
    assert drained(id, rec).post_token != nil

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  # `detection_disabled` flushes presence through the same emit, so its
  # cleareds are ordinary ones: the event closes on its post window rather
  # than being cut short at the flush.
  test "a detection_disabled flush closes the event through the normal post window", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    aggregator(ctx)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{{nil, "person"} => 0.6})
    PresenceAggregator.observed(id, base + 500, %{{nil, "person"} => 0.9})
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    PresenceAggregator.detection_disabled(id)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}
    state = drained(id, rec)
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil

    # the clip is still being written: nothing has ended it
    refute_received {:event_ended, %Event{camera_id: ^id}}

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
  end

  # Reverse start order: the tree stops the aggregator first, then the
  # recorder. The aggregator's `terminate/2` clear therefore reaches a live
  # recorder, which treats it as an ordinary transition — the close clock
  # starts, the event does not end there — and the recorder's own stop is what
  # finalizes, a moment later rather than a post window later.
  test "stopping the lane in reverse order clears presence, then ends the event", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    agg = aggregator(ctx)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{{nil, "person"} => 0.6})
    PresenceAggregator.observed(id, base + 500, %{{nil, "person"} => 0.9})
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id}}

    agg_ref = Process.monitor(agg)
    :ok = stop_supervised(:aggregator)
    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}
    assert_receive {:DOWN, ^agg_ref, :process, ^agg, _shutdown}

    # the recorder heard it: no keys left, close clock running, clip still open
    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil
    refute_received {:event_ended, %Event{camera_id: ^id}}

    ref = Process.monitor(rec)
    :ok = stop_supervised(:recorder)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
    assert_receive {:DOWN, ^ref, :process, ^rec, _shutdown}
  end

  test "the sink forwards its inferred frames to the recorder", ctx do
    recorder(ctx)
    aggregator(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    {[], state} =
      PresenceSink.handle_init(%{}, struct(PresenceSink, camera: ctx.camera))

    {[], _state} =
      PresenceSink.handle_buffer(
        :input,
        %Membrane.Buffer{
          payload: <<>>,
          metadata: %{observations: [frame([object("person", 0.9)])]}
        },
        %{},
        state
      )

    assert_receive {:extractor_cast,
                    {:track_boxes, %{boxes: [{"person", "person", @box, false, 0.9}]}}}
  end

  test "a transition for a camera with no recorder is dropped, not raised", ctx do
    assert PresenceRecorder.presence(
             "prec_absent",
             :presence_started,
             presence(ctx, "person", 0.9)
           ) ==
             :ok

    assert PresenceRecorder.frames("prec_absent", %{}, [frame([])]) == :ok
  end
end
