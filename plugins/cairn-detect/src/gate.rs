//! The motion gate's policy: what one sample is worth, once it has been
//! measured.
//!
//! Measurement happens on the decode thread ([`crate::motion`]); the decision
//! happens here, called from the inference loop of either mode. That is the
//! only place that knows which camera a sample came from and which stream
//! epoch its lines are being tagged with, so it is the only place the epoch
//! rule below can be applied at all. One [`Gate`] per camera: single mode holds
//! one, group mode one per slot.
//!
//! Every instant is handed in by the caller. [`Gate::decide`] is a function of
//! `(config, verdict, epoch, now)` and its own state and nothing else — no
//! clock, no model, no stream — which is what makes each rule testable on its
//! own. [`Telemetry`], which reports what those decisions came to, is the same
//! shape and lives here for the same reason: it is a function of the decisions
//! and the instants they were made at, and nothing else.
//!
//! The state here belongs to the *process*, not to the stream. Group mode
//! re-opens a member's RTP stream in place (`multiplex::stream_loop`), which
//! builds a fresh decoder and with it a fresh
//! [`crate::motion::MotionDetector`] — a camera whose measurement has started
//! over while its `Gate` has not. What covers the rebuilt detector's blind
//! window is [`MotionVerdict::calibrating`]; see [`Gate::decide`]. Single mode
//! has no such window: a stream failure there is fatal, and the process Cairn
//! restarts has a fresh `Gate` too.

use std::time::{Duration, Instant};

use anyhow::Result;

use crate::decode::{ModelInput, Sample};
use crate::emit::{self, Det, Publisher};
use crate::motion::{MotionConfig, MotionVerdict};

/// What the inference loop does with one sample.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Run the model and emit what it finds.
    Detect,
    /// Skip the model. The sample is still emitted — as the remembered
    /// detections re-reported `"tracked"`, or as an empty-`objects` liveness
    /// line when there is nothing remembered: see
    /// [`Publisher::seeded_line_for`](crate::emit::Publisher::seeded_line_for).
    Skip,
}

/// One camera's gate state: when it last had motion, when the model last ran
/// on it, which epoch its lines are being stamped with, and what it has told
/// the host about all of that.
#[derive(Debug, Default)]
pub struct Gate {
    telemetry: Telemetry,
    last_motion: Option<Instant>,
    last_inference: Option<Instant>,
    /// The epoch seen at the previous decision, and when it last changed.
    /// `None`/`None` is also the state before the first sample, so a camera's
    /// first announced epoch counts as a change and opens the bypass window.
    /// So does a camera *losing* its epoch (a `stream.ended` with no
    /// `started`), which stamps `epoch_changed_at` the same way — no
    /// difference it can make while it lasts, since a camera with no epoch
    /// infers on that rule alone, and the `started` that comes back is another
    /// change with a bypass window of its own.
    epoch: Option<String>,
    epoch_changed_at: Option<Instant>,
}

impl Gate {
    /// Whether to run the model on this sample, folding it into the state.
    ///
    /// The model runs when any of these holds:
    ///
    ///   * the gate is off for this camera (`config` is `None`) — every sample
    ///     is inferred, which is the behaviour with no gate at all;
    ///   * the frame has motion;
    ///   * the verdict is missing, comes from a detector that is still
    ///     calibrating, or reports a scene cut (below);
    ///   * `linger_ms` has not elapsed since the last motion. The host earns
    ///     its `stationary` flag from *detections*, so inference has to outlast
    ///     the movement it is judging;
    ///   * `epoch_bypass_ms` has not elapsed since this camera's epoch changed.
    ///     The host refuses a `"tracked"` object as evidence for adopting a
    ///     track across a stream reset, so seeds cannot re-establish what the
    ///     reset suspended — only real detections can;
    ///   * the camera has no epoch. Nothing it emits is accepted host-side
    ///     yet, so there is nothing to protect and no reason to trust a
    ///     measurement of a stream that has not been announced;
    ///   * `reverify_ms` has elapsed since the model last ran. A gated scene is
    ///     only ever re-checked here, so this is the bound on how long a seed
    ///     can outlive the object it was copied from.
    ///
    /// **A verdict this cannot use is a verdict it does not gate on.**
    /// [`MotionVerdict`] reports no motion three ways and only one of them is
    /// about the picture, so the other two are read here as the missing
    /// measurement they are, alongside a missing verdict outright
    /// (structurally unreachable today: a configured camera builds a detector
    /// and every sample it produces carries a verdict):
    ///
    ///   * `calibrating` — the detector is measuring against a background it
    ///     is still learning, and reports no motion for the whole window
    ///     whatever is in front of the camera. The guarantee that buys is
    ///     worth stating exactly: **a camera whose motion detector is not
    ///     calibrated is never gated.** That covers the process's own first
    ///     seconds and, more to the point, every plugin-side RTP reopen, which
    ///     builds a fresh detector — a reconnect the host did not cause, and
    ///     so one that arrives with no new epoch and no bypass window of its
    ///     own.
    ///   * `scene_cut` — the whole picture changed at once (an IR-cut flip,
    ///     lights coming on), so the background it was measured against
    ///     describes a scene that is gone. Inferring is the only way to learn
    ///     what the new one contains.
    ///
    /// A cut is **not** motion, and deliberately does not arm the linger
    /// window: a light coming on in an empty room costs the one model pass the
    /// cut itself buys, not `linger_ms` of them. What bounds the frames after
    /// it is the ordinary policy — they are measured against the rebaselined
    /// background, so they read still and are gated like any still frame. If
    /// the new scene does contain something, the cut's own pass detects it,
    /// and whatever that something then does is motion that arms the linger in
    /// the usual way.
    pub fn decide(
        &mut self,
        config: Option<MotionConfig>,
        verdict: Option<MotionVerdict>,
        epoch: Option<&str>,
        now: Instant,
    ) -> Decision {
        let Some(config) = config else {
            // Gate off: nothing measures this camera, so there is nothing to
            // fold in and no state here anything would ever read. A camera's
            // config is resolved once at startup and cannot become `Some`
            // later.
            return Decision::Detect;
        };

        if self.epoch.as_deref() != epoch {
            self.epoch = epoch.map(str::to_string);
            self.epoch_changed_at = Some(now);
        }
        if verdict.is_some_and(|verdict| verdict.motion) {
            self.last_motion = Some(now);
        }

        let detect = verdict
            .is_none_or(|verdict| verdict.motion || verdict.calibrating || verdict.scene_cut)
            || epoch.is_none()
            || within(self.last_motion, config.linger_ms, now)
            || within(self.epoch_changed_at, config.epoch_bypass_ms, now)
            || !within(self.last_inference, config.reverify_ms, now);

        if detect {
            self.last_inference = Some(now);
            Decision::Detect
        } else {
            Decision::Skip
        }
    }
}

/// How long one telemetry window lasts, and so the bound on how often one
/// camera can report: a window is closed by the first sample at or past this
/// age, and at most one `plugin.status` comes out of closing one.
///
/// A rate limit like [`emit`]'s on its repeated-suppression diagnostics, and
/// for the same reason — a per-sample event needs a bound before it is written
/// anywhere. The shape differs because the bound does: that one counts frames
/// (`SUPPRESSED_LOG_EVERY`), where this one is a duration, because what it
/// bounds is a line the host stores and broadcasts and because the number it
/// carries is a *rate*, which needs an interval to be measured over at all.
const REPORT_WINDOW: Duration = Duration::from_secs(5);

/// The `state` a gate report is sent under.
///
/// Not a new lifecycle state: the process said this when it came up and is
/// still saying it. The contract attaches no meaning to `state` anyway
/// (`docs/plugin-contract.md` §`plugin.status`) — what the report carries is
/// `fps` and `detail`, and changing the state string would only invent a
/// vocabulary nothing reads.
const REPORT_STATE: &str = "ready";

/// Whether a camera's samples reached the model over one window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateState {
    /// Every sample in the window was inferred.
    Detecting,
    /// At least one was skipped.
    Gated,
}

impl GateState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Detecting => "detecting",
            Self::Gated => "gated",
        }
    }
}

/// What one camera has told the host about its gate, and the counts behind the
/// next thing it will.
///
/// **A window's state is `Gated` if the gate skipped *any* of its samples.**
/// That is what keeps the re-verify from flapping the report: a gated camera
/// runs the model once every `reverify_ms` and would otherwise transition
/// twice per interval, saying "detecting" for the one sample the model ran on.
/// Reading the window instead makes the re-verify what it is — a camera that
/// is gated and checking — at the price of a lag on the way back out: a window
/// straddling the first real motion still contains the skips before it, so
/// `Detecting` is reported by the *next* window.
///
/// Every window is closed and compared, so what reaches the host is exactly
/// the changes between *consecutive* windows — the run-length encoding of the
/// window states. A camera that gates and un-gates inside one window says
/// nothing about it: the window reads `Gated`, because it skipped a sample.
#[derive(Debug, Default)]
pub struct Telemetry {
    /// Start of the open window: the instant of the previous report, or of the
    /// first sample this camera produced. The sample that sets it is not
    /// counted into the window it opens, which is what makes the rate below
    /// exactly "what happened in the interval since".
    window: Option<Instant>,
    samples: u64,
    inferences: u64,
    /// The largest `changed_fraction` in the open window. The peak rather than
    /// the mean because `min_area_fraction` is compared against one sample at a
    /// time, which makes this the number to tune it with: **a floor above the
    /// window's peak would have called no frame in it motion.** The converse
    /// does not follow — a peak can belong to a frame that reported no motion
    /// whatever the floor was, a scene cut being the loud case.
    peak_change: Option<f32>,
    reported: Option<GateState>,
}

/// One camera's gate report: the two `plugin.status` fields it fills in.
#[derive(Debug)]
struct Report {
    fps: f64,
    detail: String,
}

impl Telemetry {
    /// Fold one sample in, and close the window if this sample is old enough
    /// to close it — returning a report only when the closed window's state
    /// differs from the last one reported.
    fn observe(
        &mut self,
        decision: Decision,
        verdict: Option<MotionVerdict>,
        now: Instant,
    ) -> Option<Report> {
        let Some(start) = self.window else {
            self.window = Some(now);
            return None;
        };
        self.samples += 1;
        if decision == Decision::Detect {
            self.inferences += 1;
        }
        if let Some(fraction) = verdict.map(|verdict| verdict.changed_fraction) {
            self.peak_change = Some(self.peak_change.map_or(fraction, |peak| peak.max(fraction)));
        }

        let elapsed = now.duration_since(start);
        if elapsed < REPORT_WINDOW {
            return None;
        }
        let state = if self.inferences < self.samples {
            GateState::Gated
        } else {
            GateState::Detecting
        };
        // `elapsed` is at least `REPORT_WINDOW` here, so neither rate can be
        // infinite or NaN — and both track the decoder's configured
        // `--sample-fps` pacing, which bounds the sampled rate only up to the
        // depth of the channel feeding this loop (a stall then a drain can
        // land two samples in one interval). Either way they stay orders of
        // magnitude inside the host's 0..10 000, so no line loses its `fps`
        // field.
        let seconds = elapsed.as_secs_f64();
        let report = (self.reported != Some(state)).then(|| Report {
            fps: self.inferences as f64 / seconds,
            detail: format!(
                "motion gate: {}{}; {:.2} fps inferred of {:.2} sampled over {:.1} s; \
                 peak change {}",
                match self.reported {
                    Some(previous) => format!("{} -> ", previous.as_str()),
                    None => String::new(),
                },
                state.as_str(),
                self.inferences as f64 / seconds,
                self.samples as f64 / seconds,
                seconds,
                match self.peak_change {
                    Some(fraction) => format!("{:.2}%", f64::from(fraction) * 100.0),
                    None => "n/a".to_string(),
                }
            ),
        });

        self.reported = Some(state);
        self.window = Some(now);
        self.samples = 0;
        self.inferences = 0;
        self.peak_change = None;
        report
    }
}

/// The lines one sample owes stdout.
pub struct Lines {
    /// This sample's `frame.objects` line, real or seeded, or `None` when the
    /// publisher declined it.
    pub objects: Option<String>,
    /// A `plugin.status` when this sample closed a telemetry window whose gate
    /// state differs from the last one reported — see [`Telemetry`]. Always
    /// `None` for a camera whose gate is off: nothing there can skip a sample,
    /// so the effective inference rate is the sample rate and every line the
    /// host already receives says so.
    pub status: Option<String>,
}

/// One sample, from verdict to protocol line: the gate's decision, the model
/// pass it does or does not authorize, and the line either way.
///
/// Both modes call this and nothing else. What differs between them is which
/// camera's `gate` and `config` a sample belongs to — single mode has one of
/// each, group mode holds them by slot — never what is done with the sample,
/// which is the whole of the duplication the two inference loops carry.
///
/// A [`Lines::objects`] of `None` is the publisher declining the line (this
/// camera has no epoch, or the `pts` is outside the contract's range); it is not
/// the gate skipping one.
/// **A gated sample always produces a line to write, or a suppression the
/// publisher counted.** Nothing is silently dropped between the two — an
/// inference the gate skipped still costs a sequence number and still tells the
/// host this camera is alive.
///
/// `infer` is the model pass, called only for [`Decision::Detect`]. Taking it
/// as a closure is what keeps the tensor out of this function: the verdict is
/// read off the sample before its [`ModelInput`] is handed over, which is the
/// order that matters — the input is moved into the model and the verdict
/// would be gone with it.
pub fn sample_line(
    gate: &mut Gate,
    publisher: &mut Publisher,
    camera_id: &str,
    config: Option<MotionConfig>,
    sample: Sample,
    now: Instant,
    infer: impl FnOnce(ModelInput) -> Result<Vec<Det>>,
) -> Result<Lines> {
    // Skipped entirely for an ungated camera: `decide` answers `Detect` on a
    // `None` config without consulting the epoch, so this read would be work a
    // gate that is off has no use for.
    //
    // The publisher reads the epoch table again for the same sample, and the
    // control thread can apply a `started`/`ended` between the two, so the two
    // reads can differ by one control line. What makes that safe lives in the
    // publisher: it clears `last_dets` on the epoch it actually sees, so a
    // sample this decided to skip under the old epoch is seeded as the empty
    // liveness line under the new one, never as the old one's boxes.
    let epoch = config.and_then(|_| publisher.epoch_of(camera_id));
    let decision = gate.decide(config, sample.motion, epoch.as_deref(), now);
    // The verdict is read here for the same reason `decide` reads it here:
    // `sample.input` is moved into the model below and the verdict goes with
    // it. An `infer` that then fails loses this report, which is the right
    // outcome — both loops turn that error into a process exit.
    let status = config
        .and_then(|_| gate.telemetry.observe(decision, sample.motion, now))
        .map(|report| {
            emit::status_line(
                Some(camera_id),
                REPORT_STATE,
                Some(&report.detail),
                Some(report.fps),
            )
        });
    let objects = match decision {
        Decision::Detect => {
            let dets = infer(sample.input)?;
            publisher.line_for(camera_id, sample.pts_90k, sample.observed_at, &dets)
        }
        Decision::Skip => publisher.seeded_line_for(camera_id, sample.pts_90k, sample.observed_at),
    };
    Ok(Lines { objects, status })
}

/// Whether `since` happened, and less than `ms` ago.
///
/// `None` is "never", which is *not* within any window: a camera that has never
/// inferred fails the re-verify test and infers, and one that has never seen
/// motion is not lingering.
///
/// Strict `<` so that `0` disables the rule it bounds outright rather than
/// leaving it live for one instant — `linger_ms: 0` is "do not linger",
/// `reverify_ms: 0` is "re-verify every sample", which is a gate that never
/// skips.
fn within(since: Option<Instant>, ms: u64, now: Instant) -> bool {
    since.is_some_and(|at| now.duration_since(at) < Duration::from_millis(ms))
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPOCH: &str = "01K1B2C3D4E5F6G7H8J9K0M1N2";
    const OTHER: &str = "01K1B2C3D4E5F6G7H8J9K0M1N3";

    /// The defaults, gate on: linger 12 s, epoch bypass 15 s, re-verify 10 s.
    fn config() -> Option<MotionConfig> {
        Some(MotionConfig {
            enabled: true,
            ..MotionConfig::default()
        })
    }

    fn moving() -> Option<MotionVerdict> {
        Some(MotionVerdict {
            changed_fraction: 0.2,
            motion: true,
            calibrating: false,
            scene_cut: false,
        })
    }

    fn still() -> Option<MotionVerdict> {
        Some(MotionVerdict {
            changed_fraction: 0.0,
            motion: false,
            calibrating: false,
            scene_cut: false,
        })
    }

    fn calibrating() -> Option<MotionVerdict> {
        Some(MotionVerdict {
            changed_fraction: 0.4,
            motion: false,
            calibrating: true,
            scene_cut: false,
        })
    }

    /// The lightning branch's verdict past the calibration window: the whole
    /// picture changed, which is not motion and is not a still scene either.
    fn cut() -> Option<MotionVerdict> {
        Some(MotionVerdict {
            changed_fraction: 0.93,
            motion: false,
            calibrating: false,
            scene_cut: true,
        })
    }

    /// A gate past every window a fresh one sits inside: one epoch, seen long
    /// enough ago that the bypass has expired, with an inference just made.
    /// Returns it alongside the instant that last inference happened.
    fn settled() -> (Gate, Instant) {
        let mut gate = Gate::default();
        let start = Instant::now();
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), start),
            Decision::Detect,
            "the first sample of an epoch is inside the bypass window"
        );
        let settled = start + Duration::from_millis(15_000);
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), settled),
            Decision::Detect,
            "the bypass has expired but the re-verify is due"
        );
        (gate, settled)
    }

    fn at(base: Instant, ms: u64) -> Instant {
        base + Duration::from_millis(ms)
    }

    #[test]
    fn a_disabled_gate_infers_every_sample() {
        let mut gate = Gate::default();
        let now = Instant::now();
        // no config, no verdict, no epoch: the shape of every sample in a run
        // with the gate off, none of which may be skipped
        for step in 0..100 {
            assert_eq!(
                gate.decide(None, None, None, at(now, step * 200)),
                Decision::Detect
            );
        }
    }

    #[test]
    fn a_camera_with_no_epoch_is_never_gated() {
        let mut gate = Gate::default();
        let now = Instant::now();
        // an hour of stillness, well past every window: what keeps this
        // inferring is the missing epoch alone
        for step in 0..100 {
            assert_eq!(
                gate.decide(config(), still(), None, at(now, step * 36_000)),
                Decision::Detect
            );
        }
    }

    #[test]
    fn motion_then_linger_then_gated() {
        let (mut gate, base) = settled();

        assert_eq!(
            gate.decide(config(), moving(), Some(EPOCH), at(base, 1_000)),
            Decision::Detect
        );
        // the whole linger window past that motion, sampled at this fixture's
        // 5 fps cadence (200 ms/step — `Gate` itself reads wall-clock
        // instants, never a sample rate): still inferring, so nothing here
        // refreshes the re-verify's meaning
        for step in 1..60 {
            assert_eq!(
                gate.decide(config(), still(), Some(EPOCH), at(base, 1_000 + step * 200)),
                Decision::Detect,
                "{step} samples after the motion"
            );
        }
        // 12_000 ms after the motion the linger is over, and the last
        // inference was a sample ago — the gate closes
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 13_000)),
            Decision::Skip
        );
    }

    #[test]
    fn an_epoch_change_bypasses_the_gate() {
        let (mut gate, base) = settled();
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 1_000)),
            Decision::Skip,
            "gated before the change"
        );

        // the host restarted the stream: every sample is inferred until the
        // bypass expires, because a seed cannot re-establish a suspended track.
        // 75 samples is the whole 15 s window at this fixture's 5 fps cadence,
        // the last of them at 16 800 ms.
        for step in 0..75 {
            assert_eq!(
                gate.decide(config(), still(), Some(OTHER), at(base, 2_000 + step * 200)),
                Decision::Detect,
                "{step} samples into the new epoch"
            );
        }
        assert_eq!(
            gate.decide(config(), still(), Some(OTHER), at(base, 17_000)),
            Decision::Skip
        );
    }

    #[test]
    fn a_stopped_camera_reopens_its_bypass_when_it_comes_back() {
        let (mut gate, base) = settled();
        // `stream.ended` with no `started`: the epoch is gone, and a camera
        // with no epoch is not gated
        assert_eq!(
            gate.decide(config(), still(), None, at(base, 1_000)),
            Decision::Detect
        );
        // …and the epoch that comes back is a change like any other
        assert_eq!(
            gate.decide(config(), still(), Some(OTHER), at(base, 2_000)),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(config(), still(), Some(OTHER), at(base, 16_000)),
            Decision::Detect,
            "14 s into the bypass"
        );
        assert_eq!(
            gate.decide(config(), still(), Some(OTHER), at(base, 17_100)),
            Decision::Skip
        );
    }

    #[test]
    fn a_gated_camera_re_verifies_on_the_interval() {
        let (mut gate, base) = settled();
        // A still scene sampled at this fixture's 5 fps cadence for a minute.
        // Every sample is gated except the ones the re-verify claims, and
        // those land every `reverify_ms` — measured from the last inference,
        // so they do not drift with the sample cadence.
        let mut inferences = Vec::new();
        for step in 1..=300 {
            let ms = step * 200;
            if gate.decide(config(), still(), Some(EPOCH), at(base, ms)) == Decision::Detect {
                inferences.push(ms);
            }
        }
        assert_eq!(
            inferences,
            vec![10_000, 20_000, 30_000, 40_000, 50_000, 60_000]
        );
    }

    #[test]
    fn a_calibrating_detector_is_never_gated() {
        let (mut gate, base) = settled();
        // The state after a plugin-side RTP reopen: the same `Gate`, a brand
        // new `MotionDetector`. Its calibration window reports no motion for
        // 25 samples whatever is in front of the camera, and no epoch arrives
        // to bypass with — Cairn did not cause this reconnect and knows
        // nothing about it.
        for step in 0..25 {
            assert_eq!(
                gate.decide(config(), calibrating(), Some(EPOCH), at(base, step * 200)),
                Decision::Detect,
                "calibration sample {step}"
            );
        }
        // and the first verdict it can stand behind gates again
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 5_000)),
            Decision::Skip
        );
    }

    #[test]
    fn a_scene_cut_is_inferred_and_leaves_the_frames_after_it_to_the_ordinary_windows() {
        let (mut gate, base) = settled();
        // A floodlight coming on over a scene this gate has settled on.
        // Nothing moved by `min_area_fraction`'s reckoning, but the background
        // the verdict was measured against is gone, so this is the one frame
        // that has to be looked at.
        assert_eq!(
            gate.decide(config(), cut(), Some(EPOCH), at(base, 1_000)),
            Decision::Detect
        );
        // The rebaseline installs the lit scene as the background, so every
        // frame after it compares clean and reads still — and they are gated
        // as still frames, the cut having armed no window of its own. Just
        // under ten seconds of them at this fixture's 5 fps cadence, the last
        // one a sample short of the re-verify.
        for step in 1..50 {
            assert_eq!(
                gate.decide(config(), still(), Some(EPOCH), at(base, 1_000 + step * 200)),
                Decision::Skip,
                "{step} samples after the cut"
            );
        }
        // …and what ends the run is the re-verify, measured from the cut's own
        // inference, which is exactly what a `linger_ms` armed here would have
        // pre-empted.
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 11_000)),
            Decision::Detect
        );
    }

    #[test]
    fn a_camera_that_cuts_on_every_sample_is_never_gated() {
        let (mut gate, base) = settled();
        // An IR-cut filter hunting at dusk: the detector rebaselines on every
        // sample and reports no motion on every one. None of them is a
        // measurement of a scene, so none of them may be skipped on.
        for step in 0..50 {
            assert_eq!(
                gate.decide(config(), cut(), Some(EPOCH), at(base, step * 200)),
                Decision::Detect,
                "cut {step}"
            );
        }
    }

    #[test]
    fn a_missing_verdict_is_not_gated_on() {
        let (mut gate, base) = settled();
        for step in 0..10 {
            assert_eq!(
                gate.decide(config(), None, Some(EPOCH), at(base, step * 200)),
                Decision::Detect
            );
        }
    }

    #[test]
    fn each_window_can_be_switched_off_by_zero() {
        let zeroed = MotionConfig {
            enabled: true,
            linger_ms: 0,
            epoch_bypass_ms: 0,
            reverify_ms: 0,
            ..MotionConfig::default()
        };
        let off = Some(zeroed);
        let mut gate = Gate::default();
        let base = Instant::now();

        // `reverify_ms: 0` alone is a gate that never skips: the interval is
        // due on every sample
        assert_eq!(
            gate.decide(off, still(), Some(EPOCH), base),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(off, moving(), Some(EPOCH), at(base, 200)),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(off, still(), Some(EPOCH), at(base, 400)),
            Decision::Detect
        );

        // with the re-verify long instead, the other two zeros show: motion
        // does not linger and the epoch change does not bypass
        let no_linger = Some(MotionConfig {
            reverify_ms: 3_600_000,
            ..zeroed
        });
        let mut gate = Gate::default();
        assert_eq!(
            gate.decide(no_linger, moving(), Some(EPOCH), base),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(no_linger, still(), Some(EPOCH), at(base, 200)),
            Decision::Skip,
            "no linger past the motion"
        );
        assert_eq!(
            gate.decide(no_linger, still(), Some(OTHER), at(base, 400)),
            Decision::Skip,
            "no bypass past the epoch change"
        );
    }

    #[test]
    fn motion_refreshes_the_linger_from_the_newest_frame() {
        let (mut gate, base) = settled();
        // motion 10 s apart: the second one moves the window rather than the
        // first one's expiry standing
        assert_eq!(
            gate.decide(config(), moving(), Some(EPOCH), at(base, 1_000)),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(config(), moving(), Some(EPOCH), at(base, 11_000)),
            Decision::Detect
        );
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 22_000)),
            Decision::Detect,
            "11 s after the second motion, inside the linger"
        );
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 23_100)),
            Decision::Skip
        );
    }

    #[test]
    fn the_same_epoch_seen_again_is_not_a_change() {
        let (mut gate, base) = settled();
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 1_000)),
            Decision::Skip
        );
        // the epoch is re-read per sample; re-reading the one already held
        // must not re-open a 15 s bypass on every frame
        assert_eq!(
            gate.decide(config(), still(), Some(EPOCH), at(base, 1_200)),
            Decision::Skip
        );
    }

    /// The sample-to-line path both inference loops run, driven without a
    /// model: `infer` stands in for the detector, and counting its calls is
    /// how a skipped model pass is observed at all.
    mod sample_line {
        use std::sync::Arc;
        use std::time::SystemTime;

        use super::*;
        use crate::control::{Control, Streams};
        use crate::decode::ModelInput;
        use crate::emit::ObservationKind;
        use crate::infer::{InputSize, Projection};

        pub(super) fn publisher(camera_ids: &[&str]) -> (Arc<Streams>, Publisher) {
            let streams = Arc::new(Streams::new(camera_ids.iter().copied()));
            (Arc::clone(&streams), Publisher::new(streams))
        }

        pub(super) fn start(streams: &Streams, camera_id: &str, epoch: &str) {
            streams.apply(Control::Started {
                camera_id: camera_id.to_string(),
                stream_epoch: epoch.to_string(),
            });
        }

        fn end(streams: &Streams, camera_id: &str, epoch: &str) {
            streams.apply(Control::Ended {
                camera_id: camera_id.to_string(),
                stream_epoch: epoch.to_string(),
            });
        }

        fn sequence(line: &str) -> u64 {
            let value: serde_json::Value =
                serde_json::from_str(line).expect("emitted line is valid json");
            value["sequence"].as_u64().expect("every line is numbered")
        }

        /// A sample carrying `verdict`. The tensor is empty: nothing in this
        /// module looks at it, and the stand-in detector below never gets one
        /// it did not ignore.
        pub(super) fn sample(verdict: Option<MotionVerdict>) -> Sample {
            Sample {
                pts_90k: 900,
                observed_at: SystemTime::UNIX_EPOCH,
                motion: verdict,
                input: ModelInput {
                    tensor: Vec::new(),
                    projection: Projection::stretch(InputSize::square(64)),
                },
            }
        }

        fn det(label: &str, score: f64) -> Det {
            Det {
                label: label.to_string(),
                score,
                bbox: [0.1, 0.2, 0.3, 0.4],
                observation_kind: ObservationKind::Detected,
                evidence: true,
            }
        }

        /// A detection `--track-floor-json` admitted: below its label's
        /// `min_score`, on the wire at its real score, and not a sighting the
        /// gate may re-report.
        pub(super) fn sub_floor(label: &str, score: f64) -> Det {
            Det {
                evidence: false,
                ..det(label, score)
            }
        }

        fn objects(line: &str) -> Vec<(String, f64, String)> {
            let value: serde_json::Value =
                serde_json::from_str(line).expect("emitted line is valid json");
            value["objects"]
                .as_array()
                .expect("every line carries an objects array")
                .iter()
                .map(|object| {
                    (
                        object["label"].as_str().unwrap_or_default().to_string(),
                        object["score"].as_f64().unwrap_or_default(),
                        object["observation_kind"]
                            .as_str()
                            .unwrap_or("<absent>")
                            .to_string(),
                    )
                })
                .collect()
        }

        /// One camera as an inference loop holds it: its gate, the config it
        /// runs under, and what its stand-in model finds when it is allowed to
        /// run — plus the count of times it was.
        struct Member {
            id: &'static str,
            gate: Gate,
            config: Option<MotionConfig>,
            found: Vec<Det>,
            passes: usize,
        }

        impl Member {
            fn new(id: &'static str, config: Option<MotionConfig>, found: Vec<Det>) -> Self {
                Self {
                    id,
                    gate: Gate::default(),
                    config,
                    found,
                    passes: 0,
                }
            }

            /// One sample through the whole path.
            fn run(
                &mut self,
                publisher: &mut Publisher,
                verdict: Option<MotionVerdict>,
                now: Instant,
            ) -> Option<String> {
                let found = self.found.clone();
                let passes = &mut self.passes;
                sample_line(
                    &mut self.gate,
                    publisher,
                    self.id,
                    self.config,
                    sample(verdict),
                    now,
                    |_input| {
                        *passes += 1;
                        Ok(found)
                    },
                )
                .expect("the stand-in detector never fails")
                .objects
            }

            /// The same, for a camera the host has started: a line is owed.
            fn line(
                &mut self,
                publisher: &mut Publisher,
                verdict: Option<MotionVerdict>,
                now: Instant,
            ) -> String {
                self.run(publisher, verdict, now)
                    .expect("a started camera emits every sample, gated or not")
            }
        }

        #[test]
        fn single_mode_seeds_the_samples_it_skips_and_never_swallows_one() {
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut front = Member::new("front", config(), vec![det("person", 0.87)]);
            let base = Instant::now();

            // motion, then a still scene sampled at this fixture's 5 fps
            // cadence for 30 s: every sample emits a line, and the model runs
            // only while the policy says it should
            let lines: Vec<String> = (0..150)
                .map(|step| {
                    let verdict = if step == 0 { moving() } else { still() };
                    front.line(&mut publisher, verdict, at(base, step * 200))
                })
                .collect();

            assert_eq!(lines.len(), 150, "no sample is silently dropped");
            // The first sample is this camera's first epoch, so the 15 s
            // bypass — 75 samples — covers the linger and the motion both.
            // After it the scene is still and gated, and the model runs once
            // more when the re-verify comes due 10 s later, at 24.8 s.
            assert_eq!(front.passes, 76);
            // every line is on the wire, in order, with no gap in the
            // numbering the host reads as loss
            for (expected, line) in lines.iter().enumerate() {
                let value: serde_json::Value = serde_json::from_str(line).unwrap();
                assert_eq!(value["sequence"], expected as u64);
            }
            // and a gated one carries the last real line's boxes, seeded
            assert_eq!(
                objects(&lines[149]),
                vec![("person".to_string(), 0.87, "tracked".to_string())]
            );
            assert_eq!(
                objects(&lines[0]),
                vec![("person".to_string(), 0.87, "<absent>".to_string())]
            );
        }

        #[test]
        fn a_gate_that_is_off_runs_the_model_on_every_sample() {
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut front = Member::new("front", None, vec![det("person", 0.9)]);
            let base = Instant::now();

            for step in 0..50 {
                let line = front.line(&mut publisher, None, at(base, step * 200));
                assert_eq!(
                    objects(&line),
                    vec![("person".to_string(), 0.9, "<absent>".to_string())],
                    "nothing is ever seeded with the gate off"
                );
            }
            assert_eq!(front.passes, 50);
        }

        #[test]
        fn group_mode_gates_each_member_on_its_own() {
            // What the group loop holds: one publisher, one gate per slot. A
            // member that is busy must not keep its neighbour's model running,
            // and a member's seeds are its own.
            let (streams, mut publisher) = publisher(&["front", "drive"]);
            start(&streams, "front", EPOCH);
            start(&streams, "drive", OTHER);
            let mut front = Member::new("front", config(), vec![det("person", 0.9)]);
            let mut drive = Member::new("drive", config(), vec![det("car", 0.5)]);
            let base = Instant::now();

            // both members settle out of their epoch-bypass windows on a still
            // scene, then `front` alone starts moving
            for step in 0..200 {
                let now = at(base, step * 200);
                let moved = if step > 100 { moving() } else { still() };
                front.line(&mut publisher, moved, now);
                drive.line(&mut publisher, still(), now);
            }

            let front_line = front.line(&mut publisher, moving(), at(base, 40_000));
            let drive_line = drive.line(&mut publisher, still(), at(base, 40_000));

            assert_eq!(
                objects(&front_line),
                vec![("person".to_string(), 0.9, "<absent>".to_string())],
                "the moving member is inferring"
            );
            assert_eq!(
                objects(&drive_line),
                vec![("car".to_string(), 0.5, "tracked".to_string())],
                "the still member is gated, seeding its own last detection"
            );
            // Both paid the same 75-sample epoch bypass; what they paid after
            // it is their own scene. The quiet member ran the model twice more
            // in 40 s (the re-verifies at 24.8 s and 34.8 s), the busy one on
            // every sample from the moment it started moving.
            assert_eq!(drive.passes, 77);
            assert_eq!(front.passes, 175);
        }

        #[test]
        fn a_camera_without_an_epoch_costs_a_model_pass_and_emits_nothing() {
            // The publisher declining a line is not the gate skipping one: the
            // policy refuses to gate a camera the host has not started, so the
            // model runs and the line is suppressed where it always was.
            let (_streams, mut publisher) = publisher(&["front"]);
            let mut front = Member::new("front", config(), vec![det("person", 0.9)]);
            let base = Instant::now();

            for step in 0..10 {
                assert!(front
                    .run(&mut publisher, still(), at(base, step * 200))
                    .is_none());
            }
            assert_eq!(front.passes, 10);
        }

        #[test]
        fn a_re_verify_that_finds_fewer_objects_shrinks_the_next_seed() {
            // The two halves of "the seeds are the last real line" composed:
            // the gate deciding when the model runs again, and the publisher
            // replacing what is remembered when it does. A gated camera stops
            // re-reporting an object within `reverify_ms` of the model losing
            // it, and that bound is the whole of what a seed's lifetime is.
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut front =
                Member::new("front", config(), vec![det("person", 0.9), det("car", 0.8)]);
            let base = Instant::now();

            // the first sample of an epoch is inside the bypass, and the
            // re-verify claims the one at 16 s
            front.line(&mut publisher, still(), base);
            front.line(&mut publisher, still(), at(base, 16_000));
            assert_eq!(
                objects(&front.line(&mut publisher, still(), at(base, 16_200))),
                vec![
                    ("person".to_string(), 0.9, "tracked".to_string()),
                    ("car".to_string(), 0.8, "tracked".to_string())
                ],
                "gated, seeding both boxes of the last real line"
            );

            // the car leaves while the camera is gated, so nothing sees it go
            // until the next re-verify — which is due 10 s after the last one
            front.found = vec![det("person", 0.9)];
            assert_eq!(
                objects(&front.line(&mut publisher, still(), at(base, 26_000))),
                vec![("person".to_string(), 0.9, "<absent>".to_string())],
                "the re-verify is a real line and finds one object"
            );
            assert_eq!(
                objects(&front.line(&mut publisher, still(), at(base, 26_200))),
                vec![("person".to_string(), 0.9, "tracked".to_string())],
                "and the seeds shrank with it"
            );
            assert_eq!(front.passes, 3);
        }

        #[test]
        fn a_gated_stretch_re_reports_evidence_and_not_the_track_floors_band() {
            // The two flags composed. Every real line carries the band a track
            // floor opened — that is what the host's low-confidence stage
            // reads — and every *skipped* sample carries the evidence-grade
            // boxes of the last real line and nothing else. A sub-floor box is
            // a thing seen in one frame, not a thing to keep asserting for as
            // long as the gate holds.
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut front = Member::new(
                "front",
                config(),
                vec![det("person", 0.9), sub_floor("car", 0.3)],
            );
            let base = Instant::now();

            // inside the bypass, so this one is inferred and carries both
            assert_eq!(
                objects(&front.line(&mut publisher, still(), base)),
                vec![
                    ("person".to_string(), 0.9, "<absent>".to_string()),
                    ("car".to_string(), 0.3, "<absent>".to_string())
                ],
            );
            // the re-verify at 16 s is another real line, band included…
            assert_eq!(
                objects(&front.line(&mut publisher, still(), at(base, 16_000))).len(),
                2
            );
            // …and the sample after it is the first the gate skips, which is
            // where the band stops being re-reported
            assert_eq!(
                objects(&front.line(&mut publisher, still(), at(base, 16_200))),
                vec![("person".to_string(), 0.9, "tracked".to_string())],
            );
            assert_eq!(front.passes, 2);
        }

        #[test]
        fn an_epoch_change_mid_gate_seeds_nothing_from_before_it() {
            // With the bypass switched off the publisher's clearing is the
            // only thing between a pre-reset box and the wire: the gate skips
            // the first sample of the new epoch, and what that sample carries
            // has to be the empty liveness line rather than a ghost the host
            // would read under an epoch it never saw the object in.
            let no_bypass = Some(MotionConfig {
                enabled: true,
                epoch_bypass_ms: 0,
                ..MotionConfig::default()
            });
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut front = Member::new("front", no_bypass, vec![det("person", 0.9)]);
            let base = Instant::now();

            // a camera that has never inferred always infers, and the sample
            // after it is gated
            front.line(&mut publisher, still(), base);
            let seeded = front.line(&mut publisher, still(), at(base, 200));
            assert_eq!(
                objects(&seeded),
                vec![("person".to_string(), 0.9, "tracked".to_string())]
            );

            // the host restarts the stream
            end(&streams, "front", EPOCH);
            start(&streams, "front", OTHER);

            let line = front.line(&mut publisher, still(), at(base, 400));
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(value["stream_epoch"], OTHER);
            assert!(objects(&line).is_empty(), "nothing survives the cut");
            assert_eq!(front.passes, 1, "the gate skipped it: no bypass to open");
        }

        #[test]
        fn an_inference_error_propagates_and_costs_no_sequence_number() {
            // Both loops turn this `Err` into a fatal thread exit, so the gate
            // state it abandons dies with the process — but the line it never
            // built is a line the host never sees a number for, so the
            // sequence the next one carries is still this camera's first.
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            let mut gate = Gate::default();
            let base = Instant::now();

            let failed = sample_line(
                &mut gate,
                &mut publisher,
                "front",
                config(),
                sample(still()),
                base,
                |_input| Err(anyhow::anyhow!("the model failed")),
            );
            assert!(failed.is_err());

            let line = sample_line(
                &mut gate,
                &mut publisher,
                "front",
                config(),
                sample(still()),
                at(base, 200),
                |_input| Ok(vec![det("person", 0.9)]),
            )
            .expect("the second pass succeeds")
            .objects
            .expect("a started camera emits every sample");
            assert_eq!(sequence(&line), 0);
        }
    }

    /// The gate's own telemetry: the rate it reports and the bound on how
    /// often it reports one. Windows are closed by the sample that reaches
    /// them, so every instant here is the caller's, like the policy's.
    mod telemetry {
        use super::*;

        /// This fixture's cadence: one sample every 200 ms (5 fps). A
        /// fixture choice matching `--sample-fps`'s clap default, not
        /// anything `Telemetry` enforces — it derives `fps` from the
        /// caller's own instants.
        const STEP_MS: u64 = 200;

        /// `samples` samples at [`STEP_MS`] from `base`, each one's fate
        /// decided by `decision`. Returns every report that came back.
        fn drive(
            telemetry: &mut Telemetry,
            base: Instant,
            samples: std::ops::Range<u64>,
            mut decision: impl FnMut(u64) -> Decision,
        ) -> Vec<Report> {
            samples
                .filter_map(|step| {
                    telemetry.observe(decision(step), still(), at(base, step * STEP_MS))
                })
                .collect()
        }

        #[test]
        fn the_reported_rate_is_model_passes_per_second_of_the_window() {
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            // This fixture's 5 fps cadence for 30 s, with the model run on
            // every fourth sample. The window that closes first holds 25
            // samples and 6 model passes, so the effective inference rate is
            // 1.2 against a sample rate of 5.
            let reports = drive(&mut telemetry, base, 0..150, |step| {
                if step.is_multiple_of(4) {
                    Decision::Detect
                } else {
                    Decision::Skip
                }
            });

            let report = reports.first().expect("the first window is a transition");
            assert!(
                (report.fps - 1.2).abs() < 0.01,
                "reported {} fps, expected 1.2",
                report.fps
            );
            assert!(
                report.detail.starts_with("motion gate: gated;"),
                "{}",
                report.detail
            );
            assert!(
                report.detail.contains("of 5.00 sampled"),
                "the sample rate is reported beside the inference rate: {}",
                report.detail
            );
        }

        #[test]
        fn a_gate_that_skips_nothing_reports_the_sample_rate() {
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            let reports = drive(&mut telemetry, base, 0..50, |_| Decision::Detect);

            assert_eq!(reports.len(), 1, "one transition, into detecting");
            assert!(
                (reports[0].fps - 5.0).abs() < 0.05,
                "reported {} fps, expected ~5",
                reports[0].fps
            );
            assert!(
                reports[0].detail.starts_with("motion gate: detecting;"),
                "{}",
                reports[0].detail
            );
        }

        #[test]
        fn a_re_verify_inside_a_gated_stretch_reports_nothing() {
            // The flap this exists to prevent: at the default `reverify_ms` a
            // gated camera runs the model every 10 s, and a report keyed on
            // the *sample's* decision would say "detecting" for each of those
            // and "gated" again right after — a pair of status lines every
            // 10 s, per camera, describing a camera that never left the gate.
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            let reports = drive(&mut telemetry, base, 0..600, |step| {
                if step.is_multiple_of(50) {
                    Decision::Detect
                } else {
                    Decision::Skip
                }
            });

            assert_eq!(reports.len(), 1, "{reports:?}");
            assert!(reports[0].detail.contains("gated"), "{}", reports[0].detail);
        }

        #[test]
        fn a_transition_costs_at_most_one_report_per_window() {
            // The rate limit, driven by the worst case for it: the decision
            // alternating on every sample, 5 times a second for a minute.
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            let reports = drive(&mut telemetry, base, 0..300, |step| {
                if step.is_multiple_of(2) {
                    Decision::Detect
                } else {
                    Decision::Skip
                }
            });

            // Every window holds a skip, so every window is gated and the one
            // report is the first window's transition into it.
            assert_eq!(reports.len(), 1, "{reports:?}");
            // …and 60 s of samples is 12 windows, so even a run that did
            // transition on every one could not have reported more than that.
            assert!(reports.len() <= 12);
        }

        #[test]
        fn the_state_returns_to_detecting_a_window_after_the_gate_opens() {
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            // 20 s gated (re-verifying every 10 s), then the model on every
            // sample: the window that straddles the change still holds the
            // skips before it, so "detecting" is reported by the window after
            // it — 10 s at worst, which is the lag that reading the window
            // rather than the sample buys.
            let reports = drive(&mut telemetry, base, 0..300, |step| {
                if step >= 100 || step.is_multiple_of(50) {
                    Decision::Detect
                } else {
                    Decision::Skip
                }
            });

            let detail: Vec<&str> = reports.iter().map(|r| r.detail.as_str()).collect();
            assert_eq!(detail.len(), 2, "{detail:?}");
            assert!(detail[0].starts_with("motion gate: gated;"), "{detail:?}");
            assert!(
                detail[1].starts_with("motion gate: gated -> detecting;"),
                "{detail:?}"
            );
            // reported at 25 s: the window closing at 20 s still contains the
            // gated samples up to it, and the one closing at 25 s does not
            assert!(
                detail[1].contains("5.00 fps inferred of 5.00 sampled over 5.0 s"),
                "{detail:?}"
            );
        }

        #[test]
        fn the_peak_change_of_the_window_is_what_is_reported() {
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            let fraction = |value: f32| {
                Some(MotionVerdict {
                    changed_fraction: value,
                    motion: false,
                    calibrating: false,
                    scene_cut: false,
                })
            };

            telemetry.observe(Decision::Detect, fraction(0.01), base);
            for step in 1..25 {
                telemetry.observe(Decision::Skip, fraction(0.001), at(base, step * 200));
            }
            let report = telemetry
                .observe(Decision::Skip, fraction(0.004), at(base, 5_000))
                .expect("the window closed on a transition");
            // 0.4 % is the largest fraction since the window opened, and the
            // 1 % on the sample that opened it is not in this window at all
            assert!(
                report.detail.ends_with("peak change 0.40%"),
                "{}",
                report.detail
            );
        }

        #[test]
        fn a_window_with_no_verdict_reports_no_fraction() {
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            telemetry.observe(Decision::Detect, None, base);
            let report = telemetry
                .observe(Decision::Detect, None, at(base, 5_000))
                .expect("the first window is a transition");
            assert!(
                report.detail.ends_with("peak change n/a"),
                "{}",
                report.detail
            );
        }

        #[test]
        fn a_gated_camera_reports_through_the_status_line() {
            // What the wire actually carries, once: the `fps` field the host
            // bounds at 0..10 000 and a `detail` inside its 256-byte cap.
            let (streams, mut publisher) = sample_line::publisher(&["front"]);
            sample_line::start(&streams, "front", EPOCH);
            let mut gate = Gate::default();
            let base = Instant::now();

            let statuses: Vec<String> = (0..150)
                .filter_map(|step| {
                    sample_line(
                        &mut gate,
                        &mut publisher,
                        "front",
                        config(),
                        sample_line::sample(still()),
                        at(base, step * 200),
                        |_input| Ok(vec![]),
                    )
                    .expect("the stand-in detector never fails")
                    .status
                })
                .collect();

            // 30 s: the epoch bypass covers the first 15 s and the gate
            // closes after it, so two transitions reach the wire — into
            // detecting at 5 s, and into gated at the first window that holds
            // a skipped sample.
            assert_eq!(statuses.len(), 2, "{statuses:?}");
            let value: serde_json::Value = serde_json::from_str(&statuses[1]).unwrap();
            assert_eq!(value["type"], "plugin.status");
            assert_eq!(value["camera_id"], "front");
            assert_eq!(value["status"]["state"], REPORT_STATE);
            let fps = value["status"]["fps"].as_f64().expect("a rate is reported");
            // Bounded by this fixture's own 200 ms/step cadence — not by
            // anything `Telemetry` enforces: the inference rate it reports
            // can never exceed the rate samples arrived at, whatever that is.
            let fixture_fps = 1000.0 / STEP_MS as f64;
            assert!((0.0..=fixture_fps).contains(&fps), "{fps}");
            let detail = value["status"]["detail"].as_str().expect("a detail");
            assert!(detail.len() <= 256, "{} bytes: {detail}", detail.len());
        }

        #[test]
        fn a_camera_with_the_gate_off_reports_nothing() {
            let (streams, mut publisher) = sample_line::publisher(&["front"]);
            sample_line::start(&streams, "front", EPOCH);
            let mut gate = Gate::default();
            let base = Instant::now();

            for step in 0..150 {
                assert!(
                    sample_line(
                        &mut gate,
                        &mut publisher,
                        "front",
                        None,
                        sample_line::sample(None),
                        at(base, step * 200),
                        |_input| Ok(vec![]),
                    )
                    .expect("the stand-in detector never fails")
                    .status
                    .is_none(),
                    "sample {step}"
                );
            }
        }

        #[test]
        fn the_rate_is_measured_over_the_window_that_actually_elapsed() {
            // Every other test here closes its windows on an exact 5.000 s
            // boundary, so dividing by the `REPORT_WINDOW` constant instead of
            // the elapsed time would pass all of them. No real window closes
            // nominally — it closes on the first sample *at or past* 5 s, and a
            // soak run read "over 5.2 s" — so the rate has to be per second of
            // the window that happened.
            let mut telemetry = Telemetry::default();
            let base = Instant::now();

            telemetry.observe(Decision::Detect, still(), base);
            for step in 1..25 {
                assert!(
                    telemetry
                        .observe(Decision::Detect, still(), at(base, step * 200))
                        .is_none(),
                    "sample {step} is inside the window"
                );
            }
            // the sample that closes the window arrives late, at 5.6 s: 25
            // counted samples, all inferred, over 5.6 s is 4.46 and not 5
            let report = telemetry
                .observe(Decision::Detect, still(), at(base, 5_600))
                .expect("the first window is a transition");

            assert!(
                (report.fps - 25.0 / 5.6).abs() < 0.01,
                "reported {} fps, expected 4.46",
                report.fps
            );
            assert!(report.detail.contains("over 5.6 s"), "{}", report.detail);
        }

        #[test]
        fn a_window_reports_its_own_peak_not_the_last_windows() {
            // `peak_change` is the only counter whose reset a window's own
            // samples cannot mask: `samples` and `inferences` are compared
            // against each other, but a stale peak simply outlives every
            // smaller fraction that follows it. Dropping the reset would leave
            // a camera reporting the loudest frame it ever saw, forever.
            let mut telemetry = Telemetry::default();
            let base = Instant::now();
            let fraction = |value: f32| {
                Some(MotionVerdict {
                    changed_fraction: value,
                    motion: false,
                    calibrating: false,
                    scene_cut: false,
                })
            };

            // a gated window at 5 % change
            telemetry.observe(Decision::Skip, fraction(0.05), base);
            for step in 1..25 {
                telemetry.observe(Decision::Skip, fraction(0.05), at(base, step * 200));
            }
            let gated = telemetry
                .observe(Decision::Skip, fraction(0.05), at(base, 5_000))
                .expect("the first window is a transition");
            assert!(
                gated.detail.ends_with("peak change 5.00%"),
                "{}",
                gated.detail
            );

            // then a quiet window that infers everything, at 0.4 %
            for step in 26..50 {
                telemetry.observe(Decision::Detect, fraction(0.004), at(base, step * 200));
            }
            let detecting = telemetry
                .observe(Decision::Detect, fraction(0.004), at(base, 10_000))
                .expect("gated -> detecting is a transition");
            assert!(
                detecting.detail.ends_with("peak change 0.40%"),
                "{}",
                detecting.detail
            );
        }
    }
}
