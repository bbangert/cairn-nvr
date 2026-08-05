defmodule Cairn.Tracker do
  @moduledoc """
  Pure per-camera object tracker: turns a stream of observations into tracks
  with public `Cairn.ULID` identities and a started/updated/ended lifecycle.

  Identity is assigned one way, for every object: greedy-IoU matching against
  the live tracks of the same label, run in two confidence stages and measured
  against where each track's motion filter says its box should be by now — see
  "Matching against a prediction" and "Two stages" below, both of which
  constrain that one rule rather than adding a second. The one thing that
  loosens it is `tracking.bbd`, off by default and described under "A second
  admission" below; with it off — which is every camera that has not asked —
  overlap is the whole of what a track will answer to. There is no
  plugin-driven mode. A plugin's
  `track_id`s and `ended_tracks` are still parsed off the wire, and so is its
  `object_tracking` capability, but nothing here reads any of them — they are
  accepted and reserved, and a plugin that declares the capability is tracked
  host-side like every other.

  Every decision here is taken on one clock, `at_ms`: the observation's own
  media time anchored to the host's monotonic clock and clamped against a pts
  that stalls, rewinds or jumps, computed once at ingestion by
  `Cairn.ObservationClock`. It behaves as media time within a stream — the
  bounds below are spaced by frames, not by batches — while being comparable
  across an epoch boundary and unable to freeze, which is what a plugin's raw
  pts is neither of. No threshold here is measured on a wall clock:
  `observed_at` is carried onto the summaries as data (`started_at`,
  `last_seen_at`, `last_detected_at`, `stationary_since`) and reported as the
  instant an outage gap is measured to (`suspend/3`), and that is all it is
  for.

  Expiry is that clock, not batches: a track is ended (`:unseen`) once
  `at_ms - last_seen_ms > max_unseen_ms`. `last_seen_ms` moves on *any*
  observation of the track, predicted ones included — slow inference must not
  kill a track — and, as below, on a box the track refuses. Evidence policy is
  separate: a track whose last **detection** is older than `max_unseen_ms` is
  flagged `stale_predicted`, and `Cairn.CameraTracker` refuses it as event evidence
  however long the plugin keeps predicting it.

  A track the tracker has judged **stationary** (see below) expires at
  `@stationary_unseen_factor` times that bound instead, and for as long as it
  sits inside that extended grace — already unseen for longer than
  `max_unseen_ms` — nothing may re-match it at less than
  `@stationary_match_iou` overlap. The patience is paid for with pickiness: a
  parked object survives an occlusion that would end a moving track, and while
  the grace holds no lesser overlap inherits its identity. Outside the grace a
  stationary track matches at the same `@iou_threshold` as everything else.

  Pickiness governs *geometry*, not *presence*. A detection that no track took
  — refused on threshold, left over because the track it belongs to already has
  this batch's box for it, or never paired with it because the track's
  prediction had coasted elsewhere — but that still overlaps a live
  **same-label** track by at least `@duplicate_suppression_iou`, is **dropped**
  rather than minted, whether or not that track matched this batch. The overlap
  is measured against the track's stored box, where the object was last
  actually seen, and not against its prediction: what this asks is whether a
  second box of that object arrived, not where the object might have gone.
  Only a stage-one box is ever weighed here — the low-confidence half of a
  batch is spent before this rule is offered anything (see "Two stages").
  The second case is why the state of the track cannot be the guard: a batch
  can carry two boxes for one object, because a detector without NMS emits
  them, so "what is left over is somebody else" is not something the tracker
  may assume. The same-label test is what keeps a genuinely new object mintable
  over a tracked one: a person in front of a tracked car is a different label,
  and at this much overlap within one label two distinct physical objects is
  the implausible reading.

  If the track the box overlaps most is one this batch left unmatched, the drop
  also marks it seen — its `last_seen_ms` (and the `last_seen_at` that reports
  it) move, and nothing else does. Both halves are needed. Without the drop,
  refusing a box is itself how a second identity gets made for the object that
  was refused, since an unmatched detection mints; the strict threshold would
  hand a parked car two or three concurrent tracks rather than none. Without
  the mark, the refusal repeats on every batch for as long as the object sits
  there and nothing ever re-acquires it. Together a refusal usually costs one
  batch: the refreshed clock takes the track out of the grace, so a batch
  arriving within `max_unseen_ms` of it matches at `@iou_threshold` — against a
  prediction which, for the parked track this case is about, has barely moved
  from the stored box — and adopts it normally. Where batches are further
  apart than
  that — inference slower than the camera's own unseen bound — every batch
  finds the track back in its grace and the refusal repeats, and what ends that
  is the refusal bound below rather than a match.

  If that track *matched*, nothing is marked. It was just observed for real,
  its clock has already moved, and a box it refused adds nothing to that; the
  mark exists for a track whose only remaining sign of life is the box being
  refused.

  Being marked seen is not being observed. The box was refused, so nothing
  about it is believed — not the stillness rule's judgement of it, not the
  motion filter, which coasts on this batch exactly as it would for a track no
  box mentioned at all, and not `last_detected_ms`, so a track kept alive this
  way still goes
  `stale_predicted` on the evidence policy's own schedule and cannot be talked
  out of being parked by what it refused. Nor is `last_matched_ms`
  touched: the refusal bound below is the one bound a suppression cannot
  refresh away, so a track that only ever gets suppressions is still retired
  rather than living forever.

  What this gives up is the far half of the pickiness, and it is a deliberate
  trade. A box between the two thresholds is refused *once*, not forever, so
  an object whose very first detection lands that close to a parked track's
  stale box inherits that identity on the following batch rather than minting
  one of its own. The alternative — refusing it for as long as the track lives
  — leaves whatever is really there untracked for the whole extended grace,
  and that is the worse error for the case the grace is for: the thing sitting
  at 0.4 to 0.7 overlap with an unconfirmed parked track is nearly always that
  track's own object, re-detected slightly off after its detections flickered,
  while a genuinely new object has usually minted a track of its own where it
  entered the frame long before it gets there.

  Against a track that *did* match, the refusal is not once but for as long as
  the overlap holds — there is no grace to fall out of. That is the right
  answer for the case it exists for, a second box of the object the track just
  took. Its cost is the other one: a genuinely new same-label object that
  closes to within `@duplicate_suppression_iou` of a tracked one goes untracked
  until it separates. The threshold is chosen so that ordinary adjacency — two
  cars nose to tail, at 1/3 — stays below it and mints.

  What the grace does not require is *detections*: `last_seen_ms` moves on
  predicted observations too and the stillness rule ignores them, so a plugin
  that keeps predicting a box at the parked position holds the identity and
  the stationary flag for as long as it predicts, no matter how long that is.
  That is the "slow inference must not kill a track" contract above, over a
  window the grace makes longer; `stale_predicted` is what keeps it from
  counting as evidence.

  A pts that jumps backwards (a new ffmpeg run restarts the RTP timeline) or
  stops advancing at all never reaches this module: `at_ms` is clamped at
  ingestion so it can do neither, which is why nothing here floors an elapsed
  time at zero. What a new ffmpeg run does reach here as is a new epoch, where
  `suspend/3` cuts the live set from the new stream's matching — not because
  the clock changed, since it does not, but because nothing observed the gap
  (see below).

  ## Matching against a prediction

  What a detection is compared with is not a track's stored box but
  `Cairn.Tracker.Kalman`'s estimate of where that box would be by now. Every
  live track carries a constant-velocity filter: seeded when the track is
  minted, updated from every box the track actually took, stepped once for
  every batch that did not observe it, and asked for a further one-step
  prediction at match time. A track something detects on every batch predicts
  within jitter of its own last box, so for a scene the detector keeps up with
  this changes nothing. What it buys is the other case — an object that keeps
  moving through the batch or two nothing detected it in is matched against a
  box that moved with it, where the frozen one it left behind would already
  have fallen under `@iou_threshold` and its identity would have been lost.

  The filter is internal: it is not in `Cairn.Track`, nothing downstream is
  told about it, and — the cardinal rule in `Cairn.Tracker.Kalman`'s own doc —
  a predicted box is never stored as `bbox`, never carried onto a summary and
  never emitted. `bbox` is the last box the track was *observed* at, always,
  which is what the two rules that read a stored box need: `adopt/4` stitches a
  new epoch's detection against where the object was actually last seen, and
  `duplicate_of/2` judges a leftover box's proximity to the same. An
  extrapolation is enough to ask "is this the same object" with, and not enough
  to resume an identity across a gap nothing watched, nor to refuse a detection
  on.

  A seeded box — the plugin re-reporting an observation it already made — is
  not an observation of motion, so it neither updates the filter nor steps it.
  Through a seeded stretch the filter is held exactly as it was, and the
  prediction the next detection is matched against is the one the last
  *detection* left. Everything else about a seeded box is unchanged: it
  refreshes liveness, it moves `bbox`, and it is no more evidence than before.
  It moves `bbox` to the same place, though — a seed re-reports the last
  detected box byte for byte, the plugin replaying exactly what it emitted —
  and the `tracking.oru` replay below anchors at `bbox` on the strength of
  that: a plugin that ever seeded a *moved* box would silently break that
  anchor, which is why verbatim re-reporting is an invariant here and not a
  detail of the current plugin.

  ## Rebuilding a filter across a gap: `tracking.oru`

  A coast asserts the pre-gap heading for as long as it runs, and the longer it
  runs the less that heading is worth. With `tracking.oru` on — off by default,
  and with it off nothing below happens at all — a detection that closes a long
  enough unmatched gap does not merely correct that coast: the filter is thrown
  away and rebuilt from the last box the track was really observed at, replayed
  across the gap against boxes interpolated towards the closing detection
  (`Cairn.Tracker.Kalman.refit/3`, and its "Virtual observations" section for
  what those boxes are). The re-detection's own predict-and-update is the last
  step of that replay and is the ordinary matched step, unchanged.

  A **virtual observation** is the inverse of a seed, and the inverse in the
  one direction that matters here: a seed refreshes a track's liveness and
  moves its box while leaving the filter alone, and a virtual point moves the
  filter while leaving the track alone. It is never stored as `bbox`, moves no
  clock (`last_seen_ms`, `last_matched_ms`, `last_detected_ms`), starts and
  ends no still run, opens and closes no pending exit, produces no event,
  reaches no summary and never leaves this process — the only thing that ever
  sees one is the filter being replayed. What the closing detection does to the
  track's box and clocks it does identically with the flag off; the only
  difference is which filter its own step lands on.

  Which is not to say nothing downstream can tell, and one thing deliberately
  can. The stillness rule's drift is *read off the filter*, so the evaluation
  that same closing detection makes reads the rebuilt filter rather than the
  coasted one, and can therefore land on the other side of the floor — the
  still run, and with it the flag, may go somewhere the coasted filter would
  not have taken them. That is the intended consequence and not a leak: what a
  coast tells the stillness rule about a gap is the heading the object had
  before the gap opened, and being skeptical of exactly that is what the
  rebuild is for.

  The trigger is the **unmatched gap**, `at_ms - last_matched_ms`, and never a
  seeded stretch — a seed refreshes `last_matched_ms` like any other match, so
  a stretch the plugin was re-reporting through never opens a gap for this to
  fire on. That is load-bearing rather than incidental: through a seeded
  stretch the plugin's own account is that the object did not move and the
  filter is deliberately held, so replaying synthesized motion across one would
  manufacture the very velocity the stillness rule reads to decide the object
  is parked.

  What the replay is anchored on is the track's stored `bbox`, and one
  invariant makes that the last *detected* box rather than merely the last
  observed one: a seed re-reports the box it re-reports **byte for byte**
  (`cairn-detect` remembers each emitted detection by value and changes only
  its observation kind). A plugin that seeded a box it had *moved* would
  therefore not only mislead liveness — it would put a box no detector produced
  at one end of an interpolation, and the replay would learn motion nothing
  ever saw. It belongs with the other seed invariants above for that reason.

  ## A second admission: `tracking.bbd`

  A prediction fixes where to compare, and leaves untouched what IoU cannot
  say. Two boxes that do not touch overlap by exactly zero however near they
  are, so once a coast is long enough that the object has cleared its own
  width, the right detection and every wrong one look the same to the gate and
  the identity goes to a mint. `Cairn.Tracker.Bbd` measures the centre
  distance instead, scaled by the predicted box's own size and by how long the
  track has gone unpositioned, which separates exactly those cases.

  With the flag on, a pair that fails `match_threshold/2` and passes that
  distance is admitted as well. Nothing about the IoU half changes: its pairs
  are built, ordered and greedily spent first, so a distance-admitted pair can
  only take a track and an object that both came through untaken, and every
  IoU-calibrated threshold in this module still means what it did. Stationary
  tracks are left out of the second gate altogether — see `bbd_pairs/3`, and
  the grace above, whose whole safety is that a parked identity answers to one
  number and no other.

  With the flag off — the default — none of this runs and association is the
  rest of this doc entire.

  ## Two stages: what a low-confidence box may do

  Objects are partitioned against the camera's evidence floor — the same
  `min_score`, runtime override included, that decides what may open an event —
  and the two halves get different powers. Stage one is everything at or above
  the floor, and is the rule described above entire: it matches, and what it
  leaves over may adopt a suspension, mint a new identity, or be dropped as a
  duplicate. Stage two is everything below the floor, and may do exactly one
  thing — take a live track stage one left unmatched. It mints nothing, adopts
  nothing, and every stage-two box that took no track is dropped outright,
  never offered to suppression and so never marking any track seen.

  The asymmetry is the point of the split. A box the detector is unsure of is
  good evidence that a track it lands on is still there, and no evidence at all
  that something new has arrived: minting on one would put a track on every
  flicker of detector noise, and letting one mark a track seen would let that
  noise hold identities alive through the refusal path indefinitely. What it
  may do — carry an existing identity through the batch where the detector
  nearly lost the object — is the occlusion case tracking exists for.

  Partitioning on the *evidence* floor rather than on a floor of its own is
  what keeps the rule from starving anything: a detection good enough to earn
  video is by construction in stage one, so nothing that could become evidence
  is ever denied a mint here. Below the floor a refusal costs nothing
  downstream, because such a box could never have opened an event — which is
  what makes matching on it safe.

  A context that carries no floor puts every object in stage one, and that is
  the whole of this rule for a caller which sets none.

  ## Surviving a stream reset: suspension and adoption

  An ffmpeg respawn or reconnect mints a new epoch, and the object in frame is
  usually the same object. `suspend/3` therefore does not end the live tracks
  at the boundary: it moves them aside, keeping their identity, `started_at`,
  `best_score` and stationary flag, and excluding them from ordinary
  matching. Nothing downstream is told they ended, because they may not have.

  A detection in the new epoch may then **adopt** a suspended track — same
  ULID, no `:started`, no `:ended`. One rule decides it: a detected box
  overlapping a suspended track of the **same label** by `@stitch_iou` or more
  takes that identity back, best overlap first, each box and each suspension
  used once. Nothing else is asked — not how long the track had been absent
  before the cut, not whether it was moving or parked.

  The one time bound is on the **waiting**: `@adoption_window_ms` from the cut
  (`within_window?/2`). `track/3` settles the lapsed suspensions before any of
  this batch's detections are matched, so every suspension `adopt/4` is offered
  is one still inside its window and the geometry is the whole of the rest of
  the decision. A stream that had already been quiet for a minute before ffmpeg
  respawned still gets a full window to come back in: nothing about that camera
  was observed for either stretch, so the two are the same blindness.

  One loose threshold, rather than a strict one for the longer gaps, is
  deliberate. The two mistakes are not symmetric: handing a departed object's
  identity to whatever stands in its box costs one wrong ULID on one track,
  while refusing a returning object's costs a re-mint — and a re-minted parked
  car spends `stationary_after_ms` reading as a new arrival, which is evidence,
  which is a clip, on every reset a flaky camera has. A strict threshold also
  does not merely refuse: the box it turns down mints beside the ghost it was
  refused for, and that ghost is then adoptable by nothing, so the strictness
  manufactures the second identity it was there to prevent. What keeps the
  loose rule from producing a duplicate of its own — a second box of the object
  it has just resumed — is the duplicate suppression that still runs after it,
  last of all, with nothing between the two but stage two spending its own
  leftovers. `@stitch_iou` is picked from the same geometry
  as `@duplicate_suppression_iou` — under it, an overlap is ordinary same-label
  adjacency (two cars nose to tail sit at 1/3) rather than the object again —
  and may never be the looser of the two (currently they are equal; the guard
  at the constant enforces the ordering).

  Adoption is refused for a predicted box: an identity nothing confirmed for
  the length of the outage may not be resumed by the plugin's extrapolation of
  where it would have been.

  What resumes with the identity is nearly all of it: `at_ms` spans the cut, so
  nothing has to be re-based to stay comparable, and `last_seen_ms` still dates
  the last sighting, which the summary reports and no adoption rule reads.
  The two clock fields the adoption does move (`last_detected_ms`,
  `still_since_ms`) are moved for a reason that is not about clocks: both are
  read as *elapsed stillness* — `stationary_ms` accrues over the gap between two
  detections, the settle window measures from the start of the still run — and a
  gap nothing watched is not stillness anybody saw. The motion filter is dropped
  outright: a heading learned before a cut that may be a minute old is not a
  claim about where the object is now, so the adopting detection re-seeds it
  from scratch and the resumed track is matched on its stored box until it does.
  Everything else is kept, `started_at` and
  `stationary_since` included, and so is the
  `stationary` flag itself: a car that matches its own parking space was
  parked for the whole gap, so it resumes **already** stationary and its
  settle window does not re-arm — which is the point of all of this, since
  `Cairn.CameraTracker` refuses a stationary track as evidence and a
  re-minted one would spend `stationary_after_ms` looking like a new arrival,
  i.e. like a clip.

  What the cut costs is the tracker's ability to say the object *did* move
  during it. Stillness is judged from the motion filter, the filter is re-seeded
  by the adopting detection, and a re-seeded filter has zero velocity — so a
  suspended track that comes back stationary comes back stationary wherever in
  the frame it is adopted — the adopting evaluation reads that just-re-seeded
  filter and passes trivially — and one that comes back moving is caught by the
  ordinary rule from the second detection of the new epoch on. Nothing observed the
  gap and no geometry survives it; a car that drove off and was replaced by
  another inside `@stitch_iou` of its space keeps the flag until the new
  occupant moves. Restoring that evidence is what an association that reasons
  about observation gaps (OC-SORT's re-update) is for. `tracking.oru` is that
  machinery, and today it stops short of here: the replay runs only for a
  track whose own filter coasted through the gap, so the adopting detection
  re-seeds, as below.

  What the adoption does buy unconditionally is that the settle window does not
  re-arm: a resumed track is stationary from its first detection instead of
  spending `stationary_after_ms` looking like a new arrival.

  `epoch` follows the track: it names the epoch the track was last observed
  under, not the one it was minted in, so an adopted track's summaries carry
  the current stream. A track's samples may therefore span the cut.

  A suspended track that nothing adopts is ended `:stream_reset`.
  `expire_suspended/2` is what waits out the window; two paths do not wait —
  `end_all/2` gives up on every suspension at once (detection off, camera
  stopped), and `suspend/3` drops the oldest generation when a reconnect loop
  pushes the set past its cap. Whichever gets there, the summary carries the
  timestamps the track already had, so it reports the instant it was last
  actually seen; the waiting is bookkeeping, not observation.

  ## Host policy: the live set is bounded, on both counts

  The unseen rule alone bounds a track that is *not being observed*, which
  leaves two ways for a live set to grow without one: a scene that keeps
  minting, and a track something keeps refusing on. Both bounds belong here
  rather than in the codec because they are about accumulated state, not about
  one line:

    * **A cap on live tracks** (`max_live_tracks`, per camera). At the cap,
      minting a new identity retires the least recently seen live track with a
      final summary (`:evicted`). Tracks that this batch already assigned are
      never the victim. Suspended tracks are neither counted nor evictable:
      they are not in the live set, nothing can advance them, and counting them
      would stop the new epoch's scene from minting while last epoch's ghosts
      wait out their window. They are bounded by the same number instead —
      `suspend/3` trims the suspended set to `max_live_tracks`, oldest
      suspension first — so a camera's worst case is twice the cap for at most
      `@adoption_window_ms`.
    * **A bound on refusals** (`@refusal_factor`). A suppression marks its
      track seen, so the unseen rule cannot retire a track whose every batch
      brings another box it refuses — the mark is the sign of life, and it
      arrives as fast as the refusals do. `last_matched_ms`, which a mark does
      *not* move, bounds that: a track is expired (`:unseen`) once ten times
      its effective unseen bound has passed since it last actually took an
      observation. Both halves of `live?/2` read one `unseen_bound/2` binding,
      which is what keeps the ceiling where it has always been: the host-clock
      backstop this replaced was scaled by the same grace, so a stationary
      track's refusal ceiling is 10 × 5 × `max_unseen_ms` — 150 s at the 3 s
      default. Reading the unscaled bound here would put it at 30 s and retire
      a continuously-refused stationary track five times sooner, which may well
      be the better rule but is a change of behaviour and deliberately not one
      made here. The factor is lax either way — the unseen rule is the real
      one, and this must never fire for a track that is merely being seen
      slowly.

  ## Stationary detection

  A track is stationary once it has held still for the camera's
  `stationary_after_ms` on the observation clock. What "still" means is the
  motion filter's own answer: the object's **mean drift rate** over the current
  still run, taken from the same `Cairn.Tracker.Kalman` state that matching is
  run against, must stay under `@stationary_velocity_floor` of the box's height
  per settle window — with `@stationary_growth_floor` bounding how fast the box
  may change size over the same window. A failed evaluation restarts the run —
  on a stationary track, the one that closes the exit window below; on any
  other, every one — and the settle window is measured from the run's start, so
  what the rule asks is whether the object has moved since the last time it was
  judged to be moving — however long the track lives.

  Drift is a *rate* rather than a distance between two boxes, which is what
  keeps a slow walk from reading as motionless: every step of one is within
  jitter of the step before it, but they agree in direction and the mean adds
  them up. It is averaged over one settle window, the same duration the floor
  is expressed over, and it is the *signed* velocity that is averaged: a box
  the detector shakes about a fixed point produces velocities that alternate in
  sign and mean nothing, while a departure produces velocities that agree.
  Neither the filter's instantaneous velocity nor an average of magnitudes can
  tell those apart at this floor.

  What the average costs is at the other end. A track that really did move
  carries a velocity estimate that takes several seconds to decay under a floor
  this tight, and its still run does not begin until it has, so an object that
  parks after real motion reads stationary appreciably later than one that was
  never seen moving — a settle window plus however long the filter takes to
  agree, rather than a settle window from the moment it stopped. That is the
  deliberate direction to fail in: it delays *excluding* a track from evidence
  and never delays including one.

  Leaving the flag takes as much sustaining as earning it. A stationary track
  whose drift fails the floor does not flip on that evaluation: it goes
  *pending*, still stationary in every way anything downstream can see, and
  only once the failure has been unbroken for `@stationary_exit_ms` on the
  observation clock does the flag clear and `started_moving` go out — once,
  timestamped at the evaluation that closed the window. A single passing
  evaluation ends the pending state outright, so the next excursion starts a
  fresh clock: the rule is continuity and not a total, and two short excursions
  never add up to one departure. The window is measured on the same clock as
  everything else here, so it covers the same stretch of the world at any frame
  rate; see the constant for the flapping it was built against and for what the
  drift rate does with that fixture now.

  A pending exit is advanced by failed **evaluations** and by nothing else.
  Predicted observations do not evaluate stillness at all (below), so a
  detection gap neither closes a window nor clears it however long it runs; a
  gap is ended by the unseen bound or by suspension, not by this.

  Every stationary update is gated on `Cairn.Observation.detected?/1`, for the
  same reason as `stale_predicted`: a predicted box repeats the plugin's own
  extrapolation, so counting it would manufacture stillness out of the plugin's
  guesses. A seeded stretch leaves the still run, the drift and every stationary
  field exactly as it found them — which is also why a settle window that
  elapsed during one is credited whole at the next detection: the run's start is
  an instant, not a stopwatch that seeds can pause.

  Two things this cannot see, both because the host has boxes and not pixels:

    * **Camera motion.** A PTZ move or a knocked mount shifts every box in the
      frame, so every stationary track starts moving together, and every one
      of them settles again once the view holds and the rule catches up. There
      is no motion compensation here — the host has no view geometry to
      compensate with.
    * **Motion inside a still box.** Someone standing in place and gesturing,
      or a car idling, keeps a motionless box and reads as stationary. The
      metric is the box, not what is happening inside it.

  The flag is not only reported: expiry keys off it, so anything that reads as
  stationary — either blind spot included — also gets the longer unseen bound
  and the strict re-match threshold that comes with it, and
  `Cairn.CameraTracker` refuses it as event evidence for as long as it
  is set.

  Bboxes are `[x, y, w, h]` **normalized to the frame**, which is what the
  plugin protocol delivers. The IoU arithmetic here is scale-free and would not
  care, but `Cairn.Tracker.Kalman` is not: it caps the width and height of the
  boxes it predicts at one frame, so a track fed pixel coordinates is matched
  against a prediction shrunk to a sliver of its box and will not answer to it.
  A box that merely overhangs the frame edge is fine, and has to be — the
  protocol admits one, an object halfway out of shot is one, and the
  prediction's origin is left free precisely so that such a track goes on
  matching itself.
  """

  require Logger

  alias Cairn.Observation
  alias Cairn.Track
  alias Cairn.Tracker.Bbd
  alias Cairn.Tracker.Kalman
  alias Cairn.ULID

  @iou_threshold 0.1
  # What a stationary track in extended grace demands of a box before it will
  # answer to it. The two thresholds are a pair and neither works alone:
  # applied to a track that is still being seen, this one rejects ordinary
  # detector jitter and the match fails, which costs the object its box on
  # every batch (`@duplicate_suppression_iou` drops it and the track never
  # stops being strict) or, where the jitter is wide enough to clear that one
  # too, a second duplicate track. Applied only where it belongs — a track
  # already unseen past `max_unseen_ms`, where every overlapping box is a
  # candidate to inherit an identity nothing is currently confirming — it is
  # what makes the grace safe.
  # Getting that pairing wrong is a silent identity bug, which is why neither
  # number is config.
  @stationary_match_iou 0.7
  # What an unmatched detection has to overlap a live *same-label* host track
  # before it reads as that track's object again — and is dropped — instead of
  # as a new object. Two different ways a batch gets there, and one number
  # serves both.
  #
  # The track is free, on one of two roads. Either some `match_threshold/2`
  # said no — which makes this the other half of `@stationary_match_iou`,
  # because without it every box the grace refuses mints the duplicate identity
  # the grace exists to prevent — or the pair was never offered at all, since
  # matching weighs a detection against the track's *predicted* box while this
  # rule weighs it against the stored one. A track whose filter has coasted
  # away from where its object was last seen can therefore be free and
  # overlapping at once with nothing having refused anything, and the answer
  # this rule gives is the same for both roads: two boxes this close within one
  # label are one object, which is already tracked.
  #
  # The track matched: the batch carried two boxes for one object, which a
  # detector without NMS does. The first took the track and the second has
  # nothing left to take. Here the label test and this threshold are the *whole*
  # guard — no `match_threshold/2` has weighed in — so the geometry below is
  # carrying the case on its own.
  #
  # 0.4 splits the band below `@stationary_match_iou` where the two mistakes
  # trade off, and the geometry either side of it is what picks the number.
  # Equal-sized boxes offset by half their extent — two people shoulder to
  # shoulder, two cars nose to tail — sit at 1/3, so they stay below this and
  # still mint; drop under 1/3 and an adjacent object of the same label is
  # dropped every batch and never tracked at all. A box wholly inside the
  # track's own sits at the fraction of it that it covers, so a detector that
  # fires on two fifths of a parked car is read as that car. Raise it towards
  # `@stationary_match_iou` and the small-box case it exists for — where a
  # box a few pixels of drift wide of the track's is already well under 0.7 —
  # falls back through and duplicates again.
  #
  # The adjacency cost is paid against matched tracks too, which is what makes
  # staying above 1/3 the load-bearing half of the choice rather than a detail:
  # a same-label object closing to within this much of a track that is being
  # detected every batch is suppressed for as long as the overlap holds, and
  # mints only once it separates. At 0.4 that is a pair of objects no geometry
  # could have told apart anyway; under 1/3 it would be ordinary adjacency, and
  # the second car in a queue would never be tracked at all.
  @duplicate_suppression_iou 0.4
  # How long after a stream reset a suspended track may still be adopted, in
  # milliseconds of the observation clock, which the two sides of a cut share
  # because it is anchored to the host's and not to either stream's pts.
  #
  # The two mistakes are not symmetric, which is what picks the number. Too
  # short and a parked car re-minted after an ffmpeg reconnect spends its whole
  # `stationary_after_ms` reading as a new arrival, which is evidence, which is
  # a clip — the failure this mechanism exists to remove, and one that repeats
  # on every reset a flaky camera has. Too long and a box landing on a departed
  # object's spot inherits its identity — at `@stitch_iou` on well under half
  # the old box's evidence. The minute is kept from the two-tier design this
  # replaced, not re-derived against the looser threshold: the asymmetry still
  # holds (the re-mint failure repeats on every reset; the inheritance needs a
  # departure *and* a replacement inside one window, and the double-track case
  # is netted by duplicate suppression), and `@stitch_iou`'s own comment prices
  # what keeping it costs. A minute is also what bounds the waiting: nothing
  # suspended outlives a minute past the cut.
  #
  # Past the cut, and not past the last sighting — so this is a bound on the
  # *waiting*, not on how long the object has actually been unobserved. A
  # stream that went quiet ten minutes before ffmpeg gave up on it hands its
  # ghosts to a new epoch ten minutes stale, and they are adoptable for a
  # minute more. That is deliberate: nothing about that camera was observed for
  # either stretch, so the two are the same blindness. What it does mean is
  # that "unobserved for at most a minute" is not something an adopted track's
  # timestamps guarantee — read `last_seen_at` for that.
  @adoption_window_ms 60_000
  # What a detection must overlap a suspended track's last box to resume that
  # identity across a stream reset — the whole of the geometry, for every
  # suspended track and every length of gap inside `@adoption_window_ms`.
  # Deliberately more than `@iou_threshold`: nothing observed the gap, so the
  # geometry is the only evidence there is, and the ordinary threshold is
  # calibrated for a track something is currently confirming.
  #
  # The number comes from the same case as `@duplicate_suppression_iou`: equal
  # boxes offset by half their extent — two cars nose to tail, two people
  # shoulder to shoulder — sit at 1/3, so a neighbour cannot take the identity,
  # while a walker over a 300 ms hiccup is still up around 0.5. That
  # calibration speaks to short gaps; over a long one the geometry is
  # uncorroborated and the window above is the only other bound. It is a
  # separate constant from that one because it answers a different question —
  # that threshold decides whether to *drop* a box, this one whether to
  # *resume* an identity — but a tuning pass may not lower it below
  # `@duplicate_suppression_iou`: the moduledoc's whole safety argument is
  # that suppression nets the loose rule's own duplicate, and a box adopted
  # below suppression's floor would leave its NMS twin unsuppressed beside
  # the identity it just resumed (the guard below the constant pins this).
  #
  # It is the only threshold adoption has, and deliberately the looser of the
  # two this replaced: see the moduledoc for why a strict tier for long gaps
  # mints the duplicates it is meant to prevent. What that costs is bounded by
  # the window above rather than by a second number — an object that left
  # during the outage can lose its ULID to whatever is standing in its box, for
  # up to a minute after the cut.
  @stitch_iou 0.4

  if @stitch_iou < @duplicate_suppression_iou do
    raise CompileError,
      file: __ENV__.file,
      line: __ENV__.line,
      description:
        "@stitch_iou must be >= @duplicate_suppression_iou: a box adopted below " <>
          "suppression's floor leaves its NMS twin unsuppressed beside the identity " <>
          "it just resumed — see the comments on both constants"
  end

  # The unseen bound for a stationary track, as a multiplier of
  # `max_unseen_ms` (the `@refusal_factor` precedent: policy the operator
  # sets the base for, scaled here by a fixed factor). A parked object is
  # occluded for as long as whatever parked in front of it stays, which is not
  # the timescale a moving track needs; the patience is paid for with
  # `@stationary_match_iou`.
  @stationary_unseen_factor 5
  # How far the object's smoothed centre may drift and still count as "has not
  # moved", as a fraction of the box's own height per `stationary_after_ms`.
  # Not config, on the same rule as `@iou_threshold`: an operator looking at a
  # camera view cannot reason about a normalized drift rate, and the knob that
  # answers the question they actually have — "how long before you call it
  # parked" — is `stationary_after_ms`.
  #
  # Derived from the tolerance this replaced rather than tuned fresh. The old
  # rule passed while the smoothed box overlapped a fixed anchor by 0.8 or
  # more. For pure translation of a box of height `h` by `d`, that overlap is
  # `(h - d) / (h + d)`, so 0.8 is `d = h / 9 ≈ 0.111 h` — the displacement a
  # parked object was allowed before it read as moving. An object drifting
  # steadily crossed that tolerance, and re-set the anchor, every `0.111 h / r`
  # for a rate `r`, so the slowest drift the old machine could ever call parked
  # is the one whose crossings are `stationary_after_ms` apart: about a tenth
  # of the box's height per settle window, shipped here as the round 0.1.
  #
  # The height is the *observed* box's, not the filter's state height: the old
  # machine measured the geometry the detector reported, and an observed height
  # is defined on the first evaluation of a track whose filter has seen one box.
  @stationary_velocity_floor 0.1
  # The same tolerance for the box's height, on the same derivation. A box that
  # only changes size overlaps its old self by the ratio of the two heights, so
  # 0.8 is a fifth of the height lost or a quarter gained; the tighter of the
  # two is what ships.
  @stationary_growth_floor 0.2
  # The drift of a track nothing has measured yet: no motion, no growth. Only
  # ever written where the filter behind it says the same thing — a box just
  # seeded is a box with zero velocity — so it is a starting value and not an
  # assumption. See `began/3`.
  @at_rest {0.0, 0.0, 0.0}
  # How long the drift must keep failing that test, on the observation clock,
  # before a stationary track is called moving. Entry and exit are otherwise
  # asymmetric in a way that only ever fails one direction: earning the flag
  # takes `stationary_after_ms` of sustained stillness, and losing it took a
  # single failed evaluation.
  #
  # What that asymmetry cost is measured, not hypothetical, and it is the
  # failure the whole hysteresis exists for. A parked car far enough from the
  # camera is a small box — 0.17 by 0.09 of the frame in the case this comes
  # from — and on a box that short, 0.02 of detector drift in y took the
  # geometry the rule then used (a median of the last five boxes, against a
  # fixed anchor) to an overlap of 0.64, well under the 0.8 it wanted. The dip
  # lasted a batch or two and the median could not absorb it; the flag cleared,
  # `started_moving` went out, and the car became evidence again
  # (`Cairn.CameraTracker` refuses only a stationary track), which opened a
  # clip. One car in an otherwise empty scene produced about ten of them in 25
  # minutes.
  #
  # That fixture is now in the test suite, and the drift rate the stillness rule
  # reads today does not flinch at it: 60 batches of alternating 0.02 jitter at
  # a 300 ms cadence produce no failed evaluation at all, because a smoothed
  # velocity is a mean and detector jitter has no mean. This window is what
  # covers the excursions a mean *does* carry — a real box that moves and comes
  # back — and, being a bound on the observation clock rather than on a count of
  # batches, it does that at any frame rate. What the delay costs is 2.5 s of
  # trigger latency on a real departure, and no footage: an event opens with
  # `pre_window_seconds` of pre-roll ahead of its trigger, which at its 5 s
  # default reaches back past the whole window.
  #
  # Not config, on the same rule as `@stationary_velocity_floor` and for a
  # sharper reason than that one. The two are a pair — this window is sized
  # against exactly the excursions that floor cannot absorb — and the pairing is
  # what the `@stationary_match_iou` block calls a silent bug: set too short it
  # does nothing and the flapping returns, set too long it holds a departed
  # object flagged as parked, and neither shows up as anything an operator
  # looking at a camera view could attribute. The knob for the question they do
  # have — "how long before you call it parked" — is `stationary_after_ms`, and
  # this is the other edge of the same hysteresis rather than a second knob.
  @stationary_exit_ms 2_500
  # How many times its effective unseen bound a track may be held alive by
  # boxes it refuses. It scales `last_matched_ms`, the one of `live?/2`'s two
  # clocks a mark does not refresh. See the moduledoc: a bound on a
  # pathological case and not the
  # rule, so it is lax enough that nothing observed normally can reach it.
  @refusal_factor 10
  # `tracking.oru`'s three numbers, all of them conversions between an elapsed
  # time and a count of filter steps.
  #
  # The nominal batch cadence. `Cairn.Tracker.Kalman` has no notion of duration
  # — one `predict/1` is one step whatever separated the two batches — so a gap
  # measured in milliseconds can only be re-expressed as the step count a replay
  # needs against an assumed cadence, and this is it. Two batches a second is
  # what an inference loop on a live camera runs at and what the test suite's
  # own `@batch_ms` encodes. A camera slower than this replays more steps than
  # its gap really had and learns a per-step velocity proportionally short of
  # the object's real per-batch pace — an under-estimate, which is the direction
  # to be wrong in for a mechanism whose whole purpose is to stop a stale
  # heading being asserted with confidence.
  @oru_step_ms 500
  # The gap a re-detection must have opened before its track's filter is rebuilt
  # across it rather than corrected through it. Under a second — two batches at
  # the cadence above — a coasted filter is still close to what it last
  # measured, and rebuilding would discard a real velocity history in exchange
  # for a two-point interpolation of the same motion.
  @oru_min_gap_ms 1_000
  # And the gap past which the interpolation is worth no more than the coast it
  # would replace. About twenty steps at the cadence above: a straight line
  # drawn between two sightings that far apart is asserting a heading through a
  # stretch long enough for the object to have turned around in, which is
  # unpublished territory — OC-SORT's own guidance for its re-update stops
  # around twenty missed frames. Past this the coasted filter is left exactly as
  # it is and the ordinary matched step runs on it, which is what happens with
  # the flag off too.
  @oru_max_gap_ms 10_000
  # Warnings here fire from the per-observation path, and an observation is a
  # per-line primitive: unrate-limited they are a log-flood of their own.
  # Measured on the observation clock like everything else here, which in
  # practice can only stretch the interval: on a stalled stream that clock falls
  # behind the host's, and the only thing that puts it ahead is the ingestion
  # floor's creep — a millisecond per line that a host millisecond does not
  # separate, so nothing at all under a thousand lines a second.
  @warn_interval_ms 5_000

  # `suspended` is `%{object_id => %{tracked: object, suspended_at: at_ms}}` —
  # the live objects a stream reset moved aside, each with the observation-clock
  # instant of the cut that moved it, which is what `within_window?/2` measures
  # the adoption window from. `last_observed_at` is a different instant, and the
  # one wall clock this struct holds: the `observed_at` of the most recent
  # observation of any kind, i.e. the last sign of life before the cut. Nothing
  # here decides on it — it is reported to the caller, whose outage gap is a
  # wall-clock duration a human reads, and the two differ by however long the
  # stream had already been quiet.
  defstruct objects: %{},
            suspended: %{},
            warned_at: %{},
            last_observed_at: nil

  @type bbox :: [number()]
  @type t :: %__MODULE__{}

  @typedoc """
  What one `suspend/3` did, for the caller's link-health report: how many
  tracks are waiting for adoption, how many were ended instead — which is
  exactly the length of the event list returned beside it: any older suspension
  the cap pushed out, and any whose window had already run out — and `at`, the
  last observation before the cut, which is the instant an
  outage gap is measured from. `at` is `nil` when no observation has ever
  reached this camera, which is the one case there is no gap to report. It is
  not the cut: see `suspend/3`.
  """
  @type suspension :: %{
          suspended: non_neg_integer(),
          ended: non_neg_integer(),
          at: DateTime.t() | nil
        }

  @typedoc """
  A camera's evidence floor, per label with a `"default"` fallback — the same
  shape `Cairn.CameraTracker` gates evidence on, read here to partition a batch
  into the two association stages.
  """
  @type floors :: %{String.t() => number()}

  @typedoc """
  Everything about the observation the tracker needs, and nothing else.

  The three optional keys are the three the code reads with `Map.get/2`: a
  caller may build a context without them — `context/3` always writes all
  three — and absence means the same as their defaults, no floor, no second
  admission and no gap replay.
  """
  @type context :: %{
          :camera_id => String.t() | nil,
          :epoch => String.t() | nil,
          :at_ms => number(),
          :observed_at => DateTime.t() | nil,
          :max_unseen_ms => pos_integer(),
          :max_live_tracks => pos_integer(),
          :stationary_after_ms => pos_integer(),
          optional(:min_score) => floors() | nil,
          optional(:bbd) => boolean(),
          optional(:oru) => boolean()
        }

  @typedoc "The host-side tracking policy for one camera."
  @type policy :: %{
          :max_unseen_ms => pos_integer(),
          :max_live_tracks => pos_integer(),
          :stationary_after_ms => pos_integer(),
          optional(:min_score) => floors() | nil,
          optional(:bbd) => boolean(),
          optional(:oru) => boolean()
        }

  @type event ::
          {:started | :updated | :ended, Track.t()}
          | {:became_stationary | :started_moving | :adopted, Track.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Builds the tracking context for one observation.

  `camera_id` is the caller's — there is one `Cairn.CameraTracker` per
  *configured* camera, and that is what a track summary must name, whatever
  the plugin put on the wire.

  `at_ms` is the observation's, stamped at ingestion (`Cairn.ObservationClock`)
  rather than read from a clock here: every bound in this module is a
  subtraction of two of them, and the tracker stays pure.

  `min_score` is optional, and is the camera's **effective** evidence floor —
  the runtime override included, not the configured map alone. It partitions
  the batch into the two association stages (see the moduledoc); absent, every
  object is stage one and nothing about association changes. It has to be the
  effective floor rather than the configured one because the two must agree: a
  floor lowered at runtime admits boxes as evidence, and a box that may open an
  event but may not mint the track that carries it is an event with no identity
  behind it.

  `bbd` is optional too, and defaults to off — the whole of what a caller that
  sets no flag sees is the IoU matching described in the moduledoc. The default
  is repeated here rather than read from `Cairn.Config` because this module is
  pure and depends on nothing; `Cairn.Config`'s `@default_bbd` is the one an
  operator's config is resolved against.

  `oru` is optional on the same terms and defaults to off: with no flag every
  track's filter is corrected through a gap rather than rebuilt across it, as
  described under "Rebuilding a filter across a gap" in the moduledoc.
  """
  @spec context(Observation.t(), String.t(), policy()) :: context()
  def context(%Observation{} = observation, camera_id, policy) do
    %{
      camera_id: camera_id,
      epoch: observation.epoch,
      at_ms: observation.at_ms,
      observed_at: observation.observed_at,
      max_unseen_ms: policy.max_unseen_ms,
      max_live_tracks: policy.max_live_tracks,
      stationary_after_ms: policy.stationary_after_ms,
      min_score: Map.get(policy, :min_score),
      bbd: Map.get(policy, :bbd, false),
      oru: Map.get(policy, :oru, false)
    }
  end

  @doc """
  Folds one observation's objects into the tracker.

  Returns `{tracker, tagged_objects, events}`: every object tagged with its
  `object_id` (ULID) and its track's `stale_predicted` and `stationary` flags,
  in the order given, and the lifecycle events this observation caused.

  An object the tracker refuses — a new identity at the live-track cap with
  nothing evictable, a detection dropped as a duplicate of a live same-label
  track it overlaps (`@duplicate_suppression_iou`), or a below-floor object
  that took no live track (see the moduledoc's two stages) — is absent from the
  tagged list, so `tagged` may be shorter than `objects`.

  Every live track this batch neither matched nor minted is **coasted** once
  after the assignments are applied: one step of its motion filter, so that
  every track's filter advances exactly once per batch whatever happened to it,
  and a track nothing observed goes on being predicted forward rather than
  freezing where it was last seen.

  Staleness is refreshed *before* expiry so that an expiring track's final
  summary reports this batch's `stale_predicted`, not the previous batch's.

  Suspensions are settled *before* anything else: one whose window ran out is
  ended here rather than left to be adopted by this batch's detections.
  """
  @spec track(t(), [map()], context()) :: {t(), [map()], [event()]}
  def track(%__MODULE__{} = tracker, objects, context) do
    {tracker, lapsed} = expire_suspended(tracker, context.at_ms)
    {tracker, assignments, adopted} = assign(tracker, objects, context)

    {tracker, tagged, lifecycle, touched} =
      apply_assignments(tracker, objects, assignments, adopted, context)

    {tracker, expired} =
      tracker |> coast_unmatched(touched) |> refresh_stale(context) |> expire(context)

    {observed(tracker, context), tagged, lapsed ++ lifecycle ++ expired}
  end

  # The wall instant a later `suspend/3` reports its outage gap from — the one
  # thing here kept in wall time, because it is reported and not decided on.
  # Moved on every batch, predicted and empty ones included: what it dates is
  # the last sign of life from the stream, not the last detection in it. It is
  # not what bounds the adoption window — that runs from the cut, which
  # `suspend/3` is handed.
  defp observed(tracker, %{observed_at: nil}), do: tracker
  defp observed(tracker, context), do: %{tracker | last_observed_at: context.observed_at}

  @doc """
  Ends every live track with `reason`, and every suspended one, returning an
  emptied tracker.

  Used where nothing may be waited for any longer: detection turned off, a
  camera stopped, a shutdown. A suspended track ends `:stream_reset` whatever
  `reason` is — the reset is what it was last seen by, and a path that gives up
  on the wait early does not change what happened to it.

  `last_observed_at` is the one thing the emptied tracker keeps: it dates the
  stream's last sign of life, which a later `suspend/3` reports its outage gap
  from, and no track of this camera's has to still exist for that to be the
  right answer.
  """
  @spec end_all(t(), Track.end_reason()) :: {t(), [event()]}
  def end_all(%__MODULE__{} = tracker, reason) do
    emptied = %__MODULE__{last_observed_at: tracker.last_observed_at}

    live = for {_id, object} <- tracker.objects, do: {:ended, to_track(object, reason)}
    {emptied, live ++ suspension_ends(tracker.suspended)}
  end

  @doc """
  Moves the live tracks aside at a stream-epoch boundary.

  Nothing observed the boundary, so no track may go on matching ordinarily
  across it — the tracker is emptied of live tracks, but they are *kept*,
  suspended, so a detection in the new epoch can adopt one instead of minting a
  duplicate of the object that was already there. See the moduledoc for what
  adoption demands and what it resumes.

  `cut_ms` is the boundary itself on the observation clock — the caller's
  `cut_clock` (`System.monotonic_time/1` unless a test injects one), since no
  observation marks a cut — and it is what
  the adoption window is measured from, not `last_observed_at`, which is the
  last sign of life *before* the cut and can be a long way behind it on a
  stream that went quiet before ffmpeg noticed. The two are separate on
  purpose: the window bounds how long the caller waits for a stream to come
  back, and the waiting starts when the stream is cut. `suspension.at` reports
  `last_observed_at` in wall time, because an outage gap is what a human reads.

  The oldest suspensions beyond `max_suspended` do not survive this — a camera
  reconnecting in a loop must not accumulate a generation of ghosts per
  attempt — and neither does any whose window has run out by `cut_ms`. Both are
  returned as `:stream_reset` finals.

  Returns `{tracker, events, suspension}`; the counts in `suspension` are the
  caller's link-health report.
  """
  @spec suspend(t(), pos_integer(), number()) :: {t(), [event()], suspension()}
  def suspend(%__MODULE__{} = tracker, max_suspended, cut_ms) do
    at = tracker.last_observed_at
    {tracker, lapsed} = expire_suspended(tracker, cut_ms)

    entering =
      Map.new(tracker.objects, fn {id, o} -> {id, %{tracked: o, suspended_at: cut_ms}} end)

    {suspended, evicted} =
      trim_suspended(Map.merge(tracker.suspended, entering), max_suspended)

    severed = suspension_ends(evicted)

    tracker = %__MODULE__{
      # `warned_at` rides across the cut: it rate-limits log lines against the
      # observation clock, which is continuous across one, and a camera
      # flapping between epochs is exactly when that matters.
      warned_at: tracker.warned_at,
      last_observed_at: at,
      suspended: suspended
    }

    events = lapsed ++ severed
    {tracker, events, %{suspended: map_size(suspended), ended: length(events), at: at}}
  end

  @doc """
  Ends every suspended track whose adoption window has run out at `at_ms`.

  Driven twice over: by `track/3` on every batch, and by the caller's own timer
  for a camera whose stream never comes back — nothing would otherwise collect
  a suspension on a dead link, and the final summary its consumers are owed
  would never go out. That timer reads the caller's own monotonic clock — real
  by default, injectable so a test need not sit through the window — which is
  the clock `at_ms` is anchored to and therefore comparable with.
  """
  @spec expire_suspended(t(), number()) :: {t(), [event()]}
  def expire_suspended(%__MODULE__{suspended: suspended} = tracker, at_ms)
      when map_size(suspended) > 0 do
    {kept, lapsed} =
      Enum.split_with(suspended, fn {_id, entry} -> within_window?(entry, at_ms) end)

    {%{tracker | suspended: Map.new(kept)}, suspension_ends(lapsed)}
  end

  def expire_suspended(%__MODULE__{} = tracker, _at_ms), do: {tracker, []}

  @doc "How long a suspended track stays adoptable, in observation-clock milliseconds."
  @spec adoption_window_ms() :: pos_integer()
  def adoption_window_ms, do: @adoption_window_ms

  @doc "Summaries of the currently live tracks (ULID order, so mint order)."
  @spec live_tracks(t()) :: [Track.t()]
  def live_tracks(%__MODULE__{} = tracker) do
    # Sorted explicitly: map iteration order is only incidentally sorted while
    # `objects` is a small (flat) map, and the checkpointed track lists this
    # feeds (`checkpoint_tracks/1`) must not reshuffle once a busy scene pushes
    # it past that boundary.
    tracker.objects
    |> Enum.sort_by(fn {id, _object} -> id end)
    |> Enum.map(fn {_id, object} -> to_track(object) end)
  end

  @doc """
  Summaries of the tracks suspended at a stream reset, waiting for adoption
  (ULID order).

  Their fields are the ones they were suspended with, the old epoch included:
  a suspended track has been observed by nothing since the cut.
  """
  @spec suspended_tracks(t()) :: [Track.t()]
  def suspended_tracks(%__MODULE__{} = tracker) do
    tracker.suspended
    |> Enum.sort_by(fn {id, _entry} -> id end)
    |> Enum.map(fn {_id, entry} -> to_track(entry.tracked) end)
  end

  @doc """
  How many tracks are still waiting for adoption.

  For a caller deciding whether it still owes anything — `suspended_tracks/1`
  builds a `Cairn.Track` per entry, which is a summary nobody asking this
  question wants.
  """
  @spec suspended_count(t()) :: non_neg_integer()
  def suspended_count(%__MODULE__{suspended: suspended}), do: map_size(suspended)

  @doc """
  Every track this tracker still owes a final summary for: the live ones and
  the suspended ones together, in ULID order.

  What a checkpoint has to hold. A restore ends all of them (`:host_restart`):
  the tracker that could have adopted a suspension died with the process, and
  the fresh one has nothing to adopt it into.
  """
  @spec checkpoint_tracks(t()) :: [Track.t()]
  def checkpoint_tracks(%__MODULE__{} = tracker) do
    Enum.sort_by(live_tracks(tracker) ++ suspended_tracks(tracker), & &1.object_id)
  end

  @doc "Intersection-over-union of two `[x, y, w, h]` boxes."
  @spec iou(bbox(), bbox()) :: float()
  def iou([ax, ay, aw, ah], [bx, by, bw, bh]) do
    ix = max(ax, bx)
    iy = max(ay, by)
    ix2 = min(ax + aw, bx + bw)
    iy2 = min(ay + ah, by + bh)

    inter = max(ix2 - ix, 0) * max(iy2 - iy, 0)
    union = aw * ah + bw * bh - inter

    if union <= 0, do: 0.0, else: inter / union
  end

  # -- suspension -------------------------------------------------------------

  # A suspended track ends as what it was last seen by. Sorted by id so a
  # caller's event order does not ride on map iteration order.
  defp suspension_ends(entries) do
    entries
    |> Enum.sort_by(fn {id, _entry} -> id end)
    |> Enum.map(fn {_id, entry} -> {:ended, to_track(entry.tracked, :stream_reset)} end)
  end

  # Newest suspension first, ties by id, keeping the head: the ghosts of the
  # reset before last are the ones a reconnect loop should lose, and they are
  # also the ones closest to their window running out anyway.
  defp trim_suspended(suspended, max_suspended) do
    if map_size(suspended) <= max_suspended do
      {suspended, []}
    else
      {kept, evicted} =
        suspended
        |> Enum.sort_by(fn {id, entry} -> {-entry.suspended_at, id} end)
        |> Enum.split(max_suspended)

      {Map.new(kept), evicted}
    end
  end

  # The waiting, bounded from the cut that started it: `suspended_at` is the
  # boundary instant, not the track's last sighting, which can be a long way
  # behind it. This is the whole of adoption's dependence on time; `adopt/4`
  # asks only for geometry.
  defp within_window?(entry, at_ms), do: at_ms - entry.suspended_at <= @adoption_window_ms

  # -- assignment -------------------------------------------------------------

  # `%{object index => object_id | :drop}`; an index with no entry is a new
  # track, `:drop` an object the tracker refuses. The third element is the ids
  # this batch adopted out of suspension, which the assignment map alone does
  # not distinguish from an ordinary match.
  #
  # Greedy IoU, best overlap first, each object and each track used once. Every
  # live track is a candidate — there is one kind of track and one way to earn
  # an identity. The threshold is per candidate track (`match_threshold/2`), so
  # it decides which pairs exist and never how the ones that exist are ordered.
  # The overlap is taken against each track's *predicted* box, computed once
  # per track for the whole batch and never stored (`predicted_box/1`).
  #
  # With `tracking.bbd` on — off by default — a second list of pairs the IoU
  # gate refused is offered after that one, admitted on centre distance
  # instead (`bbd_pairs/3`). It only ever adds pairs: the IoU list is built and
  # ordered exactly as it is without the flag, and is greedily spent first.
  #
  # What is left over then goes through `adopt/4`, stage two and
  # `suppress_duplicates/4`, so the result can also carry `:drop`s, revived
  # suspensions and a tracker whose refused tracks have been marked seen —
  # which is why this returns a tracker where the greedy half alone would not
  # have to.
  #
  # The four run in that order, for reasons that are separate.
  #
  # Adoption comes after the stage-one live pass because a track this scene is
  # *currently* seeing outranks a ghost of it: the incumbent-wins convention,
  # applied across the cut.
  #
  # Stage two comes after adoption because a low-confidence box may not resume
  # an identity. Nothing observed the gap a suspension spans, so geometry is
  # the whole of the evidence there is, and a box the detector is unsure of is
  # not enough of it — so every suspension has already had its pick of the
  # boxes that could stitch it before stage two runs at all.
  #
  # Suppression comes last, as it always has: a box that would have been
  # dropped as somebody's duplicate may be the very detection that resumes an
  # identity or carries one through an occlusion — the drop must be the last
  # answer, not the first. Adoption running before it also puts what it revived
  # into the live set in time to suppress a *second* box of the same object in
  # the same batch, which is why suppression re-reads its candidates off the
  # tracker instead of taking `candidates` below.
  #
  # Stage two's own leftovers never reach suppression: `spend_leftovers/2`
  # gives each one `:drop` and marks its index used as the stage closes, so the
  # only boxes suppression weighs are stage one's, and a below-floor box can
  # neither be minted for nor mark a track seen. The partition is on the
  # evidence floor, which is what makes that safe to do: nothing that could
  # have earned video is in the half being spent, so no evidence-eligible
  # detection is ever starved of a mint by stage two.
  defp assign(tracker, objects, context) do
    indexed = Enum.with_index(objects)
    {above_floor, below_floor} = partition(indexed, context)

    # One prediction per live track for the whole batch. `predicted_box/1`
    # steps a filter, so computing it inside the comprehension would re-step
    # every candidate once per object in the batch — same answer, 64 times the
    # arithmetic at the detection cap.
    candidates = for {id, tracked} <- tracker.objects, do: {id, tracked, predicted_box(tracked)}

    matched = greedy(new_assignment(), above_floor, candidates, context)
    {tracker, matched, adopted} = adopt(tracker, above_floor, matched, context)
    matched = stage_two(matched, below_floor, candidates, context)

    {tracker, assignments} = suppress_duplicates(tracker, indexed, matched, context)
    {tracker, assignments, adopted}
  end

  # The accumulator every pass shares: the assignment map, the object indices
  # spent, and the track ids taken. Threading one through all of them is what
  # makes "each object and each track used once" hold *across* stages and not
  # only within one.
  defp new_assignment, do: {%{}, MapSet.new(), MapSet.new()}

  # This batch's objects split at the camera's evidence floor, per label with
  # the same `"default"`-then-0.5 fallback `Cairn.CameraTracker` gates evidence
  # on — the two readings of the floor have to agree, or a box could earn video
  # without being able to mint the track that carries it.
  #
  # A context with no floor is the ordinary case today and puts everything in
  # stage one, which is why every caller that sets none sees association behave
  # exactly as it did before there were stages. `Map.get/2` and not a pattern
  # match: `context` is a plain map a caller may build without the key.
  defp partition(indexed, context) do
    case Map.get(context, :min_score) do
      nil ->
        {indexed, []}

      floors ->
        Enum.split_with(indexed, fn {object, _index} ->
          object.score >= floor_for(floors, object.label)
        end)
    end
  end

  defp floor_for(floors, label), do: Map.get(floors, label) || Map.get(floors, "default", 0.5)

  # One greedy pass over the pairs `indexed` and `candidates` can make, seeded
  # with what earlier passes already spent. Stage two hands this the same
  # builder as stage one — same label gate, same predicted boxes, same
  # `match_threshold/2`, same sort key, and the same BBD admission where the
  # flag is on — because a low-confidence box that does match is a real
  # detection and gets a real match; the only thing that makes it a lesser box
  # is what it is *not* allowed to do afterwards.
  defp greedy(matched, indexed, candidates, context) do
    pairs =
      for {object, index} <- indexed,
          {id, tracked, predicted} <- candidates,
          tracked.label == object.label,
          overlap = iou(predicted, object.bbox),
          overlap >= match_threshold(tracked, context) do
        {overlap, index, id}
      end

    # A total sort key, not just `-overlap`: `pairs` is built by comprehension
    # over a map, whose iteration order is unsorted past 32 keys, and a stable
    # sort would then resolve two identically-overlapping candidates by that
    # incidental order. `index` before `id` keeps "earlier object in the batch
    # wins", matching the incumbent-wins convention elsewhere.
    iou_pairs = Enum.sort_by(pairs, fn {overlap, index, id} -> {-overlap, index, id} end)

    # Plain concatenation, and that is the whole of how the two admissions rank
    # against each other: every IoU pair is offered before every BBD pair, so a
    # BBD pair can neither outrank one nor reorder the list it is appended to.
    # The reduce's own bookkeeping is what dedups across the join — a track or
    # an object an IoU pair took is already spent by the time the BBD half is
    # reached, so the second list can only fill in what the first left free.
    ordered = iou_pairs ++ bbd_pairs(indexed, candidates, context)

    Enum.reduce(ordered, matched, fn {_cost, index, id}, {assignments, objects, tracks} = acc ->
      if MapSet.member?(objects, index) or MapSet.member?(tracks, id) do
        acc
      else
        {Map.put(assignments, index, id), MapSet.put(objects, index), MapSet.put(tracks, id)}
      end
    end)
  end

  # The second admission, `tracking.bbd` only: pairs the IoU gate refused, near
  # enough by `Cairn.Tracker.Bbd`'s centre distance to be the same object.
  # Additive and nothing else — no IoU-calibrated constant moves, and a pair
  # that clears `match_threshold/2` is matched on its overlap exactly as it was
  # before this existed. What it is for is the case IoU cannot express at all:
  # two boxes that do not touch have an overlap of exactly zero however near
  # they are, so after a coast long enough for a walker to clear its own width
  # the right pair and every wrong one are indistinguishable, and the track
  # loses its identity to a mint.
  #
  # Stationary tracks are excluded, and that exclusion is what keeps
  # `@stationary_match_iou` meaning what it says. A parked object's
  # re-detections overlap its own box by definition, so this could only ever
  # widen a parked track's admission to boxes it is *deliberately* refusing —
  # the passer-by that the grace exists to keep out is exactly a same-label
  # detection a short distance from a stationary track, which is to say exactly
  # what BBD admits.
  #
  # Sorted ascending, since a small distance is a good pair where a large
  # overlap was, and by the same total key as the IoU half for the same reason:
  # `candidates` comes off a map, and two equal distances must not be resolved
  # by its iteration order.
  defp bbd_pairs(indexed, candidates, context) do
    if Map.get(context, :bbd) do
      # `candidates` outermost, unlike the IoU comprehension above: the elapsed
      # time is a property of the track alone, so this computes one per
      # candidate rather than one per pair. The sort key is total, so nothing
      # depends on the order the pairs come out in.
      pairs =
        for {id, tracked, predicted} <- candidates,
            not tracked.stationary,
            delta_tau_s = elapsed_s(tracked, context),
            {object, index} <- indexed,
            tracked.label == object.label,
            iou(predicted, object.bbox) < match_threshold(tracked, context),
            distance = Bbd.distance(predicted, object.bbox, delta_tau_s),
            Bbd.admit?(distance) do
          {distance, index, id}
        end

      Enum.sort_by(pairs, fn {distance, index, id} -> {distance, index, id} end)
    else
      []
    end
  end

  # How long since the track last took a box, in seconds because
  # `Cairn.Tracker.Bbd`'s clip bounds are published in them and this module's
  # clocks are milliseconds. `last_matched_ms` and not `last_seen_ms`: what the
  # covariance is built out of is the age of the last position fix, and a track
  # marked seen by a box it refused was not positioned by it (`seen/3`).
  #
  # The pattern match is an assertion and not a guard against real data: every
  # live track carries this from `new_track/3` on and nothing unsets it, so a
  # nil here is a broken invariant rather than a gap to default over — and any
  # default would be an invented elapsed time, which is precisely the quantity
  # the gate's width is derived from.
  defp elapsed_s(%{last_matched_ms: last_matched_ms}, context) when is_number(last_matched_ms),
    do: (context.at_ms - last_matched_ms) / 1_000

  # The low-confidence half: match what is left, then spend the rest. Nothing
  # here can mint (a spent index never reaches `apply_object/6` as `:new`) or
  # adopt (`adopt/4` was handed stage one's objects and has already run).
  defp stage_two(matched, [], _candidates, _context), do: matched

  defp stage_two(matched, below_floor, candidates, context) do
    matched
    |> greedy(below_floor, free_candidates(candidates, matched), context)
    |> spend_leftovers(below_floor)
  end

  # The live tracks stage one left over. A pre-filter and not the invariant —
  # `greedy/4`'s own reduce rejects a taken track anyway — but the pair list
  # stage two sorts is the smaller for it.
  #
  # A track this batch revived out of suspension is not in `candidates` at all,
  # and not because of the test below: `assign/3` builds that list off
  # `tracker.objects` before `adopt/4` runs, so a revived id was never in it to
  # be filtered. Nothing is lost by that — an adoption assigns the box that
  # revived it in the same breath, so the id is taken and stage two could not
  # have matched it either way.
  defp free_candidates(candidates, {_assignments, _objects, tracks}) do
    for {id, _tracked, _predicted} = candidate <- candidates,
        not MapSet.member?(tracks, id),
        do: candidate
  end

  # Every below-floor object stage two did not match, dropped and marked spent
  # in one step. The marking is what keeps `suppress_duplicates/4` from ever
  # seeing one: a box this weak may not mint, and it may not mark a track seen
  # either, or detector noise near a live track would hold that track alive
  # through `seen/3` for as long as the noise kept arriving.
  defp spend_leftovers(matched, below_floor) do
    Enum.reduce(below_floor, matched, fn {_object, index}, {assignments, objects, tracks} = acc ->
      if MapSet.member?(objects, index) do
        acc
      else
        {drop(assignments, index), MapSet.put(objects, index), tracks}
      end
    end)
  end

  # Where the filter says the track's box would be by now, for matching and for
  # nothing else: one further step past whatever the stored state has already
  # been advanced to, taken here and thrown away. Advancing the stored filter
  # would double-step a track that goes on to match, and would step it twice
  # per batch for as long as it did not.
  #
  # A track with no filter — one revived out of suspension, whose pre-cut
  # velocity is up to `@adoption_window_ms` stale and was dropped rather than
  # believed — falls back to its stored box, which is the frozen-box behaviour
  # this replaced and the right answer for a track with no motion estimate at
  # all. `update_track/3` re-seeds it from the very next detection.
  defp predicted_box(%{kalman: nil} = tracked), do: tracked.bbox
  defp predicted_box(%{kalman: kalman}), do: kalman |> Kalman.predict() |> Kalman.predicted_bbox()

  # Every object the stage-one live pass left unmatched, against the tracks a
  # stream reset suspended: the best overlap that clears `@stitch_iou` takes
  # the identity back, each object and each suspension used once, and the
  # revived track joins the live set as if it had matched there.
  #
  # Stage one's leftovers and no others. A below-floor box may not resume an
  # identity — see `assign/3` for why the stage runs after this one — and the
  # `indexed` list this is handed is stage one's for that reason and not as an
  # optimisation.
  #
  # The overlap is against the suspension's stored box, the last one anything
  # actually saw it at, and not against a prediction: a suspended track has no
  # live filter to predict from, and the moduledoc's rule is that an
  # extrapolation may not resume an identity in any case. That is the same
  # refusal the `Observation.detected?/1` gate below makes of the plugin's
  # extrapolations, applied to the host's own.
  #
  # One threshold and no clock: how long the track had been absent does not
  # enter into it. The only time bound is the adoption window, and `track/3`
  # has already applied it — `expire_suspended/2` runs before `assign/3`, on
  # this same batch's `at_ms`, so everything still in `suspended` here is
  # inside its window.
  #
  # Only detections. A predicted box is the plugin extrapolating where the
  # object would be if it were still there, and across a gap nothing observed
  # that is precisely the question — resuming an identity on it would let a
  # plugin talk a departed object back into existence for as long as it keeps
  # guessing.
  defp adopt(%{suspended: suspended} = tracker, indexed, matched, context)
       when map_size(suspended) > 0 do
    {_assignments, objects, _tracks} = matched

    # `not MapSet.member?(objects, index)` here is a pre-filter and not the
    # invariant: the reduce below rejects the same pairs, and dropping this
    # line changes nothing but the length of the list that gets sorted. What
    # the reduce's copy of the check does that this one cannot is reject an
    # object *this pass* has already spent — one box overlapping two ghosts
    # would otherwise resume both identities and hand the second one no
    # detection at all.
    pairs =
      for {object, index} <- indexed,
          not MapSet.member?(objects, index),
          Observation.detected?(object),
          {id, entry} <- suspended,
          entry.tracked.label == object.label,
          overlap = iou(entry.tracked.bbox, object.bbox),
          overlap >= @stitch_iou do
        {overlap, index, id}
      end

    # Same total sort key as the live pass, for the same reason: `suspended` is
    # a map, and two equal overlaps must not be resolved by its iteration order.
    pairs
    |> Enum.sort_by(fn {overlap, index, id} -> {-overlap, index, id} end)
    |> Enum.reduce({tracker, matched, []}, fn {_overlap, index, id},
                                              {tracker, {assignments, objects, tracks}, adopted} =
                                                acc ->
      if MapSet.member?(objects, index) or MapSet.member?(tracks, id) do
        acc
      else
        {tracker |> revive(id, context),
         {Map.put(assignments, index, id), MapSet.put(objects, index), MapSet.put(tracks, id)},
         [id | adopted]}
      end
    end)
  end

  defp adopt(tracker, _indexed, matched, _context), do: {tracker, matched, []}

  # Back into the live set. The clock crosses the cut intact — `at_ms` is
  # anchored to the host's monotonic clock, not to either stream's pts — so
  # nothing is re-based to make it comparable, and `last_seen_ms` is left where
  # it was: it dates the last sighting, which is what the summary reports and
  # which no adoption rule reads. `update_track/3` moves it to this batch
  # immediately afterwards, as it does for any track it updates.
  #
  # The two fields that *are* moved to `context.at_ms` are moved because of what
  # reads them, not because of which stream they came from. Both are read as an
  # elapsed stillness — `update_track/3` takes `last_detected_ms` as the start
  # of the gap `stationary_ms` accrues over, and `still_since_ms` is what the
  # settle window measures from — and the outage is time nothing watched this
  # object hold still. Their nil-ness is preserved: a track that has never been
  # detected still has no still run and no `last_detected_ms`, and inventing one
  # here would manufacture the detection the object never had.
  #
  # What is deliberately *not* touched is every judgement and every wall-clock
  # field: `started_at`, `stationary`, `stationary_since`, `stationary_ms` and
  # `best_score` all carry over, which is what lets an adopted parked car resume
  # already parked rather than as a new arrival. What restarts here is the
  # *duration* of the stillness, and nothing else about it.
  #
  # `still_velocity` goes back to rest, and `kalman` is dropped outright: the
  # two are one decision, since the average is only ever an average of that
  # filter's readings. A velocity is a claim about the last few seconds, and the
  # last thing this filter saw can be a whole `@adoption_window_ms` old — a
  # minute of coasting on a heading nothing has confirmed since, which would put
  # the resumed track's prediction anywhere. The adopting box is the one thing
  # the new epoch has actually shown, so the filter is re-seeded from it:
  # `adopt/4` only ever assigns *detected* boxes, so the `update_track/3` that
  # follows in this same `track/3` call takes the nil-plus-detection path and
  # inits. Between the two, `predicted_box/1` falls back to the stored box,
  # which is all a track with no motion estimate can honestly be matched on.
  #
  # A re-seeded filter has zero velocity, so the first evaluation of the new
  # epoch reads *still* whatever the adopting box's geometry is, and a parked
  # car that was moved during the outage resumes stationary rather than opening
  # an exit window on the adopting batch. That is a deliberate consequence of
  # having no geometry memory across the cut, not an oversight: nothing observed
  # the gap, the tracker has no anchor left to say the object is somewhere else,
  # and the ordinary rule takes over from the second detection on. It is also
  # the one place this rule is weaker than the geometry it replaced, and the
  # place an observation-gap-aware association (OC-SORT's re-update) would put
  # the evidence back. `tracking.oru`'s replay does not run here today —
  # `replayed/4` passes a filterless track through untouched — so the adopting
  # detection re-seeds from zero velocity exactly as it did before the flag
  # existed.
  #
  # `pending_exit_ms` is cleared for the same reason the run restarts: an exit
  # window is a claim about an *unbroken run of observations*, and the cut is a
  # gap nothing observed, so a run that was open when the stream died cannot be
  # continued across it.
  defp revive(tracker, id, context) do
    {entry, suspended} = Map.pop(tracker.suspended, id)

    tracked = %{
      entry.tracked
      | epoch: context.epoch,
        last_detected_ms: if(entry.tracked.last_detected_ms, do: context.at_ms),
        still_since_ms: if(entry.tracked.still_since_ms, do: context.at_ms),
        still_velocity: @at_rest,
        pending_exit_ms: nil,
        kalman: nil
    }

    %{tracker | suspended: suspended, objects: Map.put(tracker.objects, id, tracked)}
  end

  # Every object still unmatched after both greedy passes and `adopt/4`,
  # against every live track there is: an overlap of
  # `@duplicate_suppression_iou` or more with a same-label track is read as
  # that track's object again, and minting for it is how one object ends up
  # with several live tracks. It is dropped instead.
  #
  # In practice that is stage one's leftovers alone — stage two spends its own
  # before this runs (`spend_leftovers/2`), so every index this still finds
  # free carried a box at or above the camera's evidence floor.
  #
  # The overlap is against each track's **stored** box, not the predicted one
  # `assign/3` matched on. The question here is whether a second box of an
  # object the tracker already has just arrived, and the answer to that is
  # where the object was actually last seen; a prediction is a guess about
  # somewhere it has not been observed, and dropping a real detection on the
  # strength of one would be the tracker refusing evidence to protect an
  # extrapolation.
  #
  # Candidates are read off the tracker here rather than reusing the list
  # `assign/3` built, because `adopt/4` has run in between: a track this
  # batch revived out of suspension is live by now, and a second box of its
  # object has to be suppressed against it like any other.
  #
  # Suspended tracks are not among the candidates and must not be: a suspension
  # is unmatched by definition, so counting one here would drop boxes near a
  # ghost on the strength of a track nothing can see. Adoption asks for no
  # less overlap than this rule does (equal today, `>=` by the guard), so what
  # that catches is what adoption refuses at
  # it — chiefly a predicted box, which may not resume an identity and must
  # still be free to mint one, since dropping it leaves whatever is really
  # there untracked for a whole minute.
  #
  # Tracks this batch *matched* are candidates, and have to be. "The tracked
  # object's own detection takes its track, so what is left over is somebody
  # else" holds only while one object yields one box, and a detector without
  # NMS (YOLOv10) emits two for one object often enough to matter: the first
  # takes the track, the second is left over with nothing left to take, and
  # minting for it gives one parked car two concurrent tracks — the observed
  # failure had their two boxes overlapping at 0.78, twice this threshold.
  #
  # What keeps a genuinely new object over a tracked one mintable is therefore
  # the same-label guard in `duplicate_of/2` and not the state of the track: a
  # person in front of a tracked car is a different label and mints. Within one
  # label, an overlap this high is the implausible reading — see
  # `@duplicate_suppression_iou`, which is picked to sit above the 1/3 that two
  # adjacent same-label objects reach.
  #
  # Only the track the box overlaps most is marked seen, and only when that
  # track is itself unmatched: a matched track was genuinely observed this
  # batch, so a box it refused is not the only sign of life it has. See `seen/3`
  # for how little the mark means and why that asymmetry costs nothing.
  defp suppress_duplicates(tracker, indexed, {assignments, objects, tracks}, context) do
    candidates = Map.to_list(tracker.objects)

    unmatched =
      for {object, index} <- indexed, not MapSet.member?(objects, index), do: {object, index}

    Enum.reduce(unmatched, {tracker, assignments}, fn {object, index},
                                                      {tracker, assignments} = acc ->
      case duplicate_of(candidates, object) do
        nil -> acc
        id -> {mark_seen_if_unmatched(tracker, id, tracks, context), drop(assignments, index)}
      end
    end)
  end

  defp drop(assignments, index), do: Map.put(assignments, index, :drop)

  # A refused box is a sign of life only for a track this batch left unmatched:
  # that is the track for which it is the *only* one. A matched track was
  # genuinely observed, and the two fields `seen/3` moves are two
  # `update_track/3` is about to write from this same context — so the guard
  # holds back nothing observable today. It holds the rule instead, and the rule
  # is what makes it safe to give `seen/3` another field: anything at all would
  # be wrong to move on the strength of a box a detected track merely
  # overlapped.
  defp mark_seen_if_unmatched(tracker, id, tracks, context) do
    if MapSet.member?(tracks, id), do: tracker, else: seen(tracker, id, context)
  end

  # The track the box is read as belonging to: most overlapping first, ties
  # broken by id so that map iteration order never decides it (the same job the
  # sort key in `assign/3` does).
  #
  # At most one track is marked seen off one box, and only this one. A second
  # track overlapping the same box is a duplicate from an earlier batch, and
  # holding every one of them alive off one box would preserve exactly the
  # pile-up this rule exists to drain. Where the winner is a track this batch
  # matched, nothing is marked at all — a lesser-overlapping free track does not
  # inherit the mark, for the same reason.
  defp duplicate_of(candidates, object) do
    overlaps =
      for {id, tracked} <- candidates,
          tracked.label == object.label,
          overlap = iou(tracked.bbox, object.bbox),
          overlap >= @duplicate_suppression_iou,
          do: {overlap, id}

    case overlaps do
      [] -> nil
      _ -> overlaps |> Enum.min_by(fn {overlap, id} -> {-overlap, id} end) |> elem(1)
    end
  end

  # Presence without adoption: this moves the clock that expiry and
  # `match_threshold/2` read, and its `last_seen_at` twin, and nothing else.
  # Not `bbox`, `score` or `best_score` — the box was refused, so nothing about
  # it may be believed. Not `kalman`: a track marked seen is not a track this
  # batch touched, so it coasts with the rest of the unobserved ones and the
  # refused box contributes no motion. Not `last_detected_ms`, so `stale_predicted` still
  # arrives on schedule and a suppression can never manufacture evidence. Not
  # `still_since_ms` or `still_velocity`, which measure a run of boxes the track
  # actually adopted. And not `last_matched_ms`: leaving the
  # refusal bound counting from the last *adopted* observation is what bounds a
  # track whose only remaining sign of life is being refused.
  #
  # Reached only through `mark_seen_if_unmatched/4`, which is where the reason a
  # matched track never gets here is written down — and, since that is reached
  # only from `suppress_duplicates/4`, only ever off a box at or above the
  # camera's evidence floor.
  defp seen(tracker, object_id, context) do
    tracked = Map.fetch!(tracker.objects, object_id)

    store(tracker, object_id, %{
      tracked
      | last_seen_ms: context.at_ms,
        last_seen_at: context.observed_at || tracked.last_seen_at
    })
  end

  # Strict only while a stationary track is in extended grace — already unseen
  # past `max_unseen_ms`, so nothing is currently confirming the identity an
  # overlapping box would inherit. A track being seen normally matches at the
  # base threshold, and must: see `@stationary_match_iou` for what dropping
  # that distinction costs.
  #
  # For a stationary track this remains the *whole* admission, `tracking.bbd`
  # or not: `bbd_pairs/3` excludes stationary tracks precisely so that what a
  # parked identity will answer to stays one number. For a moving track under
  # the flag it is no longer the only way in — a pair it refuses may still be
  # admitted on centre distance — which is why it is read there too, to decide
  # which pairs the second gate is even offered.
  defp match_threshold(%{stationary: true} = tracked, context) do
    if context.at_ms - tracked.last_seen_ms > context.max_unseen_ms,
      do: @stationary_match_iou,
      else: @iou_threshold
  end

  defp match_threshold(_tracked, _context), do: @iou_threshold

  # Returns the ids this batch **touched** alongside the rest: every track it
  # updated (a match of either stage, an adoption) or minted. That set is the
  # complement of the coast pass — a track not in it saw nothing this batch, so
  # `coast_unmatched/2` steps its filter — and a track merely marked seen by a
  # suppression is deliberately not in it, on the same rule as everything else
  # a refusal does not move.
  defp apply_assignments(tracker, objects, assignments, adopted, context) do
    adopted = MapSet.new(adopted)
    # Tracks this batch assigned a detection to: retiring one to make room for
    # a new identity would churn the very tracks the cap exists to protect. A
    # track merely marked seen by a suppression is not in here — it is not in
    # `assignments` under an id — but its refreshed `last_seen_ms` ties it with
    # the tracks this batch did match, which is as far from the LRU victim as
    # anything in the live set gets.
    protected = for {_index, id} <- assignments, is_binary(id), into: MapSet.new(), do: id

    {tracker, tagged, events, touched} =
      objects
      |> Enum.with_index()
      |> Enum.reduce({tracker, [], [], MapSet.new()}, fn {object, index}, acc ->
        apply_object(acc, object, Map.get(assignments, index, :new), adopted, protected, context)
      end)

    {tracker, Enum.reverse(tagged), Enum.reverse(events), touched}
  end

  defp apply_object(acc, _object, :drop, _adopted, _protected, _context), do: acc

  defp apply_object(
         {tracker, tagged, events, touched},
         object,
         assigned,
         adopted,
         protected,
         context
       ) do
    case fetch_assigned(tracker, assigned) do
      {:ok, object_id, existing} ->
        tracked = update_track(existing, object, context)
        summary = to_track(tracked)

        {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
         transition(existing, tracked, summary) ++
           resumed(adopted, object_id, summary) ++ [{:updated, summary} | events],
         MapSet.put(touched, object_id)}

      :error ->
        case make_room(tracker, protected, context) do
          {:ok, tracker, evicted} ->
            object_id = new_object_id(assigned)
            tracked = new_track(object_id, object, context)

            {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
             [{:started, to_track(tracked)} | Enum.reverse(evicted) ++ events],
             MapSet.put(touched, object_id)}

          {:full, tracker} ->
            {tracker, tagged, events, touched}
        end
    end
  end

  defp fetch_assigned(_tracker, :new), do: :error

  defp fetch_assigned(tracker, object_id) do
    case Map.fetch(tracker.objects, object_id) do
      {:ok, existing} -> {:ok, object_id, existing}
      :error -> :error
    end
  end

  # The binary clause is unreachable today: every id `assign/3` emits names a
  # track that is in `objects` — a live match's, or one `adopt/4` just revived
  # — and eviction spares everything this batch assigned (`protected`), so
  # `fetch_assigned/2` cannot miss on a binary. Only the removed plugin path
  # could mint under a caller-chosen id. Kept deliberately: it preserves the
  # shape `apply_object/6` is written against rather than asserting that
  # unreachability in code.
  defp new_object_id(:new), do: ULID.generate()
  defp new_object_id(object_id), do: object_id

  defp store(tracker, object_id, tracked),
    do: %{tracker | objects: Map.put(tracker.objects, object_id, tracked)}

  # `{:adopted, summary}` sits between the track's own `:updated` and any
  # stationary transition, for the reason the transition sits after `:updated`
  # at all: a consumer folding the events in order has the resumed summary —
  # new epoch, old identity — before it is told either thing about it. It is
  # only ever emitted for a track that was suspended, so no consumer sees it on
  # a track it has not already been told about.
  defp resumed(adopted, object_id, summary) do
    if MapSet.member?(adopted, object_id), do: [{:adopted, summary}], else: []
  end

  # The transition follows its own `:updated` in the event list: that summary
  # carries the stationary fields the flip is about, so a consumer that folds
  # events in order has them before it is told the edge happened.
  defp transition(%{stationary: was}, %{stationary: was}, _summary), do: []
  defp transition(_existing, %{stationary: true}, summary), do: [{:became_stationary, summary}]
  defp transition(_existing, %{stationary: false}, summary), do: [{:started_moving, summary}]

  defp tag(object, object_id, tracked) do
    Map.merge(object, %{
      object_id: object_id,
      stale_predicted: tracked.stale_predicted,
      stationary: tracked.stationary
    })
  end

  # -- the live-track cap -----------------------------------------------------

  defp make_room(tracker, protected, context) do
    if map_size(tracker.objects) < context.max_live_tracks do
      {:ok, tracker, []}
    else
      evict_oldest(tracker, protected, context)
    end
  end

  defp evict_oldest(tracker, protected, context) do
    candidates =
      for {id, object} <- tracker.objects, not MapSet.member?(protected, id), do: {id, object}

    case candidates do
      [] ->
        {:full,
         warn_cap(tracker, context, "every live track is in this batch — dropping the new object")}

      _ ->
        # `{last_seen_ms, id}` rather than `last_seen_ms` alone: ties must not
        # be broken by map iteration order.
        #
        # LRU on `last_seen_ms` already prefers a track nothing is detecting
        # any more — one riding out its grace included — over the ones this
        # scene is actively seeing, which is the preference the cap wants:
        # extended grace buys time against expiry, not against a full live set,
        # and is deliberately not exempted here. The one grace-riding track it
        # does not prefer is one a suppression just marked seen, which is the
        # right exception for the same reason the mark exists: an overlapping
        # box this batch says the object is still there.
        {id, object} = Enum.min_by(candidates, fn {id, o} -> {o.last_seen_ms, id} end)
        tracker = warn_cap(tracker, context, "evicting the least recently seen track #{id}")

        {:ok, remove_object(tracker, id), [{:ended, to_track(object, :evicted)}]}
    end
  end

  defp warn_cap(tracker, context, detail) do
    warn_once(
      tracker,
      context,
      :track_cap,
      "camera #{context.camera_id}: at the #{context.max_live_tracks} live-track cap — #{detail}"
    )
  end

  defp remove_object(tracker, object_id),
    do: %{tracker | objects: Map.delete(tracker.objects, object_id)}

  defp warn_once(tracker, context, class, message) do
    last = Map.get(tracker.warned_at, class)

    if is_nil(last) or context.at_ms - last >= @warn_interval_ms do
      Logger.warning(message)
      %{tracker | warned_at: Map.put(tracker.warned_at, class, context.at_ms)}
    else
      tracker
    end
  end

  defp new_track(object_id, object, context) do
    detected? = Observation.detected?(object)

    stale(
      %{
        object_id: object_id,
        camera_id: context.camera_id,
        label: object.label,
        bbox: object.bbox,
        score: object.score,
        best_score: object.score,
        # Every track the host mints is its own. `plugin_track_id` is carried
        # for wire and schema compatibility only — nothing sets it any more
        # (see `Cairn.Track`), and an object's own `track_id` is not read here.
        source: :host,
        plugin_track_id: nil,
        epoch: context.epoch,
        started_at: context.observed_at,
        last_seen_at: context.observed_at,
        last_detected_at: if(detected?, do: context.observed_at),
        last_seen_ms: context.at_ms,
        last_matched_ms: context.at_ms,
        last_detected_ms: if(detected?, do: context.at_ms),
        stale_predicted: not detected?,
        # A track whose first observation is predicted has no still run yet: the
        # first *detected* box is where the stillness rule starts measuring.
        still_since_ms: if(detected?, do: context.at_ms),
        # The mean drift of the current still run, in frame units per
        # millisecond of the observation clock. Internal to the stillness rule,
        # like `pending_exit_ms` below and for the same reason.
        still_velocity: @at_rest,
        stationary: false,
        stationary_since: nil,
        stationary_ms: 0,
        # The instant an unbroken run of failed stillness evaluations began,
        # or `nil` when none is open. Internal to the stillness rule and
        # not in `Cairn.Track`: a pending exit is a track that is still
        # stationary, and publishing "stationary, but" would give every
        # consumer a third state to handle for something none of them may act
        # on.
        pending_exit_ms: nil,
        # Seeded from the first box, whatever kind it is. A seeded box may not
        # *move* the filter (see the moduledoc), but a track has to start from
        # somewhere and the alternative — no filter until the first detection —
        # would only mean falling back to that same box through
        # `predicted_box/1`. Velocity starts at zero either way, so the first
        # prediction is the box itself and a track's first batch is matched
        # exactly as it was before there was a filter. Also internal, and for a
        # stronger reason than `pending_exit_ms`: `Cairn.Tracker.Kalman`'s
        # cardinal rule is that nothing it produces may be stored or emitted.
        kalman: Kalman.init(object.bbox)
      },
      context
    )
  end

  defp update_track(tracked, object, context) do
    detected? = Observation.detected?(object)
    # Read before `last_detected_ms` moves below: stationary time accrues over
    # the gap between two *detections*, which is what this value is until then.
    previous_detected_ms = tracked.last_detected_ms

    %{
      tracked
      | label: object.label,
        bbox: object.bbox,
        score: object.score,
        best_score: max(tracked.best_score, object.score),
        last_seen_at: context.observed_at || tracked.last_seen_at,
        last_seen_ms: context.at_ms,
        last_matched_ms: context.at_ms,
        last_detected_at: if(detected?, do: context.observed_at, else: tracked.last_detected_at),
        last_detected_ms: if(detected?, do: context.at_ms, else: tracked.last_detected_ms),
        kalman: tracked |> replayed(object, detected?, context) |> advance(object, detected?)
    }
    |> stillness(object, detected?, previous_detected_ms, context)
    |> stale(context)
  end

  # The filter's one step for a track that was observed: predict, then correct
  # with the box. `bbox` above is written from the same object on the same
  # write, which is what keeps "stored box observed, filter predicted" from
  # being two facts that can drift apart.
  #
  # A seeded box advances nothing at all — not the state, not the covariance.
  # It is the plugin re-reporting a sighting it already made, so treating it as
  # an observation would let one detection be counted as many, and merely
  # predicting on it would inflate the filter's uncertainty over a stretch
  # where by the plugin's own account nothing has happened. Held is the honest
  # reading, and it is what the moduledoc promises.
  #
  # The nil case is a track `revive/3` cleared: the first detection after an
  # adoption seeds a fresh filter from the box the new epoch actually produced,
  # rather than resuming a heading a minute of blindness has invalidated.
  defp advance(kalman, _object, false), do: kalman
  defp advance(nil, object, true), do: Kalman.init(object.bbox)
  defp advance(kalman, object, true), do: kalman |> Kalman.predict() |> Kalman.update(object.bbox)

  # The filter `advance/3` then takes its one step on: the track's own, unless
  # `tracking.oru` is on and this detection closed a gap long enough that what
  # the coast has been asserting through it is not worth correcting. In that
  # case the coasted filter is dropped and rebuilt across the gap from the last
  # box the track was really observed at, against virtual observations
  # interpolated towards this detection (`Cairn.Tracker.Kalman.refit/3`).
  #
  # `refit/3` deliberately stops one step short of the target, and the step it
  # stops short of is the `advance/3` above — so nothing here predicts, and the
  # closing detection is counted exactly once. Both ends of every interpolation
  # are real boxes a detector produced: `bbox` is the last of them (a seed
  # re-reports its box verbatim, so a seeded stretch cannot have moved it) and
  # `object.bbox` is this batch's own, which is what `detected?` gates on.
  #
  # The gap is measured from `last_matched_ms`, which is what keeps a seeded
  # stretch out of this altogether — see the moduledoc: a seed refreshes that clock, so no gap
  # opens across a stretch the plugin was re-reporting through, and the motion
  # this would otherwise synthesize is motion the plugin's own account says did
  # not happen.
  #
  # A track with no filter is left without one for `advance/3` to seed from
  # this box. That is `revive/3`'s adoption case, where the gap spans a stream
  # reset: there is no coast to be skeptical of there, and today the replay
  # runs only where one is.
  defp replayed(%{kalman: nil}, _object, _detected?, _context), do: nil

  defp replayed(tracked, object, detected?, context) do
    gap = context.at_ms - tracked.last_matched_ms

    if detected? and Map.get(context, :oru, false) and gap >= @oru_min_gap_ms and
         gap <= @oru_max_gap_ms do
      Kalman.refit(tracked.bbox, object.bbox, gap_steps(gap))
    else
      tracked.kalman
    end
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

  # One step of every live track's filter that this batch neither observed nor
  # minted: the coast, and the reason an unmatched track's prediction keeps
  # moving instead of freezing where it was last seen. Exactly once per batch,
  # which is what `apply_assignments/5`'s touched set buys — a track this batch
  # matched has already been stepped by `advance/3`, and stepping it again here
  # would tell the filter the object had moved twice as far as it did.
  #
  # With `tracking.oru` on, a long coast may not outlive the detection that ends
  # it: `replayed/4` discards the coasted filter and rebuilds it across the gap.
  # That takes nothing away from the steps here, which have already done the one
  # job they are for by then — being the prediction this batch's detections were
  # matched against.
  #
  # A track with no filter stays without one until a detection re-seeds it.
  # There is nothing to coast, and inventing a filter from a stored box on a
  # batch that saw nothing would be minting a motion estimate out of silence.
  defp coast_unmatched(tracker, touched) do
    objects =
      Map.new(tracker.objects, fn {id, tracked} ->
        if MapSet.member?(touched, id), do: {id, tracked}, else: {id, coast(tracked)}
      end)

    %{tracker | objects: objects}
  end

  defp coast(%{kalman: nil} = tracked), do: tracked
  defp coast(tracked), do: %{tracked | kalman: Kalman.predict(tracked.kalman)}

  # -- stillness --------------------------------------------------------------

  # A predicted box is the plugin repeating itself, so it neither advances nor
  # resets stillness — a pending exit included, which is what makes a detection
  # gap unable to complete one. See the moduledoc, and `failed/4`.
  defp stillness(tracked, _object, false, _previous_detected_ms, _context), do: tracked

  # The first detection of a track has no run to measure and no motion estimate
  # worth reading — the filter was seeded from this very box — so it opens the
  # run and judges nothing. `still_since_ms` and `last_detected_ms` are nil
  # together on every path that writes either, which is what lets the drift
  # below divide by an interval it never has to check.
  defp stillness(tracked, object, true, previous_detected_ms, context) do
    if is_nil(tracked.still_since_ms) do
      began(tracked, @at_rest, context)
    else
      {drift, reading} = drift(tracked, previous_detected_ms, context)
      tracked = %{tracked | still_velocity: drift}

      if still?(drift, object, context) do
        still(tracked, previous_detected_ms, context)
      else
        failed(tracked, reading, previous_detected_ms, context)
      end
    end
  end

  # The object's mean drift rate over the current still run, in frame units per
  # millisecond, and the unsmoothed reading behind it.
  #
  # The filter's velocity is per *step*, and a step is however long it was —
  # one batch on a healthy stream, the whole gap when a seeded stretch held the
  # filter and the closing detection's single predict spans it — so it is
  # divided by the interval since the last detection before anything compares
  # it to a floor. Batches have no fixed cadence here (inference rate, seeded
  # stretches, a camera that stalls), and an undivided velocity would make the
  # same object read as drifting twice as fast for having been detected half as
  # often. The one case the division over-corrects is a *coasted* stretch —
  # unmatched batches each stepped the filter, so the last step covered one
  # batch and not the whole gap it is divided by — and that error reads as
  # stiller than the truth, the forgiving direction for a rule whose only power
  # is to exclude a track from evidence.
  #
  # Smoothed over one `stationary_after_ms`, which is the window the floor is
  # expressed over: both sides of the test then speak about the same duration,
  # and what the comparison asks is whether the object has drifted more than a
  # tenth of its height in a settle window's worth of motion. Averaging the
  # *signed* velocity is what makes detector jitter free: a box shaken about a
  # fixed point produces velocities that alternate in sign and mean nothing,
  # while a departure produces velocities that agree and accumulate. The raw
  # magnitude cannot tell those apart at this floor — measured, the production
  # jitter fixture's jittered batches peak past five times it — and averaging
  # magnitudes would not either, since a magnitude has no sign to cancel.
  defp drift(tracked, previous_detected_ms, context) do
    interval = max(context.at_ms - previous_detected_ms, 1)
    {vcx, vcy} = Kalman.velocity(tracked.kalman)
    reading = {vcx / interval, vcy / interval, growth(tracked.kalman) / interval}

    {smooth(tracked.still_velocity, reading, interval / context.stationary_after_ms), reading}
  end

  defp growth(%Kalman{mean: [_cx, _cy, _a, _h, _vcx, _vcy, _va, vh]}), do: vh

  defp smooth({sx, sy, sh}, {vx, vy, vh}, weight) do
    weight = min(weight, 1.0)

    {sx + weight * (vx - sx), sy + weight * (vy - sy), sh + weight * (vh - sh)}
  end

  # Both floors scale with the height of the box that was *observed*, so the
  # tolerance is a fraction of the object rather than of the frame: the same car
  # parked at the far end of the drive is a shorter box, moves fewer normalized
  # units when it does move, and would otherwise need a tighter floor to be
  # judged by the same standard.
  defp still?({vx, vy, vh}, object, context) do
    [_x, _y, _w, h] = object.bbox

    :math.sqrt(vx * vx + vy * vy) <=
      @stationary_velocity_floor * h / context.stationary_after_ms and
      abs(vh) <= @stationary_growth_floor * h / context.stationary_after_ms
  end

  # One passing evaluation is enough to end a pending exit, and ends it
  # outright rather than crediting the failures back: the excursion is over,
  # and whatever fails next starts its own window. That is the whole difference
  # between this and a counter — two two-second excursions with a good batch
  # between them are two excursions, not a four-second departure.
  defp still(tracked, previous_detected_ms, context) do
    settled(%{tracked | pending_exit_ms: nil}, previous_detected_ms, context)
  end

  defp settled(%{stationary: true} = tracked, previous_detected_ms, context) do
    %{tracked | stationary_ms: tracked.stationary_ms + (context.at_ms - previous_detected_ms)}
  end

  defp settled(tracked, _previous_detected_ms, context) do
    if context.at_ms - tracked.still_since_ms >= context.stationary_after_ms do
      %{tracked | stationary: true, stationary_since: context.observed_at}
    else
      tracked
    end
  end

  # A failed evaluation against a *stationary* track opens the exit window
  # rather than clearing the flag: see `@stationary_exit_ms` for the flapping
  # this exists to stop. Until the window closes the track is stationary in
  # every way that matters downstream — not evidence, on the extended unseen
  # bound, matching at `@stationary_match_iou` in grace — and no transition is
  # emitted, because none has happened.
  #
  # `pending_exit_ms` is the instant the *unbroken* run of failures began, not
  # a running total, and it is left where it is by every failure after the
  # first. So is the still run: while the window is open the drift goes on
  # being averaged over the run the object was parked in, which is what makes
  # the window a test of sustained motion. Zeroing the average here instead
  # would hand the next evaluation one batch's worth of accumulation — under
  # the floor even mid-departure — and a slow walk would pass evaluation after
  # evaluation, clearing its own window each time, and never leave the flag.
  #
  # Only failed evaluations reach this, so only failed evaluations can close
  # the window. A predicted stretch does not evaluate stillness at all
  # (`stillness/5`'s first clause), so a detection gap neither completes a
  # pending exit nor clears it however long it runs: time passing with nothing
  # to judge is not evidence that the object left, and a gap that goes on is
  # ended by the unseen bound or by suspension, not from here. The first
  # failure after such a gap does close a window it lands past — two failures
  # that far apart with nothing between them saying otherwise is the same
  # reading as two adjacent ones.
  #
  # `stationary_ms` accrues across the window, on the rule it accrues on
  # everywhere else: it counts the time the flag was set, and the flag is set
  # here. A real departure is over-credited by at most one window; not
  # accruing would under-credit a parked car by one excursion every time it
  # jitters, which on an object that sits there for hours is the larger error
  # and the one that grows.
  defp failed(%{stationary: true} = tracked, reading, previous_detected_ms, context) do
    pending_since = tracked.pending_exit_ms || context.at_ms

    if context.at_ms - pending_since >= @stationary_exit_ms do
      moved(tracked, reading, context)
    else
      %{
        tracked
        | pending_exit_ms: pending_since,
          stationary_ms: tracked.stationary_ms + (context.at_ms - previous_detected_ms)
      }
    end
  end

  # A track that is not stationary has no flag to sustain and no window open:
  # every failure starts its still run over, which is how the run follows a
  # moving object and how a settle is measured from where it stopped.
  defp failed(tracked, reading, _previous_detected_ms, context),
    do: moved(tracked, reading, context)

  # Leaving the flag and closing the window are one write, so nothing can
  # produce a moving track that still carries a pending exit.
  defp moved(tracked, reading, context) do
    %{
      began(tracked, reading, context)
      | stationary: false,
        stationary_since: nil,
        pending_exit_ms: nil
    }
  end

  # A still run starts from the unsmoothed reading, never from rest — the one
  # exception being a track that has no motion estimate to be honest about yet
  # (`@at_rest`, for a first detection; `revive/3` writes the same value
  # directly when an adoption drops the filter, and reaches here only for a
  # track never detected before the cut). Seeding the average at zero instead
  # would credit the object with
  # a stillness the filter has not reported: a departure whose every evaluation
  # restarts the run here would read as still on the batch after each one, and
  # a slow enough walk would collect a settle window of them.
  defp began(tracked, velocity, context),
    do: %{tracked | still_since_ms: context.at_ms, still_velocity: velocity}

  # -- expiry -----------------------------------------------------------------

  # Every elapsed time below is a subtraction of two `at_ms`, which is clamped
  # at ingestion so it neither rewinds (a restarted pts would otherwise make
  # every elapsed time negative and expire nothing, so a broken stream's whole
  # scene would live for ever) nor freezes (a stalled pts would otherwise never
  # reach a bound at all). Neither case needs a rule here.
  defp expire(tracker, context) do
    {live, expired} = Enum.split_with(tracker.objects, fn {_id, o} -> live?(o, context) end)

    case expired do
      [] ->
        {tracker, []}

      _ ->
        {%{tracker | objects: Map.new(live)},
         for({_id, object} <- expired, do: {:ended, to_track(object, :unseen)})}
    end
  end

  defp live?(object, context) do
    bound = unseen_bound(object, context)

    context.at_ms - object.last_seen_ms <= bound and
      context.at_ms - object.last_matched_ms <= @refusal_factor * bound
  end

  # Both of `live?/2`'s conditions read this one value, and the binding is what
  # holds the refusal ceiling where the host-clock backstop it replaced had it:
  # 10 × 5 × `max_unseen_ms` for a stationary track, 150 s at the 3 s default.
  # Scale only the unseen side and that becomes `@refusal_factor *
  # max_unseen_ms`, 30 s — five times sooner, on exactly the tracks the grace
  # exists for, since a track nothing is detecting is the one a suppression
  # refuses boxes on batch after batch.
  defp unseen_bound(%{stationary: true}, context),
    do: context.max_unseen_ms * @stationary_unseen_factor

  defp unseen_bound(_object, context), do: context.max_unseen_ms

  defp refresh_stale(tracker, context) do
    %{tracker | objects: Map.new(tracker.objects, fn {id, o} -> {id, stale(o, context)} end)}
  end

  defp stale(tracked, context) do
    %{tracked | stale_predicted: stale?(tracked, context)}
  end

  defp stale?(%{last_detected_ms: nil}, _context), do: true

  defp stale?(tracked, context),
    do: context.at_ms - tracked.last_detected_ms > context.max_unseen_ms

  # -- summaries --------------------------------------------------------------

  defp to_track(tracked, end_reason \\ nil) do
    %Track{
      object_id: tracked.object_id,
      camera_id: tracked.camera_id,
      label: tracked.label,
      score: tracked.score,
      best_score: tracked.best_score,
      bbox: tracked.bbox,
      source: tracked.source,
      plugin_track_id: tracked.plugin_track_id,
      epoch: tracked.epoch,
      started_at: tracked.started_at,
      last_seen_at: tracked.last_seen_at,
      last_detected_at: tracked.last_detected_at,
      stale_predicted: tracked.stale_predicted,
      stationary: tracked.stationary,
      stationary_since: tracked.stationary_since,
      stationary_ms: tracked.stationary_ms,
      end_reason: end_reason
    }
  end
end
