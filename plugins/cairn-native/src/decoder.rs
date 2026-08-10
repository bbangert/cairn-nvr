//! One camera's decode stream: compressed access units in, content-rect RGB
//! frames out — the decode half of the split boundary whose inference half
//! is the `cairn-ort` crate's stream.
//!
//! What crosses between them is `cairn_detect::decode::RgbSampled` spelled as
//! a term: exact u8 pixels plus the geometry to rebuild the fit from, so the
//! tensor packed on the far side (`model_input_from_rgb`) is the one the
//! unsplit path would have packed. The rate gate does *not* live here — the
//! caller passes `sample` per access unit and owns the wall clock
//! (`Cairn.Pipeline.SampleGate`) — but every access unit is decoded whatever
//! `sample` says, because a stateful decoder needs its references.
//!
//! The tolerated per-frame failures (a decode error mid-GOP, a frame that
//! will not convert) are counted and skipped exactly as the unsplit path
//! skipped them.

use std::time::{SystemTime, UNIX_EPOCH};

use cairn_detect::decode::{self, Decoder, RgbSampled};
use cairn_detect::infer::InputSpec;
use cairn_detect::motion::MotionVerdict;
use cairn_detect::note;
use rsmpeg::avcodec::{AVCodecParameters, AVPacket};
use rsmpeg::avutil::AVFrame;
use rsmpeg::ffi;
use rsmpeg::UnsafeDerefMut;

use crate::config::DecoderParams;
use crate::error::{chain, NativeError, Result};

/// How often a tolerated per-frame error is logged: the first, then every
/// fiftieth, as in `cairn_detect::decode::run`.
const LOG_EVERY: u64 = 50;

/// How many `receive_frame` calls one drain may make. Reordering completes a
/// handful of frames per access unit, so the bound is never reached in practice —
/// it is there because the drain keeps going past an error, and a decoder stuck
/// answering `Err` would otherwise spin a dirty scheduler thread forever, which in
/// this VM costs more than a lost access unit.
const MAX_DRAIN: usize = 64;

/// What one access unit produced, term-shaped.
///
/// `completed` says whether the decoder finished a frame for this access unit
/// at all — the caller's rate gate spends its interval on that, not on
/// `frame`, so a sample whose conversion failed (or that the hardware path's
/// filter graph held back) still spends it, exactly as the unsplit path set
/// `last_sample` before `to_tensor`.
pub struct Decoded {
    pub completed: bool,
    pub frame: Option<DecodedFrame>,
}

/// One sampled frame on its way across the boundary. The payload convention
/// (D-C2) is `Cairn.Pipeline.Decoder`'s to document; this is just its data.
pub struct DecodedFrame {
    /// Tightly packed RGB24 rows, `width * 3 * height` bytes: the content
    /// rectangle, not the padded model rect.
    pub rgb: Vec<u8>,
    pub width: usize,
    pub height: usize,
    /// The geometry the camera sent — on the hardware path the GPU has
    /// already scaled, so this is not the payload's.
    pub orig_width: usize,
    pub orig_height: usize,
    /// The frame's own timestamp in the caller's time base (reordering means
    /// it is not always the access unit's), or `None` when the decoder had
    /// none to offer — dated `0` on the 90 kHz clock, as the unsplit path did.
    pub pts: Option<i64>,
    /// Wall clock at the moment this frame cleared the sample gate — the
    /// contract's `observed_at`, captured decode-side because a frame can
    /// wait behind a busy model pass on its way to inference.
    pub observed_at_ms: i64,
    /// Content pixels per source pixel, per axis: the two differ, because
    /// each scaled side is floored to an even pixel count independently.
    pub scale_x: f64,
    pub scale_y: f64,
    /// What the model rect adds around the content: on the right and bottom
    /// only (the content sits top-left, YOLOX's own convention).
    pub pad_w: usize,
    pub pad_h: usize,
    pub motion: Option<MotionVerdict>,
}

pub struct DecodeStream {
    camera_id: String,
    decoder: Box<dyn Decoder>,
    /// The engine's resolved input spec, copied at open: what `pad_w`/`pad_h`
    /// are measured against, and the spec the consumer will rebuild the fit
    /// from.
    spec: InputSpec,
    decode_errors: u64,
    convert_errors: u64,
}

impl DecodeStream {
    /// Open one camera's decoder for the input spec an engine resolved.
    ///
    /// The spec arrives as terms rather than as the engine itself: the engine
    /// lives in another NIF library (`cairn-ort`), and no resource can cross
    /// between two. No camera-id claim either — the registry guards the
    /// *inference* stream, which is where duplicate detection has to be
    /// refused; two decoders for one camera would only waste work.
    pub fn open(camera_id: String, params: DecoderParams) -> Result<Self> {
        quiet_libav();
        let decoder = open_decoder(&params)?;
        Ok(Self {
            camera_id,
            decoder,
            spec: params.spec,
            decode_errors: 0,
            convert_errors: 0,
        })
    }

    /// Feed one access unit; convert and hand over its frame only when
    /// `sample` says this call cleared the caller's rate gate.
    ///
    /// Never more than one frame, whatever the decoder completed: see
    /// [`sampled_frame`]. A frame the gate skips is skipped by the motion
    /// detector too — it never reaches the background.
    pub fn push_au(&mut self, au: &[u8], pts: i64, sample: bool) -> Result<Decoded> {
        let packet = packet_from(au, pts)?;
        if let Err(error) = self.decoder.send_packet(&packet) {
            // Joining mid-GOP means feeding the decoder frames whose
            // references never arrived; it resyncs on the next keyframe.
            self.note(Tolerated::Decode, &error);
            return Ok(none(false));
        }

        let (frame, drained) = sampled_frame(self.decoder.as_mut());
        if let Some(error) = drained {
            self.note(Tolerated::Decode, &error);
        }
        let Some(frame) = frame else {
            return Ok(none(false));
        };
        if !sample {
            return Ok(none(true));
        }
        let observed_at = SystemTime::now();
        let pts = decode::frame_pts(&frame);

        let sampled = match self.decoder.to_rgb(frame) {
            Ok(Some(sampled)) => sampled,
            Ok(None) => return Ok(none(true)),
            Err(error) => {
                // One access unit, not the stream: sws has no path for a
                // mid-stream format change and a filter graph rebuild can fail
                // transiently.
                self.note(Tolerated::Convert, &error);
                return Ok(none(true));
            }
        };

        Ok(Decoded {
            completed: true,
            frame: Some(self.frame_from(sampled, pts, observed_at)),
        })
    }

    fn frame_from(
        &self,
        sampled: RgbSampled,
        pts: Option<i64>,
        observed_at: SystemTime,
    ) -> DecodedFrame {
        let RgbSampled {
            rgb,
            content,
            source,
            motion,
        } = sampled;
        DecodedFrame {
            rgb,
            width: content.w,
            height: content.h,
            orig_width: source.w,
            orig_height: source.h,
            pts,
            observed_at_ms: unix_ms(observed_at),
            scale_x: content.w as f64 / source.w as f64,
            scale_y: content.h as f64 / source.h as f64,
            pad_w: self.spec.size.w - content.w,
            pad_h: self.spec.size.h - content.h,
            motion,
        }
    }

    /// The tolerated-error counters, `(decode, sample conversion)`.
    #[cfg(test)]
    pub fn tolerated(&self) -> (u64, u64) {
        (self.decode_errors, self.convert_errors)
    }

    fn note(&mut self, what: Tolerated, error: &anyhow::Error) {
        let count = match what {
            Tolerated::Decode => &mut self.decode_errors,
            Tolerated::Convert => &mut self.convert_errors,
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

fn none(completed: bool) -> Decoded {
    Decoded {
        completed,
        frame: None,
    }
}

#[derive(Clone, Copy)]
enum Tolerated {
    Decode,
    Convert,
}

impl Tolerated {
    fn name(self) -> &'static str {
        match self {
            Self::Decode => "decode",
            Self::Convert => "sample conversion",
        }
    }
}

/// Whether the `count`-th tolerated anomaly is one of the logged ones: the
/// first, then every fiftieth, as in `cairn_detect::decode::run`.
fn should_log(count: u64) -> bool {
    count % LOG_EVERY == 1
}

/// The frame an access unit is sampled at — the first it completed — with the
/// rest of its frames drained and dropped.
///
/// Reordering completes several frames for one access unit, and the caller's rate
/// gate is one decision per call, so only the first is kept. A dropped frame never
/// reaches [`Decoder::to_rgb`], so the motion background never absorbs it either
/// — one access unit stays at most one sample, which is the unit
/// [`cairn_detect::motion::MotionDetector`]'s calibration window counts in.
///
/// Drained rather than left queued, and the drain continues past a tolerated error:
/// `avcodec_send_packet` refuses the next packet while output is pending, and
/// `SwDecoder` and `HwDecoder` both swallow that refusal as a lost access unit
/// rather than reporting it — a hole in the decoder's input that nobody declares,
/// which the host's Picker cannot know to wait out an IDR for.
///
/// The error is returned rather than logged because the count and its rate limit
/// belong to the [`DecodeStream`].
fn sampled_frame(decoder: &mut dyn Decoder) -> (Option<AVFrame>, Option<anyhow::Error>) {
    let mut sampled = None;
    let mut first_error = None;
    for _ in 0..MAX_DRAIN {
        match decoder.receive_frame() {
            Ok(Some(frame)) => {
                if sampled.is_none() {
                    sampled = Some(frame);
                }
            }
            Ok(None) => break,
            Err(error) => {
                first_error.get_or_insert(error);
            }
        }
    }
    (sampled, first_error)
}

/// Open this stream's decoder against a bare H.264 stream description.
///
/// There is no container here to take stream parameters from — the caller is
/// Membrane's H.264 parser, which delivers whole access units with SPS and PPS in
/// band — so these parameters carry the codec and nothing else and the decoder
/// learns its geometry from the first SPS. Both decode paths already tolerate a
/// missing declared size.
fn open_decoder(params: &DecoderParams) -> Result<Box<dyn Decoder>> {
    #[cfg(test)]
    panic_if_armed_for_open();
    let mut codecpar = AVCodecParameters::new();
    // SAFETY: `codecpar` is our own freshly allocated parameters struct, and
    // both fields are plain enums with no ownership.
    unsafe {
        let raw = codecpar.deref_mut();
        raw.codec_id = ffi::AV_CODEC_ID_H264;
        raw.codec_type = ffi::AVMEDIA_TYPE_VIDEO;
    }
    decode::open(
        params.kind,
        &codecpar,
        params.spec,
        params.motion,
        params.sample_fps,
    )
    .map_err(|e| NativeError::OpenStream(chain(&e)))
}

/// Panic inside the *next* decoder open, where a driver actually can. The
/// hook lives here now that no engine exists on this side to carry it.
#[cfg(test)]
pub(crate) fn panic_in_the_next_open() {
    OPEN_PANIC.store(true, std::sync::atomic::Ordering::SeqCst);
}

#[cfg(test)]
static OPEN_PANIC: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
fn panic_if_armed_for_open() {
    if OPEN_PANIC.swap(false, std::sync::atomic::Ordering::SeqCst) {
        panic!("the decoder exploded while opening");
    }
}

/// Stop libav writing the BEAM's stderr for us.
///
/// A camera joining mid-GOP or any flaky RTSP source emits two `AV_LOG_ERROR`
/// lines *per malformed access unit* (`No start code is found.` / `Error
/// splitting the input into NAL units.`), at frame rate, per camera — and in-VM
/// that is the node's log. Nothing is lost: those are the tolerated errors
/// [`DecodeStream::note`] already counts and rate-limits. `AV_LOG_FATAL` and
/// `AV_LOG_PANIC` still print.
///
/// A level rather than an `av_log_set_callback`: routing the text through
/// [`note!`] means reformatting a `va_list`, whose bindgen type differs between
/// x86_64 and the aarch64 board.
///
/// Once per VM, not per decoder: the setting is a libav global.
fn quiet_libav() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    // SAFETY: `av_log_set_level` stores an int in a libav global. Serialized by
    // `Once` against itself; libav reads it unsynchronized either way, and an
    // int is what every one of its own callers writes there too.
    ONCE.call_once(|| unsafe {
        ffi::av_log_set_level(ffi::AV_LOG_FATAL as i32);
    });
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
    use cairn_detect::decode::Sampled;
    use std::time::Duration;

    /// A decoder that completes a fixed number of frames per packet, which is
    /// what reordering does and no fixture produces on demand. `to_rgb`
    /// counts its calls: it is the only way onto the boundary and the only thing
    /// [`cairn_detect::motion::MotionDetector`] updates from, so a frame that
    /// reaches it is a frame the background absorbed.
    #[derive(Default)]
    struct Burst {
        per_packet: usize,
        pending: usize,
        conversions: usize,
        /// Which frame of the burst `receive_frame` fails on, counted from zero.
        fail_after: Option<usize>,
        /// Whether that failure is transient: a sticky one is what the drain's
        /// bound exists for, a transient one is what it keeps draining past.
        fail_once: bool,
        calls: usize,
    }

    impl Decoder for Burst {
        fn send_packet(&mut self, _packet: &AVPacket) -> anyhow::Result<()> {
            self.pending = self.per_packet;
            Ok(())
        }

        fn receive_frame(&mut self) -> anyhow::Result<Option<AVFrame>> {
            self.calls += 1;
            if self.fail_after == Some(self.per_packet.saturating_sub(self.pending)) {
                if self.fail_once {
                    self.fail_after = None;
                }
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
            unreachable!("the decode stream converts through to_rgb");
        }

        fn to_rgb(&mut self, _frame: AVFrame) -> anyhow::Result<Option<RgbSampled>> {
            self.conversions += 1;
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

        // the dropped frames were never converted, so the motion background
        // absorbed one frame for this access unit and not three
        assert_eq!(decoder.conversions, 0, "`sampled_frame` converted nothing");
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

    /// The invariant [`sampled_frame`]'s doc rests on: an error must not leave
    /// frames queued, because `avcodec_send_packet` then refuses the next access
    /// unit and both production decoders swallow that refusal silently.
    #[test]
    fn the_drain_continues_past_a_tolerated_error_and_leaves_nothing_queued() {
        let mut decoder = Burst {
            per_packet: 3,
            fail_after: Some(1),
            fail_once: true,
            ..Burst::default()
        };
        decoder
            .send_packet(&packet_from(&[1, 2, 3], 0).unwrap())
            .unwrap();

        let (frame, error) = sampled_frame(&mut decoder);
        assert_eq!(frame.expect("the first frame came before the error").pts, 1);
        assert!(error.is_some(), "the tolerated error was swallowed");
        assert_eq!(
            decoder.pending, 0,
            "frames left queued, so the next access unit is refused and lost"
        );
    }

    #[test]
    fn a_decoder_stuck_on_an_error_bounds_the_drain_instead_of_spinning() {
        let mut decoder = Burst {
            per_packet: 1,
            fail_after: Some(0),
            ..Burst::default()
        };
        decoder.send_packet(&packet_from(&[1], 0).unwrap()).unwrap();

        let (frame, error) = sampled_frame(&mut decoder);
        assert!(frame.is_none());
        assert!(error.is_some());
        assert_eq!(decoder.calls, MAX_DRAIN);
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
}
