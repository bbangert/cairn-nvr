defmodule Cairn.Tracker.Stage.Bbd do
  @moduledoc """
  Bounding-box distance admission: the second association, as a batch stage.

  Pairs the IoU gate refused, admitted on `Cairn.Tracker.Bbd`'s centre
  distance instead. Additive and nothing else — no IoU-calibrated constant
  moves, and a pair that clears `Cairn.Tracker.match_threshold/2` is matched
  on its overlap exactly as it is without this stage. What it is for is the
  case IoU cannot express at all: two boxes that do not touch have an
  overlap of exactly zero however near they are, so after a coast long
  enough for a walker to clear its own width the right pair and every wrong
  one are indistinguishable, and the track loses its identity to a mint.

  The stage runs immediately after each IoU association pass, seeded with
  that pass's accumulator (`Cairn.Tracker.Batch.spend/2`): every IoU pair
  has been offered before every BBD pair, so a BBD pair can neither outrank
  one nor reorder anything — the accumulator's own bookkeeping is what
  dedups across the join, and the second list can only fill in what the
  first left free. That seeded-reduce composition is bit-identical to the
  inline `iou_pairs ++ bbd_pairs` interleave it replaced *because* nothing
  spends objects or tracks in between — the two constraints `constraints/0`
  declares:

    * `adjacent_after: :iou_association` — a spending stage between the IoU
      pass and this one would change which pairs are free, which is a
      different algorithm, not a reordering;
    * `paired_across_association: true` — both evidence tiers or neither. A
      low-confidence box that does match is a real detection and gets a real
      match through the same admission; an admission running for one tier
      only is not the algorithm the soak measured.

  Which tier this instance admits from is `batch.association`'s answer, not
  a guess: `:one` reads `above_floor`, `:two` reads `below_floor`. The
  candidate list is the batch's full one — a pair whose track an earlier
  pass already took is skipped by the seeded reduce, so pre-filtering
  spent tracks changes nothing but the length of the list sorted.

  ## Gating

  A listed stage runs unconditionally — there is no flag test in here. The
  `tracking.bbd` boolean gates whether this stage is *listed*, in
  `Cairn.Tracker`'s `batch_stages/1` translation; a config that never set
  the flag produces an empty stage list and the pre-stage association bit
  for bit.
  """

  @behaviour Cairn.Tracker.Stage

  alias Cairn.Tracker
  alias Cairn.Tracker.Batch
  alias Cairn.Tracker.Bbd

  @impl true
  def call(batch, _params) do
    %{batch | assignment: Batch.spend(batch.assignment, pairs(batch))}
  end

  @impl true
  def constraints, do: %{adjacent_after: :iou_association, paired_across_association: true}

  # Stationary tracks are excluded, and that exclusion is what keeps
  # `@stationary_match_iou` meaning what it says. A parked object's
  # re-detections overlap its own box by definition, so this could only ever
  # widen a parked track's admission to boxes it is *deliberately* refusing —
  # the passer-by that the grace exists to keep out is exactly a same-label
  # detection a short distance from a stationary track, which is to say
  # exactly what BBD admits.
  #
  # Sorted ascending, since a small distance is a good pair where a large
  # overlap was, and by the same total key as the IoU half for the same
  # reason: `candidates` comes off a map, and two equal distances must not be
  # resolved by its iteration order.
  defp pairs(batch) do
    indexed = admitting(batch)
    context = batch.context

    # `candidates` outermost, unlike the IoU comprehension in `Cairn.Tracker`:
    # the elapsed time is a property of the track alone, so this computes one
    # per candidate rather than one per pair. The sort key is total, so
    # nothing depends on the order the pairs come out in.
    pairs =
      for {id, tracked, predicted} <- batch.candidates,
          not tracked.stationary,
          delta_tau_s = elapsed_s(tracked, context),
          {object, index} <- indexed,
          tracked.label == object.label,
          Tracker.iou(predicted, object.bbox) < Tracker.match_threshold(tracked, context),
          distance = Bbd.distance(predicted, object.bbox, delta_tau_s),
          Bbd.admit?(distance) do
        {distance, index, id}
      end

    Enum.sort_by(pairs, fn {distance, index, id} -> {distance, index, id} end)
  end

  defp admitting(%Batch{association: :one} = batch), do: batch.above_floor
  defp admitting(%Batch{association: :two} = batch), do: batch.below_floor

  # How long since the track last took a box, in seconds because
  # `Cairn.Tracker.Bbd`'s clip bounds are published in them and the tracker's
  # clocks are milliseconds. `last_matched_ms` and not `last_seen_ms`: what
  # the covariance is built out of is the age of the last position fix, and a
  # track marked seen by a box it refused was not positioned by it (`seen/3`
  # in `Cairn.Tracker`).
  #
  # The pattern match is an assertion and not a guard against real data: every
  # live track carries this from `new_track/3` on and nothing unsets it, so a
  # nil here is a broken invariant rather than a gap to default over — and any
  # default would be an invented elapsed time, which is precisely the quantity
  # the gate's width is derived from.
  defp elapsed_s(%{last_matched_ms: last_matched_ms}, context) when is_number(last_matched_ms),
    do: (context.at_ms - last_matched_ms) / 1_000
end
