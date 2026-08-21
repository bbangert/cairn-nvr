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
  @box [0.1, 0.1, 0.2, 0.4]

  setup do
    camera_id = "prec_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}

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
         start_extractor: fn _camera, event ->
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

  # A clock the test moves by hand, for the seams that measure an age. Shared
  # by every reader in the recorder, which is what a monotonic clock is.
  defp fake_clock do
    counter = :counters.new(1, [])
    {counter, fn -> :counters.get(counter, 1) end}
  end

  # Stands in for `Cairn.EventExtractor`: stays alive and hands every cast it
  # is sent to the test, which is how the `{:track_boxes, _}` stream is
  # observed. Unlinked, so a test that kills it does not take itself down —
  # a monitor on the test process is what reaps it instead.
  defp relay(test_pid) do
    spawn(fn ->
      Process.monitor(test_pid)
      relay_loop(test_pid)
    end)
  end

  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", message} ->
        send(test_pid, {:extractor_cast, message})
        relay_loop(test_pid)

      {:DOWN, _ref, :process, ^test_pid, _reason} ->
        :ok

      _other ->
        relay_loop(test_pid)
    end
  end

  defp started(ctx, label \\ "person", score \\ 0.9) do
    PresenceRecorder.presence(ctx.camera_id, :presence_started, presence(ctx, label, score))
  end

  defp cleared(ctx, label \\ "person", score \\ 0.9) do
    PresenceRecorder.presence(ctx.camera_id, :presence_cleared, presence(ctx, label, score))
  end

  # The ledger row the aggregator inserts before a `presence_started` goes out.
  # The segmenting cap asks the ledger whether a label this process believes
  # present is still announced (`resegment/2`), so a test driving transitions
  # directly has to leave the trace the aggregator would have.
  defp announce(ctx, label, score \\ 0.9) do
    PresenceLedger.announced(ctx.camera_id, label, DateTime.utc_now(), score)
    on_exit(fn -> PresenceLedger.cleared(ctx.camera_id, label) end)
  end

  defp presence(ctx, label, score) do
    now = DateTime.utc_now()

    %PresenceEvent{
      camera_id: ctx.camera_id,
      label: label,
      score: score,
      first_seen_at: now,
      at: now
    }
  end

  defp frames(ctx, objects) do
    PresenceRecorder.frames(ctx.camera_id, %{"default" => 0.5}, [frame(objects)])
  end

  defp frame(objects) do
    %{
      pts: 0,
      observed_at_ms: DateTime.to_unix(DateTime.utc_now(), :millisecond),
      inferred: true,
      infer_us: 0,
      objects: objects
    }
  end

  defp object(label, score, bbox \\ @box, kind \\ "detected") do
    %{label: label, score: score, bbox: bbox, track_id: nil, observation_kind: kind}
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
    assert {%Event{id: ^eid}, ["person"], extractor} = PresenceCheckpoint.get(id)
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
    CameraControl.set(id, %{min_score: 0.3})
    on_exit(fn -> CameraControl.set(id, %{min_score: nil}) end)

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

    # Every clear is a checkpoint edge, past the throttle: which labels are
    # left, and whether the close clock is running, is what a restore reads.
    assert {%Event{id: ^eid}, ["car"], _extractor} = PresenceCheckpoint.get(ctx.camera_id)

    cleared(ctx, "car")
    assert :sys.get_state(rec).post_token != nil
    assert {%Event{id: ^eid}, [], _extractor} = PresenceCheckpoint.get(ctx.camera_id)

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized} = ended}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid, status: :finalized}}
    assert %DateTime{} = ended.ended_at

    _ = :sys.get_state(rec)
    assert PresenceCheckpoint.get(ctx.camera_id) == nil
    assert :sys.get_state(rec).event == nil
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
         start_extractor: fn _camera, event ->
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
    assert :sys.get_state(rec).present_labels |> MapSet.member?("person")
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
    assert {%Event{id: ^second}, ["person"], _pid} = PresenceCheckpoint.get(ctx.camera_id)
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

    CameraControl.set(id, %{min_score: 0.95})
    on_exit(fn -> CameraControl.set(id, %{min_score: nil}) end)

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
         start_extractor: fn _camera, event ->
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
         start_extractor: fn _camera, _event -> {:error, :no_event_supervisor} end,
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

  # Nothing about a pending retry outranks a camera that is going away — the
  # latch only defers to an event already being written, and there is none.
  test "a retire stops a recorder that is holding nothing but a retry", ctx do
    id = ctx.camera_id
    camera = ctx.camera

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id -> {camera, @policy} end,
         start_extractor: fn _camera, _event -> {:error, :no_event_supervisor} end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :retry_retire_recorder
      )

    announce(ctx, "person")
    started(ctx, "person", 0.9)
    assert :sys.get_state(rec).retry_token != nil

    ref = Process.monitor(rec)
    PresenceRecorder.retire(id)

    assert_receive {:DOWN, ^ref, :process, ^rec, :normal}
  end

  # The moduledoc's named exception to segmentation: a camera on its way out
  # gets no further clips. Its aggregator's flushed cleareds may still be in
  # flight, and a segment opened here would be a clip for a camera that is
  # gone by the time it closes.
  test "a retiring recorder does not segment at the cap", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    announce(ctx, "person")

    started(ctx, "person", 0.9)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    ref = Process.monitor(rec)
    PresenceRecorder.retire(id)
    assert :sys.get_state(rec).retiring?
    # the label is still present and still announced — everything a segment
    # needs except the camera
    assert MapSet.member?(:sys.get_state(rec).present_labels, "person")

    fire(rec, :max_event, eid)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    refute_received {:extractor_started, %Event{}, _pid}
    refute_received {:event_started, %Event{camera_id: ^id}}
    # and the latch is paid the moment the event it outranked has closed
    assert_receive {:DOWN, ^ref, :process, ^rec, :normal}
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
         start_extractor: fn _camera, event ->
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

    CameraControl.set(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.set(id, %{recording_enabled: true}) end)

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
         start_extractor: fn _camera, event ->
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
    PresenceCheckpoint.put(id, event, ["person"], nil)

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
    CameraControl.set(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.set(id, %{recording_enabled: true}) end)

    rec = recorder(ctx)
    started(ctx)

    _ = :sys.get_state(rec)
    refute_received {:event_started, %Event{camera_id: ^id}}
    assert PresenceCheckpoint.get(id) == nil
    # The label is still tracked as present — it is presence state, not an
    # event decision — so the clear that follows is a no-op rather than a
    # stranded label.
    assert MapSet.member?(:sys.get_state(rec).present_labels, "person")
  end

  # Switching recording off is a statement about the next event, not about the
  # clip being written: an event already open runs to its normal close.
  test "recording disabled mid-event leaves the open event running", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    CameraControl.set(id, %{recording_enabled: false})
    on_exit(fn -> CameraControl.set(id, %{recording_enabled: true}) end)

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
    frames(ctx, [object("person", 0.9, left), object("person", 0.6, right)])

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes}}}

    assert Enum.sort(boxes) ==
             Enum.sort([
               {"person", "person", left, false, 0.9},
               {"person/1", "person", right, false, 0.6}
             ])

    # The next frame flips which subject scores best; the slots must follow
    # POSITION, not rank — the sidecar path is render continuity, and a rank
    # swap would drag each path across the frame.
    frames(ctx, [object("person", 0.95, right), object("person", 0.5, left)])

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: boxes2}}}

    assert Enum.sort(boxes2) ==
             Enum.sort([
               {"person", "person", left, false, 0.5},
               {"person/1", "person", right, false, 0.95}
             ])
  end

  test "a frame over the per-label cap forwards its best four boxes", ctx do
    recorder(ctx)
    started(ctx)
    assert_receive {:extractor_started, %Event{}, _pid}

    dets =
      for {score, i} <- Enum.with_index([0.9, 0.8, 0.7, 0.6, 0.55]),
          do: object("person", score, [0.15 * i, 0.2, 0.1, 0.3])

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

    frames(ctx, [object("person", 0.9, [0.1, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person", _, _, _, _}]}}}

    # Centre moved 0.2 — inside the 0.25 manhattan radius: same slot.
    frames(ctx, [object("person", 0.9, [0.3, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person", _, _, _, _}]}}}

    # A jump past the radius is deliberately a NEW path, not a yank: the
    # subject exits left and re-enters right, and dragging the old path
    # across the frame would draw motion that never happened.
    frames(ctx, [object("person", 0.9, [0.8, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person/1", _, _, _, _}]}}}
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

    frames(ctx, [object("person", 0.95), object("car", 0.6, [0.5, 0.5, 0.1, 0.1])])

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

    frames(ctx, [object("car", 0.95, [0.5, 0.5, 0.1, 0.1], "tracked")])

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

  # A config `changed` restart stops the camera (which retires the lane) and
  # starts it again still tier 1. The recorder that outlived the stop for its
  # open event is the one the new session's `ensure/1` finds — and if the latch
  # survived that adoption, the close would stop the process and nothing would
  # ever call `ensure/1` again: every later transition would drop at the
  # registry lookup and the camera would record nothing more.
  test "a camera that comes back adopts its latched recorder and keeps the lane", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: first}, _pid}

    PresenceRecorder.retire(id)
    assert :sys.get_state(rec).retiring?

    assert {:ok, ^rec} = PresenceRecorder.ensure(id)
    refute :sys.get_state(rec).retiring?

    ref = Process.monitor(rec)
    cleared(ctx)
    fire(rec, :post_window, first)
    assert_receive {:event_ended, %Event{id: ^first, status: :finalized}}
    refute_receive {:DOWN, ^ref, :process, ^rec, _reason}, 200

    started(ctx)
    assert_receive {:extractor_started, %Event{id: second}, _pid}
    assert second != first
  end

  test "a retire with nothing open stops the recorder", ctx do
    rec = recorder(ctx)
    ref = Process.monitor(rec)

    PresenceRecorder.retire(ctx.camera_id)

    assert_receive {:DOWN, ^ref, :process, ^rec, :normal}
  end

  # The race the adoption is a *call* for: the retire is already in the mailbox
  # when the camera comes back, and with nothing open the recorder honours it
  # and stops. Whether `ensure/1` then adopts the dying one or starts a fresh
  # one is not the assertion — that the caller is handed a recorder that is
  # alive and answering is.
  test "ensure after a retire that is already in flight yields a live recorder", ctx do
    id = ctx.camera_id
    recorder(ctx)

    on_exit(fn ->
      PresenceRecorder.retire(id)
      Registry.await_unregistered(id, :presence_recorder)
    end)

    PresenceRecorder.retire(id)

    assert {:ok, pid} = PresenceRecorder.ensure(id)
    assert is_map(:sys.get_state(pid))
    refute :sys.get_state(pid).retiring?
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

    CameraControl.set(id, %{min_score: 0.3})
    on_exit(fn -> CameraControl.set(id, %{min_score: nil}) end)

    started(ctx, "person", 0.4)

    assert_receive {:event_started, %Event{camera_id: ^id, max_scores: %{"person" => 0.4}}}
  end

  # -- wiring -----------------------------------------------------------------

  # `start_aggregator/1` ensures the recorder once, at the aggregator's birth;
  # every observation after that finds the aggregator registered and never
  # reaches it again. Without a retry on the transition itself, a lane that
  # failed to start — or that stopped and was not replaced — would record
  # nothing for the life of the aggregator.
  #
  # The healed recorder is a real one, so its extractor dies on the sandbox it
  # has no ownership of; the event opening is what this test is about, and the
  # crash it logs is the price of not stubbing the process under test.
  test "a transition heals a lane whose recorder is gone", ctx do
    id = ctx.camera_id
    recorder(ctx)

    on_exit(fn ->
      PresenceAggregator.retire(id)
      Registry.await_unregistered(id, :presence)
      Registry.await_unregistered(id, :presence_recorder)
    end)

    # The aggregator starts here, while the lane is up — so nothing later can
    # heal it by that path.
    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    assert Registry.whereis(id, :presence) != nil

    PresenceRecorder.retire(id)
    Registry.await_unregistered(id, :presence_recorder)
    refute Registry.whereis(id, :presence_recorder)

    capture_log(fn ->
      PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})

      assert_receive {:event_started, %Event{camera_id: ^id}}, 2_000
    end)

    assert Registry.whereis(id, :presence_recorder) != nil
  end

  test "the aggregator's confirm and clear reach the recorder", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    on_exit(fn ->
      PresenceAggregator.retire(id)
      Registry.await_unregistered(id, :presence)
    end)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})

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

    on_exit(fn ->
      PresenceAggregator.retire(id)
      Registry.await_unregistered(id, :presence)
    end)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})
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

  # A camera stop is `PresenceAggregator.retire/1`, which latches this process
  # and then flushes the aggregator's labels — so the drain the tracked lane
  # does on `:camera_stopped` (ending the tracks nothing else will end,
  # camera_tracker.ex's `apply_epoch/3`) has no analogue here: there are no
  # tracks, and the cleareds the flush emits are the drain. The recorder
  # outlives its own retire for exactly as long as the clip takes to close.
  test "a retire flush closes the open event through the post window, then stops", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    ref = Process.monitor(rec)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    PresenceAggregator.retire(id)
    Registry.await_unregistered(id, :presence)

    state = :sys.get_state(rec)
    assert state.retiring?
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil
    refute_received {:event_ended, %Event{camera_id: ^id}}

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
    assert_receive {:DOWN, ^ref, :process, ^rec, :normal}
  end

  test "the sink forwards its inferred frames to the recorder", ctx do
    id = ctx.camera_id
    recorder(ctx)

    on_exit(fn ->
      PresenceAggregator.retire(id)
      Registry.await_unregistered(id, :presence)
    end)

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
