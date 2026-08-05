defmodule Cairn.Tracker.Stage.Oru do
  @moduledoc """
  Observation-centric re-update: rebuilding a filter across a gap.

  A coast asserts the pre-gap heading for as long as it runs, and the longer
  it runs the less that heading is worth. This stage — `tracking.oru`'s
  mechanism, run per object by `Cairn.Tracker`'s per-object hook when the
  flag lists it — takes a detection that closed a long enough unmatched gap
  and, rather than merely correcting the coast, throws the filter away and
  rebuilds it from the last box the track was really observed at, replayed
  across the gap against boxes interpolated towards the closing detection
  (`Cairn.Tracker.Kalman.refit/3`, and its "Virtual observations" section for
  what those boxes are). The re-detection's own predict-and-update stays in
  `Cairn.Tracker` (`advance/3`) as the last step of that replay and is the
  ordinary matched step, unchanged.

  Two kinds of gap reach the rebuild, and it is the same rebuild for both
  because the anchor is the same. One is the live re-match, where a filter
  coasted through the gap and is discarded. The other is a **stream reset**:
  a track suspended at the cut and adopted in the new epoch has no filter at
  all (`Cairn.Tracker`'s `revive/3` drops it), but it does have the two
  things the replay actually needs — the box the object was last really
  observed at and the instant it was last matched, both carried across the
  cut untouched by suspension. So the case with nothing to be skeptical of is
  served by the same interpolation as the case with a stale heading to throw
  away, and neither needs any state the tracker was not already keeping.

  A **virtual observation** never leaves the replay: it is not stored as
  `bbox`, moves no clock (`last_seen_ms`, `last_matched_ms`,
  `last_detected_ms`), starts and ends no still run, opens and closes no
  pending exit, produces no event, reaches no summary and never leaves the
  process — the only thing that ever sees one is the filter being replayed.
  What the closing detection does to the track's box and clocks it does
  identically without this stage; the only difference is which filter its own
  step lands on. The stationary flag an adoption may clear below is no
  exception: it is judged from the two *real* boxes bounding the gap, never
  from anything interpolated between them.

  Which is not to say nothing downstream can tell, and one thing deliberately
  can. The stillness rule's drift is *read off the filter*, so the evaluation
  the closing detection makes reads the rebuilt filter rather than the
  coasted one, and can land on the other side of the floor — the still run,
  and with it the flag, may go somewhere the coasted filter would not have
  taken them. That is the intended consequence and not a leak: what a coast
  tells the stillness rule about a gap is the heading the object had before
  the gap opened, and being skeptical of exactly that is what the rebuild is
  for.

  Across a stream reset that same skepticism is spent through a second route
  as well, because the first one is unavailable there: an adoption restarts
  the still run, so its drift average starts from rest and the adopting
  evaluation reads the rebuilt filter through a weight of nearly nothing. The
  gap's own displacement is therefore put to the stationary flag directly
  instead, on the floor the live rule uses — `resumed_motion/4` below.

  The trigger is the **unmatched gap**, `at_ms - last_matched_ms`, and never
  a seeded stretch — a seed refreshes `last_matched_ms` like any other match,
  so a stretch the plugin was re-reporting through never opens a gap for this
  to fire on. That is load-bearing rather than incidental: through a seeded
  stretch the plugin's own account is that the object did not move and the
  filter is deliberately held, so replaying synthesized motion across one
  would manufacture the very velocity the stillness rule reads to decide the
  object is parked.

  The replay is anchored on the track's stored `bbox`, and it is
  `Cairn.Tracker`'s seed invariants (its moduledoc's "detection, seed,
  prediction" section) that make that the last *detected* box rather than
  merely the last observed one: a seed re-reports its box **byte for byte**,
  so a seeded stretch cannot have moved the anchor, and a plugin that ever
  seeded a moved box would put a box no detector produced at one end of the
  interpolation — the replay would learn motion nothing ever saw. This stage
  is a second underwriter of that invariant, not a second copy of it.

  ## Gating

  A listed stage runs unconditionally — there is no flag test in here. The
  `tracking.oru` boolean gates whether this stage is *listed*, in
  `Cairn.Tracker`'s `per_object_stages/1` translation; a config that never
  set the flag produces an empty stage list and the tracker's no-stage path,
  which is the pre-stage code bit for bit.
  """

  @behaviour Cairn.Tracker.Stage

  alias Cairn.Tracker
  alias Cairn.Tracker.Kalman

  # `tracking.oru`'s three numbers, all of them conversions between an elapsed
  # time and a count of filter steps.
  #
  # The nominal batch cadence. `Cairn.Tracker.Kalman` has no notion of duration
  # — one `predict/1` is one step whatever separated the two batches — so a gap
  # measured in milliseconds can only be re-expressed as the step count a replay
  # needs against an assumed cadence, and this is it. Two batches a second is
  # what an inference loop on a live camera runs at and what the tracker test
  # suite's own `@batch_ms` encodes. A camera slower than this replays more
  # steps than its gap really had and learns a per-step velocity proportionally
  # short of the object's real per-batch pace — an under-estimate, which is the
  # direction to be wrong in for a mechanism whose whole purpose is to stop a
  # stale heading being asserted with confidence.
  @oru_step_ms 500
  # The gap a re-detection must have opened before its track's filter is rebuilt
  # across it rather than corrected through it. Under a second — two batches at
  # the cadence above — a coasted filter is still close to what it last
  # measured, and rebuilding would discard a real velocity history in exchange
  # for a two-point interpolation of the same motion. An adoption reaching this
  # bound has no history to discard, but it has no gap worth interpolating
  # either: a stream cut and resumed inside a second leaves an object that has
  # barely moved, and the adopting box seeds a filter for it as it always did.
  @oru_min_gap_ms 1_000
  # And the gap past which the interpolation is worth no more than the coast it
  # would replace. About twenty steps at the cadence above: a straight line
  # drawn between two sightings that far apart is asserting a heading through a
  # stretch long enough for the object to have turned around in, which is
  # unpublished territory — OC-SORT's own guidance for its re-update stops
  # around twenty missed frames. Past this the coasted filter is left exactly as
  # it is and the ordinary matched step runs on it — or, for an adoption, the
  # absent one stays absent and the adopting box seeds it — which is what
  # happens with the stage unlisted too. It is `Cairn.Tracker`'s
  # `adoption_window_ms/0` that decides how long a suspension stays adoptable,
  # and at six times this bound most of that window is deliberately outside the
  # replay's.
  @oru_max_gap_ms 10_000

  @doc """
  One track's ORU update: the adoption's stationary reading, then the replay.

  The filter this leaves on the track is what `Cairn.Tracker`'s `advance/3`
  then takes its one step on: the track's own, unless this detection closed a
  gap the replay is for. In that case whatever filter the track was carrying
  is dropped and one is built across the gap from the last box the track was
  really observed at, against virtual observations interpolated towards this
  detection (`Cairn.Tracker.Kalman.refit/3`).

  `refit/3` deliberately stops one step short of the target, and the step it
  stops short of is that `advance/3` — so nothing here predicts, and the
  closing detection is counted exactly once. Both ends of every interpolation
  are real boxes a detector produced: `bbox` is the last of them (a seed
  re-reports its box verbatim, so a seeded stretch cannot have moved it) and
  `object.bbox` is this batch's own, which is what `detected?` gates on.

  Two kinds of track arrive here with a gap, and the rebuild is deliberately
  blind to which. One carries a coasted filter, asserting a heading through a
  stretch nothing confirmed, and that is what the rebuild is skeptical of.
  The other carries none at all: `revive/3` in `Cairn.Tracker` drops the
  filter of a track adopted out of suspension, and a nil filter at this point
  is *exactly* that and nothing else — `new_track/3` is the only other thing
  that writes the field from scratch and it always seeds one, neither
  `coast/1` nor `advance/3` can turn a filter into a nil, and an adoption is
  always assigned its (detected) adopting box in the same batch, so no nil
  filter ever survives to a later one. (That chain lives in `Cairn.Tracker`;
  `revive/3`'s own comment holds up the other end.) There is no coast to be
  skeptical of there, but the two boxes bounding the gap are the same two,
  since suspension carries `bbox` and `last_matched_ms` across the cut
  untouched. Outside the window a nil falls through to `advance/3` to seed
  from this box, which is what the stage-unlisted path does with every
  adoption.

  The gap is measured from `last_matched_ms`, which is what keeps a seeded
  stretch out of this altogether — see the moduledoc: a seed refreshes that
  clock, so no gap opens across a stretch the plugin was re-reporting
  through, and the motion this would otherwise synthesize is motion the
  plugin's own account says did not happen.
  """
  @impl true
  def per_object(tracked, object, detected?, context, _params) do
    tracked = resumed_motion(tracked, object, detected?, context)

    case replayable_gap(tracked, detected?, context) do
      nil -> tracked
      gap -> %{tracked | kalman: Kalman.refit(tracked.bbox, object.bbox, gap_steps(gap))}
    end
  end

  # The gap this detection closed when it is one the replay is for, and `nil`
  # otherwise. No flag test here — a listed stage runs (see "Gating" in the
  # moduledoc); the `oru` boolean is spent in `Cairn.Tracker`'s
  # `per_object_stages/1` before this module is ever called.
  #
  # Two callers, one window, on purpose. `per_object/5` rebuilds the filter
  # across this gap and `resumed_motion/4` reads the same two boxes for what
  # they say about a resumed track's stationary flag, so a window either
  # computed for itself could drift from the other and leave a track judged on
  # a measurement its own filter never saw.
  #
  # `detected?` is the second gate and it is `adopt/4`'s refusal applied to the
  # filter: an extrapolation may not tell the tracker where an object went any
  # more than it may resume an identity.
  defp replayable_gap(tracked, detected?, context) do
    gap = context.at_ms - tracked.last_matched_ms

    if detected? and gap >= @oru_min_gap_ms and gap <= @oru_max_gap_ms, do: gap
  end

  # What a replayed gap says about a resumed track's stationary flag — the only
  # thing this stage changes about an adoption besides the filter, and the one
  # place in the pipeline where a *displacement* rather than a filter reading
  # decides stillness.
  #
  # It runs only for a track that has no filter and is currently stationary.
  # The first, by the invariant in `per_object/5`'s doc, means an adoption made
  # by this same batch and nothing else; the second means there is a flag to
  # clear at all, since this only ever takes one away.
  # With the stage unlisted — `tracking.oru` off, the default — none of this
  # module runs, so a suspended track resumes with the flag it was suspended
  # with whatever the outage did to it, exactly as `revive/3` describes.
  #
  # With the gap inside the replay window, the two boxes the replay
  # interpolates between are two *real* sightings of the object either side of
  # a cut nothing observed, so for once there is a measurement to put against
  # the flag — and where that measurement is a displacement the live rule would
  # have called motion, "parked" is a claim the evidence contradicts.
  #
  # The test is `Cairn.Tracker.still?/3` — the live rule's own — handed the
  # gap's mean drift in place of the filter's velocity. That is what makes the
  # scaling honest rather than notional: both stationary floors are expressed
  # per `stationary_after_ms`, so both sides of the comparison are rates and
  # the allowance grows with the gap — an 8 s gap of a 10 s settle window buys
  # four fifths of the floor's displacement, which is precisely what a live
  # track drifting that slowly would have been allowed to accumulate over the
  # same stretch. A per-step floor applied to a many-step gap would have failed
  # every adoption that moved at all.
  #
  # Clearing, and nothing else. The flag is re-earned the ordinary way — a
  # settle window of stillness measured from the run `revive/3` restarted — so
  # a car pushed a metre and parked again reads as parked again, late rather
  # than never. No exit window is opened and none is honoured:
  # `@stationary_exit_ms` exists to stop a *stationary* track flapping on a
  # couple of batches of detector jitter, and this is one measurement over
  # seconds of gap, made once per adoption. `stationary_since` goes with the
  # flag as it does in `moved/3`, since a track that is not stationary has no
  # instant it became so; `pending_exit_ms` is already nil, `revive/3` having
  # cleared it, and `stillness/5` runs after this on a track that is no longer
  # stationary, so nothing can leave a moving track carrying an open exit
  # window.
  #
  # Running here — on the pre-write copy, inside the hook — rather than in
  # `revive/3` is what emits the flip; that placement is the stage contract's
  # pre-write rule, stated with its downstream consequences in
  # `Cairn.Tracker.Stage`'s moduledoc ("The pre-write contract").
  defp resumed_motion(%{kalman: nil, stationary: true} = tracked, object, detected?, context) do
    case replayable_gap(tracked, detected?, context) do
      nil ->
        tracked

      gap ->
        if Tracker.still?(gap_drift(tracked.bbox, object.bbox, gap), object, context),
          do: tracked,
          else: %{tracked | stationary: false, stationary_since: nil}
    end
  end

  defp resumed_motion(tracked, _object, _detected?, _context), do: tracked

  # The gap's mean drift in `Cairn.Tracker.still?/3`'s units — frame units per
  # millisecond of the observation clock — from the centre of the box the track
  # was last observed at to the centre of the box that resumed it, with the
  # height change over the same gap for the growth half of the test.
  #
  # A straight line between two sightings, saying nothing about the path
  # between them. That is the whole of what a gap nothing observed can honestly
  # report, and it is the same assumption `Kalman.refit/3` interpolates its
  # virtual observations on, so the flag and the filter are reading one story.
  defp gap_drift([ax, ay, aw, ah], [bx, by, bw, bh], gap) do
    {(bx + bw / 2 - (ax + aw / 2)) / gap, (by + bh / 2 - (ay + ah / 2)) / gap, (bh - ah) / gap}
  end

  # The gap as a count of filter steps, at the nominal cadence.
  #
  # The floor of two is what makes the replay a replay: `refit/3` at one step
  # has no interior to interpolate and degenerates to a bare re-init from the
  # anchor, which would throw the coasted filter away and put nothing measured
  # in its place. The ceiling is `@oru_max_gap_ms` restated in steps. At today's
  # three constants neither bound can bind — the window's own endpoints are
  # exactly 2 and 20 steps — and they are here so that tuning the window can
  # never hand `refit/3` a degenerate count.
  defp gap_steps(gap), do: (gap / @oru_step_ms) |> round() |> max(2) |> min(20)
end
