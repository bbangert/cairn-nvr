defmodule Cairn.Tracker.Bbd do
  @moduledoc """
  StableTrack's Bbox-Based Distance (arXiv 2511.20418, appendices B and C): a
  Mahalanobis-style distance between two boxes' centres, over a covariance
  built deterministically from the predicted box's geometry and the time
  elapsed since the track was last positioned by an observation.

  ## Why a deterministic covariance

  The usual way to gate a match by Mahalanobis distance is to take the
  covariance from the filter that produced the prediction. That is a good
  choice when the filter is well fed: the covariance is the filter's own
  earned account of how wrong it might be, updated against a run of real
  measurements. Under sparse or low-frequency detections it is the wrong
  choice, because the filter's covariance is precisely the quantity that has
  gone unreliable — after a long coast it is a projection of process noise
  that no measurement has corrected, and asking it whether the coast is still
  trustworthy is asking the extrapolation to grade itself.

  BBD rebuilds the covariance on every comparison instead, out of two things
  that remain known however long the gap was: the predicted box's width and
  height, which say how large the object is on screen and therefore what
  counts as a large offset for *this* object, and the elapsed time, which says
  how much room the object had to move. Nothing in the distance depends on the
  filter's internal state, so a filter that has drifted into overconfidence
  or into uselessness changes where the box is but not how far away a
  detection is allowed to be.

  ## Invariance under frame normalization

  The paper states the formula in pixels; cairn's boxes are frame-normalized.
  The distance is unchanged by that, and the derivation is worth keeping here
  because two of the constants below — `@c` and `@theta` — are carried over
  from the paper on the strength of it.

  The x-term is `dx / (c * w * sqrt(clip))`, where `dx` is a distance along
  the frame's width and `w` a length along the same axis. Normalizing divides
  both by the frame width, and the ratio of two quantities divided by the same
  number is the number it was. The y-term is the same argument along the
  height. What makes the argument work is the covariance's axis pairing — the
  x-term scaled by `w`, the y-term by `h`. A covariance that mixed the axes,
  scaling both terms by a diagonal or by a mean dimension, would end up
  dividing a width-normalized length by a height-normalized one, and would
  come apart on any frame that is not square.

  So `@c` and `@theta` are pure numbers and carry over from the published
  values arithmetically rather than by re-tuning, and the clip bounds carry
  over as published too — the paper quotes them in seconds. The one unit left
  for a caller to respect is therefore time: cairn's clocks run in
  milliseconds, and a gap must be handed in as seconds for the bounds to mean
  what the paper meant. That invariance is a claim about this arithmetic, and
  it is pinned by a property test that feeds the same boxes in both spaces
  rather than by constants derived a second time by hand.

  ## The threshold is wide here

  At cairn's batch cadence of roughly 500 ms, `delta_tau_s` almost always
  exceeds `@clip_max_s` and the time term saturates at its cap. The gate then
  degenerates to a fixed ellipse around the predicted centre:

      (dx / w)^2 + (dy / h)^2 < theta^2 * clip_max = 64

  which is a radius of about eight box-widths. That is wide for greedy
  matching. StableTrack can afford it because BBD is only the admission gate
  there, with a Re-ID appearance similarity supplying the cost *inside* the
  gate; cairn has no appearance term, so whatever the gate admits is ranked on
  geometry alone. `@theta` therefore ships at the published default rather
  than at a guess, and is the first knob to move under soak measurement — most
  likely downwards.

  ## Units

  Boxes are `[x, y, w, h]` **normalized to the frame**, `x, y` the top-left
  corner — the same convention as `Cairn.Tracker.iou/2` and
  `Cairn.Tracker.Kalman`. The elapsed time is in seconds.

  The arithmetic itself is unit-agnostic, which is the whole of the invariance
  point above, and the property test exploits that by feeding it pixel boxes.
  The one term that is not scale-free is the `@min_dim` floor, which is stated
  in frame fractions and so only means what it says on normalized input.

  ## Role

  A second admission test for association pairs that fail the IoU gate. Two
  boxes that do not overlap have an IoU of exactly zero and are
  indistinguishable under it, however near or far apart they are; after a
  coast long enough for a walking object to clear its own width, that is every
  pair including the right one. A centre distance scaled by box size and
  elapsed time separates those cases, so it can widen admission without
  widening it uniformly — a small, distant box is allowed a small absolute
  offset and a large, near one a large one.
  """

  # StableTrack's global scaling constant on the covariance (appendix B). It
  # survives the move to frame-normalized coordinates unchanged for the reason
  # in the module doc — it multiplies a ratio of two same-axis lengths, which
  # normalization leaves alone — and not because anything here re-tuned it.
  @c 1.0

  # The clip bounds α and β on the elapsed time (appendix B), in seconds as
  # published — the suffix is a reminder that cairn's millisecond clocks need
  # converting before a gap is compared against these. The lower bound keeps
  # the covariance from
  # collapsing towards zero on a tiny gap, which would turn any offset at all
  # into an enormous distance; the upper bound caps how far temporal
  # uncertainty is allowed to grow, so an arbitrarily long coast does not
  # eventually admit an arbitrarily distant box.
  @clip_min_s 0.025
  @clip_max_s 0.25

  # The admission threshold (appendix C, table 7). At cairn's ~500 ms cadence
  # the time term is almost always saturated at `@clip_max_s`, so this is in
  # effect a fixed ellipse of `(dx/w)^2 + (dy/h)^2 < 64` — a radius of about
  # eight box-widths, which is wide for a greedy matcher with no appearance
  # term to rank inside the gate. It is the published default, and the first
  # thing to tighten under measurement.
  @theta 16

  # Floor for the predicted box's dimensions. Deliberately three orders of
  # magnitude above `Cairn.Tracker.Kalman`'s `1.0e-6` state floor, because the
  # dimension enters here squared in a denominator: at `1.0e-6` a degenerate
  # box turns any ordinary offset into a distance in the millions, which does
  # not fail loudly but silently refuses every pair the box appears in.
  # Distance blow-up on degenerate boxes is BBD's documented failure mode. At
  # a thousandth of a frame the same box yields a distance that is large but
  # stays in a range a threshold can still reason about.
  @min_dim 1.0e-3

  @typedoc "A frame-normalized `[x, y, w, h]` box."
  @type bbox :: [number()]

  @doc """
  The Bbox-Based Distance between a predicted box and a detection, given the
  elapsed time since the track was last positioned by an observation.

  The covariance is `diag((c*w)^2, (c*h)^2) * clip`, with `w` and `h` taken
  from the **predicted** box — the detection's own dimensions never enter,
  only its centre. That asymmetry is deliberate: the scale that decides what
  counts as a large offset is the tracker's belief about the object, and a
  detection that is a badly sized box for the object it belongs to should not
  get to widen its own gate.

  `delta_tau_s` is clipped into `#{@clip_min_s}..#{@clip_max_s}` seconds
  before use, which is also what makes a zero or negative gap safe to pass.
  """
  @spec distance(bbox(), bbox(), number()) :: float()
  def distance([x, y, w, h], detection_bbox, delta_tau_s) do
    # The floor is applied before the centre is taken, so that a degenerate
    # predicted box is one box to both halves of the formula rather than a
    # zero-width box to the numerator and a floored one to the denominator.
    # The floor moves a centre by at most half a thousandth of a frame, which
    # is below anything the distance is asked to resolve.
    width = max(w * 1.0, @min_dim)
    height = max(h * 1.0, @min_dim)

    {predicted_cx, predicted_cy} = centre([x, y, width, height])
    {detection_cx, detection_cy} = centre(detection_bbox)

    clip = clip(delta_tau_s)

    x_term = (predicted_cx - detection_cx) / (@c * width)
    y_term = (predicted_cy - detection_cy) / (@c * height)

    :math.sqrt((x_term * x_term + y_term * y_term) / clip)
  end

  @doc """
  Whether a pair whose distance is `distance` is close enough to be matched.

  Takes an already-computed distance rather than the two boxes and a gap,
  because a caller that admits pairs also has to rank them: the distance is
  the cost it sorts by, so it holds the number already and a three-argument
  form would make it compute the same distance twice.

  The comparison is strict, matching the paper's stage-one cost formula, which
  gates on `D < #{@theta}`; a distance landing exactly on the threshold is a
  measure-zero case either way.
  """
  @spec admit?(float()) :: boolean()
  def admit?(distance), do: distance < @theta

  @spec centre(bbox()) :: {float(), float()}
  defp centre([x, y, w, h]), do: {x + w / 2, y + h / 2}

  # The clamp runs on both sides, so it doubles as the guard against a
  # nonsensical gap: a caller whose clocks disagree, or which asks about a
  # track positioned this instant, hands in zero or a negative number and gets
  # the same covariance as the shortest gap the bounds admit.
  @spec clip(number()) :: float()
  defp clip(delta_tau_s), do: delta_tau_s |> max(@clip_min_s) |> min(@clip_max_s)
end
