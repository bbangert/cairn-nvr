defmodule Cairn.Tracker.KalmanTest do
  use ExUnit.Case, async: true

  alias Cairn.Tracker.Kalman

  # One batch as a caller runs it: coast the state forward, then fold in what
  # was actually observed. Every test here steps through this rather than
  # calling `update/2` alone, because a filter is only ever exercised that way
  # and the two halves' noise terms are tuned against each other.
  defp step(kf, bbox), do: kf |> Kalman.predict() |> Kalman.update(bbox)

  # `[x, y, w, h]` for a box of the given size centred on `{cx, cy}` — the
  # trajectories below are written in centres, which is what the filter tracks,
  # while its API speaks the host's top-left convention.
  defp centred(cx, cy, w, h), do: [cx - w / 2, cy - h / 2, w, h]

  defp centre_x([x, _y, w, _h]), do: x + w / 2

  defp diagonal(covariance) do
    covariance
    |> Enum.with_index()
    |> Enum.map(fn {row, i} -> Enum.at(row, i) end)
  end

  defp element(m, i, j), do: m |> Enum.at(i) |> Enum.at(j)

  # What `predicted_bbox/1` promises, and the whole of it: a positive width and
  # height no larger than the frame, and four finite numbers. The origin is
  # deliberately unbounded — a prediction has to be able to follow an object
  # out of shot, and a detection may legally overhang the frame edge — so a
  # containment assertion here would pin a property the module does not have
  # and must not acquire.
  defp assert_positive_area([x, y, w, h]) do
    assert w > 0.0
    assert h > 0.0
    assert w <= 1.0
    assert h <= 1.0

    Enum.each([x, y, w, h], &assert_finite/1)
  end

  defp assert_positive_shape(kf) do
    [_cx, _cy, a, h | _velocities] = kf.mean

    assert a > 0.0
    assert h > 0.0

    assert_positive_area(Kalman.predicted_bbox(kf))
  end

  # Three separate ways a float can be garbage and still be a float, so
  # `is_float/1` alone proves nothing: NaN is the one value not equal to
  # itself, an infinity passes any self-equality check, and a merely enormous
  # value passes both. The magnitude bound is far above anything a
  # frame-normalized state can legitimately reach.
  defp assert_finite(value) do
    assert is_float(value)
    assert equal?(value, value)
    assert abs(value) < 1.0e6
  end

  # The self-equality above has to go through a call: written inline it reads
  # as a tautology to a human and to Credo alike, and only the runtime knows
  # that for one float it is false.
  defp equal?(a, b), do: a == b

  describe "convergence on constant velocity" do
    test "velocity and box converge on a track moving 0.01 per step" do
      # 50 noiseless samples of a box sliding right at a hundredth of the frame
      # per step. Nothing here is random: the filter's only job is to work out
      # that the centre is advancing, and how fast, from the positions alone —
      # velocity is never measured.
      kf =
        Enum.reduce(1..50, Kalman.init(centred(0.20, 0.50, 0.10, 0.20)), fn k, kf ->
          step(kf, centred(0.20 + 0.01 * k, 0.50, 0.10, 0.20))
        end)

      {vcx, vcy} = Kalman.velocity(kf)

      assert_in_delta vcx, 0.01, 1.0e-4
      # The trajectory has no vertical component at all, so this one is exact:
      # every innovation in y is zero and nothing ever moves `vcy` off its
      # initial zero.
      assert vcy == 0.0

      [x, y, w, h] = Kalman.predicted_bbox(kf)
      [true_x, true_y, true_w, true_h] = centred(0.70, 0.50, 0.10, 0.20)

      assert_in_delta x, true_x, 1.0e-4
      assert_in_delta y, true_y, 1.0e-9
      assert_in_delta w, true_w, 1.0e-9
      assert_in_delta h, true_h, 1.0e-9
    end
  end

  describe "a parked box loses its velocity" do
    # `stationary_after_ms` defaults to 10_000 (`Cairn.Config`), which at the
    # 5 fps the detector runs at is 50 samples. The filter must have settled
    # inside that window or the stillness judgement would be made against a
    # velocity that is still decaying.
    @parked_samples 50

    test "a box that never moves keeps zero velocity" do
      kf =
        Enum.reduce(1..@parked_samples, Kalman.init(centred(0.30, 0.30, 0.10, 0.20)), fn _k, kf ->
          step(kf, centred(0.30, 0.30, 0.10, 0.20))
        end)

      {vcx, vcy} = Kalman.velocity(kf)

      assert_in_delta vcx, 0.0, 1.0e-9
      assert_in_delta vcy, 0.0, 1.0e-9
    end

    test "a box that moved once and then parked is pulled back to zero" do
      # The case that matters: stillness has to be *earned* after motion, not
      # merely never lost. One step of real motion leaves the filter believing
      # in a velocity of roughly 0.0103 per step, and the 50 parked samples
      # then have to talk it back down.
      moved =
        Kalman.init(centred(0.30, 0.30, 0.10, 0.20))
        |> step(centred(0.35, 0.30, 0.10, 0.20))

      {moving_vcx, _vcy} = Kalman.velocity(moved)
      assert moving_vcx > 0.01

      parked =
        Enum.reduce(1..@parked_samples, moved, fn _k, kf ->
          step(kf, centred(0.35, 0.30, 0.10, 0.20))
        end)

      {vcx, vcy} = Kalman.velocity(parked)

      assert_in_delta vcx, 0.0, 1.0e-4
      assert_in_delta vcy, 0.0, 1.0e-4
    end
  end

  describe "missed updates" do
    test "predict-only coasting drifts linearly and grows the covariance" do
      # Ten observed steps to establish a heading, then fifteen batches in
      # which nothing detected this object at all.
      established =
        Enum.reduce(1..10, Kalman.init(centred(0.20, 0.50, 0.10, 0.20)), fn k, kf ->
          step(kf, centred(0.20 + 0.01 * k, 0.50, 0.10, 0.20))
        end)

      {coasted, centres, positional_variances} =
        Enum.reduce(1..15, {established, [], []}, fn _k, {kf, centres, variances} ->
          kf = Kalman.predict(kf)

          {kf, [centre_x(Kalman.predicted_bbox(kf)) | centres],
           [element(kf.covariance, 0, 0) | variances]}
        end)

      centres = Enum.reverse(centres)
      positional_variances = Enum.reverse(positional_variances)

      # A constant-velocity model with no measurement to correct it advances by
      # exactly its velocity every step, so the steps are identical to within
      # the float noise of one addition — a coast that curved would mean the
      # motion matrix was doing something other than `x += v`.
      [first_delta | rest_deltas] =
        centres
        |> Enum.zip(tl(centres))
        |> Enum.map(fn {previous, current} -> current - previous end)

      assert first_delta > 0.0

      for delta <- rest_deltas do
        assert_in_delta delta, first_delta, 1.0e-12
      end

      # And the filter's confidence has to decay while it coasts: every step
      # adds a step's process noise plus the velocity uncertainty projected
      # onto position, and nothing subtracts.
      for {previous, current} <-
            Enum.zip(positional_variances, tl(positional_variances)) do
        assert current > previous
      end

      assert element(coasted.covariance, 0, 0) > element(established.covariance, 0, 0)
    end
  end

  describe "aspect and height stay positive" do
    test "a vanishing box is floored before the state is ever seeded from it" do
      # A degenerate detection: a box a billionth of the frame across, three
      # orders of magnitude under the floor. This pins the *measurement* floor
      # in `to_measurement/1`, which is the only thing such an input can
      # actually exercise: the floors bite before `init/1` writes a mean, and
      # repeating the same degenerate box thereafter produces an innovation of
      # about zero, so the state never travels anywhere the state clamp would
      # have to catch it. The guarantee that `clamp_state/1` holds a mean off
      # zero is a different claim about a different input, and belongs to the
      # shrink-then-coast test below.
      degenerate = [0.10, 0.10, 1.0e-9, 1.0e-9]

      [_cx, _cy, a, h | _velocities] = Kalman.init(degenerate).mean

      # Both floors biting, read straight off the seeded mean: the height is
      # the floor itself rather than the billionth that was handed in, and the
      # aspect ratio is the ratio of two floored lengths rather than a `0/0`.
      assert a == 1.0
      assert h == 1.0e-6

      # And the shape invariant survives the input being fed for a while,
      # which is what a caller would actually do with a stuck detector.
      kf =
        Enum.reduce(1..30, Kalman.init(degenerate), fn _k, kf ->
          kf = step(kf, degenerate)

          assert_positive_shape(kf)
          kf
        end)

      assert_positive_shape(kf)
    end

    test "a shrinking box coasted for 200 steps cannot cross zero height" do
      shrinking =
        Enum.reduce(1..20, Kalman.init(centred(0.40, 0.40, 0.10, 0.20)), fn k, kf ->
          h = max(0.20 - 0.009 * k, 0.001)

          step(kf, centred(0.40, 0.40, h / 2, h))
        end)

      # The precondition that makes the clamp load-bearing rather than
      # decorative: the filter now believes the box is shrinking by roughly
      # 0.009 per step while standing 0.02 tall, so an unclamped state crosses
      # zero height inside three predict-only steps and is deeply negative
      # after two hundred.
      [_cx, _cy, _a, height | _velocities] = shrinking.mean
      vh = Enum.at(shrinking.mean, 7)

      assert vh < 0.0
      assert height / abs(vh) < 5.0

      coasted =
        Enum.reduce(1..200, shrinking, fn _k, kf ->
          kf = Kalman.predict(kf)

          assert_positive_shape(kf)
          kf
        end)

      # Bottomed out *on* the floor, not through it, and still emitting a box a
      # caller can hand to an IoU test. The equality is the point: `vh` is
      # untouched by `predict/1`, so an unclamped state would be at roughly
      # `-1.8` by now, and anything short of exact-floor equality would also
      # pass for a state that merely happened to land somewhere small.
      [_cx, _cy, _a, floored | _velocities] = coasted.mean
      assert floored == 1.0e-6
    end

    test "a box coasted out of frame follows the object out, and its overlap decays" do
      # Ten observed steps establishing a heading of 0.03 per step towards the
      # bottom-right, then predict-only for long enough that the state's centre
      # is outside the image altogether.
      established =
        Enum.reduce(1..10, Kalman.init(centred(0.60, 0.60, 0.10, 0.20)), fn k, kf ->
          step(kf, centred(0.60 + 0.03 * k, 0.60 + 0.03 * k, 0.10, 0.20))
        end)

      # A box the object was last seen near and that stays put, so the decay
      # below is the prediction leaving rather than anything moving to meet it.
      parked = centred(0.90, 0.90, 0.10, 0.20)

      {coasted, overlaps, corners} =
        Enum.reduce(1..20, {established, [], []}, fn _k, {kf, overlaps, corners} ->
          kf = Kalman.predict(kf)
          [x, _y, w, _h] = box = Kalman.predicted_bbox(kf)

          # positive, bounded area at every step — what the overlap arithmetic
          # downstream needs, and the whole of what this box promises
          assert_positive_area(box)

          {kf, [Cairn.Tracker.iou(box, parked) | overlaps], [{x, w} | corners]}
        end)

      # `clamp_state/1` deliberately leaves the centre free to leave the frame,
      # and the mean says it did — both coordinates are past the far edge.
      [cx, cy, _a, _h | _velocities] = coasted.mean

      assert cx > 1.0
      assert cy > 1.0

      # And the handed-out box goes with it rather than being pinned flush
      # against the edge: `x` is past the far corner a clamped origin would
      # have stopped at, and it kept moving after it got there.
      [{last_x, last_w} | _rest] = corners
      assert last_x > 1.0 - last_w

      origins = corners |> Enum.reverse() |> Enum.map(&elem(&1, 0))
      assert origins == Enum.sort(origins)

      # The point of letting it leave: overlap with an in-frame box decays to
      # nothing instead of snapping to whatever the border would allow.
      overlaps = Enum.reverse(overlaps)

      assert List.first(overlaps) > 0.0
      assert List.last(overlaps) == 0.0
      assert overlaps == Enum.sort(overlaps, :desc)
    end

    test "a box grown wider than the frame is capped at the frame's width" do
      # A height ramped to 0.9 at a fixed aspect ratio of 1.5, so the state's
      # own `a * h` ends up wider than the whole frame. The aspect ratio never
      # moves off the 1.5 the filter was seeded with — every measurement
      # carries that same ratio, so every innovation in `a` is exactly zero —
      # which leaves the height as the only thing driving the width.
      grown =
        Enum.reduce(1..40, Kalman.init(centred(0.50, 0.50, 0.30, 0.20)), fn k, kf ->
          height = min(0.20 + 0.05 * k, 0.90)
          kf = step(kf, centred(0.50, 0.50, 1.5 * height, height))

          assert_positive_area(Kalman.predicted_bbox(kf))
          kf
        end)

      # The precondition that makes the cap load-bearing rather than
      # decorative: the state now believes in a box wider than the whole frame,
      # so an uncapped width would hand out a box with more area than the image
      # has.
      [_cx, _cy, a, height | _velocities] = grown.mean

      assert a * height > 1.0

      # Capped at the full frame width. The origin is not capped with it — it
      # is wherever the centre puts a box of that width, which for a box
      # centred at 0.5 is zero, and the assertion below is about the width.
      [_x, _y, w, _h] = Kalman.predicted_bbox(grown)

      assert w == 1.0
    end
  end

  describe "numeric stability" do
    test "1000 steps on an oscillating trajectory stay finite and symmetric" do
      # A slow deterministic wobble on two different periods, for a thousand
      # predict-and-update cycles. This is the shape of a long-lived parked
      # track with a jittery detector, which is where a hand-rolled filter
      # accumulates asymmetry in the covariance and eventually cannot invert
      # the innovation covariance at all.
      kf =
        Enum.reduce(1..1000, Kalman.init(centred(0.40, 0.40, 0.10, 0.20)), fn k, kf ->
          cx = 0.45 + 0.05 * :math.sin(k / 20)
          cy = 0.45 + 0.03 * :math.cos(k / 30)

          step(kf, centred(cx, cy, 0.10, 0.20))
        end)

      for value <- kf.mean do
        assert_finite(value)
      end

      for row <- kf.covariance, value <- row do
        assert_finite(value)
      end

      for variance <- diagonal(kf.covariance) do
        assert variance > 0.0
      end

      for i <- 0..7, j <- 0..7 do
        assert_in_delta element(kf.covariance, i, j), element(kf.covariance, j, i), 1.0e-9
      end

      assert_positive_area(Kalman.predicted_bbox(kf))
    end
  end
end
