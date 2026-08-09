//! One camera's stream: compressed access units in, observation terms out.
//!
//! `multiplex.rs`'s member without the transport — everything per camera and
//! stateful, and nothing that reads a socket.
//!
//! The tolerated per-frame failures (a decode error mid-GOP, a frame that will
//! not convert) are counted and skipped exactly as `cairn_detect::decode::run`
//! skips them. The rate is where the two paths differ: `run` paces itself on the
//! wall clock, while here `Cairn.Pipeline.Picker` decides which access units
//! arrive at all, and one of them costs at most one model pass.

use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use cairn_detect::decode::{self, Decoder, Sampled};
use cairn_detect::emit::{seeds_from, Det, MAX_PTS};
use cairn_detect::gate::{Decision, Gate};
use cairn_detect::infer::ScoreFloors;
use cairn_detect::motion::MotionConfig;
use cairn_detect::note;
use rsmpeg::avcodec::{AVCodecParameters, AVPacket};
use rsmpeg::avutil::{AVFrame, AVRational};
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
    /// `None` for a camera whose motion gate is off, which makes [`Gate::decide`]
    /// infer on every sample.
    motion: Option<MotionConfig>,
    /// Fixed for the life of the stream, because here a new stream session is a
    /// new [`Stream`]. That is what makes the gate's epoch-bypass window right
    /// without an epoch setter — a fresh `Gate` opens the window on its own first
    /// sample.
    epoch: Option<String>,
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
            engine,
            camera_id,
            decoder,
            gate: Gate::default(),
            floors: params.floors,
            motion: params.motion,
            epoch: params.epoch,
            seeds: Seeds::default(),
            decode_errors: 0,
            tensor_errors: 0,
            unbounded_pts: 0,
        };
        claim.handed_to(&stream);
        Ok(stream)
    }

    /// Feed one access unit and take the one observation it is worth, or none —
    /// the decoder may want more input, and a frame that will not convert costs
    /// its access unit.
    ///
    /// Never more than one, whatever the decoder completed: see
    /// [`sampled_frame`]. The list is the host's shape, not a count.
    ///
    /// `now` dates [`Gate::decide`]'s linger, re-verify and epoch-bypass windows;
    /// nothing here paces on it.
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

        let (frame, drained) = sampled_frame(self.decoder.as_mut());
        if let Some(error) = drained {
            self.note(Tolerated::Decode, &error);
        }
        let Some(frame) = frame else {
            return Ok(Vec::new());
        };
        let observed_at = SystemTime::now();
        let pts = decode::pts_90k(&frame, time_base);

        let Sampled { input, motion } = match self.decoder.to_tensor(frame) {
            Ok(Some(sampled)) => sampled,
            Ok(None) => return Ok(Vec::new()),
            Err(error) => {
                // One access unit, not the stream: sws has no path for a
                // mid-stream format change and a filter graph rebuild can fail
                // transiently.
                self.note(Tolerated::Tensor, &error);
                return Ok(Vec::new());
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
            return Ok(Vec::new());
        }

        Ok(vec![FrameObservations {
            pts,
            observed_at_ms: unix_ms(observed_at),
            inferred,
            objects,
        }])
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
    fn drop(&mut self) {
        self.engine.release(&self.camera_id);
    }
}

/// A camera id claimed in the engine's registry with no [`Stream`] yet holding it.
///
/// The claim is taken before the decoder — a duplicate open is then cheap to
/// refuse — so there is a window where the id is spoken for and [`Stream`]'s
/// `Drop` does not exist yet. Anything leaving that window without releasing
/// refuses this camera as a duplicate for the life of the engine, and returning an
/// error is not the only way out of it: decoder setup can panic, and `guarded`
/// then answers `panicked` with nothing constructed to drop.
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

/// The frame an access unit is sampled at — the first it completed — with the
/// rest of its frames drained and dropped.
///
/// The rate lives upstream in `Cairn.Pipeline.Picker`, which gates *access
/// units*; reordering completes several frames for one of them, and inferring on
/// each would run the model at some multiple of the rate that was asked for. A
/// dropped frame never reaches [`Decoder::to_tensor`], so the motion background
/// never absorbs it either — one access unit stays one sample, which is the unit
/// [`cairn_detect::motion::MotionDetector`]'s calibration window counts in.
///
/// Drained rather than left queued: `avcodec_send_packet` refuses the next packet
/// while output is pending, and both [`Decoder`] implementations swallow that
/// refusal as a lost access unit rather than reporting it.
///
/// The error is returned rather than logged because the count and its rate limit
/// belong to the [`Stream`].
fn sampled_frame(decoder: &mut dyn Decoder) -> (Option<AVFrame>, Option<anyhow::Error>) {
    let mut sampled = None;
    loop {
        match decoder.receive_frame() {
            Ok(Some(frame)) => {
                if sampled.is_none() {
                    sampled = Some(frame);
                }
            }
            Ok(None) => return (sampled, None),
            Err(error) => return (sampled, Some(error)),
        }
    }
}

/// Open this stream's decoder against a bare H.264 stream description.
///
/// There is no container here to take stream parameters from — the caller is
/// Membrane's H.264 parser, which delivers whole access units with SPS and PPS in
/// band — so these parameters carry the codec and nothing else and the decoder
/// learns its geometry from the first SPS. Both decode paths already tolerate a
/// missing declared size.
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

/// One access unit as a packet the decoder can take. The bytes are copied because
/// libavcodec's buffer needs its own padding and its own lifetime; the binary they
/// came from belongs to the calling Elixir process.
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
/// cold-booted SBC) reads as the epoch rather than failing, as `emit::rfc3339_utc`
/// does: a wrong timestamp is visible in the data where a dropped frame is not.
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
    use std::time::Duration;

    /// A decoder that completes a fixed number of frames per packet, which is
    /// what reordering does and no fixture produces on demand. `to_tensor`
    /// counts its calls: it is the only way into a model pass and the only thing
    /// [`cairn_detect::motion::MotionDetector`] updates from, so a frame that
    /// reaches it is a frame the background absorbed.
    #[derive(Default)]
    struct Burst {
        per_packet: usize,
        pending: usize,
        tensors: usize,
        fail_after: Option<usize>,
    }

    impl Decoder for Burst {
        fn send_packet(&mut self, _packet: &AVPacket) -> anyhow::Result<()> {
            self.pending = self.per_packet;
            Ok(())
        }

        fn receive_frame(&mut self) -> anyhow::Result<Option<AVFrame>> {
            if self.fail_after == Some(self.per_packet - self.pending) {
                anyhow::bail!("the decoder gave up mid-burst");
            }
            if self.pending == 0 {
                return Ok(None);
            }
            self.pending -= 1;
            let mut frame = AVFrame::new();
            // Which one came back is the whole question, so they are numbered.
            frame.set_pts((self.per_packet - self.pending) as i64);
            Ok(Some(frame))
        }

        fn to_tensor(&mut self, _frame: AVFrame) -> anyhow::Result<Option<Sampled>> {
            self.tensors += 1;
            Ok(None)
        }
    }

    fn burst(per_packet: usize) -> Burst {
        Burst {
            per_packet,
            ..Burst::default()
        }
    }

    #[test]
    fn one_access_unit_is_sampled_at_its_first_frame_and_the_rest_are_dropped() {
        let mut decoder = burst(3);
        decoder
            .send_packet(&packet_from(&[1, 2, 3], 0).unwrap())
            .unwrap();

        let (frame, error) = sampled_frame(&mut decoder);
        assert_eq!(frame.expect("three frames and none returned").pts, 1);
        assert!(error.is_none());
        // …and nothing is left queued, which is what lets the next packet in
        assert_eq!(decoder.pending, 0);

        // the dropped frames never became tensors, so the motion background
        // absorbed one frame for this access unit and not three
        assert_eq!(decoder.tensors, 0, "`sampled_frame` converted nothing");
    }

    #[test]
    fn a_burst_that_fails_mid_drain_still_yields_the_frame_it_had() {
        let mut decoder = Burst {
            per_packet: 3,
            fail_after: Some(2),
            ..Burst::default()
        };
        decoder
            .send_packet(&packet_from(&[1, 2, 3], 0).unwrap())
            .unwrap();

        let (frame, error) = sampled_frame(&mut decoder);
        assert_eq!(frame.expect("the first frame was already in hand").pts, 1);
        assert!(error.is_some(), "the tolerated error was swallowed");

        // …and a failure before any frame is the empty answer, not a lost one
        let mut decoder = Burst {
            per_packet: 3,
            fail_after: Some(0),
            ..Burst::default()
        };
        decoder.send_packet(&packet_from(&[1], 0).unwrap()).unwrap();
        let (frame, error) = sampled_frame(&mut decoder);
        assert!(frame.is_none());
        assert!(error.is_some());
    }

    #[test]
    fn a_packet_that_completed_nothing_is_the_empty_answer() {
        let mut decoder = burst(0);
        decoder.send_packet(&packet_from(&[1], 0).unwrap()).unwrap();

        let (frame, error) = sampled_frame(&mut decoder);
        assert!(frame.is_none());
        assert!(error.is_none());
    }

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

    /// [`Stream`] needs a model and a decoder to build, so the seed memory is
    /// driven directly.
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
