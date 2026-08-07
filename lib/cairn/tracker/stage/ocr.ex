defmodule Cairn.Tracker.Stage.Ocr do
  @moduledoc """
  Observation-centric recovery: offer a coasted track's last observation.

  Both association passes and the BBD stage weigh detections against a live
  track's *predicted* box. A track that coasts on a stale heading carries
  that prediction away from where its object was last seen, so the object
  that pauses behind an occluder and reappears at the old spot overlaps
  nothing the pipeline has offered — and worse than going unmatched, the
  reappearance then meets duplicate suppression, which weighs it against
  the coasted track's *stored* box, drops it as an NMS twin, and marks the
  track seen. Without recovery the paused mover is not re-minted; it is
  invisible, feeding the very track that lost it (pinned in
  `tracker_test.exs`). The stored `bbox` is exactly where the object
  vanished (`update_track/3` writes only real boxes into it, never
  predictions), so this stage runs once, after the second association and
  its BBD companion and *before* suppression can swallow the box, offering
  `{iou(tracked.bbox, object.bbox), index, id}` for whatever is still
  unspent. Stream-reset adoption already does precisely this for the
  *suspended* population (`@stitch_iou`); this covers the live-coasted one.

  Running last keeps it strictly additive: BBD's soak-measured behavior
  stays primary, and a pair either of them already spent is a no-op in the
  seeded reduce (`Cairn.Tracker.Batch.spend/2`). The whole batch is
  offered, both floor tiers — an object re-emerging from behind an
  occluder is exactly when the detector reports it faintly, and a
  below-floor box may resume an identity here for the same reason it may
  match one in the second association: matching is not minting.

  There is no minimum coast age. A young coast's prediction still hugs the
  stored box, so recovery degenerates to the offer the IoU pass already
  refused and the threshold refuses it again — an age gate would only add
  a constant with nothing to buy.

  ## Gating

  A listed stage runs unconditionally — there is no flag test in here. What
  gates whether this stage is *listed* is `Cairn.Tracker`'s
  `recovery_stages/1` translation, reading the global `tracking.ocr`
  boolean or a hardware profile's `tracking: ocr:` entry
  (`Cairn.Config.Profile`, `docs/profile-authoring.md`). Off produces an
  empty stage list and the pre-stage pipeline bit for bit.
  """

  @behaviour Cairn.Tracker.Stage

  alias Cairn.Tracker
  alias Cairn.Tracker.Batch

  # What a lost identity answers to at its last box. `Cairn.Tracker` holds
  # the invariant that this is not below `@duplicate_suppression_iou` (see
  # the compile-time guard there): a box recovered below suppression's floor
  # would leave its NMS twin unsuppressed beside the identity it just
  # resumed — the same argument `@stitch_iou` makes for adoption, and this
  # is the same admission for the population that never suspended.
  @recovery_iou 0.4

  @doc "The recovery admission threshold, exposed for `Cairn.Tracker`'s guard."
  @spec recovery_iou() :: float()
  def recovery_iou, do: @recovery_iou

  @impl true
  def call(batch, _params) do
    %{batch | assignment: Batch.spend(batch.assignment, pairs(batch))}
  end

  # Stationary tracks are excluded for the same reason the BBD stage
  # excludes them, with more force: a parked track's stored box IS its last
  # observation, so recovery here could only widen a parked identity's
  # admission to the nearby same-label passer-by that
  # `@stationary_match_iou` exists to refuse.
  #
  # Sorted by the same total key as the IoU pass: `candidates` comes off a
  # map, and two equal overlaps must not be resolved by its iteration order.
  defp pairs(batch) do
    # The whole batch, as `suppress_duplicates` reads it — recovery has no
    # tier of its own, and a spent index is a no-op in the reduce anyway.
    pairs =
      for {id, tracked, _predicted} <- batch.candidates,
          not tracked.stationary,
          {object, index} <- batch.indexed,
          tracked.label == object.label,
          overlap = Tracker.iou(tracked.bbox, object.bbox),
          overlap >= @recovery_iou do
        {overlap, index, id}
      end

    Enum.sort_by(pairs, fn {overlap, index, id} -> {-overlap, index, id} end)
  end
end
