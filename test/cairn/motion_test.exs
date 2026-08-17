defmodule Cairn.MotionTest do
  @moduledoc """
  The port's spec is the crate's own test suite: every test in
  `plugins/cairn-detect/src/motion.rs` appears here under the same name,
  asserting the same values — exactly, because the detector's job is to make
  the same gate decision the Rust implementation makes, frame for frame
  (`test/cairn/motion_parity_test.exs` then pins that against the real
  NIF on a real clip). The stride variants are the one omission: the element
  payload is tightly packed by contract, so the port takes no stride.
  """

  use ExUnit.Case, async: true

  alias Cairn.Motion
  alias Cairn.Motion.{Config, Thumbnail}

  # The fixture clock, the crate's tests' own: one observation every 200 ms,
  # a real delivered 5 fps. Real-scale on purpose — compressing the window in
  # fixtures changes which stimuli cross a rate threshold (see
  # `.claude/solutions/compressed-timescale-fixture-changes-what-crosses-a-rate-floor-20260804.md`),
  # so the 5 s window is spanned by real pts deltas, never shrunk.
  @step_ns 200_000_000
  # Observations inside the window on this clock: observation `k` carries pts
  # `k * @step_ns`, so `k = 25` is the first with five seconds elapsed (and
  # past the 10-frame floor).
  @window 25

  defp f32(x), do: Config.f32(x)

  # The pts an observation at `step` on the fixture clock carries.
  defp at(step), do: step * @step_ns

  # A detector on the defaults, with the gate switched on.
  defp detector do
    Motion.new(%Config{enabled: true})
  end

  # A thumbnail built directly, bypassing the RGB24 downsample.
  defp thumb(w, h, fill) do
    %Thumbnail{w: w, h: h, tensor: Nx.broadcast(Nx.tensor(fill, type: :u8), {h, w})}
  end

  # `fill`, with a `bw x bh` block of `value` at the top-left corner.
  defp block(w, h, fill, bw, bh, value) do
    filled =
      Nx.put_slice(
        thumb(w, h, fill).tensor,
        [0, 0],
        Nx.broadcast(Nx.tensor(value, type: :u8), {bh, bw})
      )

    %Thumbnail{w: w, h: h, tensor: filled}
  end

  # Observe one still frame at fixture-clock steps `from..from + count - 1`.
  defp observe_still(detector, still, from, count) do
    Enum.reduce(from..(from + count - 1)//1, detector, fn step, detector ->
      {_verdict, detector} = Motion.observe(detector, still, at(step))
      detector
    end)
  end

  # Run a detector to the end of its calibration window on one still frame,
  # so the observation at step `@window` is the first that can report motion.
  defp calibrate(detector, still), do: observe_still(detector, still, 0, @window)

  # A packed RGB24 buffer filled by `pixel(x, y) -> {r, g, b}`.
  defp rgb24(w, h, pixel) do
    for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
      {r, g, b} = pixel.(x, y)
      <<r, g, b>>
    end
  end

  # ---- the detector ---------------------------------------------------------

  test "nothing reports motion while the background is still being learned" do
    warming = detector()
    still = thumb(96, 54, 100)
    moved = block(96, 54, 100, 48, 27, 200)

    # The first frame becomes the background; every frame in the window after
    # it differs from that background by a quarter of the picture and still
    # reports no motion.
    {_verdict, warming} = Motion.observe(warming, still, at(0))

    Enum.reduce(1..(@window - 1), warming, fn step, warming ->
      {verdict, warming} = Motion.observe(warming, moved, at(step))
      refute verdict.motion, "step #{step}"
      warming
    end)

    # ...and it is the window that says so, not the picture: a detector past
    # it has an opinion about the very same frame.
    calibrated = calibrate(detector(), still)
    {verdict, _} = Motion.observe(calibrated, moved, at(@window))
    assert verdict.motion
  end

  test "the calibration window ends on the first frame with five seconds elapsed" do
    still = thumb(96, 54, 100)
    moved = block(96, 54, 100, 48, 27, 200)

    last_inside = observe_still(detector(), still, 0, @window - 1)
    {verdict, _} = Motion.observe(last_inside, moved, at(@window - 1))
    refute verdict.motion, "one step short of five seconds"
    assert verdict.calibrating

    first_outside = observe_still(detector(), still, 0, @window)
    {verdict, _} = Motion.observe(first_outside, moved, at(@window))
    assert verdict.motion, "the first frame with five seconds elapsed"
    refute verdict.calibrating
  end

  test "the calibration window spans five seconds at any delivered rate" do
    # The invariant the time basis buys: the window is five seconds of the
    # stream's own time however fast frames actually arrive.
    still = thumb(96, 54, 100)
    moved = block(96, 54, 100, 48, 27, 200)

    # 10 fps delivered needs 50 observations; 2 fps (the tier-1 ladder
    # floor) needs 10 — the frame floor and the elapsed rule agree there.
    for {label, step_ns, steps} <- [{"10 fps", 100_000_000, 50}, {"2 fps", 500_000_000, 10}] do
      warming =
        Enum.reduce(0..(steps - 1), detector(), fn step, warming ->
          {verdict, warming} = Motion.observe(warming, still, step * step_ns)
          assert verdict.calibrating, "#{label}: step #{step}"
          warming
        end)

      {verdict, _} = Motion.observe(warming, moved, steps * step_ns)
      refute verdict.calibrating, "#{label}: five seconds elapsed"
      assert verdict.motion, label
    end
  end

  test "a camera below the frame floor calibrates on frames not time" do
    # One frame a second: five seconds elapse after five frames, but five
    # folds are not a learned background — the 10-frame floor holds the
    # window open until enough frames have folded in.
    still = thumb(96, 54, 100)
    step_ns = 1_000_000_000

    warming =
      Enum.reduce(0..9, detector(), fn step, warming ->
        {verdict, warming} = Motion.observe(warming, still, step * step_ns)
        assert verdict.calibrating, "step #{step}"
        warming
      end)

    {verdict, _} = Motion.observe(warming, still, 10 * step_ns)
    refute verdict.calibrating, "the floor is met and time long since"
  end

  test "undated frames advance the floor but never the clock" do
    # A decoder that cannot date a frame hands `nil`: the frame still folds
    # into the background, but it cannot end the window — and once the
    # window is over, the latch means it cannot reopen it either.
    still = thumb(96, 54, 100)
    {_verdict, warming} = Motion.observe(detector(), still, at(0))

    warming =
      Enum.reduce(1..(@window + 5), warming, fn step, warming ->
        {verdict, warming} = Motion.observe(warming, still, nil)
        assert verdict.calibrating, "step #{step}"
        warming
      end)

    # A dated frame past the window ends it...
    {verdict, calibrated} = Motion.observe(warming, still, at(@window + 5))
    refute verdict.calibrating
    # ...and undated frames after it stay calibrated.
    {verdict, _} = Motion.observe(calibrated, still, nil)
    refute verdict.calibrating
  end

  test "a backward pts jump rebases the window instead of waiting out the gap" do
    # A camera that resets its clock mid-calibration would otherwise hold
    # elapsed at zero until the new clock caught the old baseline up. The
    # window rebases onto step 1's pts, so it ends five seconds after that.
    still = thumb(96, 54, 100)
    {_verdict, warming} = Motion.observe(detector(), still, 100_000_000_000)

    warming =
      Enum.reduce(1..@window, warming, fn step, warming ->
        {verdict, warming} = Motion.observe(warming, still, at(step))
        assert verdict.calibrating, "step #{step}"
        warming
      end)

    {verdict, _} = Motion.observe(warming, still, at(@window + 1))
    refute verdict.calibrating
  end

  test "every observation of the calibration window is flagged as one" do
    warming = detector()
    still = thumb(96, 54, 100)

    {verdict, warming} = Motion.observe(warming, still, at(0))
    assert verdict.calibrating, "the first frame"

    warming =
      Enum.reduce(1..(@window - 1), warming, fn step, warming ->
        {verdict, warming} = Motion.observe(warming, still, at(step))
        assert verdict.calibrating, "step #{step}"
        warming
      end)

    {verdict, _} = Motion.observe(warming, still, at(@window))
    refute verdict.calibrating, "the first one past it"
  end

  test "a scene that cuts on every sample still finishes calibrating" do
    # An IR-cut filter hunting at dusk: every sample after the first is a
    # scene cut. The counter has to keep moving through those, or the camera
    # reports no motion for as long as it flickers.
    flickering = detector()
    dark = thumb(96, 54, 40)
    bright = thumb(96, 54, 200)

    flickering =
      Enum.reduce(0..(@window - 1), flickering, fn step, flickering ->
        flip = if rem(step, 2) == 0, do: bright, else: dark
        {verdict, flickering} = Motion.observe(flickering, flip, at(step))
        refute verdict.motion, "#{step}"
        # The first frame *is* the background; every one after it is a cut.
        assert verdict.scene_cut == step > 0, "#{step}"
        flickering
      end)

    # Calibrated, on the scene the last cut left behind.
    settled = if rem(@window, 2) == 0, do: 40, else: 200
    {verdict, _} = Motion.observe(flickering, block(96, 54, settled, 48, 27, 120), at(@window))
    assert verdict.motion
  end

  test "a static scene reports no motion after calibration" do
    still = thumb(96, 54, 120)
    detector = calibrate(detector(), still)

    Enum.reduce(@window..(@window + 49), detector, fn step, detector ->
      {verdict, detector} = Motion.observe(detector, still, at(step))
      assert verdict.changed_fraction == 0.0
      refute verdict.motion
      detector
    end)
  end

  test "a moving block reports motion covering its own area" do
    # A quarter of the frame changes; the fraction reported is that quarter,
    # which is what makes `min_area_fraction` mean something an operator can
    # reason about.
    still = thumb(96, 54, 100)
    detector = calibrate(detector(), still)

    {verdict, _} = Motion.observe(detector, block(96, 54, 100, 48, 27, 200), at(@window))
    assert verdict.motion
    assert verdict.changed_fraction == 0.25
  end

  test "a change under the area floor is not motion but is still measured" do
    detector = Motion.new(%Config{enabled: true, min_area_fraction: f32(0.1)})

    still = thumb(100, 10, 100)
    detector = calibrate(detector, still)

    # 50 of 1000 pixels: half the floor.
    {verdict, _} = Motion.observe(detector, block(100, 10, 100, 50, 1, 200), at(@window))
    refute verdict.motion
    assert verdict.changed_fraction == f32(0.05)
  end

  test "a change exactly at the area floor counts as motion" do
    # The compare is `>=`, so the floor is the first fraction that counts.
    detector = Motion.new(%Config{enabled: true, min_area_fraction: f32(0.1)})

    still = thumb(100, 10, 100)
    detector = calibrate(detector, still)

    # 100 of 1000 pixels: the floor exactly.
    {verdict, _} = Motion.observe(detector, block(100, 10, 100, 100, 1, 200), at(@window))
    assert verdict.changed_fraction == f32(0.1)
    assert verdict.motion
  end

  test "a frame changing exactly the scene cut fraction is motion" do
    # The scene-cut compare is strict, so 80 % is the largest change that is
    # still an object rather than a cut.
    still = thumb(10, 10, 100)
    detector = calibrate(detector(), still)

    # 80 of 100 pixels.
    {verdict, detector} = Motion.observe(detector, block(10, 10, 100, 10, 8, 200), at(@window))
    assert verdict.changed_fraction == Config.lightning_fraction()
    assert verdict.motion

    # ...and it went through the rolling average, not the rebaseline: a cut
    # would have taken the new scene outright and read 0.0 next.
    {held, _} = Motion.observe(detector, block(10, 10, 100, 10, 8, 200), at(@window + 1))
    assert held.changed_fraction == Config.lightning_fraction()
  end

  test "sensor noise under the threshold is not motion" do
    # A real static scene is not a constant picture: sensor noise moves every
    # pixel between samples. While that swing stays under the threshold none
    # of it counts as changed.
    noisy = fn phase ->
      values =
        Nx.iota({54, 96})
        |> Nx.add(phase)
        |> Nx.remainder(2)
        |> Nx.multiply(-20)
        |> Nx.add(110)
        |> Nx.as_type(:u8)

      %Thumbnail{w: 96, h: 54, tensor: values}
    end

    detector = calibrate(detector(), noisy.(0))

    # Every pixel swings the full 20 levels, under the threshold of 25.
    {verdict, _} = Motion.observe(detector, noisy.(1), at(@window))
    assert verdict.changed_fraction == 0.0
    refute verdict.motion
  end

  test "a whole-frame illumination change rebaselines instead of reporting motion" do
    dark = thumb(96, 54, 40)
    detector = calibrate(detector(), dark)

    bright = thumb(96, 54, 200)
    {flash, detector} = Motion.observe(detector, bright, at(@window))
    assert flash.changed_fraction == 1.0
    refute flash.motion, "a scene cut is not motion"
    assert flash.scene_cut
    refute flash.calibrating

    # The background is the new scene outright, so the very next frame is
    # judged against it — not averaged toward it over the next 50 frames.
    {settled, detector} = Motion.observe(detector, bright, at(@window + 1))
    assert settled.changed_fraction == 0.0
    refute settled.motion
    refute settled.scene_cut
    refute settled.calibrating

    # ...and the detector is still calibrated: it did not go blind.
    {verdict, _} = Motion.observe(detector, block(96, 54, 200, 48, 27, 40), at(@window + 2))
    assert verdict.motion
  end

  test "a scene cut inside the calibration window carries both flags" do
    # The two "this says nothing about the picture" bits are independent.
    warming = detector()
    {_verdict, warming} = Motion.observe(warming, thumb(96, 54, 40), at(0))

    {flash, _} = Motion.observe(warming, thumb(96, 54, 200), at(1))
    assert flash.changed_fraction == 1.0
    assert flash.scene_cut
    assert flash.calibrating
    refute flash.motion
  end

  test "a geometry change starts over rather than comparing mismatched frames" do
    detector = calibrate(detector(), thumb(96, 54, 100))

    {verdict, detector} = Motion.observe(detector, thumb(96, 72, 200), at(@window))
    assert verdict == %{changed_fraction: 0.0, motion: false, calibrating: true, scene_cut: false}

    # ...and it re-calibrates at the new geometry: a whole fresh window,
    # rebased on the pts the geometry changed at.
    {verdict, _} = Motion.observe(detector, block(96, 72, 200, 96, 36, 40), at(@window + 1))
    refute verdict.motion
    assert verdict.calibrating
  end

  test "raising the threshold lowers the changed fraction monotonically" do
    # Four bands, each a different distance from the background.
    still = thumb(4, 4, 100)

    banded =
      [10, 20, 40, 80]
      |> Enum.with_index()
      |> Enum.reduce(still.tensor, fn {delta, row}, tensor ->
        Nx.put_slice(tensor, [row, 0], Nx.broadcast(Nx.tensor(100 + delta, type: :u8), {1, 4}))
      end)
      |> then(&%Thumbnail{w: 4, h: 4, tensor: &1})

    fraction_at = fn threshold ->
      detector = Motion.new(%Config{enabled: true, threshold: threshold})
      detector = calibrate(detector, still)
      {verdict, _} = Motion.observe(detector, banded, at(@window))
      verdict.changed_fraction
    end

    fractions = Enum.map([5, 15, 30, 60, 100], fraction_at)
    assert fractions == [1.0, 0.75, 0.5, 0.25, 0.0]

    # The property itself, as the crate asserts it — kept separately so the
    # exact-list assertion above can never quietly become the only guard on
    # monotonicity.
    for [higher, lower] <- Enum.chunk_every(fractions, 2, 1, :discard) do
      assert lower <= higher, "#{inspect(fractions)}"
    end
  end

  test "a faster alpha absorbs a held change sooner" do
    # Something moves into frame and stops there. The background is supposed
    # to learn it, and how fast is exactly what alpha says — this is the knob
    # that decides when a parked car stops being motion.
    still = thumb(20, 20, 100)
    held = block(20, 20, 100, 20, 10, 160)

    frames_to_settle = fn alpha ->
      detector = Motion.new(%Config{enabled: true, alpha: f32(alpha)})
      detector = calibrate(detector, still)

      Enum.reduce_while(1..500, detector, fn frame, detector ->
        {verdict, detector} = Motion.observe(detector, held, at(@window + frame))
        if verdict.motion, do: {:cont, detector}, else: {:halt, frame}
      end)
    end

    slow = frames_to_settle.(0.02)
    medium = frames_to_settle.(0.1)
    fast = frames_to_settle.(0.5)
    assert is_integer(fast), "the background absorbs a held change at any alpha"
    assert fast < medium, "#{fast} vs #{medium}"
    assert medium < slow, "#{medium} vs #{slow}"
  end

  # ---- the thumbnail --------------------------------------------------------

  test "the thumbnail keeps the content aspect under a width cap" do
    assert Thumbnail.thumb_size(416, 234) == {96, 54}
    assert Thumbnail.thumb_size(1920, 1080) == {96, 54}
    # The stretch profiles hand this a square content rect — it is the model
    # input itself — so the thumbnail is square whatever the camera's shape.
    assert Thumbnail.thumb_size(384, 384) == {96, 96}
    assert Thumbnail.thumb_size(640, 640) == {96, 96}
    # 4:3 stays 4:3 rather than being squashed into the 16:9 shape.
    assert Thumbnail.thumb_size(640, 480) == {96, 72}
    # Portrait: the cap is on the width, so the height is the long side.
    assert Thumbnail.thumb_size(480, 640) == {96, 128}
    # Already smaller than the cap: kept as it is, never scaled up.
    assert Thumbnail.thumb_size(64, 32) == {64, 32}
    # A sliver still has a usable row.
    assert Thumbnail.thumb_size(4000, 2) |> elem(1) == 1
  end

  test "a downsample averages each block rather than sampling a point" do
    # A 1-pixel checkerboard: every point sample is 0 or 255 and every box
    # mean is 127. Point sampling here would make a frame that shifted by one
    # pixel look like a total scene change.
    checker =
      rgb24(192, 108, fn x, y ->
        on = if rem(x + y, 2) == 0, do: 255, else: 0
        {on, on, on}
      end)

    thumb = Thumbnail.from_rgb24(checker, 192, 108)
    assert Thumbnail.size(thumb) == {96, 54}
    assert thumb.tensor |> Nx.equal(127) |> Nx.all() |> Nx.to_number() == 1
  end

  test "a downsample places constant blocks where they belong" do
    # Left half white, right half black: the boundary has to land in the
    # middle of the thumbnail, not be smeared across it.
    split =
      rgb24(192, 108, fn x, _y ->
        if x < 96, do: {255, 255, 255}, else: {0, 0, 0}
      end)

    thumb = Thumbnail.from_rgb24(split, 192, 108)
    left = Nx.slice(thumb.tensor, [0, 0], [54, 48])
    right = Nx.slice(thumb.tensor, [0, 48], [54, 48])
    assert left |> Nx.equal(255) |> Nx.all() |> Nx.to_number() == 1
    assert right |> Nx.equal(0) |> Nx.all() |> Nx.to_number() == 1
  end

  test "luma weights a grey ramp the way bt601 does" do
    # Grey in, the same grey out — the property the weights summing to 256
    # buys, and the one an off-by-one weight breaks at the white end.
    for level <- [0, 1, 77, 128, 254, 255] do
      thumb = Thumbnail.from_rgb24(rgb24(8, 4, fn _x, _y -> {level, level, level} end), 8, 4)
      assert thumb.tensor |> Nx.equal(level) |> Nx.all() |> Nx.to_number() == 1, "grey #{level}"
    end

    # ...and the channels are not interchangeable: green dominates, and a
    # saturated primary lands on its own weight scaled by 255/256.
    at = fn pixel ->
      Thumbnail.from_rgb24(rgb24(4, 4, fn _x, _y -> pixel end), 4, 4).tensor[[0, 0]]
      |> Nx.to_number()
    end

    assert {at.({255, 0, 0}), at.({0, 255, 0}), at.({0, 0, 255})} == {76, 149, 28}
  end

  test "a content rectangle smaller than the cap is copied pixel for pixel" do
    ramp =
      rgb24(8, 4, fn x, y ->
        v = (y * 8 + x) * 8
        {v, v, v}
      end)

    thumb = Thumbnail.from_rgb24(ramp, 8, 4)
    assert Thumbnail.size(thumb) == {8, 4}

    expected = Nx.iota({4, 8}) |> Nx.multiply(8) |> Nx.as_type(:u8)
    assert thumb.tensor |> Nx.equal(expected) |> Nx.all() |> Nx.to_number() == 1
  end

  test "the thumbnail reaches the detector as motion" do
    # The two halves together: a real RGB24 plane through the downsample and
    # into a verdict — the path `Cairn.Pipeline.MotionGate` takes per frame.
    still = Thumbnail.from_rgb24(rgb24(192, 108, fn _x, _y -> {30, 30, 30} end), 192, 108)

    moved =
      Thumbnail.from_rgb24(
        rgb24(192, 108, fn _x, y ->
          if y < 54, do: {220, 220, 220}, else: {30, 30, 30}
        end),
        192,
        108
      )

    detector = calibrate(detector(), still)
    {verdict, _} = Motion.observe(detector, moved, at(@window))
    assert verdict.motion
    assert_in_delta verdict.changed_fraction, 0.5, 0.02
  end

  test "a payload of the wrong geometry is refused, not misread" do
    plan = Thumbnail.plan(8, 4)

    assert_raise ArgumentError, ~r/9 bytes, not the 96/, fn ->
      Thumbnail.from_rgb24(<<0::size(9 * 8)>>, plan)
    end
  end

  # ---- config ---------------------------------------------------------------

  test "the gate is off unless it is switched on" do
    assert Config.resolve(%{}, %{}) == nil
    # Every other knob set, still off.
    {:ok, tuned} = Config.parse(~s({"threshold":40,"alpha":0.1}))
    assert Config.resolve(tuned, %{}) == nil
    refute %Config{}.enabled
    # The unconfigured gate, as the camera spec reads it.
    assert Config.resolve_json(nil) == {:ok, nil}
  end

  test "an enabled gate resolves to the documented defaults" do
    {:ok, overrides} = Config.parse(~s({"enabled":true}))
    config = Config.resolve(overrides, %{})
    assert config == %Config{enabled: true}
    assert config.threshold == 25
    assert config.min_area_fraction == f32(0.005)
    assert config.alpha == f32(0.02)
    assert config.linger_ms == 12_000
    assert config.epoch_bypass_ms == 15_000
    assert config.reverify_ms == 10_000
  end

  test "a camera overrides only the knobs it names" do
    {:ok, global} = Config.parse(~s({"enabled":true,"threshold":40,"alpha":0.1}))
    {:ok, camera} = Config.parse(~s({"threshold":15,"linger_ms":30000}))

    resolved = Config.resolve(global, camera)
    assert resolved.threshold == 15, "the camera's own value wins"
    assert resolved.alpha == f32(0.1), "the global value survives"
    assert resolved.linger_ms == 30_000
    assert resolved.min_area_fraction == f32(0.005), "a knob neither names keeps the default"
    # The other camera in the same group is unaffected.
    assert Config.resolve(global, %{}).threshold == 40
  end

  test "a camera can switch the gate on or off by itself" do
    {:ok, on} = Config.parse(~s({"enabled":true}))
    {:ok, off} = Config.parse(~s({"enabled":false}))
    assert %Config{} = Config.resolve(%{}, on)
    assert Config.resolve(on, off) == nil
  end

  test "every knob parses from json" do
    all = ~s({"enabled":true,"threshold":30,"min_area_fraction":0.02,"alpha":0.05,
              "linger_ms":9000,"epoch_bypass_ms":20000,"reverify_ms":4000})

    {:ok, overrides} = Config.parse(all)

    assert Config.resolve(overrides, %{}) == %Config{
             enabled: true,
             threshold: 30,
             min_area_fraction: f32(0.02),
             alpha: f32(0.05),
             linger_ms: 9_000,
             epoch_bypass_ms: 20_000,
             reverify_ms: 4_000
           }
  end

  test "out-of-range knobs are refused at parse time" do
    for json <- [
          ~s({"threshold":0}),
          # 255 is the largest difference two pixels can have and the compare
          # is strict, so it counts nothing as changed.
          ~s({"threshold":255}),
          ~s({"min_area_fraction":0}),
          ~s({"min_area_fraction":1.5}),
          ~s({"min_area_fraction":-0.1}),
          # At or above the scene-cut fraction the floor is unreachable.
          ~s({"min_area_fraction":0.8}),
          ~s({"min_area_fraction":1}),
          ~s({"alpha":0}),
          ~s({"alpha":1.5}),
          # The switch does not exempt the knobs under it — an experiment
          # parked behind `enabled: false` fails at parse rather than waiting
          # there to be switched on.
          ~s({"enabled":false,"alpha":0}),
          # Beyond u64: the inference side's Rust parser reads the same JSON
          # into u64 fields, so accepting it here would only defer the
          # failure to stream open.
          ~s({"linger_ms":18446744073709551616})
        ] do
      assert {:error, _message} = Config.parse(json), "#{json} parsed"
    end

    # The edges that do something are legal: alpha 1 is "the background is
    # the last frame", threshold 254 is "only a near-total swing counts", and
    # a floor just under the scene-cut fraction is the least sensitive gate
    # that can still fire.
    assert {:ok, _} = Config.parse(~s({"alpha":1,"min_area_fraction":0.79,"threshold":254}))
  end

  test "an explicitly null knob reads as unset rather than as an error" do
    # `null` maps onto the same "unset" an absent key produces, as serde
    # reads it, so a template layer that emits nulls for the knobs it has no
    # value for runs on the defaults.
    {:ok, parsed} = Config.parse(~s({"enabled":true,"threshold":null}))
    assert parsed.threshold == nil
    assert Config.resolve(parsed, %{}).threshold == 25
  end

  test "malformed and mistyped knobs are refused" do
    assert {:error, _} = Config.parse("not json")
    assert {:error, _} = Config.parse("[]")
    assert {:error, _} = Config.parse(~s({"enabled":"yes"}))
    assert {:error, _} = Config.parse(~s({"threshold":300}))
    # A mistyped knob is refused rather than silently running on defaults.
    assert {:error, _} = Config.parse(~s({"enable":true}))
    assert {:error, _} = Config.parse(~s({"min_area":0.1}))
    # A fractional threshold is not an integer knob.
    assert {:error, _} = Config.parse(~s({"threshold":25.5}))
    assert {:error, _} = Config.parse(~s({"linger_ms":-1}))
    # ...and an empty object is the documented "all defaults".
    assert {:ok, %{}} == Config.parse("{}")
  end
end
