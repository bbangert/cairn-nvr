defmodule Cairn.PresenceRecorderTest do
  # No `Cairn.DataCase`: the extractor is stubbed in every test here, so
  # nothing on this lane reaches the event index.
  #
  # Not async, for two reasons that are the same reason: every case here
  # subscribes to the one `"events"` topic every other presence suite
  # broadcasts on, and several assert on a lifecycle message arriving inside
  # `assert_receive`'s default window — which a loaded scheduler can miss.
  use ExUnit.Case, async: false

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
  defp recorder(ctx, overrides \\ %{}, id \\ :recorder) do
    test_pid = self()
    camera = ctx.camera
    policy = Map.merge(@policy, overrides)

    start_supervised!(
      {PresenceRecorder,
       camera_id: ctx.camera_id,
       resolve_policy: fn _camera_id -> {camera, policy} end,
       start_extractor: fn _camera, event ->
         pid = relay(test_pid)
         send(test_pid, {:extractor_started, event, pid})
         {:ok, pid}
       end,
       finalize_extractor: fn pid, event ->
         send(test_pid, {:extractor_finalized, pid, event})
       end},
      id: id
    )
  end

  # Stands in for `Cairn.EventExtractor`: stays alive and hands every cast it
  # is sent to the test, which is how the `{:track_boxes, _}` stream is
  # observed. Unlinked, so a test that kills it does not take itself down.
  defp relay(test_pid) do
    spawn(fn -> relay_loop(test_pid) end)
  end

  defp relay_loop(test_pid) do
    receive do
      {:"$gen_cast", message} -> send(test_pid, {:extractor_cast, message})
      _other -> :ok
    end

    relay_loop(test_pid)
  end

  defp started(ctx, label \\ "person", score \\ 0.9) do
    PresenceRecorder.presence(ctx.camera_id, :presence_started, presence(ctx, label, score))
  end

  defp cleared(ctx, label \\ "person", score \\ 0.9) do
    PresenceRecorder.presence(ctx.camera_id, :presence_cleared, presence(ctx, label, score))
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
    assert {%Event{id: ^eid}, ["person"]} = PresenceCheckpoint.get(id)
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
    assert {%Event{id: ^eid}, ["car"]} = PresenceCheckpoint.get(ctx.camera_id)

    cleared(ctx, "car")
    assert :sys.get_state(rec).post_token != nil
    assert {%Event{id: ^eid}, []} = PresenceCheckpoint.get(ctx.camera_id)

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

  test "max_event closes the event whether or not anything is still present", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    fire(rec, :max_event, eid)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
    assert :sys.get_state(rec).present_labels |> MapSet.member?("person")
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

  test "frames are dropped on the floor while no event is open", ctx do
    rec = recorder(ctx)

    frames(ctx, [object("person", 0.9)])

    state = :sys.get_state(rec)
    assert state.event == nil
    refute_received {:extractor_cast, _}
  end

  test "while an event is open, frames feed boxes, the trigger and the label timeline", ctx do
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, _pid}

    frames(ctx, [object("person", 0.95), object("car", 0.6, [0.5, 0.5, 0.1, 0.1])])

    # Boxes are unfiltered and label-keyed (D-E5b), best score first.
    assert_receive {:extractor_cast, {:track_boxes, %{t_ms: t_ms, boxes: boxes}}}
    assert t_ms >= 0

    assert boxes == [
             {"person", "person", @box, false},
             {"car", "car", [0.5, 0.5, 0.1, 0.1], false}
           ]

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

    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"car", "car", _, false}]}}}

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

  # -- wiring -----------------------------------------------------------------

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

  # `detection_disabled` flushes presence through the same emit, so the event
  # closes on its post window rather than being cut short.
  test "a detection_disabled flush clears the recorder's labels too", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    on_exit(fn ->
      PresenceAggregator.retire(id)
      Registry.await_unregistered(id, :presence)
    end)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})
    assert_receive {:extractor_started, %Event{id: _eid}, _pid}

    PresenceAggregator.detection_disabled(id)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}
    state = drained(id, rec)
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil
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
                    {:track_boxes, %{boxes: [{"person", "person", @box, false}]}}}
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
