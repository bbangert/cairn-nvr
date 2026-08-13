defmodule Cairn.Pipeline.ObservationStamperTest do
  use ExUnit.Case, async: true

  alias Cairn.CameraControl
  alias Cairn.Config.Camera
  alias Cairn.NativeStub
  alias Cairn.Pipeline.{ObservationStamper, TrackSink}
  alias Membrane.Buffer
  alias Membrane.MOTTracker.Event.EndAll

  @policy %{
    pre: 5,
    post: 10,
    max: 300,
    max_unseen_ms: 3_000,
    max_live_tracks: 128,
    stationary_after_ms: 10_000,
    track: %{"person" => %{min_score: 0.4}},
    record: %{"person" => %{min_score: 0.6}}
  }

  setup do
    camera_id = "stamp_#{System.unique_integer([:positive])}"

    %{
      camera_id: camera_id,
      camera: %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}},
      epoch: Cairn.ULID.generate()
    }
  end

  defp stamper(ctx, policy \\ @policy) do
    {[], state} =
      ObservationStamper.handle_init(
        %{},
        struct(ObservationStamper, camera: ctx.camera, policy: policy)
      )

    state
  end

  # The epoch rides the buffer, as `Cairn.Pipeline.Inference` carries it over
  # from the frame — this element holds none.
  defp feed(state, observations, epoch) do
    ObservationStamper.handle_buffer(
      :input,
      %Buffer{
        payload: <<>>,
        pts: 1,
        metadata: %{observations: observations, stream_epoch: epoch}
      },
      %{},
      state
    )
  end

  defp batches(actions), do: for({:buffer, {:output, buffer}} <- actions, do: buffer.metadata)

  test "one buffer per observation, carrying the objects and the batch's instant", ctx do
    {actions, _state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

    assert [%{objects: objects, context: context, at_ms: at_ms, epoch: epoch}] = batches(actions)
    assert is_list(objects)
    assert epoch == ctx.epoch
    assert context.epoch == ctx.epoch
    assert context.camera_id == ctx.camera_id
    # `at_ms` rides beside the context as well as in it: the element times its
    # own work with the one and hands the core the other
    assert context.at_ms == at_ms
  end

  test "stamps at_ms on the host's monotonic clock, not the wall clock", ctx do
    # A wall-clock stamp keeps every intra-stream duration right and still
    # breaks the tracker: the element stamps a stream cut with the batch clock
    # and measures the adoption window as a subtraction of two of them, so a
    # wall-clock `at_ms` lapses every suspension the instant it is offered.
    {actions, _state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

    assert [%{at_ms: at_ms}] = batches(actions)
    assert_in_delta at_ms, System.monotonic_time(:millisecond), 5_000
  end

  test "each buffer's observations carry that buffer's own epoch", ctx do
    # This element outlives the sessions it serves, so two epochs really do
    # cross one instance of it — and tagging from element state would give the
    # first session's stragglers the second session's epoch.
    second = Cairn.ULID.generate()

    {first_actions, state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)
    {second_actions, _state} = feed(state, [NativeStub.frame()], second)

    assert [%{epoch: first}] = batches(first_actions)
    assert [%{epoch: ^second}] = batches(second_actions)
    assert first == ctx.epoch
  end

  test "a buffer with no epoch is dropped and counted, not crashed on", ctx do
    {actions, state} = feed(stamper(ctx), [NativeStub.frame()], nil)

    assert actions == []
    assert state.dropped == 1
  end

  # The key existing is not the contract holding: a nil where the list should
  # be must fall to the same counted drop, not into from_frames.
  test "a buffer whose observations are not a list is dropped, not crashed on", ctx do
    {actions, state} = feed(stamper(ctx), nil, ctx.epoch)

    assert actions == []
    assert state.dropped == 1
  end

  test "several observations in one buffer become batches in the library's order", ctx do
    frames = for pts <- [90_000, 93_000, 96_000], do: %{NativeStub.frame() | pts: pts}
    {actions, state} = feed(stamper(ctx), frames, ctx.epoch)

    at_ms = for %{at_ms: at_ms} <- batches(actions), do: at_ms

    assert length(at_ms) == 3
    # the tracking clock is strictly increasing across them, so a reordering
    # here would be a stream that appears to run backwards
    assert at_ms == Enum.sort(at_ms)
    assert state.stamped == 3
  end

  test "carries a refreshed policy without restarting anything", ctx do
    state = stamper(ctx)
    camera = %{ctx.camera | max_unseen_ms: 9_000}
    policy = Map.put(@policy, :max_unseen_ms, 9_000)

    {actions, state} =
      ObservationStamper.handle_parent_notification({:policy, camera, policy}, %{}, state)

    assert actions == []

    {actions, _state} = feed(state, [NativeStub.frame()], ctx.epoch)
    assert [%{context: %{max_unseen_ms: 9_000}}] = batches(actions)
  end

  test "the sink dispatches every batch under the pair that stamped it", ctx do
    # The reload reaches the two ends of the tracker element on one buffer or
    # on two notifications; only the first can keep them in step. The element
    # between them echoes the context untouched (mot_tracker_test), so its
    # out-buffer is the stamper's own metadata in `Tracks` clothing.
    {[], sink} =
      TrackSink.handle_init(
        %{},
        struct(TrackSink, camera: ctx.camera, policy: @policy, tracker: self())
      )

    camera = %{ctx.camera | max_unseen_ms: 9_000}
    reloaded = Map.put(@policy, :max_unseen_ms, 9_000)

    {stale, state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

    {[], state} =
      ObservationStamper.handle_parent_notification({:policy, camera, reloaded}, %{}, state)

    {fresh, _state} = feed(state, [NativeStub.frame()], ctx.epoch)

    assert [%{context: %{max_unseen_ms: 3_000}}] = batches(stale)
    assert [%{context: %{max_unseen_ms: 9_000}}] = batches(fresh)

    Enum.reduce(batches(stale) ++ batches(fresh), sink, fn metadata, sink ->
      {[], sink} = TrackSink.handle_buffer(:input, tracks(metadata), %{}, sink)
      sink
    end)

    # Each in the order its batch went through: the old bound with the old
    # `record:` tier, then both halves of the reload together.
    old = ctx.camera
    assert_received {:"$gen_cast", {:tracked, ^old, @policy, _batch}}
    assert_received {:"$gen_cast", {:tracked, ^camera, ^reloaded, _batch}}
  end

  defp tracks(metadata) do
    %Buffer{
      payload: <<>>,
      metadata: %{
        tagged: [],
        events: [],
        suspension: nil,
        snapshot: [],
        epoch: metadata.epoch,
        context: metadata.context
      }
    }
  end

  describe "the runtime control overlay" do
    test "the effective min_score rides the context, override included", ctx do
      CameraControl.set(ctx.camera_id, %{min_score: 0.95})
      on_exit(fn -> CameraControl.set(ctx.camera_id, %{min_score: nil}) end)

      {actions, _state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

      # the same number the event gate downstream reads off the batch: the
      # tracker partitions on it and `Cairn.CameraTracker` gates evidence on it
      assert [%{context: %{min_score: %{"default" => 0.95}}}] = batches(actions)
    end

    test "no override leaves the camera's configured floor", ctx do
      {actions, _state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)
      assert [%{context: %{min_score: %{"default" => 0.5}}}] = batches(actions)
    end

    test "detection off drops the batch and tells the tracker to let go, once", ctx do
      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      on_exit(fn -> CameraControl.set(ctx.camera_id, %{detection_enabled: true}) end)

      {actions, state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

      assert actions == [event: {:output, %EndAll{reason: :detection_disabled}}]
      assert state.dropped == 1

      # once per transition, not once per frame: the tracks are already gone
      {actions, _state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert actions == []
    end

    test "detection back on stamps again and re-arms the ending", ctx do
      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      {_actions, state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

      CameraControl.set(ctx.camera_id, %{detection_enabled: true})
      {actions, state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert [%{context: _}] = batches(actions)

      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      on_exit(fn -> CameraControl.set(ctx.camera_id, %{detection_enabled: true}) end)
      {actions, _state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert actions == [event: {:output, %EndAll{reason: :detection_disabled}}]
    end

    # The whole reason the ending is an event: a flip off and straight back on
    # puts both halves on one pad, in the order the gate closed and reopened,
    # so the tracks the resumed batch mints are minted after the ending. The
    # parent hop this replaces had no such order — the ending could arrive
    # behind the resumed batch and end exactly the tracks it had just minted.
    test "an off→on flip ends the old tracks and leaves the new ones alone", ctx do
      on_exit(fn -> CameraControl.set(ctx.camera_id, %{detection_enabled: true}) end)

      {actions, state} = feed(stamper(ctx), [frame_with_person()], ctx.epoch)
      {tracked, element} = drive(tracker_element(), actions)
      assert [%{tagged: [%{object_id: old_id}]}] = tracked

      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      {off, state} = feed(state, [frame_with_person()], ctx.epoch)

      CameraControl.set(ctx.camera_id, %{detection_enabled: true})
      {on, _state} = feed(state, [frame_with_person()], ctx.epoch)

      # In the order the pad delivers them, which is the order the stamper
      # produced them in.
      {out, _element} = drive(element, off ++ on)

      assert [ended, resumed] = out
      assert [{:ended, %{object_id: ^old_id, end_reason: :detection_disabled}}] = ended.events

      # A fresh identity, minted after the ending and untouched by it.
      assert [%{object_id: new_id}] = resumed.tagged
      assert [{:started, %{object_id: ^new_id}}] = resumed.events
      assert [%{object_id: ^new_id}] = resumed.snapshot
    end
  end

  # The real element over the real core, driven by hand — `Cairn.TrackerDriver`
  # without the sink, since what is under test here is the element's reaction to
  # the stamper's own actions and their order.
  defp tracker_element do
    {[], element} =
      Membrane.MOTTracker.handle_init(
        %{},
        struct(Membrane.MOTTracker, tracker: {Cairn.Tracker, []}, max_suspended: 128)
      )

    element
  end

  # Every buffer the element produced, in order, and the element after them.
  defp drive(element, actions) do
    Enum.reduce(actions, {[], element}, fn action, {out, element} ->
      {actions, element} =
        case action do
          {:buffer, {:output, buffer}} ->
            Membrane.MOTTracker.handle_buffer(:input, buffer, %{}, element)

          {:event, {:output, event}} ->
            Membrane.MOTTracker.handle_event(:input, event, %{}, element)
        end

      {out ++ for({:buffer, {:output, buffer}} <- actions, do: buffer.metadata), element}
    end)
  end

  defp frame_with_person do
    %{
      NativeStub.frame()
      | objects: [
          %{
            label: "person",
            score: 0.9,
            bbox: [0.1, 0.1, 0.2, 0.4],
            track_id: nil,
            observation_kind: "detected"
          }
        ]
    }
  end
end
