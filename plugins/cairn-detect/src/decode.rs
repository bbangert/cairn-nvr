//! Decode → sample → tensor.
//!
//! [`Decoder`] is the hardware/software seam: `receive_frame` hands back
//! whatever the decoder produced (a system-memory frame from software or
//! v4l2m2m, a GPU surface from VAAPI/QSV/NVDEC) and `to_tensor` is only ever
//! called on the frames that survive the sample gate — `--sample-fps` frames
//! a second, 5 by default. Everything expensive — scale, pixel-format
//! convert, and for the hardware paths the download out of GPU memory —
//! happens there, so a hardware decoder never pays for the frames between
//! samples that it is about to discard, which at the default rate on a
//! ~60 fps camera is most of them.
//!
//! One thing that happens there is *not* about feeding the model: when the
//! motion gate is configured, [`RgbScaler::tensor_from`] also downsamples the
//! scaled frame to a [`crate::motion::GrayThumb`] and compares it against that
//! camera's background. That is deliberate cheap work at this layer — one pass
//! over the content rect, into a few-thousand-pixel thumbnail, on a frame
//! already in system memory, next to the megapixel scale immediately above it —
//! and it is here because this is the only place in the process holding
//! pixels. What it measures is carried out on [`Sample`], and
//! what to *do* about it is decided on the inference thread.

use std::fmt;
use std::slice;
use std::time::{Duration, Instant, SystemTime};

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
use crate::infer::{Fit, InputSize, InputSpec, Projection};
use crate::motion::{GrayThumb, MotionConfig, MotionDetector, MotionVerdict};
use crate::note;

/// The clap default for `--sample-fps`, and nothing more: the decode
/// thread's actual sample rate is whatever `--sample-fps` resolved to, which
/// is this value only when the flag was not given. Nothing in this crate may
/// treat it as the operative rate — thread the resolved `u32` instead.
pub const DEFAULT_SAMPLE_FPS: u32 = 5;

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
    /// Wall clock at the moment this frame cleared the sample gate — the
    /// contract's `observed_at`. Captured here rather than at emit time
    /// because a sample can wait behind a busy model pass, and the host uses
    /// this to place the frame on its timeline, not to measure our latency.
    pub observed_at: SystemTime,
    /// How much of the picture differs from this camera's rolling-average
    /// background — not from the previous sample — or `None` when the motion
    /// gate is not configured for it.
    ///
    /// Measured on the decode thread because that is where the pixels are;
    /// carried here because the inference thread is the only place that knows
    /// which camera a sample came from, which is where [`crate::gate`] reads
    /// it and decides whether this sample is worth a model pass.
    pub motion: Option<MotionVerdict>,
    pub input: ModelInput,
}

/// Everything one sampled frame produced, on its way to a [`Sample`].
///
/// A pair rather than a third field on [`ModelInput`]: that type's two halves
/// are two halves of a single decision (see its doc), while the motion verdict
/// is an independent measurement that merely shares the frame they were
/// derived from.
pub struct Sampled {
    pub input: ModelInput,
    /// `None` when the motion gate is not configured for this camera.
    pub motion: Option<MotionVerdict>,
}

/// Everything one sampled frame produced on the decode side of the split NIF
/// boundary: the content-rect RGB24 image, its geometry, and the motion
/// measured from it. What [`Sampled`] is to the in-process pipeline, this is
/// to a seam frames cross as terms — the tensor is packed on the far side by
/// [`model_input_from_rgb`], from these exact bytes, so the split costs no
/// precision.
pub struct RgbSampled {
    /// Tightly packed RGB24 rows (stride is exactly `content.w * 3`).
    pub rgb: Vec<u8>,
    /// The content rectangle ([`Fit`]'s `inner`) — what `rgb` is sized as,
    /// not the model rect: letterbox padding is the consumer's to add.
    pub content: InputSize,
    /// The geometry the camera sent, which on the hardware path is not
    /// `content`'s: the GPU scaled before this value existed.
    pub source: InputSize,
    /// `None` when the motion gate is not configured for this camera.
    pub motion: Option<MotionVerdict>,
}

/// One frame as the model takes it, plus the way back out.
///
/// The two travel together because they are two halves of the same decision:
/// how this frame was fitted into the input rectangle is what says where the
/// model's output boxes were in the original picture. Splitting them is how a
/// letterboxed run silently reports every box against the wrong geometry.
#[derive(Debug)]
pub struct ModelInput {
    /// CHW f32, `3 * w * h` long for the resolved model input, in whichever
    /// `TensorEncoding` the detector asked for.
    ///
    pub tensor: Vec<f32>,
    /// Model-space boxes back to this frame's own normalized coordinates.
    pub projection: Projection,
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

    /// Scale and convert a sampled frame into the model input tensor, and
    /// measure its motion on the way when the gate is configured.
    ///
    /// Takes ownership because the hardware path feeds the frame straight
    /// into a filter graph, which consumes it. `Ok(None)` means "no tensor
    /// for this frame, try the next one" — a filter graph that has not
    /// produced output yet is not an error. A skipped frame is skipped by the
    /// motion detector too: it never reaches the background, which is
    /// unchanged by it.
    fn to_tensor(&mut self, frame: AVFrame) -> Result<Option<Sampled>>;

    /// [`Self::to_tensor`]'s decode-side half: scale and convert a sampled
    /// frame to the content-rect RGB24 image, measuring motion on the way,
    /// and leave the tensor packing to the consumer
    /// ([`model_input_from_rgb`]). Same ownership and `Ok(None)` contract as
    /// `to_tensor`.
    fn to_rgb(&mut self, frame: AVFrame) -> Result<Option<RgbSampled>>;
}

/// A decoded frame's own geometry, which is what a projection is built from.
///
/// Refused rather than clamped when either axis is non-positive: a scaler
/// built for it fails much later and a projection built for it divides by
/// zero.
pub fn source_size(frame: &AVFrame) -> Result<InputSize> {
    if frame.width <= 0 || frame.height <= 0 {
        bail!(
            "decoded frame has no usable geometry ({}x{})",
            frame.width,
            frame.height
        );
    }
    Ok(InputSize {
        w: frame.width as usize,
        h: frame.height as usize,
    })
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
/// `motion` is one camera's resolved gate config, or `None` when the gate is
/// off for it — see [`crate::motion::resolve`]. It reaches the decoder rather
/// than the inference thread because the detector's state is per camera, and
/// one decoder is what "per camera" means on this side in both modes.
///
/// `sample_fps` is the process's resolved `--sample-fps` — one rate for every
/// camera this process serves, single mode or grouped, since the flag is
/// per-process by design. It reaches the decoder for the same reason `motion`
/// does: [`RgbScaler`]'s [`crate::motion::MotionDetector`] derives its
/// calibration window from it.
pub fn open(
    kind: DecoderKind,
    codecpar: &AVCodecParameters,
    spec: InputSpec,
    motion: Option<MotionConfig>,
    sample_fps: u32,
) -> Result<Box<dyn Decoder>> {
    let order = probe_order(kind);
    if order.is_empty() && kind != DecoderKind::Sw && kind != DecoderKind::Auto {
        note!("decoder {kind} is not available on this platform");
    }
    for backend in order {
        match HwDecoder::open(backend, codecpar, spec, motion, sample_fps) {
            Ok(decoder) => return Ok(Box::new(decoder)),
            Err(e) => note!("hardware decoder {backend} unavailable: {e:#}"),
        }
    }
    if kind != DecoderKind::Sw {
        note!("no hardware decoder opened; falling back to software decode");
    }
    Ok(Box::new(SwDecoder::open(
        codecpar, spec, motion, sample_fps,
    )?))
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

/// Scale-and-convert into the model's RGB input.
///
/// Shared by both paths: the hardware path scales on the GPU and downloads
/// NV12 already at the model's size, then lands here for the NV12 -> RGB24
/// conversion. Because both paths converge on this one RGB24 frame, it is
/// also where the motion gate reads from, which is why a scaler owns a
/// camera's motion state as well as its scaler state.
pub struct RgbScaler {
    spec: InputSpec,
    /// Rebuilt if the source ever changes geometry or pixel format mid-run.
    target: Option<Target>,
    /// The motion gate's frame-to-frame state, when it is configured. One
    /// scaler belongs to one decoder belongs to one camera, so this is
    /// per-camera by construction rather than by a lookup that could go wrong
    /// in group mode.
    motion: Option<MotionDetector>,
}

/// Everything settled by one (source geometry, pixel format) pair.
struct Target {
    key: (i32, i32, i32, InputSize),
    sws: SwsContext,
    fit: Fit,
    /// RGB24 at `fit.inner` — the *content* rectangle, not the whole input.
    /// Padding is added while packing rather than scaled into, so swscale
    /// never has to write into a sub-rectangle of a larger frame.
    rgb: AVFrame,
}

impl Target {
    /// Scale `frame` into the RGB24 content rectangle, returning the plane
    /// and its stride. The slice is `self.rgb`'s own buffer — read or copied
    /// out before the next scale overwrites it, which the borrow enforces.
    fn scale(&mut self, frame: &AVFrame) -> Result<(&[u8], usize)> {
        self.sws
            .scale_frame(frame, 0, frame.height, &mut self.rgb)
            .context("scaling to the model input size")?;
        let stride = self.rgb.linesize[0] as usize;
        // SAFETY: `self.rgb` is our own `alloc_buffer`'d RGB24 frame of
        // `self.fit.inner`, so data[0] is non-null and the allocation covers
        // linesize[0] * height bytes. Both invariants break if `ensure_target`
        // ever stops allocating the frame it describes.
        let plane = unsafe {
            slice::from_raw_parts(self.rgb.data[0] as *const u8, stride * self.fit.inner.h)
        };
        Ok((plane, stride))
    }
}

impl RgbScaler {
    /// `sample_fps` is only ever read here to build the [`MotionDetector`]'s
    /// calibration window — see [`MotionDetector::new`] — and is otherwise
    /// unused: nothing else this type does depends on how often it is called.
    pub fn new(spec: InputSpec, motion: Option<MotionConfig>, sample_fps: u32) -> Result<Self> {
        Ok(Self {
            spec,
            target: None,
            motion: motion.map(|config| MotionDetector::new(config, sample_fps)),
        })
    }

    /// `source` is the geometry of the frame as the *camera* sent it, which is
    /// not always `frame`'s: on the hardware path the GPU has already scaled
    /// the frame down to the fit's content size, and the fit — and so the
    /// projection — is still the original frame's.
    fn ensure_target(&mut self, frame: &AVFrame, source: InputSize) -> Result<()> {
        let key = (frame.width, frame.height, frame.format, source);
        if self.target.as_ref().map(|t| t.key) == Some(key) {
            return Ok(());
        }
        let fit = self.spec.resize.fit(self.spec.size, source);
        let mut rgb = AVFrame::new();
        rgb.set_width(fit.inner.w as i32);
        rgb.set_height(fit.inner.h as i32);
        rgb.set_format(ffi::AV_PIX_FMT_RGB24);
        rgb.alloc_buffer()
            .context("allocating the RGB scale target")?;
        let sws = SwsContext::get_context(
            frame.width,
            frame.height,
            frame.format,
            fit.inner.w as i32,
            fit.inner.h as i32,
            ffi::AV_PIX_FMT_RGB24,
            ffi::SWS_BILINEAR,
            None,
            None,
            None,
        )
        .ok_or_else(|| {
            anyhow!(
                "no scaler for {}x{} pixel format {} to {}",
                frame.width,
                frame.height,
                frame.format,
                fit.inner
            )
        })?;
        self.target = Some(Target { key, sws, fit, rgb });
        Ok(())
    }

    pub fn tensor_from(&mut self, frame: &AVFrame, source: InputSize) -> Result<Sampled> {
        let spec = self.spec;
        self.ensure_target(frame, source)?;
        let target = self.target.as_mut().expect("target was just set");
        let fit = target.fit;
        let (plane, stride) = target.scale(frame)?;
        let motion = observe(&mut self.motion, plane, stride, fit.inner);
        Ok(Sampled {
            input: ModelInput {
                tensor: pack_chw(plane, stride, fit, spec),
                projection: fit.projection(source),
            },
            motion,
        })
    }

    /// [`Self::tensor_from`]'s decode-side half: the content-rect RGB24 image
    /// itself, rows packed tight, with the same motion measurement taken on
    /// the way — the bytes [`model_input_from_rgb`] packs on the far side of
    /// the seam into the tensor this method would have.
    pub fn rgb_from(&mut self, frame: &AVFrame, source: InputSize) -> Result<RgbSampled> {
        self.ensure_target(frame, source)?;
        let target = self.target.as_mut().expect("target was just set");
        let fit = target.fit;
        let (plane, stride) = target.scale(frame)?;
        let motion = observe(&mut self.motion, plane, stride, fit.inner);
        let mut rgb = Vec::with_capacity(fit.inner.w * 3 * fit.inner.h);
        for y in 0..fit.inner.h {
            rgb.extend_from_slice(&plane[y * stride..y * stride + fit.inner.w * 3]);
        }
        Ok(RgbSampled {
            rgb,
            content: fit.inner,
            source,
            motion,
        })
    }
}

/// One frame into the motion background, when the gate is configured.
///
/// This RGB24 frame is the motion gate's source because it is the one
/// representation both decode paths converge on: the hardware path has
/// already scaled on the GPU, downloaded NV12 and converted it here, so
/// measuring from it gives a camera the same sensitivity whichever decoder
/// happened to open. It is also `fit.inner` — the *content* rectangle — so no
/// letterbox padding is ever averaged into a background as if it were picture.
///
/// The hardware path's NV12 Y plane is strictly cheaper (a ready-made luma
/// plane, no RGB conversion, no weighting) and is deliberately not used: it
/// exists on that path only, which would make the gate's sensitivity depend
/// on the decoder, and this dev container has no GPU to test that path on. It
/// stays a documented non-goal until it can be exercised —
/// `hwdecode::HwBackend::filter_spec` is where that plane is produced.
fn observe(
    motion: &mut Option<MotionDetector>,
    plane: &[u8],
    stride: usize,
    content: InputSize,
) -> Option<MotionVerdict> {
    motion
        .as_mut()
        .map(|detector| detector.observe(&GrayThumb::from_rgb24(plane, stride, content)))
}

struct SwDecoder {
    ctx: AVCodecContext,
    rgb: RgbScaler,
}

impl SwDecoder {
    fn open(
        codecpar: &AVCodecParameters,
        spec: InputSpec,
        motion: Option<MotionConfig>,
        sample_fps: u32,
    ) -> Result<Self> {
        let codec = AVCodec::find_decoder(codecpar.codec_id)
            .ok_or_else(|| anyhow!("no decoder for codec id {}", codecpar.codec_id))?;
        let mut ctx = AVCodecContext::new(&codec);
        ctx.apply_codecpar(codecpar)
            .context("applying stream parameters to the decoder")?;
        cap_frame_size(&mut ctx);
        ctx.open(None).context("opening the decoder")?;

        note!("decoder: software ({})", codec.name().to_string_lossy());
        Ok(Self {
            ctx,
            rgb: RgbScaler::new(spec, motion, sample_fps)?,
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

    fn to_tensor(&mut self, frame: AVFrame) -> Result<Option<Sampled>> {
        let source = source_size(&frame)?;
        self.rgb.tensor_from(&frame, source).map(Some)
    }

    fn to_rgb(&mut self, frame: AVFrame) -> Result<Option<RgbSampled>> {
        let source = source_size(&frame)?;
        self.rgb.rgb_from(&frame, source).map(Some)
    }
}

/// Bound what a stream's SPS can make libavcodec allocate.
pub fn cap_frame_size(ctx: &mut AVCodecContext) {
    unsafe { ctx.deref_mut() }.max_pixels = MAX_PIXELS;
}

/// Packed RGB24 rows (`stride` may exceed the row width) -> CHW f32, placed
/// into the model's input rectangle according to `fit`.
///
/// The scale target is always RGB24 because that is one pixel format for
/// swscale to reach from anything; the encoding decides only what happens on
/// the way into the planes — the affine, and for BGR which source byte each
/// plane draws from.
///
/// The padding goes through the same encoding as the pixels: the model was
/// trained on a padded picture, not on an out-of-range constant. Under a
/// stretch `fit.inner` *is* the input, so there is no padding and the fill is
/// skipped rather than written and immediately overwritten.
fn pack_chw(plane: &[u8], stride: usize, fit: Fit, spec: InputSpec) -> Vec<f32> {
    let size = spec.size;
    let packing = spec.encoding.packing();
    let plane_len = size.w * size.h;
    let mut tensor = vec![0f32; size.tensor_len()];
    if fit.inner != size {
        for (p, chunk) in tensor.chunks_exact_mut(plane_len).enumerate() {
            chunk.fill(packing.value(p, fit.pad));
        }
    }
    let (ox, oy) = fit.offset;
    for y in 0..fit.inner.h {
        let row = &plane[y * stride..y * stride + fit.inner.w * 3];
        for x in 0..fit.inner.w {
            let px = &row[x * 3..x * 3 + 3];
            let at = (oy + y) * size.w + ox + x;
            for (p, source) in packing.source.iter().enumerate() {
                tensor[p * plane_len + at] = packing.value(p, px[*source]);
            }
        }
    }
    tensor
}

/// One scaled RGB24 content rectangle -> the model input it packs into.
///
/// The seam the NIF decoder/inference split crosses: the decode side produces
/// the content-rect RGB24 plane ([`RgbScaler`]'s scale target, tightly packed
/// rows) plus the source geometry, and the inference side calls this to pack
/// the very tensor [`RgbScaler::tensor_from`] would have — same `pack_chw`,
/// same projection, so the two paths cannot drift.
///
/// `content` is the producer's claim about the plane's geometry, and it is
/// checked against the fit this spec derives from `source` rather than
/// trusted: a disagreement means the producer resized for a different spec,
/// and packing anyway would letterbox the wrong rectangle and project every
/// box against geometry the pixels never had.
pub fn model_input_from_rgb(
    plane: &[u8],
    content: InputSize,
    source: InputSize,
    spec: InputSpec,
) -> Result<ModelInput> {
    let fit = spec.resize.fit(spec.size, source);
    if fit.inner != content {
        bail!(
            "a {content} frame from a {source} source does not fit this model's \
             {} {} input, which takes {} content",
            spec.size,
            spec.resize,
            fit.inner
        );
    }
    let expected = content.w * 3 * content.h;
    if plane.len() != expected {
        bail!(
            "RGB24 payload is {} bytes where {content} needs {expected}",
            plane.len()
        );
    }
    Ok(ModelInput {
        tensor: pack_chw(plane, content.w * 3, fit, spec),
        projection: fit.projection(source),
    })
}

/// The wall-clock gap between samples that `--sample-fps` asks for.
///
/// Public because [`run`] is not the only loop that paces on it: a second spelling
/// of this arithmetic is a second sample rate.
pub fn sample_interval(sample_fps: u32) -> Duration {
    // Integer nanos, not a float reciprocal: exact for every legal rate,
    // and identical to the old `from_secs_f64(1.0 / 5.0)` at the default.
    Duration::from_nanos(1_000_000_000 / u64::from(sample_fps))
}

/// Read packets forever, handing sampled frames to the inference thread.
///
/// Returns only on error or end of stream — both are fatal for the process,
/// which is what Cairn's restart-with-backoff expects.
///
/// `sample_fps` is the process's resolved `--sample-fps`, validated at parse
/// time to `1..=30` — this loop just turns it into an interval and never
/// second-guesses it.
pub fn run(
    input: &mut AVFormatContextInput,
    stream_index: usize,
    time_base: AVRational,
    decoder: &mut dyn Decoder,
    sink: &dyn SampleSink,
    sample_fps: u32,
) -> Result<()> {
    let interval = sample_interval(sample_fps);
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
            let observed_at = SystemTime::now();

            let pts_90k = pts_90k(&frame, time_base);
            // A frame we cannot convert costs one sample, not the process:
            // sws has no path for a mid-stream format change, a filter graph
            // rebuild can fail transiently, and restarting is expensive (model
            // load plus up to a minute of open retries).
            let Sampled { input, motion } = match decoder.to_tensor(frame) {
                Ok(Some(sampled)) => sampled,
                Ok(None) => continue,
                Err(e) => {
                    note_error(&mut tensor_errors, "sample conversion", &e);
                    continue;
                }
            };
            if !sink.offer(Sample {
                pts_90k,
                observed_at,
                motion,
                input,
            })? {
                dropped += 1;
                if dropped.is_multiple_of(50) {
                    note!("inference behind: {dropped} samples skipped so far");
                }
            }
        }
    }
}

/// Count a tolerated error, logging the first and every 50th.
fn note_error(count: &mut u64, what: &str, e: &impl fmt::Display) {
    *count += 1;
    if *count % 50 == 1 {
        note!("{what} error ({count} so far): {e}");
    }
}

/// A decoded frame's presentation time on the contract's 90 kHz clock. Public
/// because the NIF path dates its frames here too, and two derivations would date
/// the same frame differently.
pub fn pts_90k(frame: &AVFrame, time_base: AVRational) -> i64 {
    match frame_pts(frame) {
        Some(pts) => rescale_90k(pts, time_base),
        None => 0,
    }
}

/// The timestamp a decoded frame is dated by, still in the decoder's own time
/// base — the frame's pts, or libavcodec's best effort when reordering left
/// none. `None` is a frame with no date at all, which [`pts_90k`] spells `0`.
///
/// Split from [`pts_90k`] for the NIF decoder/inference seam: the selection
/// needs the [`AVFrame`], which only the decode side holds, while the rescale
/// happens wherever the 90 kHz value is consumed.
pub fn frame_pts(frame: &AVFrame) -> Option<i64> {
    if frame.pts != ffi::AV_NOPTS_VALUE {
        Some(frame.pts)
    } else if frame.best_effort_timestamp != ffi::AV_NOPTS_VALUE {
        Some(frame.best_effort_timestamp)
    } else {
        None
    }
}

/// `time_base` ticks onto the contract's 90 kHz clock.
///
/// The RTP demuxer already ticks at 90 kHz, but the rescale keeps this correct
/// for any other time base (e.g. a file fixture, or the host's nanoseconds).
pub fn rescale_90k(pts: i64, time_base: AVRational) -> i64 {
    av_rescale_q(pts, time_base, PTS_TIMEBASE)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::infer::{ResizePolicy, TensorEncoding};

    fn spec(size: InputSize, encoding: TensorEncoding, resize: ResizePolicy) -> InputSpec {
        InputSpec {
            size,
            encoding,
            resize,
        }
    }

    fn unit_rgb(size: InputSize) -> InputSpec {
        spec(size, TensorEncoding::UnitRgb, ResizePolicy::Stretch)
    }

    /// Pack a whole `size`-sized RGB24 buffer with no padding, which is what
    /// `Stretch` always produces.
    fn stretched(
        plane: &[u8],
        stride: usize,
        size: InputSize,
        encoding: TensorEncoding,
    ) -> Vec<f32> {
        let spec = spec(size, encoding, ResizePolicy::Stretch);
        pack_chw(plane, stride, ResizePolicy::Stretch.fit(size, size), spec)
    }

    #[test]
    fn rescales_pts_to_90khz() {
        let mut frame = AVFrame::new();
        frame.set_pts(1000);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 1000);
        assert_eq!(pts_90k(&frame, AVRational { num: 1, den: 1000 }), 90_000);
    }

    #[test]
    fn a_frame_pts_falls_back_to_best_effort_and_then_to_none() {
        let mut frame = AVFrame::new();
        frame.set_pts(1000);
        assert_eq!(frame_pts(&frame), Some(1000));

        let mut frame = AVFrame::new();
        frame.set_pts(ffi::AV_NOPTS_VALUE);
        // SAFETY: plain i64 field on our own freshly allocated frame.
        unsafe { frame.deref_mut() }.best_effort_timestamp = 700;
        assert_eq!(frame_pts(&frame), Some(700));
        assert_eq!(pts_90k(&frame, AVRational { num: 1, den: 1000 }), 63_000);

        let mut frame = AVFrame::new();
        frame.set_pts(ffi::AV_NOPTS_VALUE);
        assert_eq!(frame_pts(&frame), None);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 0);
    }

    /// The seam invariant everything in the split rests on: packing the
    /// content-rect RGB bytes on the far side of the boundary yields the very
    /// tensor and projection the unsplit path builds.
    #[test]
    fn the_rgb_seam_reproduces_tensor_from_exactly() {
        let spec = spec(
            InputSize::square(64),
            TensorEncoding::UnitRgb,
            ResizePolicy::Letterbox { pad: 114 },
        );
        let source = InputSize { w: 100, h: 80 };
        let frame = rgb24_frame(source, |x, y| {
            [
                (x * 7 % 256) as u8,
                (y * 5 % 256) as u8,
                ((x + y) % 256) as u8,
            ]
        });

        // Fresh scalers so neither run's motion state has seen the other's frame.
        let motion = Some(MotionConfig::default());
        let mut unsplit = RgbScaler::new(spec, motion, DEFAULT_SAMPLE_FPS).unwrap();
        let whole = unsplit.tensor_from(&frame, source).unwrap();

        let mut split = RgbScaler::new(spec, motion, DEFAULT_SAMPLE_FPS).unwrap();
        let sampled = split.rgb_from(&frame, source).unwrap();
        assert_eq!(sampled.source, source);
        assert_eq!(sampled.rgb.len(), sampled.content.w * 3 * sampled.content.h);

        let input = model_input_from_rgb(&sampled.rgb, sampled.content, source, spec).unwrap();
        assert_eq!(
            input.tensor, whole.input.tensor,
            "the packed tensors differ"
        );
        assert_eq!(input.projection, whole.input.projection);
        // …and the motion measurement is the same measurement.
        assert_eq!(sampled.motion, whole.motion);
    }

    #[test]
    fn a_content_rect_for_a_different_fit_is_refused_not_packed() {
        let spec = spec(
            InputSize::square(64),
            TensorEncoding::UnitRgb,
            ResizePolicy::Letterbox { pad: 114 },
        );
        let source = InputSize { w: 100, h: 80 };
        let fit = spec.resize.fit(spec.size, source);

        // A plane sized for the model rect rather than the content rect: the
        // producer resized for some other spec.
        let wrong = InputSize::square(64);
        assert_ne!(fit.inner, wrong);
        let plane = vec![0u8; wrong.w * 3 * wrong.h];
        let error = model_input_from_rgb(&plane, wrong, source, spec).unwrap_err();
        assert!(error.to_string().contains("does not fit"), "{error:#}");

        // The right geometry with the wrong byte count is refused too.
        let short = vec![0u8; fit.inner.w * 3 * fit.inner.h - 3];
        let error = model_input_from_rgb(&short, fit.inner, source, spec).unwrap_err();
        assert!(error.to_string().contains("bytes"), "{error:#}");
    }

    /// An RGB24 frame with per-pixel values from `paint`, allocated the way
    /// libav would hand one over (stride may exceed the row width).
    fn rgb24_frame(size: InputSize, paint: impl Fn(usize, usize) -> [u8; 3]) -> AVFrame {
        let mut frame = AVFrame::new();
        frame.set_width(size.w as i32);
        frame.set_height(size.h as i32);
        frame.set_format(ffi::AV_PIX_FMT_RGB24);
        frame.alloc_buffer().unwrap();
        let stride = frame.linesize[0] as usize;
        // SAFETY: `alloc_buffer` sized data[0] as stride * height.
        let plane = unsafe { slice::from_raw_parts_mut(frame.data[0], stride * size.h) };
        for y in 0..size.h {
            for x in 0..size.w {
                plane[y * stride + x * 3..y * stride + x * 3 + 3].copy_from_slice(&paint(x, y));
            }
        }
        frame
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
        let decoder = SwDecoder::open(
            &codecpar,
            unit_rgb(InputSize::square(640)),
            None,
            DEFAULT_SAMPLE_FPS,
        )
        .unwrap();
        assert_eq!(decoder.ctx.max_pixels, MAX_PIXELS);
        // Generous enough for 8K, small enough that a 16384x16384 SPS fails.
        const { assert!(MAX_PIXELS > 7680 * 4320) };
        const { assert!(MAX_PIXELS < 16384 * 16384) };
    }

    #[test]
    fn packs_rgb_rows_into_planes() {
        // One padded row of red, green, blue pixels; the rest stays black.
        for size in [InputSize::square(640), InputSize { w: 320, h: 192 }] {
            let stride = size.w * 3 + 16;
            let mut plane = vec![0u8; stride * size.h];
            plane[0..9].copy_from_slice(&[255, 0, 0, 0, 255, 0, 0, 0, 255]);

            let tensor = stretched(&plane, stride, size, TensorEncoding::UnitRgb);
            let plane_len = size.w * size.h;
            assert_eq!(tensor.len(), size.tensor_len());
            assert_eq!(tensor.len(), 3 * plane_len);
            assert_eq!(tensor[0], 1.0);
            assert_eq!(tensor[plane_len + 1], 1.0);
            assert_eq!(tensor[2 * plane_len + 2], 1.0);
            assert_eq!(tensor[1], 0.0);
            assert!(tensor.iter().all(|v| (0.0..=1.0).contains(v)));
        }
    }

    #[test]
    fn raw_bgr_keeps_the_byte_values_and_swaps_the_outer_planes() {
        let size = InputSize { w: 320, h: 192 };
        let stride = size.w * 3 + 16;
        let mut plane = vec![0u8; stride * size.h];
        // pixel 0 is pure red, pixel 1 pure green, pixel 2 pure blue
        plane[0..9].copy_from_slice(&[255, 0, 0, 0, 255, 0, 0, 0, 255]);

        let tensor = stretched(&plane, stride, size, TensorEncoding::RawBgr);
        let plane_len = size.w * size.h;
        assert_eq!(tensor.len(), size.tensor_len());
        // 0..255, not 0..1
        assert_eq!(tensor[2 * plane_len], 255.0);
        // plane 0 is blue, plane 2 is red: the red pixel lands in the last
        // plane and the blue one in the first
        assert_eq!(tensor[2], 255.0);
        assert_eq!(tensor[plane_len + 1], 255.0);
        assert_eq!(tensor[0], 0.0);
        assert!(tensor.iter().all(|v| (0.0..=255.0).contains(v)));
    }

    #[test]
    fn imagenet_normalization_reaches_the_tensor() {
        // The plumbing, not the arithmetic (which `infer` pins): an encoding
        // with a non-zero bias has to survive the packer, which for a long
        // time could only express a scale.
        let size = InputSize { w: 64, h: 32 };
        let stride = size.w * 3;
        // every pixel pure red
        let mut plane = vec![0u8; stride * size.h];
        for px in plane.chunks_exact_mut(3) {
            px[0] = 255;
        }
        let tensor = stretched(&plane, stride, size, TensorEncoding::ImageNetRgb);
        let plane_len = size.w * size.h;
        assert_eq!(tensor.len(), size.tensor_len());
        // red plane is (1 - 0.485) / 0.229, green and blue are (0 - mean)/std:
        // negative, which no other encoding here can produce
        assert!((tensor[0] - 2.2489).abs() < 1e-3, "{}", tensor[0]);
        assert!(
            (tensor[plane_len] - -2.0357).abs() < 1e-3,
            "{}",
            tensor[plane_len]
        );
        assert!(
            (tensor[2 * plane_len] - -1.8044).abs() < 1e-3,
            "{}",
            tensor[2 * plane_len]
        );
        assert!(tensor.iter().any(|v| *v < 0.0), "bias was dropped");
    }

    #[test]
    fn only_the_encoding_differs_between_the_two_packings() {
        // Same bytes, same geometry: every value is the other's, scaled and
        // with the outer planes exchanged. Nothing else may move.
        let size = InputSize { w: 64, h: 32 };
        let stride = size.w * 3;
        let plane: Vec<u8> = (0..stride * size.h).map(|i| (i % 251) as u8).collect();
        let plane_len = size.w * size.h;

        let unit = stretched(&plane, stride, size, TensorEncoding::UnitRgb);
        let raw = stretched(&plane, stride, size, TensorEncoding::RawBgr);
        for i in 0..plane_len {
            for (raw, unit) in [
                (raw[i], unit[2 * plane_len + i]),
                (raw[plane_len + i], unit[plane_len + i]),
                (raw[2 * plane_len + i], unit[i]),
            ] {
                assert!((0.0..=255.0).contains(&raw));
                assert!((raw / 255.0 - unit).abs() < 1e-6, "{raw} vs {unit}");
            }
        }
    }

    #[test]
    fn a_letterboxed_pack_places_the_content_at_the_origin_and_pads_the_rest() {
        // 1920x1080 into a 416x416 input: 416x234 of picture with 182 rows of
        // 114 under it, which is what YOLOX's own preproc builds.
        let input = InputSize::square(416);
        let source = InputSize { w: 1920, h: 1080 };
        let resize = ResizePolicy::Letterbox { pad: 114 };
        let fit = resize.fit(input, source);
        assert_eq!(fit.inner, InputSize { w: 416, h: 234 });

        let stride = fit.inner.w * 3 + 8;
        let plane = vec![255u8; stride * fit.inner.h];
        let tensor = pack_chw(
            &plane,
            stride,
            fit,
            spec(input, TensorEncoding::RawBgr, resize),
        );

        assert_eq!(tensor.len(), input.tensor_len());
        let plane_len = input.w * input.h;
        for p in 0..3 {
            // the content rows carry the picture...
            assert_eq!(tensor[p * plane_len], 255.0, "plane {p} row 0");
            assert_eq!(
                tensor[p * plane_len + (fit.inner.h - 1) * input.w + input.w - 1],
                255.0,
                "plane {p} last content pixel"
            );
            // ...and every row below them is the pad, in the tensor's own
            // encoding rather than a raw 114 that a 0..1 model would read as
            // an impossible value
            assert_eq!(
                tensor[p * plane_len + fit.inner.h * input.w],
                114.0,
                "plane {p} first pad row"
            );
            assert_eq!(tensor[(p + 1) * plane_len - 1], 114.0, "plane {p} last pad");
        }
        let pad_count = tensor.iter().filter(|v| **v == 114.0).count();
        assert_eq!(pad_count, 3 * (input.h - fit.inner.h) * input.w);
    }

    #[test]
    fn the_letterbox_pad_goes_through_the_encoding() {
        // The same 114 grey, packed for a 0..1 model: 114/255, not 114.
        let input = InputSize::square(64);
        let resize = ResizePolicy::Letterbox { pad: 114 };
        let fit = resize.fit(input, InputSize { w: 128, h: 64 });
        assert_eq!(fit.inner, InputSize { w: 64, h: 32 });
        let stride = fit.inner.w * 3;
        let plane = vec![0u8; stride * fit.inner.h];
        let tensor = pack_chw(
            &plane,
            stride,
            fit,
            spec(input, TensorEncoding::UnitRgb, resize),
        );
        let first_pad = fit.inner.h * input.w;
        assert!(
            (tensor[first_pad] - 114.0 / 255.0).abs() < 1e-6,
            "{}",
            tensor[first_pad]
        );
        assert!(tensor.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    #[test]
    fn a_stretch_pack_leaves_no_padding_at_all() {
        let size = InputSize { w: 64, h: 32 };
        let stride = size.w * 3;
        let plane = vec![7u8; stride * size.h];
        let tensor = stretched(&plane, stride, size, TensorEncoding::RawBgr);
        assert!(tensor.iter().all(|v| *v == 7.0));
    }

    #[test]
    fn missing_pts_is_zero() {
        let mut frame = AVFrame::new();
        frame.set_pts(ffi::AV_NOPTS_VALUE);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 0);
    }

    #[test]
    fn the_sample_interval_is_the_reciprocal_of_the_requested_rate() {
        assert_eq!(
            sample_interval(DEFAULT_SAMPLE_FPS),
            Duration::from_millis(200)
        );
        // A non-default rate has to move the interval too, not just parse:
        // this is the arithmetic `run` actually paces its gate on.
        assert_eq!(sample_interval(10), Duration::from_millis(100));
        assert_eq!(sample_interval(1), Duration::from_secs(1));
        // 1e9/30 doesn't divide evenly; the exact truncated-nanos value is
        // the contract now that the construction is integer.
        assert_eq!(sample_interval(30), Duration::from_nanos(33_333_333));
    }
}
