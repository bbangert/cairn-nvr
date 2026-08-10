//! One camera's inference stream: sampled content-rect RGB frames in,
//! observation terms out — the inference half of the boundary
//! [`crate::decoder`] is the decode half of.
//!
//! The tensor is packed here, from the exact bytes the decode side scaled
//! (`cairn_detect::decode::model_input_from_rgb`), so the split changes no
//! number. The detection gate ([`Gate`]) lives here too: its verdicts arrive
//! on the frame, measured where the pixels were, and what to *do* about them
//! is decided where the model is.
//!
//! Calls block the caller on a dirty scheduler, ~12 ms per inference. The one
//! shared session is the only admission control and there is none here: past
//! what it can pass, surplus becomes `push_frame` latency for the host to
//! refuse.

use std::sync::Arc;
use std::time::Instant;

use cairn_detect::decode;
use cairn_detect::emit::{seeds_from, Det, MAX_PTS};
use cairn_detect::gate::{Decision, Gate};
use cairn_detect::infer::{InputSize, ScoreFloors};
use cairn_detect::motion::{MotionConfig, MotionVerdict};
use cairn_detect::note;

use crate::config::StreamParams;
use crate::engine::Engine;
use crate::error::{chain, NativeError, Result};
use crate::observation::FrameObservations;

/// How often the out-of-bounds pts drop is logged: the first, then every
/// fiftieth, as in `cairn_detect::decode::run`.
const LOG_EVERY: u64 = 50;

/// One sampled frame as the boundary carries it, resolved from the term shape.
///
/// Geometry travels with the pixels because the projection is rebuilt from it:
/// `orig` is what the *camera* sent, which on the hardware decode path is not
/// the payload's own size.
pub struct Frame<'a> {
    /// Tightly packed RGB24 rows, `content.w * 3 * content.h` bytes.
    pub rgb: &'a [u8],
    pub content: InputSize,
    pub orig: InputSize,
    /// The frame's timestamp in `time_base`, or `None` for a frame the
    /// decoder could not date — spelled `0` on the 90 kHz clock, as the
    /// unsplit path spelled it.
    pub pts: Option<i64>,
    pub time_base: (i32, i32),
    /// Wall clock at the moment the frame cleared the sample gate, captured
    /// decode-side: a frame can wait behind a busy model pass on its way here.
    pub observed_at_ms: i64,
    pub motion: Option<MotionVerdict>,
}

pub struct Stream {
    engine: Arc<Engine>,
    camera_id: String,
    gate: Gate,
    floors: ScoreFloors,
    /// `None` for a camera whose motion gate is off, which makes [`Gate::decide`]
    /// infer on every sample. Resolved from the same `motion_json` the decode
    /// stream measures under, so the windows judge the verdicts they were
    /// configured with.
    motion: Option<MotionConfig>,
    /// Fixed for the life of the stream, because here a new stream session is a
    /// new [`Stream`]. That is what makes the gate's epoch-bypass window right
    /// without an epoch setter — a fresh `Gate` opens the window on its own first
    /// sample.
    epoch: Option<String>,
    seeds: Seeds,
    unbounded_pts: u64,
}

impl Stream {
    pub fn open(engine: Arc<Engine>, camera_id: String, params: StreamParams) -> Result<Self> {
        let claim = Claim::take(&engine, &camera_id)?;
        let stream = Self {
            engine,
            camera_id,
            gate: Gate::default(),
            floors: params.floors,
            motion: params.motion,
            epoch: params.epoch,
            seeds: Seeds::default(),
            unbounded_pts: 0,
        };
        claim.handed_to(&stream);
        Ok(stream)
    }

    /// Take one sampled frame through the detection gate and, when it says so,
    /// the model — one observation either way, because a gated frame still
    /// re-reports the last pass's evidence.
    ///
    /// `now` dates [`Gate::decide`]'s linger, re-verify and epoch-bypass
    /// windows — one instant for the whole call, read after the stream lock,
    /// so a caller that queued behind another push does not age the windows by
    /// however long it waited.
    pub fn push_frame(&mut self, frame: Frame<'_>, now: Instant) -> Result<Vec<FrameObservations>> {
        let time_base = crate::decoder::rational(frame.time_base)?;
        let input = decode::model_input_from_rgb(
            frame.rgb,
            frame.content,
            frame.orig,
            self.engine.input_spec,
        )
        // Not a tolerated per-frame skip: the geometry disagreeing with the
        // engine's own spec means the producer resized for a different model,
        // and every later frame would be wrong the same way.
        .map_err(|e| NativeError::Infer(chain(&e)))?;

        let pts = match frame.pts {
            Some(pts) => decode::rescale_90k(pts, time_base),
            None => 0,
        };

        let decision = self
            .gate
            .decide(self.motion, frame.motion, self.epoch.as_deref(), now);
        let (objects, inferred, infer_us) = match decision {
            Decision::Detect => {
                // Started before the call, not after the model lock is taken:
                // under saturation the wait on the engine's model mutex is
                // exactly what a caller reading this as latency needs to see.
                let started = Instant::now();
                let dets = self.engine.detect(input, &self.floors)?;
                let infer_us = started.elapsed().as_micros() as i64;
                self.seeds.remember(&dets);
                (dets, true, infer_us)
            }
            // Re-report the last real pass, so a parked object the gate
            // stopped inferring on does not age out of the host's tracker
            // while it is still standing there.
            Decision::Skip => (self.seeds.replay(), false, 0),
        };

        // The same bound the ndjson path refuses a line for: a `pts` this far
        // out means the rescale saturated, so it is not a timestamp.
        if !(-MAX_PTS..=MAX_PTS).contains(&pts) {
            self.unbounded_pts += 1;
            if self.unbounded_pts % LOG_EVERY == 1 {
                note!(
                    "camera {}: pts {pts} is outside +-2^62, {} frame(s) dropped so far",
                    self.camera_id,
                    self.unbounded_pts
                );
            }
            return Ok(Vec::new());
        }

        Ok(vec![FrameObservations {
            pts,
            observed_at_ms: frame.observed_at_ms,
            inferred,
            infer_us,
            objects,
        }])
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        self.engine.release(&self.camera_id);
    }
}

/// A [`Frame`] over what a decode stream just produced — the test path from
/// one half of the boundary to the other without a term in between.
#[cfg(test)]
pub fn frame_from<'a>(
    sampled: &'a crate::decoder::DecodedFrame,
    time_base: (i32, i32),
) -> Frame<'a> {
    Frame {
        rgb: &sampled.rgb,
        content: InputSize {
            w: sampled.width,
            h: sampled.height,
        },
        orig: InputSize {
            w: sampled.orig_width,
            h: sampled.orig_height,
        },
        pts: sampled.pts,
        time_base,
        observed_at_ms: sampled.observed_at_ms,
        motion: sampled.motion,
    }
}

/// A camera id claimed in the engine's registry with no [`Stream`] yet holding it.
///
/// The claim is taken before the stream is assembled — a duplicate open is then
/// cheap to refuse — so there is a window where the id is spoken for and
/// [`Stream`]'s `Drop` does not exist yet. Anything leaving that window without
/// releasing refuses this camera as a duplicate for the life of the engine, and
/// returning an error is not the only way out of it: an open can panic, and
/// `guarded` then answers `panicked` with nothing constructed to drop.
struct Claim {
    engine: Arc<Engine>,
    camera_id: String,
    armed: bool,
}

impl Claim {
    /// Armed after the claim and never before: a refusal means *another* stream
    /// holds that id, and releasing on the way out would hand a live camera's
    /// claim back.
    fn take(engine: &Arc<Engine>, camera_id: &str) -> Result<Self> {
        let mut claim = Self {
            engine: Arc::clone(engine),
            camera_id: camera_id.to_string(),
            armed: false,
        };
        claim.engine.register(&claim.camera_id)?;
        claim.armed = true;
        Ok(claim)
    }

    /// The claim is now `stream`'s, whose `Drop` releases it. Takes the `&Stream`
    /// so that an early disarm is unwriteable: there has to be something to hand
    /// it to.
    fn handed_to(mut self, _stream: &Stream) {
        self.armed = false;
    }
}

impl Drop for Claim {
    fn drop(&mut self) {
        if self.armed {
            self.engine.release(&self.camera_id);
        }
    }
}

/// What this stream's next gated frame will re-report.
///
/// The rule is [`cairn_detect::emit::seeds_from`], shared with the ndjson path.
/// What that path adds and this one does not is remembering only the prefix of
/// the list that reached the wire: there is no line to shed from here, and
/// `infer`'s own cap (`MAX_DETS`, 32) is under the contract's per-line object cap
/// ([`cairn_detect::emit::MAX_OBJECTS`], 64) anyway.
#[derive(Default)]
struct Seeds(Vec<Det>);

impl Seeds {
    /// Replace the memory with this pass's seeds. A pass that found nothing empties
    /// it, which is what stops a departed object from being re-reported past the
    /// re-verify that lost it.
    fn remember(&mut self, dets: &[Det]) {
        self.0 = seeds_from(dets);
    }

    fn replay(&self) -> Vec<Det> {
        self.0.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [`Stream`] needs a model to build, so the seed memory is driven directly.
    mod seeds {
        use super::*;
        use cairn_detect::control::{Control, Streams};
        use cairn_detect::emit::{ObservationKind, Publisher};
        use std::time::SystemTime;

        const EPOCH: &str = "01K1B2C3D4E5F6G7H8J9K0M1N2";

        fn det(label: &str, score: f64) -> Det {
            Det {
                label: label.to_string(),
                score,
                bbox: [0.1, 0.2, 0.3, 0.4],
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
            }
        }

        /// A detection `--track-floor-json` admitted below its label's
        /// `min_score`, and so not a sighting to repeat.
        fn sub_floor(label: &str, score: f64) -> Det {
            Det {
                evidence: false,
                ..det(label, score)
            }
        }

        /// One model pass, feature and band both.
        fn pass() -> Vec<Det> {
            let mut with_feature = det("person", 0.87);
            with_feature.embedding = Some("QUJD".to_string());
            vec![with_feature, sub_floor("car", 0.3), det("person", 0.25)]
        }

        #[test]
        fn a_gated_frame_re_reports_the_last_passs_evidence_alone() {
            let mut seeds = Seeds::default();
            assert!(seeds.replay().is_empty(), "nothing seeds before a pass");

            seeds.remember(&pass());
            let replayed = seeds.replay();
            assert_eq!(
                replayed.iter().map(|det| det.score).collect::<Vec<_>>(),
                vec![0.87, 0.25],
                "the band box is not a sighting to re-report"
            );
            assert!(replayed
                .iter()
                .all(|det| det.observation_kind == ObservationKind::Tracked));
            assert!(
                replayed.iter().all(|det| det.embedding.is_none()),
                "a seed re-reports a position, not an appearance"
            );
            // replaying is not consuming: the gate skips many frames per pass
            assert_eq!(seeds.replay(), replayed);
        }

        #[test]
        fn every_pass_replaces_what_is_seeded() {
            let mut seeds = Seeds::default();
            seeds.remember(&pass());
            assert_eq!(seeds.replay().len(), 2);

            // the re-verify that loses an object shrinks the seeds by itself:
            // the memory is the last pass, not a high-water mark
            seeds.remember(&[det("person", 0.5)]);
            assert_eq!(seeds.replay().len(), 1);
            assert_eq!(seeds.replay()[0].score, 0.5);

            // …and a pass with nothing but band on it seeds nothing at all
            seeds.remember(&[sub_floor("car", 0.3)]);
            assert!(seeds.replay().is_empty());
        }

        #[test]
        fn the_two_paths_seed_the_same_boxes_from_the_same_detections() {
            // What the ndjson path puts on the wire has to be what this path
            // holds in hand.
            let found = pass();
            let mut seeds = Seeds::default();
            seeds.remember(&found);

            let streams = Arc::new(Streams::new(["front"]));
            streams.apply(Control::Started {
                camera_id: "front".to_string(),
                stream_epoch: EPOCH.to_string(),
            });
            let mut publisher = Publisher::new(Arc::clone(&streams));
            publisher
                .line_for("front", 900, SystemTime::UNIX_EPOCH, &found)
                .expect("a started camera emits its inferred line");
            let seeded = publisher
                .seeded_line_for("front", 1_800, SystemTime::UNIX_EPOCH)
                .expect("…and its gated one");

            let line: serde_json::Value =
                serde_json::from_str(&seeded).expect("the plugin emits valid json");
            assert_eq!(
                line["objects"],
                serde_json::to_value(seeds.replay()).expect("a seed serializes"),
                "the two producers disagree about what a gated frame carries"
            );
            // …and not by both being empty, which would agree about nothing
            assert_eq!(line["objects"].as_array().map(Vec::len), Some(2));
        }
    }
}
