//! Decode → sample → tensor.
//!
//! [`Decoder`] is the hardware/software seam: `receive_frame` hands back
//! whatever the decoder produced (a system-memory frame from software or
//! v4l2m2m, a GPU surface from VAAPI/QSV/NVDEC) and `to_tensor` is only ever
//! called on the frames that survive the 5 fps sample gate. Everything
//! expensive — scale, pixel-format convert, and for the hardware paths the
//! download out of GPU memory — happens there, so a hardware decoder never
//! pays for the ~55 fps of frames it is about to discard.

use std::fmt;
use std::slice;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clap::ValueEnum;
use crossbeam_channel::{Sender, TrySendError};
use rsmpeg::avcodec::{AVCodec, AVCodecContext, AVCodecParameters};
use rsmpeg::avformat::AVFormatContextInput;
use rsmpeg::avutil::{av_rescale_q, AVFrame, AVRational};
use rsmpeg::error::RsmpegError;
use rsmpeg::ffi;
use rsmpeg::swscale::SwsContext;
use rsmpeg::UnsafeDerefMut;

use crate::hwdecode::{HwBackend, HwDecoder};
use crate::infer::INPUT_SIZE;

pub const SAMPLE_FPS: u32 = 5;

/// The RTP clock the contract emits `pts` in.
const PTS_TIMEBASE: AVRational = AVRational {
    num: 1,
    den: 90_000,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DecoderKind {
    Auto,
    Vaapi,
    Qsv,
    Nvdec,
    V4l2,
    Videotoolbox,
    Sw,
}

/// Renders as the flag value the user typed, not the Rust variant name.
impl fmt::Display for DecoderKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(
            self.to_possible_value()
                .expect("no DecoderKind variant is skipped")
                .get_name(),
        )
    }
}

pub struct Sample {
    pub pts_90k: i64,
    /// CHW RGB f32 in 0..1, `3 * INPUT_SIZE * INPUT_SIZE` long.
    pub tensor: Vec<f32>,
}

/// Where [`run`] hands sampled frames to inference.
///
/// Never blocks: stalling the decode loop stalls the socket read, and at
/// camera bitrates the kernel receive buffer overflows inside that window —
/// which corrupts the stream rather than merely dropping a sample. A busy
/// consumer therefore costs a sample, and which one is the implementation's
/// choice (a plain channel keeps the pending one; a group's slot replaces
/// it).
pub trait SampleSink {
    /// `Ok(true)` when the sample reached the consumer, `Ok(false)` when a
    /// sample was skipped because the consumer is still busy, `Err` when the
    /// consumer is gone.
    fn offer(&self, sample: Sample) -> Result<bool>;
}

/// The single-camera handoff: one pending sample, newer ones skipped.
impl SampleSink for Sender<Sample> {
    fn offer(&self, sample: Sample) -> Result<bool> {
        match self.try_send(sample) {
            Ok(()) => Ok(true),
            Err(TrySendError::Full(_)) => Ok(false),
            Err(TrySendError::Disconnected(_)) => bail!("inference thread is gone"),
        }
    }
}

pub trait Decoder: Send {
    fn send_packet(&mut self, packet: &rsmpeg::avcodec::AVPacket) -> Result<()>;

    /// Next decoded frame, or `None` when the decoder wants more input.
    fn receive_frame(&mut self) -> Result<Option<AVFrame>>;

    /// Scale and convert a sampled frame into the model input tensor.
    ///
    /// Takes ownership because the hardware path feeds the frame straight
    /// into a filter graph, which consumes it. `Ok(None)` means "no tensor
    /// for this frame, try the next one" — a filter graph that has not
    /// produced output yet is not an error.
    fn to_tensor(&mut self, frame: AVFrame) -> Result<Option<Vec<f32>>>;
}

/// Cap on decoded frame size, applied to every codec context.
///
/// Cairn's ffmpeg is `-c:v copy`, so this plugin is the first thing in the
/// system that actually decodes camera bitstream: without a cap, an SPS
/// declaring 16384x16384 gets buffers allocated to match. 8K (33.2 MP) fits
/// under this; anything larger fails inside libavcodec (which logs the
/// dimensions it rejected) and lands in the tolerated decode-error path
/// instead of the allocator.
const MAX_PIXELS: i64 = 32 * 1024 * 1024;

/// Open a decoder for `codecpar`, probing hardware before software.
///
/// Probing happens once at startup. A backend that cannot open — no device,
/// no driver, no GPU scaler — is logged and skipped; software decode is
/// always the last resort, including when `--decoder <hw>` names a backend
/// explicitly. Crash-looping on a box without the hardware would be worse
/// than running slowly on it.
pub fn open(kind: DecoderKind, codecpar: &AVCodecParameters) -> Result<Box<dyn Decoder>> {
    let order = probe_order(kind);
    if order.is_empty() && kind != DecoderKind::Sw && kind != DecoderKind::Auto {
        eprintln!("decoder {kind} is not available on this platform");
    }
    for backend in order {
        match HwDecoder::open(backend, codecpar) {
            Ok(decoder) => return Ok(Box::new(decoder)),
            Err(e) => eprintln!("hardware decoder {backend} unavailable: {e:#}"),
        }
    }
    if kind != DecoderKind::Sw {
        eprintln!("no hardware decoder opened; falling back to software decode");
    }
    Ok(Box::new(SwDecoder::open(codecpar)?))
}

/// Backends to try, in order, for a given `--decoder` value.
///
/// `auto` is ordered by how much of the pipeline the backend takes over on
/// its typical host: VAAPI and QSV are the primary x86 targets, NVDEC covers
/// Nvidia, v4l2m2m covers SBCs (and decodes on the ASIC but hands back
/// system memory). A named backend probes only itself.
pub fn probe_order(kind: DecoderKind) -> Vec<HwBackend> {
    match kind {
        DecoderKind::Sw => Vec::new(),
        DecoderKind::Auto => AUTO_ORDER.to_vec(),
        DecoderKind::Vaapi => vec![HwBackend::Vaapi],
        DecoderKind::Qsv => vec![HwBackend::Qsv],
        DecoderKind::Nvdec => vec![HwBackend::Nvdec],
        DecoderKind::V4l2 => vec![HwBackend::V4l2],
        #[cfg(target_os = "macos")]
        DecoderKind::Videotoolbox => vec![HwBackend::Videotoolbox],
        #[cfg(not(target_os = "macos"))]
        DecoderKind::Videotoolbox => Vec::new(),
    }
}

#[cfg(target_os = "macos")]
const AUTO_ORDER: &[HwBackend] = &[HwBackend::Videotoolbox];
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
const AUTO_ORDER: &[HwBackend] = &[
    HwBackend::Vaapi,
    HwBackend::Qsv,
    HwBackend::Nvdec,
    HwBackend::V4l2,
];
// SBCs: no VAAPI/QSV, and an Nvidia GPU on one is exotic enough to name.
#[cfg(all(target_os = "linux", not(target_arch = "x86_64")))]
const AUTO_ORDER: &[HwBackend] = &[HwBackend::V4l2];
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const AUTO_ORDER: &[HwBackend] = &[];

/// Scale-and-convert into the model's 640x640 RGB input.
///
/// Shared by both paths: the hardware path scales on the GPU and downloads
/// NV12 at 640x640, then lands here for the NV12 -> RGB24 conversion.
pub struct Rgb640 {
    /// Rebuilt if the input ever changes geometry or pixel format mid-run.
    sws: Option<(SwsContext, (i32, i32, i32))>,
    rgb: AVFrame,
}

impl Rgb640 {
    pub fn new() -> Result<Self> {
        let mut rgb = AVFrame::new();
        rgb.set_width(INPUT_SIZE as i32);
        rgb.set_height(INPUT_SIZE as i32);
        rgb.set_format(ffi::AV_PIX_FMT_RGB24);
        rgb.alloc_buffer()
            .context("allocating the RGB scale target")?;
        Ok(Self { sws: None, rgb })
    }

    fn ensure_scaler(&mut self, frame: &AVFrame) -> Result<()> {
        let key = (frame.width, frame.height, frame.format);
        if self.sws.as_ref().map(|(_, k)| *k) != Some(key) {
            // Letterbox-free stretch: bboxes are normalized, so only ratios
            // matter and the model sees the whole frame either way.
            let sws = SwsContext::get_context(
                frame.width,
                frame.height,
                frame.format,
                INPUT_SIZE as i32,
                INPUT_SIZE as i32,
                ffi::AV_PIX_FMT_RGB24,
                ffi::SWS_BILINEAR,
                None,
                None,
                None,
            )
            .ok_or_else(|| {
                anyhow!(
                    "no scaler for {}x{} pixel format {}",
                    frame.width,
                    frame.height,
                    frame.format
                )
            })?;
            self.sws = Some((sws, key));
        }
        Ok(())
    }

    pub fn tensor_from(&mut self, frame: &AVFrame) -> Result<Vec<f32>> {
        let height = frame.height;
        self.ensure_scaler(frame)?;
        let (scaler, _) = self.sws.as_mut().expect("scaler was just set");
        scaler
            .scale_frame(frame, 0, height, &mut self.rgb)
            .context("scaling to the model input size")?;

        let stride = self.rgb.linesize[0] as usize;
        // SAFETY: `self.rgb` is our own `alloc_buffer`'d RGB24 frame of
        // INPUT_SIZE x INPUT_SIZE, so data[0] is non-null and the allocation
        // covers linesize[0] * height bytes. Both invariants break if
        // `Rgb640::new` ever stops allocating the frame it describes.
        let plane =
            unsafe { slice::from_raw_parts(self.rgb.data[0] as *const u8, stride * INPUT_SIZE) };
        Ok(rgb_to_chw(plane, stride))
    }
}

struct SwDecoder {
    ctx: AVCodecContext,
    rgb: Rgb640,
}

impl SwDecoder {
    fn open(codecpar: &AVCodecParameters) -> Result<Self> {
        let codec = AVCodec::find_decoder(codecpar.codec_id)
            .ok_or_else(|| anyhow!("no decoder for codec id {}", codecpar.codec_id))?;
        let mut ctx = AVCodecContext::new(&codec);
        ctx.apply_codecpar(codecpar)
            .context("applying stream parameters to the decoder")?;
        cap_frame_size(&mut ctx);
        ctx.open(None).context("opening the decoder")?;

        eprintln!("decoder: software ({})", codec.name().to_string_lossy());
        Ok(Self {
            ctx,
            rgb: Rgb640::new()?,
        })
    }
}

impl Decoder for SwDecoder {
    fn send_packet(&mut self, packet: &rsmpeg::avcodec::AVPacket) -> Result<()> {
        match self.ctx.send_packet(Some(packet)) {
            Ok(()) => Ok(()),
            // Only reachable if the caller stops draining; treat as a lost
            // packet rather than a fatal error.
            Err(RsmpegError::DecoderFullError) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    fn receive_frame(&mut self) -> Result<Option<AVFrame>> {
        match self.ctx.receive_frame() {
            Ok(frame) => Ok(Some(frame)),
            Err(RsmpegError::DecoderDrainError | RsmpegError::DecoderFlushedError) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn to_tensor(&mut self, frame: AVFrame) -> Result<Option<Vec<f32>>> {
        self.rgb.tensor_from(&frame).map(Some)
    }
}

/// Bound what a stream's SPS can make libavcodec allocate.
pub fn cap_frame_size(ctx: &mut AVCodecContext) {
    unsafe { ctx.deref_mut() }.max_pixels = MAX_PIXELS;
}

/// Packed RGB24 rows (`stride` may exceed the row width) -> CHW f32 in 0..1.
fn rgb_to_chw(plane: &[u8], stride: usize) -> Vec<f32> {
    let plane_len = INPUT_SIZE * INPUT_SIZE;
    let mut tensor = vec![0f32; 3 * plane_len];
    for y in 0..INPUT_SIZE {
        let row = &plane[y * stride..y * stride + INPUT_SIZE * 3];
        for x in 0..INPUT_SIZE {
            let px = &row[x * 3..x * 3 + 3];
            tensor[y * INPUT_SIZE + x] = f32::from(px[0]) / 255.0;
            tensor[plane_len + y * INPUT_SIZE + x] = f32::from(px[1]) / 255.0;
            tensor[2 * plane_len + y * INPUT_SIZE + x] = f32::from(px[2]) / 255.0;
        }
    }
    tensor
}

/// Read packets forever, handing sampled frames to the inference thread.
///
/// Returns only on error or end of stream — both are fatal for the process,
/// which is what Cairn's restart-with-backoff expects.
pub fn run(
    input: &mut AVFormatContextInput,
    stream_index: usize,
    time_base: AVRational,
    decoder: &mut dyn Decoder,
    sink: &dyn SampleSink,
) -> Result<()> {
    let interval = Duration::from_secs_f64(1.0 / f64::from(SAMPLE_FPS));
    // Wall-clock sampling, not PTS sampling: the point is to cap how often we
    // run the model, and a stream that arrives in bursts would otherwise fire
    // several samples at once.
    let mut last_sample: Option<Instant> = None;
    let mut dropped: u64 = 0;
    let mut decode_errors: u64 = 0;
    let mut tensor_errors: u64 = 0;

    loop {
        let Some(packet) = input.read_packet().context("reading rtp packet")? else {
            bail!("rtp stream ended");
        };
        if packet.stream_index as usize != stream_index {
            continue;
        }
        if let Err(e) = decoder.send_packet(&packet) {
            // Joining mid-GOP means feeding the decoder frames whose
            // references never arrived; it resyncs on the next keyframe.
            note_error(&mut decode_errors, "decode", &e);
            continue;
        }

        loop {
            let frame = match decoder.receive_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(e) => {
                    note_error(&mut decode_errors, "decode", &e);
                    break;
                }
            };

            let now = Instant::now();
            if last_sample.is_some_and(|last| now.duration_since(last) < interval) {
                continue;
            }
            last_sample = Some(now);

            let pts_90k = pts_90k(&frame, time_base);
            // A frame we cannot convert costs one sample, not the process:
            // sws has no path for a mid-stream format change, a filter graph
            // rebuild can fail transiently, and restarting is expensive (model
            // load plus up to a minute of open retries).
            let tensor = match decoder.to_tensor(frame) {
                Ok(Some(tensor)) => tensor,
                Ok(None) => continue,
                Err(e) => {
                    note_error(&mut tensor_errors, "sample conversion", &e);
                    continue;
                }
            };
            if !sink.offer(Sample { pts_90k, tensor })? {
                dropped += 1;
                if dropped.is_multiple_of(50) {
                    eprintln!("inference behind: {dropped} samples skipped so far");
                }
            }
        }
    }
}

/// Count a tolerated error, logging the first and every 50th.
fn note_error(count: &mut u64, what: &str, e: &impl fmt::Display) {
    *count += 1;
    if *count % 50 == 1 {
        eprintln!("{what} error ({count} so far): {e}");
    }
}

fn pts_90k(frame: &AVFrame, time_base: AVRational) -> i64 {
    let pts = if frame.pts != ffi::AV_NOPTS_VALUE {
        frame.pts
    } else if frame.best_effort_timestamp != ffi::AV_NOPTS_VALUE {
        frame.best_effort_timestamp
    } else {
        return 0;
    };
    // The RTP demuxer already ticks at 90 kHz, but the rescale keeps this
    // correct for any other time base (e.g. a file fixture).
    av_rescale_q(pts, time_base, PTS_TIMEBASE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rescales_pts_to_90khz() {
        let mut frame = AVFrame::new();
        frame.set_pts(1000);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 1000);
        assert_eq!(pts_90k(&frame, AVRational { num: 1, den: 1000 }), 90_000);
    }

    #[test]
    fn sw_probes_nothing() {
        assert!(probe_order(DecoderKind::Sw).is_empty());
    }

    #[test]
    fn a_named_backend_probes_only_itself() {
        assert_eq!(probe_order(DecoderKind::Vaapi), vec![HwBackend::Vaapi]);
        assert_eq!(probe_order(DecoderKind::Nvdec), vec![HwBackend::Nvdec]);
        assert_eq!(probe_order(DecoderKind::V4l2), vec![HwBackend::V4l2]);
    }

    #[test]
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    fn auto_prefers_vaapi_then_qsv_then_nvdec_then_v4l2() {
        assert_eq!(
            probe_order(DecoderKind::Auto),
            vec![
                HwBackend::Vaapi,
                HwBackend::Qsv,
                HwBackend::Nvdec,
                HwBackend::V4l2
            ]
        );
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn videotoolbox_is_empty_off_macos() {
        // Falls through to the software decoder instead of failing the run.
        assert!(probe_order(DecoderKind::Videotoolbox).is_empty());
    }

    #[test]
    fn decoders_cap_the_frame_size() {
        use rsmpeg::UnsafeDerefMut;

        let mut codecpar = AVCodecParameters::new();
        unsafe {
            let raw = codecpar.deref_mut();
            raw.codec_id = ffi::AV_CODEC_ID_H264;
            raw.codec_type = ffi::AVMEDIA_TYPE_VIDEO;
            raw.width = 1920;
            raw.height = 1080;
        }
        let decoder = SwDecoder::open(&codecpar).unwrap();
        assert_eq!(decoder.ctx.max_pixels, MAX_PIXELS);
        // Generous enough for 8K, small enough that a 16384x16384 SPS fails.
        const { assert!(MAX_PIXELS > 7680 * 4320) };
        const { assert!(MAX_PIXELS < 16384 * 16384) };
    }

    #[test]
    fn packs_rgb_rows_into_planes() {
        // One padded row of red, green, blue pixels; the rest stays black.
        let stride = INPUT_SIZE * 3 + 16;
        let mut plane = vec![0u8; stride * INPUT_SIZE];
        plane[0..9].copy_from_slice(&[255, 0, 0, 0, 255, 0, 0, 0, 255]);

        let tensor = rgb_to_chw(&plane, stride);
        let plane_len = INPUT_SIZE * INPUT_SIZE;
        assert_eq!(tensor.len(), 3 * plane_len);
        assert_eq!(tensor[0], 1.0);
        assert_eq!(tensor[plane_len + 1], 1.0);
        assert_eq!(tensor[2 * plane_len + 2], 1.0);
        assert_eq!(tensor[1], 0.0);
        assert!(tensor.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    #[test]
    fn missing_pts_is_zero() {
        let mut frame = AVFrame::new();
        frame.set_pts(ffi::AV_NOPTS_VALUE);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 0);
    }
}
