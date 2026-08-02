defmodule Cairn.Tracker do
  @moduledoc """
  Pure per-camera object tracker: turns a stream of observations into tracks
  with public `Cairn.ULID` identities and a started/updated/ended lifecycle.

  Identity is assigned one way, for every object: greedy-IoU matching against
  the live tracks of the same label. There is no plugin-driven mode. A plugin's
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
  — refused on threshold, or left over because the track it belongs to already
  has this batch's box for it — but that still overlaps a live **same-label**
  track by at least `@duplicate_suppression_iou`, is **dropped** rather than
  minted, whether or not that track matched this batch.
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
  arriving within `max_unseen_ms` of it matches the same box at
  `@iou_threshold` and adopts it normally. Where batches are further apart than
  that — inference slower than the camera's own unseen bound — every batch
  finds the track back in its grace and the refusal repeats, and what ends that
  is the refusal bound below rather than a match.

  If that track *matched*, nothing is marked. It was just observed for real,
  its clock has already moved, and a box it refused adds nothing to that; the
  mark exists for a track whose only remaining sign of life is the box being
  refused.

  Being marked seen is not being observed. The box was refused, so nothing
  about it is believed — not the anchor, not the stillness window, not
  `last_detected_ms`, so a track kept alive this way still goes
  `stale_predicted` on the evidence policy's own schedule and cannot be
  dragged off its anchor by what it refused. Nor is `last_matched_ms`
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

  ## Surviving a stream reset: suspension and adoption

  An ffmpeg respawn or reconnect mints a new epoch, and the object in frame is
  usually the same object. `suspend/3` therefore does not end the live tracks
  at the boundary: it moves them aside, keeping their identity, `started_at`,
  `best_score`, stationary flag and anchor, and excluding them from ordinary
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
  it has just resumed — is the duplicate suppression that runs immediately
  after it, which is retained. `@stitch_iou` is picked from the same geometry
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
  The two clock fields the adoption does move (`last_detected_ms`, `anchor_ms`)
  are moved for a reason that is not about clocks: both are read as *elapsed
  stillness* — `stationary_ms` accrues over the gap between two detections, the
  settle window measures from the anchor — and a gap nothing watched is not
  stillness anybody saw. Everything else is kept, `started_at` and
  `stationary_since` included, and so is the
  `stationary` flag itself: a car that matches its own parking space was
  parked for the whole gap, so it resumes **already** stationary and its
  settle window does not re-arm — which is the point of all of this, since
  `Cairn.CameraTracker` refuses a stationary track as evidence and a
  re-minted one would spend `stationary_after_ms` looking like a new arrival,
  i.e. like a clip. Resuming the flag is not the same as freezing it: what
  happens to it on the adopting batch is below.

  The anchor keeps its box and takes the adopting batch's clock, which splits
  the two questions stillness asks. *Has it moved* is still measured against
  where the object was before the cut, and it is asked on the adopting batch
  itself: the median window (`@recent_boxes`) is emptied at the adoption, so the
  first smoothed box of the new epoch is the adopting box and nothing else.
  *How long has it held still* restarts at the adoption, which is all the
  tracker can honestly say about a gap it did not watch.

  So `stationary` crosses the cut but is **not** guaranteed to survive the
  adoption: it is re-derived from the adopting box by the ordinary rule,
  exactly as it would be for a track that never left. A car back in its own
  space stays stationary; one whose box has drifted off the anchor by more than
  `@stationary_iou` fails the stillness test on the adopting batch itself
  rather than once a median has caught up, and — by the same rule as any other
  failure, which the adoption gets no exemption from — leaves the flag
  `@stationary_exit_ms` later, once that failure has sustained. Note that
  `@stitch_iou` is well *below* `@stationary_iou`, so a box adopted between the
  two resumes the identity and starts its exit window in the same batch — the
  same answer the ordinary rule gives for a box that far
  off its anchor. What the adoption does buy unconditionally is that the settle
  window does not re-arm: a resumed track that is still where it was is stationary
  from its first detection instead of spending `stationary_after_ms` looking
  like a new arrival.

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

  A track is stationary once its box has held still for the camera's
  `stationary_after_ms` on the observation clock. "Still" is measured against
  an **anchor** — the box the object was last seen to move to — not against the
  previous box: comparing consecutive boxes calls a slow walk motionless,
  because every step is within jitter of the one before it. The anchor is
  reset only when the object is judged to have moved — which, leaving the flag,
  is when the exit window below closes and not when the failures start — so it
  answers "has it moved since it last moved" however long the track lives.

  The current box is the per-coordinate median of the last few **detected**
  boxes rather than the newest one, so a single mis-sized box cannot flip a
  motionless object into motion, nor a moving one out of it.

  Leaving the flag takes as much sustaining as earning it. A stationary track
  whose smoothed box fails the anchor test does not flip on that evaluation: it
  goes *pending*, still stationary in every way anything downstream can see,
  and only once the failure has been unbroken for `@stationary_exit_ms` on the
  observation clock does the flag clear and `started_moving` go out — once,
  timestamped at the evaluation that closed the window. A single passing
  evaluation ends the pending state outright, so the next excursion starts a
  fresh clock: the rule is continuity and not a total, and two short excursions
  never add up to one departure. Without this, a couple of hundredths of
  detector drift on a small box — under `@stationary_iou` for the batch or two
  the median takes to absorb it — cleared the flag on a parked car every minute
  or so, and each clearing made it evidence again.

  A pending exit is advanced by failed **evaluations** and by nothing else.
  Predicted observations do not evaluate stillness at all (below), so a
  detection gap neither closes a window nor clears it however long it runs; a
  gap is ended by the unseen bound or by suspension, not by this.

  Every stationary update is gated on `Cairn.Observation.detected?/1`, for the
  same reason as `stale_predicted`: a predicted box repeats the plugin's own
  extrapolation, so counting it would manufacture stillness out of the
  plugin's guesses. Predicted observations leave the anchor and every
  stationary field untouched.

  Two things this cannot see, both because the host has boxes and not pixels:

    * **Camera motion.** A PTZ move or a knocked mount shifts every box in the
      frame, so every stationary track starts moving together as the median
      follows the new view, and every one of them settles again a threshold
      after it stops. There is no motion compensation here — the host has no
      view geometry to compensate with.
    * **Motion inside a still box.** Someone standing in place and gesturing,
      or a car idling, keeps a motionless box and reads as stationary. The
      metric is the box, not what is happening inside it.

  The flag is not only reported: expiry keys off it, so anything that reads as
  stationary — either blind spot included — also gets the longer unseen bound
  and the strict re-match threshold that comes with it, and
  `Cairn.CameraTracker` refuses it as event evidence for as long as it
  is set.

  Bboxes are `[x, y, w, h]` in any consistent unit (normalized or pixels).
  """

  require Logger

  alias Cairn.Observation
  alias Cairn.Track
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
  # The track is free: refusal is the only way both sides are left over at once,
  # since greedy matching pairs anything overlapping a track at
  # `@iou_threshold`, the threshold for every track not in extended grace. So a
  # free track and a free detection overlapping this much means some
  # `match_threshold/2` said no, which makes this the other half of
  # `@stationary_match_iou`: without it, every box the grace refuses mints the
  # duplicate identity the grace exists to prevent.
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
  # Overlap between the anchor and the smoothed current box that still counts
  # as "has not moved". Not config, on the same rule as `@iou_threshold`: an
  # operator looking at a camera view cannot reason about an IoU number, and
  # the knob that answers the question they actually have — "how long before
  # you call it parked" — is `stationary_after_ms`.
  @stationary_iou 0.8
  # How long the smoothed box must keep failing that test, on the observation
  # clock, before a stationary track is called moving. Entry and exit are
  # otherwise asymmetric in a way that only ever fails one direction: earning
  # the flag takes `stationary_after_ms` of sustained stillness, and losing it
  # took a single failed evaluation.
  #
  # What that asymmetry cost is measured, not hypothetical. A parked car far
  # enough from the camera is a small box — 0.17 by 0.09 of the frame in the
  # case this comes from — and on a box that short, 0.02 of detector drift in y
  # already puts the median at 0.64 against the anchor, under `@stationary_iou`
  # with room to spare. The dip lasted a batch or two and the median could not
  # absorb it; the flag cleared, `started_moving` went out, and the car became
  # evidence again (`Cairn.CameraTracker` refuses only a stationary
  # track), which opened a clip. One car in an otherwise empty scene produced
  # about ten of them in 25 minutes.
  #
  # 2_500 sits clear of those excursions at any usable frame rate — a couple of
  # batches, plus the couple more the median takes to turn back over — and well
  # under any departure, which fails the test continuously for as long as the
  # object is leaving, because the anchor stays put while the window is open
  # and every step of the exit is therefore measured against where the object
  # was parked rather than against where it was a batch ago. What the delay
  # costs is 2.5 s of trigger latency on a real departure, and no footage: an
  # event opens with `pre_window_seconds` of pre-roll ahead of its trigger,
  # which at its 5 s default reaches back past the whole window.
  #
  # Not config, on the same rule as `@stationary_iou` and for a sharper reason
  # than that one. The two are a pair — this window is sized against exactly
  # the jitter that threshold cannot absorb — and the pairing is what the
  # `@stationary_match_iou` block calls a silent bug: set too short it does
  # nothing and the flapping returns, set too long it holds a departed object
  # flagged as parked, and neither shows up as anything an operator looking at
  # a camera view could attribute. The knob for the question they do have —
  # "how long before you call it parked" — is `stationary_after_ms`, and this
  # is the other edge of the same hysteresis rather than a second knob.
  @stationary_exit_ms 2_500
  # Detected boxes kept for the per-coordinate median. Odd, so a full window's
  # median is a value the detector actually reported on each axis (a warming-up
  # window can be even and average two); short, so a real move reaches the
  # smoothed box within a handful of detections at any frame rate.
  @recent_boxes 5
  # How many times its effective unseen bound a track may be held alive by
  # boxes it refuses. It scales `last_matched_ms`, the one of `live?/2`'s two
  # clocks a mark does not refresh. See the moduledoc: a bound on a
  # pathological case and not the
  # rule, so it is lax enough that nothing observed normally can reach it.
  @refusal_factor 10
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

  @typedoc "Everything about the observation the tracker needs, and nothing else."
  @type context :: %{
          camera_id: String.t() | nil,
          epoch: String.t() | nil,
          at_ms: number(),
          observed_at: DateTime.t() | nil,
          max_unseen_ms: pos_integer(),
          max_live_tracks: pos_integer(),
          stationary_after_ms: pos_integer()
        }

  @typedoc "The host-side tracking policy for one camera."
  @type policy :: %{
          max_unseen_ms: pos_integer(),
          max_live_tracks: pos_integer(),
          stationary_after_ms: pos_integer()
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
      stationary_after_ms: policy.stationary_after_ms
    }
  end

  @doc """
  Folds one observation's objects into the tracker.

  Returns `{tracker, tagged_objects, events}`: every object tagged with its
  `object_id` (ULID) and its track's `stale_predicted` and `stationary` flags,
  in the order given, and the lifecycle events this observation caused.

  An object the tracker refuses — a new identity at the live-track cap with
  nothing evictable, or a detection dropped as a duplicate of a live same-label
  track it overlaps (`@duplicate_suppression_iou`) — is absent from the tagged
  list, so `tagged` may be shorter than `objects`.

  Staleness is refreshed *before* expiry so that an expiring track's final
  summary reports this batch's `stale_predicted`, not the previous batch's.

  Suspensions are settled *before* anything else: one whose window ran out is
  ended here rather than left to be adopted by this batch's detections.
  """
  @spec track(t(), [map()], context()) :: {t(), [map()], [event()]}
  def track(%__MODULE__{} = tracker, objects, context) do
    {tracker, lapsed} = expire_suspended(tracker, context.at_ms)
    {tracker, assignments, adopted} = assign(tracker, objects, context)

    {tracker, tagged, lifecycle} =
      apply_assignments(tracker, objects, assignments, adopted, context)

    {tracker, expired} = tracker |> refresh_stale(context) |> expire(context)

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
  #
  # What is left over then goes through `adopt/4` and `suppress_duplicates/4`,
  # so the result can also carry `:drop`s, revived suspensions and a tracker
  # whose refused tracks have been marked seen — which is why this returns a
  # tracker where the greedy half alone would not have to.
  #
  # The three run in that order for two separate reasons. Adoption comes after
  # the live pass because a track this scene is *currently* seeing outranks a
  # ghost of it: the incumbent-wins convention, applied across the cut. It
  # comes before suppression because a suspended track is unmatched by
  # definition and a box that would have been dropped as somebody's duplicate
  # may be the very detection that resumes an identity — the drop must be the
  # last answer, not the first. Running it first also puts what it revived into
  # the live set in time to suppress a *second* box of the same object in the
  # same batch, which is why suppression re-reads its candidates off the tracker
  # instead of taking `candidates` below.
  defp assign(tracker, objects, context) do
    indexed = Enum.with_index(objects)
    candidates = Map.to_list(tracker.objects)

    pairs =
      for {object, index} <- indexed,
          {id, tracked} <- candidates,
          tracked.label == object.label,
          overlap = iou(tracked.bbox, object.bbox),
          overlap >= match_threshold(tracked, context) do
        {overlap, index, id}
      end

    # A total sort key, not just `-overlap`: `pairs` is built by comprehension
    # over a map, whose iteration order is unsorted past 32 keys, and a stable
    # sort would then resolve two identically-overlapping candidates by that
    # incidental order. `index` before `id` keeps "earlier object in the batch
    # wins", matching the incumbent-wins convention elsewhere.
    matched =
      pairs
      |> Enum.sort_by(fn {overlap, index, id} -> {-overlap, index, id} end)
      |> Enum.reduce({%{}, MapSet.new(), MapSet.new()}, fn {_overlap, index, id},
                                                           {assignments, objects, tracks} ->
        if MapSet.member?(objects, index) or MapSet.member?(tracks, id) do
          {assignments, objects, tracks}
        else
          {Map.put(assignments, index, id), MapSet.put(objects, index), MapSet.put(tracks, id)}
        end
      end)

    {tracker, matched, adopted} = adopt(tracker, indexed, matched, context)
    {tracker, assignments} = suppress_duplicates(tracker, indexed, matched, context)
    {tracker, assignments, adopted}
  end

  # Every object the live pass left unmatched, against the tracks a stream
  # reset suspended: the best overlap that clears `@stitch_iou` takes the
  # identity back, each object and each suspension used once, and the revived
  # track joins the live set as if it had matched there.
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
  # of the gap `stationary_ms` accrues over, and `anchor_ms` is what the settle
  # window measures from — and the outage is time nothing watched this object
  # hold still. Their nil-ness is preserved: a track that has never been
  # detected still has no anchor and no `last_detected_ms`, and inventing one
  # here would manufacture the detection the object never had.
  #
  # What is deliberately *not* touched is every judgement and every wall-clock
  # field: `started_at`, `stationary`, `stationary_since`, `stationary_ms`,
  # `best_score` and the anchor box all carry over, which is what lets an
  # adopted parked car resume already parked rather than as a new arrival. The
  # anchor keeps its box but takes this batch's clock, so movement is still
  # measured against where the object last was while the *duration* of stillness
  # restarts here.
  #
  # `recent_boxes` is the one piece of geometry that does not carry over, and
  # emptying it is what makes the sentence above mean something. It is the
  # window the stillness rule takes a median over, and every box in it belongs
  # to the stream that just died: left in place it outvotes the adopting box
  # for as many batches as it has entries, so a track that really did move
  # during the gap goes on reading `stationary` — refused as evidence — until
  # the median catches up, and the number of batches that takes is whatever the
  # window happened to hold at the cut. Emptied, it is refilled by the update
  # this batch applies immediately afterwards and ends the batch holding
  # exactly the one detection the new epoch has produced, which is the shape
  # `new_track/3` leaves for a track's first detection. `stationary` is then
  # re-derived from the adopting box against the anchor, and from nothing else.
  #
  # `pending_exit_ms` is cleared for the same reason: an exit window is a claim
  # about an *unbroken run of observations*, and the cut is a gap nothing
  # observed, so a run that was open when the stream died cannot be continued
  # across it. An adoption whose
  # box has drifted off the anchor therefore opens its window on the adopting
  # batch and leaves the flag `@stationary_exit_ms` later — the sustain rule
  # has no exemption for an adoption, and an object that really did move during
  # the gap is a real departure, which is exactly the case the rule is happy to
  # take that long over.
  #
  # That the window is never *observed* empty is `adopt/4`'s doing: it revives
  # a track only for a detected object it has just assigned to it, so
  # `update_track/3` refills it in the same `track/3` call. (`median_box/1`
  # could not be handed the empty list in any case — `stillness/5` prepends the
  # current box before it takes the median.)
  defp revive(tracker, id, context) do
    {entry, suspended} = Map.pop(tracker.suspended, id)

    tracked = %{
      entry.tracked
      | epoch: context.epoch,
        last_detected_ms: if(entry.tracked.last_detected_ms, do: context.at_ms),
        anchor_ms: if(entry.tracked.anchor_bbox, do: context.at_ms),
        recent_boxes: [],
        pending_exit_ms: nil
    }

    %{tracker | suspended: suspended, objects: Map.put(tracker.objects, id, tracked)}
  end

  # Every object still unmatched after the greedy pass and `adopt/4`, against
  # every live track there is: an overlap of `@duplicate_suppression_iou`
  # or more with a same-label track is read as that track's object again, and
  # minting for it is how one object ends up with several live tracks. It is
  # dropped instead.
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
  # failure had their anchors overlapping at 0.78, twice this threshold.
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
  # it may be believed. Not `last_detected_ms`, so `stale_predicted` still
  # arrives on schedule and a suppression can never manufacture evidence. Not
  # the anchor or `recent_boxes`, which the stillness rule compares against
  # boxes the track actually adopted. And not `last_matched_ms`: leaving the
  # refusal bound counting from the last *adopted* observation is what bounds a
  # track whose only remaining sign of life is being refused.
  #
  # Reached only through `mark_seen_if_unmatched/4`, which is where the reason a
  # matched track never gets here is written down.
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
  defp match_threshold(%{stationary: true} = tracked, context) do
    if context.at_ms - tracked.last_seen_ms > context.max_unseen_ms,
      do: @stationary_match_iou,
      else: @iou_threshold
  end

  defp match_threshold(_tracked, _context), do: @iou_threshold

  defp apply_assignments(tracker, objects, assignments, adopted, context) do
    adopted = MapSet.new(adopted)
    # Tracks this batch assigned a detection to: retiring one to make room for
    # a new identity would churn the very tracks the cap exists to protect. A
    # track merely marked seen by a suppression is not in here — it is not in
    # `assignments` under an id — but its refreshed `last_seen_ms` ties it with
    # the tracks this batch did match, which is as far from the LRU victim as
    # anything in the live set gets.
    protected = for {_index, id} <- assignments, is_binary(id), into: MapSet.new(), do: id

    {tracker, tagged, events} =
      objects
      |> Enum.with_index()
      |> Enum.reduce({tracker, [], []}, fn {object, index}, acc ->
        apply_object(acc, object, Map.get(assignments, index, :new), adopted, protected, context)
      end)

    {tracker, Enum.reverse(tagged), Enum.reverse(events)}
  end

  defp apply_object(acc, _object, :drop, _adopted, _protected, _context), do: acc

  defp apply_object({tracker, tagged, events}, object, assigned, adopted, protected, context) do
    case fetch_assigned(tracker, assigned) do
      {:ok, object_id, existing} ->
        tracked = update_track(existing, object, context)
        summary = to_track(tracked)

        {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
         transition(existing, tracked, summary) ++
           resumed(adopted, object_id, summary) ++ [{:updated, summary} | events]}

      :error ->
        case make_room(tracker, protected, context) do
          {:ok, tracker, evicted} ->
            object_id = new_object_id(assigned)
            tracked = new_track(object_id, object, context)

            {store(tracker, object_id, tracked), [tag(object, object_id, tracked) | tagged],
             [{:started, to_track(tracked)} | Enum.reverse(evicted) ++ events]}

          {:full, tracker} ->
            {tracker, tagged, events}
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
        # A track whose first observation is predicted has no anchor yet: the
        # first *detected* box is what the stillness rule measures against.
        anchor_bbox: if(detected?, do: object.bbox),
        anchor_ms: if(detected?, do: context.at_ms),
        recent_boxes: if(detected?, do: [object.bbox], else: []),
        stationary: false,
        stationary_since: nil,
        stationary_ms: 0,
        # The instant an unbroken run of failed stillness evaluations began,
        # or `nil` when none is open. Internal to the stillness rule and
        # not in `Cairn.Track`: a pending exit is a track that is still
        # stationary, and publishing "stationary, but" would give every
        # consumer a third state to handle for something none of them may act
        # on.
        pending_exit_ms: nil
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
        last_detected_ms: if(detected?, do: context.at_ms, else: tracked.last_detected_ms)
    }
    |> stillness(object, detected?, previous_detected_ms, context)
    |> stale(context)
  end

  # -- stillness --------------------------------------------------------------

  # A predicted box is the plugin repeating itself, so it neither advances nor
  # resets stillness — a pending exit included, which is what makes a detection
  # gap unable to complete one. See the moduledoc, and `failed/4`.
  defp stillness(tracked, _object, false, _previous_detected_ms, _context), do: tracked

  defp stillness(tracked, object, true, previous_detected_ms, context) do
    recent = Enum.take([object.bbox | tracked.recent_boxes], @recent_boxes)
    tracked = %{tracked | recent_boxes: recent}

    cond do
      is_nil(tracked.anchor_bbox) ->
        anchor(tracked, object.bbox, context)

      iou(tracked.anchor_bbox, median_box(recent)) >= @stationary_iou ->
        still(tracked, previous_detected_ms, context)

      true ->
        failed(tracked, object.bbox, previous_detected_ms, context)
    end
  end

  # The anchor stays where it is for as long as the object does not move, so
  # the comparison spans the whole still stretch rather than one frame of it.
  #
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
    if context.at_ms - tracked.anchor_ms >= context.stationary_after_ms do
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
  # first. So is the anchor: while the window is open every
  # evaluation is still measured against where the object was parked, which is
  # what makes the window a test of sustained motion. Re-anchoring here would
  # ask instead whether the object moved since the previous *evaluation* — the
  # slow-walk mistake the anchor exists to avoid — and a departure taken a step
  # at a time would pass every one of them and never leave the flag.
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
  defp failed(%{stationary: true} = tracked, bbox, previous_detected_ms, context) do
    pending_since = tracked.pending_exit_ms || context.at_ms

    if context.at_ms - pending_since >= @stationary_exit_ms do
      moved(tracked, bbox, context)
    else
      %{
        tracked
        | pending_exit_ms: pending_since,
          stationary_ms: tracked.stationary_ms + (context.at_ms - previous_detected_ms)
      }
    end
  end

  # A track that is not stationary has no flag to sustain and no window open:
  # it re-anchors on every failure, which is how the anchor follows a moving
  # object and how a settle is measured from where it stopped.
  defp failed(tracked, bbox, _previous_detected_ms, context), do: moved(tracked, bbox, context)

  # Leaving the flag and closing the window are one write, so nothing can
  # produce a moving track that still carries a pending exit.
  defp moved(tracked, bbox, context) do
    %{
      anchor(tracked, bbox, context)
      | stationary: false,
        stationary_since: nil,
        pending_exit_ms: nil
    }
  end

  defp anchor(tracked, bbox, context),
    do: %{tracked | anchor_bbox: bbox, anchor_ms: context.at_ms}

  defp median_box(boxes), do: for(axis <- 0..3, do: median(Enum.map(boxes, &Enum.at(&1, axis))))

  defp median(values) do
    sorted = Enum.sort(values)
    mid = div(length(values), 2)

    if rem(length(values), 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

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
