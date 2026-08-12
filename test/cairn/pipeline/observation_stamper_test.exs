defmodule Cairn.Pipeline.ObservationStamperTest do
  use ExUnit.Case, async: true

  alias Cairn.CameraControl
  alias Cairn.Config.Camera
  alias Cairn.NativeStub
  alias Cairn.Pipeline.ObservationStamper
  alias Membrane.Buffer

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

      assert actions == [notify_parent: {:end_all, :detection_disabled}]
      assert state.dropped == 1

      # once per transition, not once per frame: the tracks are already gone
      {actions, _state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert actions == []
    end

    test "detection back on stamps again and re-arms the notification", ctx do
      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      {_actions, state} = feed(stamper(ctx), [NativeStub.frame()], ctx.epoch)

      CameraControl.set(ctx.camera_id, %{detection_enabled: true})
      {actions, state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert [%{context: _}] = batches(actions)

      CameraControl.set(ctx.camera_id, %{detection_enabled: false})
      on_exit(fn -> CameraControl.set(ctx.camera_id, %{detection_enabled: true}) end)
      {actions, _state} = feed(state, [NativeStub.frame()], ctx.epoch)
      assert actions == [notify_parent: {:end_all, :detection_disabled}]
    end
  end
end
