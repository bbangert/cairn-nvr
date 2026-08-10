defmodule Cairn.Pipeline.DetectSinkTest do
  use ExUnit.Case, async: true

  alias Cairn.Config.Camera
  alias Cairn.NativeStub
  alias Cairn.Observation
  alias Cairn.Pipeline.DetectSink
  alias Membrane.Buffer

  @policy %{
    pre: 5,
    post: 10,
    max: 300,
    track: %{"person" => %{min_score: 0.4}},
    record: %{"person" => %{min_score: 0.6}}
  }

  setup do
    camera_id = "detect_#{System.unique_integer([:positive])}"

    %{
      camera_id: camera_id,
      camera: %Camera{id: camera_id, rtsp_url: "rtsp://h/1"},
      epoch: Cairn.ULID.generate()
    }
  end

  defp sink(ctx) do
    options =
      struct(DetectSink,
        camera: ctx.camera,
        policy: @policy,
        epoch: ctx.epoch,
        # the dispatch seam's injection point: this process stands in for
        # the camera's tracker and sees the casts it would have received
        tracker: self()
      )

    {[], state} = DetectSink.handle_init(%{}, options)
    state
  end

  defp feed(state, observations) do
    DetectSink.handle_buffer(
      :input,
      %Buffer{payload: <<>>, pts: 1, metadata: %{observations: observations}},
      %{},
      state
    )
  end

  test "observations reach the tracker through the dispatch seam", ctx do
    {_actions, _state} = feed(sink(ctx), [NativeStub.frame()])

    camera_id = ctx.camera_id
    epoch = ctx.epoch
    camera = ctx.camera

    # the same cast the plugin ports make, carrying the same policy —
    # `track:` and `record:` included, and neither read on the way
    assert_received {:"$gen_cast", {:detections, ^camera, @policy, observation}}
    assert %Observation{camera_id: ^camera_id, epoch: ^epoch} = observation
  end

  test "stamps at_ms on the host's monotonic clock, like both plugin producers", ctx do
    # A wall-clock stamp keeps every intra-stream duration right and still
    # breaks the tracker: `Cairn.CameraTracker` stamps a stream cut with
    # `System.monotonic_time/1`, so a wall-clock `at_ms` lapses every
    # suspension the instant it is offered and no track can ever be adopted
    # across a reset.
    {_actions, _state} = feed(sink(ctx), [NativeStub.frame()])

    assert_received {:"$gen_cast", {:detections, _camera, @policy, observation}}
    assert_in_delta observation.at_ms, System.monotonic_time(:millisecond), 5_000
  end

  test "several observations in one buffer dispatch in the library's order", ctx do
    frames = for pts <- [90_000, 93_000, 96_000], do: %{NativeStub.frame() | pts: pts}
    {_actions, state} = feed(sink(ctx), frames)

    pts_order =
      for _ <- 1..3 do
        assert_received {:"$gen_cast", {:detections, _camera, @policy, observation}}
        {observation.pts, observation.at_ms}
      end

    assert [{90_000, _}, {93_000, _}, {96_000, _}] = pts_order
    # the tracker's `at_ms` is strictly non-decreasing across them, so a
    # reordering here would be a stream that appears to run backwards
    assert pts_order |> Enum.map(&elem(&1, 1)) |> then(&(&1 == Enum.sort(&1)))
    assert state.dispatched == 3
  end

  test "carries a refreshed policy without restarting anything", ctx do
    state = sink(ctx)
    camera = %{ctx.camera | record: %{"person" => %{min_score: 0.9}}}
    policy = Map.put(@policy, :record, camera.record)

    {actions, state} =
      DetectSink.handle_parent_notification({:policy, camera, policy}, %{}, state)

    assert actions == []

    {_actions, _state} = feed(state, [NativeStub.frame()])
    assert_received {:"$gen_cast", {:detections, ^camera, ^policy, %Observation{}}}
  end

  test "stats count what was dispatched", ctx do
    {_actions, state} = feed(sink(ctx), [NativeStub.frame(), NativeStub.frame()])

    assert {[notify_parent: {:stats, %{dispatched: 2}}], _state} =
             DetectSink.handle_parent_notification(:stats, %{}, state)
  end
end
