defmodule Cairn.MotionParityTest do
  # Task 3.3's load-bearing test: the Nx gate against the Rust one, same
  # clip, same knobs, frame for frame — **exact** equality on all four
  # verdict fields, `changed_fraction` included (an f32 widens to f64
  # losslessly on both sides). A divergence here changes which frames get
  # inferred, which no detection diff would ever show, so it is a defect and
  # not a tolerance question.
  #
  # The Rust side is the decode NIF asked to measure (`motion_json` in the
  # decoder params — the measurement `Cairn.Pipeline.Camera` no longer
  # requests, kept in the crate as exactly this reference). Every access
  # unit is fed with `sample: true` and pts converted to nanoseconds (the
  # decode_au contract where motion is measured), so both sides observe
  # every decoded frame on the same clock and the time-based calibration
  # window flips on the same frame — no model, no plugin binary, no wall
  # clock anywhere.
  #
  # `:native_parity` is excluded in `test/test_helper.exs` (CI's Elixir job
  # builds no Rust); this needs the NIF, ffmpeg/ffprobe and one clip:
  #
  #     mix test --only native_parity
  use ExUnit.Case, async: false

  alias Cairn.{Motion, Native}
  alias Cairn.Motion.{Config, Thumbnail}
  alias Cairn.Native.Parity

  @moduletag :native_parity
  @moduletag timeout: 300_000

  @clips "data/events/reolink_main"
  # Plenty to cross the 5 s calibration window, and to accumulate drift if
  # there were any to accumulate.
  @max_aus 400

  setup_all do
    unless Native.available?() do
      raise "cairn-native is not loaded (#{inspect(Native.load_error())}); " <>
              "cargo build --release in plugins/cairn-native, then copy " <>
              "target/release/libcairn_native.so to priv/native/"
    end

    case Path.wildcard(@clips <> "/*.mp4") do
      [] -> raise "no clips under #{@clips}"
      clips -> {:ok, clip: Enum.min(clips)}
    end
  end

  @tag :tmp_dir
  test "default knobs: the same verdict on every frame", ctx do
    verdicts = compare(ctx, ~s({"enabled":true}))

    # On the defaults this scene's changes stay under the area floor (its
    # peak fraction is ~6e-4 against 0.005) — "no motion" is the correct
    # verdict throughout. What keeps the comparison non-vacuous is that the
    # *fractions* move: half the frames measure real nonzero change, each
    # compared exactly.
    assert Enum.any?(verdicts, &(&1.changed_fraction > 0)), "nothing ever changed — vacuous"
    assert Enum.any?(verdicts, &(not &1.calibrating)), "never left calibration"
  end

  @tag :tmp_dir
  test "knobs tuned to the scene open the gate, and the verdicts still agree", ctx do
    # Sensitive enough that this clip's distant traffic trips it (probed:
    # ~64 motion frames of ~360) — so the parity covers verdicts on both
    # sides of every boundary, not just a gate that never opens.
    json = ~s({"enabled":true,"threshold":10,"min_area_fraction":0.0005,"alpha":0.1})
    verdicts = compare(ctx, json)

    assert Enum.any?(verdicts, & &1.motion), "the gate never opened — vacuous parity"
    assert Enum.any?(verdicts, &(not &1.motion and not &1.calibrating)), "never closed again"
  end

  # Both measurements over the same decoded frames; returns the agreed
  # verdicts after asserting they agree.
  defp compare(%{clip: clip, tmp_dir: tmp_dir}, motion_json) do
    frames = rust_run(clip, tmp_dir, motion_json)

    # The window is 5 s of the frames' own time: the clip has to span it
    # with room to accumulate drift after it, or the comparison says nothing.
    span_ns = List.last(frames).pts - hd(frames).pts

    assert span_ns > 10 * 1_000_000_000,
           "the clip spans #{span_ns} ns — too short to say anything"

    {:ok, %Config{} = config} = Config.resolve_json(motion_json)
    [first | _] = frames

    {mismatches, _detector} =
      frames
      |> Enum.with_index()
      |> Enum.reduce(
        {[], Motion.new(config)},
        fn {frame, index}, {mismatches, detector} ->
          thumb = Thumbnail.from_rgb24(frame.payload, frame.width, frame.height)
          # The same pts the crate's detector read inside `decode_au`.
          {verdict, detector} = Motion.observe(detector, thumb, frame.pts)

          mismatches =
            if verdict == frame.motion,
              do: mismatches,
              else: [%{frame: index, rust: frame.motion, nx: verdict} | mismatches]

          {mismatches, detector}
        end
      )

    assert mismatches == [],
           "#{length(mismatches)}/#{length(frames)} frames diverged " <>
             "(#{first.width}x#{first.height} content):\n" <>
             Enum.map_join(Enum.reverse(mismatches), "\n", &inspect/1)

    Enum.map(frames, & &1.motion)
  end

  # The reference: the crate's own MotionDetector, measuring inside
  # `decode_au` on every frame the software decoder completes. The input
  # spec is hand-written wire terms — motion is measured on the content
  # rectangle, which only needs *a* model geometry, not a model. The clip's
  # container pts are rescaled to nanoseconds before the seam: that is the
  # unit `decode_au` documents where motion is measured, and the unit
  # `Cairn.Motion` reads.
  defp rust_run(clip, tmp_dir, motion_json) do
    %{aus: aus, time_base: {num, den}} = Parity.read_clip(clip, tmp_dir)

    aus =
      aus
      |> Enum.take(@max_aus)
      |> Enum.map(fn {au, pts} -> {au, div(pts * num * 1_000_000_000, den)} end)

    {:ok, decoder} =
      Native.open_decoder("motion_parity", %{
        decoder: "sw",
        width: 416,
        height: 416,
        encoding: "raw_bgr",
        resize: "letterbox",
        resize_pad: 114,
        source_width: nil,
        source_height: nil,
        motion_json: motion_json
      })

    try do
      Enum.flat_map(aus, fn {au, pts} ->
        {:ok, {_completed, frame}} = Native.decode_au(decoder, au, pts, true)
        List.wrap(frame)
      end)
    after
      Native.close_decoder(decoder)
    end
  end
end
