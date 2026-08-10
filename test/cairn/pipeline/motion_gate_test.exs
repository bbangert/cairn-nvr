defmodule Cairn.Pipeline.MotionGateTest do
  use ExUnit.Case, async: true

  alias Cairn.Motion.Config
  alias Cairn.Pipeline.MotionGate
  alias Membrane.Buffer

  # 96x54 is at the thumbnail cap, so the downsample is a pixel-for-pixel
  # copy and every fraction below is exact by inspection.
  @width 96
  @height 54
  @sample_fps 5
  @calibration_frames 5 * @sample_fps

  @format %Membrane.RawVideo{
    width: @width,
    height: @height,
    framerate: nil,
    pixel_format: :RGB,
    aligned: true
  }

  defp element(opts \\ []) do
    options =
      struct(
        MotionGate,
        Keyword.merge([config: %Config{enabled: true}, sample_fps: @sample_fps], opts)
      )

    {[], state} = MotionGate.handle_init(%{}, options)
    state
  end

  defp formatted(state, format \\ @format) do
    {[stream_format: {:output, _}], state} =
      MotionGate.handle_stream_format(:input, format, %{}, state)

    state
  end

  defp grey(level, w \\ @width, h \\ @height) do
    :binary.copy(<<level, level, level>>, w * h)
  end

  # `level`, with the top half at `moved` — half the thumbnail changes.
  defp half(level, moved) do
    top = :binary.copy(<<moved, moved, moved>>, @width * div(@height, 2))
    bottom = :binary.copy(<<level, level, level>>, @width * (@height - div(@height, 2)))
    top <> bottom
  end

  defp feed(state, payload, pts \\ 0) do
    MotionGate.handle_buffer(:input, %Buffer{payload: payload, pts: pts}, %{}, state)
  end

  defp observe(state, payload, count) do
    Enum.reduce(1..count, state, fn _frame, state ->
      {[buffer: _], state} = feed(state, payload)
      state
    end)
  end

  test "forwards the stream format unchanged" do
    {actions, _state} = MotionGate.handle_stream_format(:input, @format, %{}, element())
    assert actions == [stream_format: {:output, @format}]
  end

  test "passes demand through one-for-one, keeping the one-frame seam intact" do
    assert {[demand: {:input, 3}], _state} =
             MotionGate.handle_demand(:output, 3, :buffers, %{}, element())
  end

  test "stamps a verdict on the buffer and touches nothing else" do
    buffer = %Buffer{payload: grey(100), pts: 42, metadata: %{observed_at_ms: 7}}

    {[buffer: {:output, out}], _state} =
      MotionGate.handle_buffer(:input, buffer, %{}, formatted(element()))

    assert out.pts == 42
    assert out.payload == buffer.payload
    assert out.metadata.observed_at_ms == 7

    # The first frame is the background: the fixed still verdict, in the
    # exact shape the decode NIF mints.
    assert out.metadata.motion == %{
             changed_fraction: 0.0,
             motion: false,
             calibrating: true,
             scene_cut: false
           }
  end

  test "reports motion once the calibration window has passed" do
    state = observe(formatted(element()), grey(100), @calibration_frames)

    {[buffer: {:output, out}], _state} = feed(state, half(100, 200))
    assert out.metadata.motion.motion
    refute out.metadata.motion.calibrating
    assert out.metadata.motion.changed_fraction == 0.5
  end

  test "a new stream format restarts the measurement at the new geometry" do
    state = observe(formatted(element()), grey(100), @calibration_frames + 1)

    narrow = %{@format | width: 64, height: 32}
    state = formatted(state, narrow)

    {[buffer: {:output, out}], _state} = feed(state, grey(200, 64, 32))
    assert out.metadata.motion.calibrating
    refute out.metadata.motion.motion
  end

  test "a payload that is not the declared geometry crashes rather than misreads" do
    state = formatted(element())

    assert_raise ArgumentError, ~r/packed RGB24/, fn ->
      feed(state, grey(100, 8, 8))
    end
  end

  test "stats name what was observed and what the verdicts said" do
    state = formatted(element())
    state = observe(state, grey(100), @calibration_frames)
    # One scene cut (everything changes), then motion (half changes).
    state = observe(state, grey(230), 1)
    state = observe(state, half(230, 100), 1)

    {[notify_parent: {:stats, stats}], _state} =
      MotionGate.handle_parent_notification(:stats, %{}, state)

    assert stats == %{
             observed: @calibration_frames + 2,
             motion: 1,
             scene_cuts: 1,
             calibrating: false
           }
  end
end
