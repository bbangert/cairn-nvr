//! One camera's stream: compressed access units in, observation terms out.
//!
//! `multiplex.rs`'s member re-hosted, keeping everything per camera and stateful
//! — the decoder and its motion background, the [`Gate`], the score floors, and
//! what a gated frame re-reports — and dropping the transport, because the caller
//! is an Elixir process handing over one access unit at a time.
//!
//! **Nothing on this path may panic**, so every per-frame failure is a value: the
//! tolerated ones (a decode error mid-GOP, a frame that will not convert) are
//! counted and skipped exactly as `cairn_detect::decode::run` skips them, and the
//! fatal ones are returned. All of those cost this stream alone except
//! [`NativeError::ModelPoisoned`], which is the shared session's.

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cairn_detect::decode::{self, Decoder, Sampled};
use cairn_detect::emit::{seeds_from, Det, MAX_PTS};
use cairn_detect::gate::{Decision, Gate};
use cairn_detect::infer::ScoreFloors;
use cairn_detect::motion::MotionConfig;
use cairn_detect::note;
use rsmpeg::avcodec::{AVCodecParameters, AVPacket};
use rsmpeg::avutil::AVRational;
use rsmpeg::ffi;
use rsmpeg::UnsafeDerefMut;

use crate::config::StreamParams;
use crate::engine::Engine;
use crate::error::{chain, NativeError, Result};
use crate::observation::FrameObservations;

/// How often a tolerated per-frame error is logged: the first, then every
/// fiftieth, as in `cairn_detect::decode::run`.
const LOG_EVERY: u64 = 50;

pub struct Stream {
    engine: Arc<Engine>,
    camera_id: String,
    decoder: Box<dyn Decoder>,
    gate: Gate,
    floors: ScoreFloors,
    /// `None` for a camera whose motion gate is off, which is the default and
    /// makes [`Gate::decide`] infer on every sample.
    motion: Option<MotionConfig>,
    /// Fixed for the life of the stream: an epoch identifies one stream session,
    /// and here a new session is a new [`Stream`]. That is what makes the gate's
    /// epoch-bypass window right without an epoch setter — a fresh `Gate` opens
    /// the window on its own first sample.
    epoch: Option<String>,
    interval: Duration,
    last_sample: Option<Instant>,
    seeds: Seeds,
    decode_errors: u64,
    tensor_errors: u64,
    unbounded_pts: u64,
}

impl Stream {
    pub fn open(engine: Arc<Engine>, camera_id: String, params: StreamParams) -> Result<Self> {
        let claim = Claim::take(&engine, &camera_id)?;
        let decoder = open_decoder(&engine, params.motion)?;

        let stream = Self {
            interval: decode::sample_interval(engine.sample_fps),
            engine,
            camera_id,
            decoder,
            gate: Gate::default(),
            floors: params.floors,
            motion: params.motion,
            epoch: params.epoch,
            last_sample: None,
            seeds: Seeds::default(),
            decode_errors: 0,
            tensor_errors: 0,
            unbounded_pts: 0,
        };
        // Not one line earlier: between the two there is nothing but moves.
        claim.handed_to(&stream);
        Ok(stream)
    }

    /// Feed one access unit and take whatever frames it completed.
    ///
    /// Usually one, but an access unit can complete none (the decoder wants more
    /// input, or the sample gate is not due) and, with reordering, more than one —
    /// so the caller must not assume a frame per push.
    ///
    /// `now` is taken once for the whole call rather than per decoded frame as
    /// `decode::run` does. The two agree because an access unit is one picture;
    /// the difference shows only in a decoder emitting a burst, where sharing an
    /// instant yields one sample instead of one per frame — which is what the rate
    /// limit is for anyway.
    pub fn push_au(
        &mut self,
        au: &[u8],
        pts: i64,
        time_base: (i32, i32),
        now: Instant,
    ) -> Result<Vec<FrameObservations>> {
        let time_base = rational(time_base)?;
        let packet = packet_from(au, pts)?;
        if let Err(error) = self.decoder.send_packet(&packet) {
            // Joining mid-GOP means feeding the decoder frames whose
            // references never arrived; it resyncs on the next keyframe.
            self.note(Tolerated::Decode, &error);
            return Ok(Vec::new());
        }

        let mut frames = Vec::new();
        loop {
            let frame = match self.decoder.receive_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(error) => {
                    self.note(Tolerated::Decode, &error);
                    break;
                }
            };
            if self
                .last_sample
                .is_some_and(|last| now.duration_since(last) < self.interval)
            {
                continue;
            }
            self.last_sample = Some(now);
            let observed_at = SystemTime::now();
            let pts = decode::pts_90k(&frame, time_base);

            let Sampled { input, motion } = match self.decoder.to_tensor(frame) {
                Ok(Some(sampled)) => sampled,
                Ok(None) => continue,
                Err(error) => {
                    // One sample, not the stream: sws has no path for a
                    // mid-stream format change and a filter graph rebuild can
                    // fail transiently.
                    self.note(Tolerated::Tensor, &error);
                    continue;
                }
            };

            let decision = self
                .gate
                .decide(self.motion, motion, self.epoch.as_deref(), now);
            let (objects, inferred) = match decision {
                Decision::Detect => {
                    let dets = self.engine.detect(input, &self.floors)?;
                    self.seeds.remember(&dets);
                    (dets, true)
                }
                // Re-report the last real pass, so a parked object the gate
                // stopped inferring on does not age out of the host's tracker
                // while it is still standing there.
                Decision::Skip => (self.seeds.replay(), false),
            };

            // The same bound the ndjson path refuses a line for: a `pts` this far
            // out means the rescale saturated, so it is not a timestamp.
            if !(-MAX_PTS..=MAX_PTS).contains(&pts) {
                self.unbounded_pts += 1;
                if should_log(self.unbounded_pts) {
                    note!(
                        "camera {}: pts {pts} is outside +-2^62, {} frame(s) dropped so far",
                        self.camera_id,
                        self.unbounded_pts
                    );
                }
                continue;
            }

            frames.push(FrameObservations {
                pts,
                observed_at_ms: unix_ms(observed_at),
                inferred,
                objects,
            });
        }
        Ok(frames)
    }

    /// The tolerated-error counters, `(decode, sample conversion)`.
    #[cfg(test)]
    pub fn tolerated(&self) -> (u64, u64) {
        (self.decode_errors, self.tensor_errors)
    }

    fn note(&mut self, what: Tolerated, error: &anyhow::Error) {
        let count = match what {
            Tolerated::Decode => &mut self.decode_errors,
            Tolerated::Tensor => &mut self.tensor_errors,
        };
        *count += 1;
        if should_log(*count) {
            note!(
                "camera {}: {} error ({count} so far): {}",
                self.camera_id,
                what.name(),
                chain(error)
            );
        }
    }
}

impl Drop for Stream {
    /// Hands the camera id back whether the host called `close_stream` or the
    /// BEAM simply collected the handle.
    fn drop(&mut self) {
        self.engine.release(&self.camera_id);
    }
}

/// A camera id claimed in the engine's registry with no [`Stream`] yet holding it.
///
/// The claim is taken before the decoder, because that is what makes a duplicate
/// open cheap to refuse — so there is a window where the id is spoken for and
/// [`Stream`]'s `Drop`, which normally hands it back, does not exist yet. A failed
/// open has to release it or that camera is refused as a duplicate for the life of
/// the engine, and *returning* an error is not the only way out of that window:
/// in-VM, decoder setup can panic, and the NIF's `catch_unwind` then answers
/// `panicked` with nothing constructed to drop. This releases on either.
///
/// It owns its copies of both rather than borrowing the caller's, so the
/// disarming can come after the `Stream` has consumed them — which is what makes
/// the guarded window cover the whole construction and not merely most of it.
struct Claim {
    engine: Arc<Engine>,
    camera_id: String,
    armed: bool,
}

impl Claim {
    /// Claim `camera_id`, or refuse. Armed after the claim and never before: a
    /// refusal means *another* stream holds that id, and releasing on the way
    /// out would hand a live camera's claim back.
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

    /// The claim is now `stream`'s, whose `Drop` releases it.
    ///
    /// Takes the stream it was handed to so that disarming is impossible to
    /// write before there is something to hand it to.
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
/// The rule for turning a model pass into seeds is
/// [`cairn_detect::emit::seeds_from`], shared with the ndjson path so the two
/// cannot drift apart. All this adds is the feed, which is the one place the two
/// deliberately differ: the ndjson path remembers only the prefix of the list that
/// reached the wire, and there is no equivalent here because there is no line to
/// shed from — `infer`'s own cap (`MAX_DETS`, 32) is under the contract's per-line
/// object cap ([`cairn_detect::emit::MAX_OBJECTS`], 64).
#[derive(Default)]
struct Seeds(Vec<Det>);

impl Seeds {
    /// Replace the memory with this pass's seeds. A pass that found nothing empties
    /// it, which is what stops a departed object from being re-reported past the
    /// re-verify that lost it.
    fn remember(&mut self, dets: &[Det]) {
        self.0 = seeds_from(dets);
    }

    /// The seeds for one gated frame, cloned because the memory outlives any
    /// number of them.
    fn replay(&self) -> Vec<Det> {
        self.0.clone()
    }
}

#[derive(Clone, Copy)]
enum Tolerated {
    Decode,
    Tensor,
}

impl Tolerated {
    fn name(self) -> &'static str {
        match self {
            Self::Decode => "decode",
            Self::Tensor => "sample conversion",
        }
    }
}

fn should_log(count: u64) -> bool {
    count % LOG_EVERY == 1
}

/// Open this stream's decoder against a bare H.264 stream description.
///
/// There is no container here to take stream parameters from — the caller is
/// Membrane's H.264 parser, which delivers whole access units with SPS and PPS in
/// band. So the codec parameters carry the codec and nothing else, and the decoder
/// learns its geometry from the first SPS it sees; both decode paths tolerate a
/// missing declared size already.
fn open_decoder(engine: &Engine, motion: Option<MotionConfig>) -> Result<Box<dyn Decoder>> {
    #[cfg(test)]
    engine.panic_if_armed_for_open();
    let mut codecpar = AVCodecParameters::new();
    // SAFETY: `codecpar` is our own freshly allocated parameters struct, and
    // both fields are plain enums with no ownership.
    unsafe {
        let raw = codecpar.deref_mut();
        raw.codec_id = ffi::AV_CODEC_ID_H264;
        raw.codec_type = ffi::AVMEDIA_TYPE_VIDEO;
    }
    decode::open(
        engine.decoder,
        &codecpar,
        engine.input_spec,
        motion,
        engine.sample_fps,
    )
    .map_err(|e| NativeError::OpenStream(chain(&e)))
}

/// One access unit as a packet the decoder can take.
///
/// The bytes are copied because libavcodec's buffer needs its own padding and its
/// own lifetime; the binary this came from belongs to the calling Elixir process
/// and may be gone the moment the NIF returns.
fn packet_from(au: &[u8], pts: i64) -> Result<AVPacket> {
    if au.is_empty() {
        return Err(NativeError::Decode("empty access unit".to_string()));
    }
    let size = i32::try_from(au.len())
        .map_err(|_| NativeError::Decode(format!("access unit of {} bytes", au.len())))?;

    let mut packet = AVPacket::new();
    // SAFETY: `av_new_packet` allocates `size` bytes plus libavcodec's own
    // padding and sets `data`/`size`, so the copy below stays inside the
    // allocation. A negative return means it allocated nothing, which is why
    // the copy is on the success path only.
    unsafe {
        let raw = packet.as_mut_ptr();
        let allocated = ffi::av_new_packet(raw, size);
        if allocated < 0 {
            return Err(NativeError::Decode(format!(
                "allocating a {size}-byte packet failed ({allocated})"
            )));
        }
        std::ptr::copy_nonoverlapping(au.as_ptr(), (*raw).data, au.len());
    }
    packet.set_pts(pts);
    packet.set_dts(pts);
    Ok(packet)
}

/// The caller's time base, refused rather than trusted: `av_rescale_q` divides by
/// the denominator and reads the sign of both, so a zero or negative term is not a
/// slightly wrong timestamp but an arithmetic fault inside libavutil.
fn rational((num, den): (i32, i32)) -> Result<AVRational> {
    if num <= 0 || den <= 0 {
        return Err(NativeError::Decode(format!(
            "time base {num}/{den} must be positive"
        )));
    }
    Ok(AVRational { num, den })
}

/// Milliseconds since the Unix epoch. A clock before the epoch (an unset RTC on a
/// cold-booted SBC) reads as the epoch rather than failing: a wrong timestamp is
/// visible in the data where a dropped frame is not. `emit::rfc3339_utc` does the
/// same.
fn unix_ms(at: SystemTime) -> i64 {
    i64::try_from(
        at.duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_time_base_that_would_fault_the_rescale_is_refused() {
        for bad in [(0, 90_000), (1, 0), (-1, 90_000), (1, -90_000)] {
            let error = rational(bad).unwrap_err();
            assert_eq!(error.reason(), "decode", "{bad:?}");
        }
        let ok = rational((1, 90_000)).unwrap();
        assert_eq!((ok.num, ok.den), (1, 90_000));
    }

    #[test]
    fn an_empty_access_unit_is_an_error_and_not_a_packet() {
        assert_eq!(packet_from(&[], 0).unwrap_err().reason(), "decode");
    }

    #[test]
    fn a_packet_carries_the_bytes_and_the_pts() {
        let au = [0u8, 0, 0, 1, 0x67, 0x42];
        let mut packet = packet_from(&au, 4_500).unwrap();
        assert_eq!(packet.pts, 4_500);
        assert_eq!(packet.dts, 4_500);
        assert_eq!(packet.size as usize, au.len());
        // SAFETY: `packet_from` returned, so `data` covers `size` bytes.
        let data = unsafe { std::slice::from_raw_parts(packet.as_mut_ptr().read().data, au.len()) };
        assert_eq!(data, au);
    }

    #[test]
    fn the_error_log_fires_on_the_first_and_every_fiftieth() {
        assert!(should_log(1));
        assert!(!should_log(2));
        assert!(should_log(LOG_EVERY + 1));
        assert!(!should_log(LOG_EVERY));
    }

    #[test]
    fn a_clock_before_the_epoch_reads_as_the_epoch() {
        assert_eq!(unix_ms(UNIX_EPOCH), 0);
        assert_eq!(unix_ms(UNIX_EPOCH - Duration::from_secs(60)), 0);
        assert_eq!(unix_ms(UNIX_EPOCH + Duration::from_millis(1_500)), 1_500);
    }

    /// [`Stream`] itself needs a model and a decoder to build, so the seed memory
    /// is driven directly — it is the whole of what a `Decision::Skip` consults.
    mod seeds {
        use super::*;
        use cairn_detect::control::{Control, Streams};
        use cairn_detect::emit::{ObservationKind, Publisher};

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

        /// A detection `--track-floor-json` admitted: on the wire at its real score,
        /// below its label's `min_score`, and not a sighting to repeat.
        fn sub_floor(label: &str, score: f64) -> Det {
            Det {
                evidence: false,
                ..det(label, score)
            }
        }

        /// One model pass as `push_au` hands it over, feature and band both.
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
            // replaying is not consuming: the gate skips many frames per pass and
            // each one owes the host the same boxes
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
            // The ndjson path is driven through a real publisher — a started
            // stream, one inferred line, then a seeded one — and what it puts on
            // the wire has to be what this path holds in hand.
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
