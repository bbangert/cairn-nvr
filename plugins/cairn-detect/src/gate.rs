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
//! own.
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
use crate::emit::{Det, Publisher};
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
/// on it, and which epoch its lines are being stamped with.
#[derive(Debug, Default)]
pub struct Gate {
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

/// One sample, from verdict to protocol line: the gate's decision, the model
/// pass it does or does not authorize, and the line either way.
///
/// Both modes call this and nothing else. What differs between them is which
/// camera's `gate` and `config` a sample belongs to — single mode has one of
/// each, group mode holds them by slot — never what is done with the sample,
/// which is the whole of the duplication the two inference loops carry.
///
/// `Ok(None)` is the publisher declining the line (this camera has no epoch, or
/// the `pts` is outside the contract's range); it is not the gate skipping one.
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
) -> Result<Option<String>> {
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
    Ok(
        match gate.decide(config, sample.motion, epoch.as_deref(), now) {
            Decision::Detect => {
                let dets = infer(sample.input)?;
                publisher.line_for(camera_id, sample.pts_90k, sample.observed_at, &dets)
            }
            Decision::Skip => {
                publisher.seeded_line_for(camera_id, sample.pts_90k, sample.observed_at)
            }
        },
    )
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
        // the whole linger window past that motion, sampled at 5 fps: still
        // inferring, so nothing here refreshes the re-verify's meaning
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
        // 75 samples is the whole 15 s window at 5 fps, the last of them at
        // 16 800 ms.
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
        // A still scene sampled at 5 fps for a minute. Every sample is gated
        // except the ones the re-verify claims, and those land every
        // `reverify_ms` — measured from the last inference, so they do not
        // drift with the sample cadence.
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
        // under ten seconds of them at 5 fps, the last one a sample short of
        // the re-verify.
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

        fn publisher(camera_ids: &[&str]) -> (Arc<Streams>, Publisher) {
            let streams = Arc::new(Streams::new(camera_ids.iter().copied()));
            (Arc::clone(&streams), Publisher::new(streams))
        }

        fn start(streams: &Streams, camera_id: &str, epoch: &str) {
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
        fn sample(verdict: Option<MotionVerdict>) -> Sample {
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

            // motion, then a still scene sampled at 5 fps for 30 s: every
            // sample emits a line, and the model runs only while the policy
            // says it should
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
            .expect("a started camera emits every sample");
            assert_eq!(sequence(&line), 0);
        }
    }
}
