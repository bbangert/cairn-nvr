defmodule Cairn.Tracker.BbdTest do
  use ExUnit.Case, async: true

  alias Cairn.Tracker.Bbd

  # The two clip bounds and the threshold, restated here rather than read off
  # the module: a test that computed its expectations from the same attribute
  # the code uses would pass unchanged if the attribute moved, which is the one
  # thing these tests exist to notice.
  @clip_min_s 0.025
  @clip_max_s 0.25
  @theta 16

  # Dimensions no smaller than 0.01 of a frame keep the `@min_dim` floor
  # disengaged in both spaces — it is the one term in the formula that is
  # stated in frame fractions and so does not scale, and a box small enough to
  # trip it in normalized space would not trip it in pixels.
  defp random_box do
    [
      :rand.uniform() * 0.5,
      :rand.uniform() * 0.5,
      0.01 + :rand.uniform() * 0.49,
      0.01 + :rand.uniform() * 0.49
    ]
  end

  defp to_pixels([x, y, w, h], frame_w, frame_h) do
    [x * frame_w, y * frame_h, w * frame_w, h * frame_h]
  end

  # A float's self-equality has to go through a call: written inline it reads
  # as a tautology to a human and to Credo alike, and only the runtime knows
  # that for one float it is false.
  defp equal?(a, b), do: a == b

  describe "distance/3" do
    test "a box offset by a known fraction of its own size, inside the clip band" do
      # Predicted box 0.2 wide and 0.1 tall, centred at (0.5, 0.45). The
      # detection is the same box shifted right by 0.06 and down by 0.02, so
      # its centre is (0.56, 0.47) and the offsets are 0.3 of a width and 0.2
      # of a height. At a gap of 0.1 s the clip is inert — 0.1 lies strictly
      # between 0.025 and 0.25 — so the whole of the time term is the divisor.
      predicted = [0.4, 0.4, 0.2, 0.1]
      detection = [0.46, 0.42, 0.2, 0.1]

      expected =
        :math.sqrt(0.06 / 0.2 * (0.06 / 0.2) + 0.02 / 0.1 * (0.02 / 0.1)) / :math.sqrt(0.1)

      assert_in_delta Bbd.distance(predicted, detection, 0.1), expected, 1.0e-12
      # sqrt(0.09 + 0.04) / sqrt(0.1), spelled out as a number so a change in
      # the shape of the formula cannot quietly agree with itself.
      assert_in_delta Bbd.distance(predicted, detection, 0.1), 1.140175425, 1.0e-9
    end

    test "a tall narrow box, offset in x only, at a different gap" do
      # Predicted box 0.05 wide and 0.4 tall, centred at (0.125, 0.4). The
      # detection is a much larger box whose centre is (0.4, 0.4) — same y, so
      # the y-term vanishes and the x-term is 0.275 / 0.05 = 5.5 widths. The
      # gap of 0.2 s is again strictly inside the band.
      predicted = [0.10, 0.20, 0.05, 0.40]
      detection = [0.20, 0.10, 0.40, 0.60]

      expected = 0.275 / 0.05 / :math.sqrt(0.2)

      assert_in_delta Bbd.distance(predicted, detection, 0.2), expected, 1.0e-12
      assert_in_delta Bbd.distance(predicted, detection, 0.2), 12.298373876, 1.0e-9
    end

    test "the detection's dimensions enter only through its centre" do
      # Two detections with the same centre and wildly different sizes. The
      # scale that decides what counts as a large offset comes from the
      # predicted box alone, so these have to agree exactly.
      predicted = [0.10, 0.20, 0.05, 0.40]
      large = [0.20, 0.10, 0.40, 0.60]
      small = [0.39, 0.395, 0.02, 0.01]

      assert Bbd.distance(predicted, large, 0.2) == Bbd.distance(predicted, small, 0.2)
    end

    test "swapping the arguments changes the distance" do
      # The covariance is built from the predicted box alone, so the same two
      # boxes at the same gap measure differently depending on which one is
      # doing the predicting — a narrow prediction judges a given offset more
      # harshly than a wide one would.
      predicted = [0.10, 0.20, 0.05, 0.40]
      detection = [0.20, 0.10, 0.40, 0.60]

      forward = Bbd.distance(predicted, detection, 0.2)
      swapped = Bbd.distance(detection, predicted, 0.2)

      assert forward > swapped
    end
  end

  describe "the elapsed-time clip" do
    setup do
      %{predicted: [0.4, 0.4, 0.2, 0.1], detection: [0.46, 0.42, 0.2, 0.1]}
    end

    test "a gap under the lower bound is the lower bound", %{
      predicted: predicted,
      detection: detection
    } do
      floored = Bbd.distance(predicted, detection, @clip_min_s)

      assert Bbd.distance(predicted, detection, 0.01) == floored
      assert Bbd.distance(predicted, detection, 0.0) == floored
      # A negative gap is a caller whose clocks disagree, and the same clamp
      # catches it before it reaches a square root.
      assert Bbd.distance(predicted, detection, -1.0) == floored
    end

    test "a gap over the upper bound is the upper bound", %{
      predicted: predicted,
      detection: detection
    } do
      capped = Bbd.distance(predicted, detection, @clip_max_s)

      assert Bbd.distance(predicted, detection, 5.0) == capped
      assert Bbd.distance(predicted, detection, 600.0) == capped
    end

    test "inside the band a longer gap is a smaller distance", %{
      predicted: predicted,
      detection: detection
    } do
      # The covariance grows with elapsed time, so the same offset counts for
      # less the longer the track has gone unobserved. Strict, because a clip
      # that had accidentally clamped one of these would make them equal.
      short = Bbd.distance(predicted, detection, 0.03)
      middle = Bbd.distance(predicted, detection, 0.10)
      long = Bbd.distance(predicted, detection, 0.20)

      assert short > middle
      assert middle > long
    end
  end

  describe "degenerate predicted boxes" do
    test "a zero-width prediction is floored rather than dividing by zero" do
      detection = [0.46, 0.42, 0.2, 0.1]

      floored = Bbd.distance([0.4, 0.4, 1.0e-3, 0.1], detection, 0.1)

      assert Bbd.distance([0.4, 0.4, 0.0, 0.1], detection, 0.1) == floored
      assert Bbd.distance([0.4, 0.4, 1.0e-9, 0.1], detection, 0.1) == floored

      # Large, as it should be — the offset is some hundred and sixty times a
      # box this thin — but a number, and one a threshold can still act on. The
      # self-equality is the NaN check; a float is the only value that can
      # fail it.
      assert is_float(floored)
      assert equal?(floored, floored)
      assert floored > 100.0
      assert floored < 1.0e6
    end

    test "a zero-height prediction is floored the same way" do
      detection = [0.46, 0.42, 0.2, 0.1]

      floored = Bbd.distance([0.4, 0.4, 0.2, 1.0e-3], detection, 0.1)

      assert Bbd.distance([0.4, 0.4, 0.2, 0.0], detection, 0.1) == floored
      assert floored < 1.0e6
    end
  end

  describe "admit?/1" do
    test "admits below the threshold and refuses at or above it" do
      assert Bbd.admit?(0.0)
      assert Bbd.admit?(@theta - 1.0e-9)
      refute Bbd.admit?(@theta * 1.0)
      refute Bbd.admit?(@theta + 1.0e-9)
      refute Bbd.admit?(1.0e6)
    end

    test "the threshold is what separates two real pairs" do
      # Two detections either side of the gate at a saturated gap, which is
      # the regime the tracker actually runs in. At the cap the admitted
      # radius in x alone is 8 widths, so 7 widths is in and 9 is out.
      predicted = [0.4, 0.4, 0.02, 0.1]

      near = [0.4 + 7 * 0.02, 0.4, 0.02, 0.1]
      far = [0.4 + 9 * 0.02, 0.4, 0.02, 0.1]

      assert predicted |> Bbd.distance(near, 1.0) |> Bbd.admit?()
      refute predicted |> Bbd.distance(far, 1.0) |> Bbd.admit?()
    end
  end

  describe "invariance under frame normalization" do
    @cases 200

    test "the same boxes in pixels and in frame fractions give the same distance" do
      # The claim the module doc's derivation makes, checked rather than
      # re-derived: `c` and `theta` are published in pixel space and used here
      # in normalized space unchanged, which is only sound if the distance is
      # blind to the scaling. A fixed seed keeps a failure reproducible.
      :rand.seed(:exsss, {20_260_804, 1_741, 99})

      for _case <- 1..@cases do
        frame_w = 160 + :rand.uniform(3681) - 1
        frame_h = 160 + :rand.uniform(3681) - 1

        predicted = random_box()
        detection = random_box()
        gap = :rand.uniform() * 2.0

        normalized = Bbd.distance(predicted, detection, gap)

        pixels =
          Bbd.distance(
            to_pixels(predicted, frame_w, frame_h),
            to_pixels(detection, frame_w, frame_h),
            gap
          )

        # Relative, because the distances range over several orders of
        # magnitude; the absolute floor covers the pairs that land near zero,
        # where a relative bound means nothing.
        assert_in_delta normalized, pixels, 1.0e-9 * max(normalized, 1.0)
      end
    end
  end
end
