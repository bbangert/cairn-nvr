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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
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
use crate::infer::{Fit, InputSize, InputSpec, Projection, TensorValues};
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
    /// CHW, `3 * w * h` values for the resolved model input, in whichever
    /// `TensorEncoding` the detector asked for — f32 for the float graph-IO
    /// contract, u8 codes when the spec carries `input_quant`.
    pub tensor: TensorValues,
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
    /// `pts_ns` is the frame's presentation time in nanoseconds — the
    /// caller's, because only the caller knows the stream's time base — and
    /// exists for the motion detector's elapsed-time calibration window
    /// ([`crate::motion::MotionDetector::observe`]); `None` for a frame the
    /// decoder could not date.
    ///
    /// Takes ownership because the hardware path feeds the frame straight
    /// into a filter graph, which consumes it. `Ok(None)` means "no tensor
    /// for this frame, try the next one" — a filter graph that has not
    /// produced output yet is not an error. A skipped frame is skipped by the
    /// motion detector too: it never reaches the background, which is
    /// unchanged by it.
    fn to_tensor(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<Sampled>>;

    /// [`Self::to_tensor`]'s decode-side half: scale and convert a sampled
    /// frame to the content-rect RGB24 image, measuring motion on the way,
    /// and leave the tensor packing to the consumer
    /// ([`model_input_from_rgb`]). Same ownership, `pts_ns` and `Ok(None)`
    /// contract as `to_tensor`.
    fn to_rgb(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<RgbSampled>>;

    /// The hardware backend this decoder opened on, `None` for software decode.
    ///
    /// [`open`] falls back rather than failing, so a caller that named a
    /// backend has no other way to learn whether it got the one it named.
    fn hw_backend(&self) -> Option<HwBackend>;

    /// True while [`open`]'s deferred hardware probe has not decided yet:
    /// software is decoding, but the stream's first in-band parameter sets
    /// may still promote it to a hardware backend. A caller enforcing a
    /// named backend must not read the interim `hw_backend() == None` as
    /// the final answer — the probe itself refuses the fallback at settle
    /// time ([`DeferredHwDecoder`]).
    fn hw_pending(&self) -> bool {
        false
    }
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
/// A backend that cannot open — no device, no driver, no GPU scaler — is
/// logged and skipped, and software decode is the last resort. What a
/// *named* backend's failure means is the embedder's to say via `fallback`:
/// the plugin binary allows the fallback (its refusal would be a process
/// exit into a restart loop), the NIF path refuses it so the branch goes
/// dark with the reason surfaced instead of silently decoding at software
/// cost. At open time both behave alike — the eager path always falls back,
/// and the NIF's `require_named_hardware` turns that into an open error —
/// `fallback` decides the *deferred* probe's settle, which happens after
/// open has already succeeded.
///
/// Every hardware open runs under [`HW_OPEN_DEADLINE`] on its own thread: a
/// wedged driver ioctl otherwise blocks this call indefinitely, and on the
/// NIF path that is a GenServer timeout and a crash-looping pipeline instead
/// of a fallback.
///
/// For an H.264 stream whose `codecpar` has no extradata — the NIF path,
/// where Membrane's parser delivers SPS/PPS in band — the hardware probe is
/// *deferred*: decoding starts in software and the probe runs once the
/// stream has produced both parameter sets, which become the extradata the
/// open needs. v4l2m2m in particular negotiates its formats as the context
/// opens: on QCS6490's venus an open with no extradata never returned,
/// while the same decoder with parameter sets attached opens immediately.
///
/// `motion` is one camera's resolved gate config, or `None` when the gate is
/// off for it — see [`crate::motion::resolve`]. It reaches the decoder rather
/// than the inference thread because the detector's state is per camera, and
/// one decoder is what "per camera" means on this side in both modes.
pub fn open(
    kind: DecoderKind,
    codecpar: &AVCodecParameters,
    spec: InputSpec,
    motion: Option<MotionConfig>,
    fallback: NamedFallback,
) -> Result<Box<dyn Decoder>> {
    let order = probe_order(kind);
    if order.is_empty() && kind != DecoderKind::Sw && kind != DecoderKind::Auto {
        note!("decoder {kind} is not available on this platform");
    }
    let bare_h264 = codecpar.codec_id == ffi::AV_CODEC_ID_H264
        && (codecpar.extradata.is_null() || codecpar.extradata_size <= 0);
    if !order.is_empty() && bare_h264 {
        let required = fallback == NamedFallback::Refused && kind != DecoderKind::Auto;
        let sw = SwDecoder::open(codecpar, spec, motion)?;
        return Ok(Box::new(DeferredHwDecoder::new(
            sw,
            order,
            spawn_hw_open,
            clone_codecpar(codecpar)?,
            spec,
            motion,
            required,
        )));
    }
    for backend in order {
        match clone_codecpar(codecpar)
            .and_then(|clone| open_hw_bounded(backend, SendCodecpar(clone), spec, motion))
        {
            Ok(decoder) => return Ok(Box::new(decoder)),
            Err(e) => note!("hardware decoder {backend} unavailable: {e:#}"),
        }
    }
    if kind != DecoderKind::Sw {
        note!("no hardware decoder opened; falling back to software decode");
    }
    Ok(Box::new(SwDecoder::open(codecpar, spec, motion)?))
}

/// What a named backend's failure to open means for this embedder — see
/// [`open`]. Only the deferred probe consults it; the eager open falls back
/// either way and lets the embedder refuse from `hw_backend()`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedFallback {
    /// Settle on software decode with a note.
    Allowed,
    /// Refuse: every packet after the settle fails with a [`DecoderRefusal`]
    /// for the embedder to surface.
    Refused,
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

/// How long one hardware backend gets to open before it is abandoned.
///
/// A healthy open is milliseconds; what this bounds is a driver that never
/// answers — v4l2m2m blocked in format negotiation is the observed case. An
/// abandoned open finishes or fails on its own detached thread, where the
/// decoder it may still produce is dropped and its device fds closed.
const HW_OPEN_DEADLINE: Duration = Duration::from_secs(3);

/// How many access units without a complete parameter-set pair the deferred
/// probe tolerates before giving up. 900 is fifteen seconds of 60 fps
/// access units — three worst-case keyframe intervals at a 5 s GOP — and
/// software is decoding the whole time, so waiting long costs nothing but a
/// late note. A stream that never carries SPS/PPS in band left them in
/// extradata it also did not provide, so hardware was never reachable.
const DEFER_AU_LIMIT: u32 = 900;

/// A named hardware backend's deferred probe settled without opening.
///
/// Its own error type because the embedder must tell this apart from the
/// tolerated per-packet decode errors: a mid-GOP join heals on the next
/// keyframe, this never does, and treating it as transient is how a named
/// backend's camera would read healthy while decoding nothing. cairn-native
/// downcasts to it in `push_au` and returns its own hard error class.
#[derive(Debug, Clone)]
pub struct DecoderRefusal(pub String);

impl fmt::Display for DecoderRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DecoderRefusal {}

/// A full-fidelity copy of stream parameters, extradata included.
fn clone_codecpar(codecpar: &AVCodecParameters) -> Result<AVCodecParameters> {
    let mut copy = AVCodecParameters::new();
    // SAFETY: both structs are valid and owned; avcodec_parameters_copy
    // resets `copy` and allocates its own extradata, which `copy`'s drop
    // frees.
    let ret = unsafe { ffi::avcodec_parameters_copy(copy.deref_mut(), codecpar.as_ptr()) };
    if ret < 0 {
        bail!("copying stream parameters failed ({ret})");
    }
    Ok(copy)
}

/// Attach `extradata` to parameters that have none.
fn set_extradata(codecpar: &mut AVCodecParameters, extradata: &[u8]) -> Result<()> {
    let size = i32::try_from(extradata.len()).context("extradata larger than an i32")?;
    // SAFETY: `codecpar` is exclusively owned. The buffer is av_mallocz'd
    // with the padding libavcodec requires (zeroed by the allocation), and
    // its ownership transfers to `codecpar`, whose drop frees it; any prior
    // extradata is freed first so nothing leaks.
    unsafe {
        let raw = codecpar.deref_mut();
        if !raw.extradata.is_null() {
            ffi::av_freep(std::ptr::addr_of_mut!(raw.extradata).cast());
            raw.extradata_size = 0;
        }
        let padded = extradata.len() + ffi::AV_INPUT_BUFFER_PADDING_SIZE as usize;
        let buf = ffi::av_mallocz(padded).cast::<u8>();
        if buf.is_null() {
            bail!("out of memory for {padded} bytes of extradata");
        }
        std::ptr::copy_nonoverlapping(extradata.as_ptr(), buf, extradata.len());
        raw.extradata = buf;
        raw.extradata_size = size;
    }
    Ok(())
}

/// An owned `AVCodecParameters` allowed across the deadline-thread boundary.
///
/// The struct is plain heap data with no thread affinity — rsmpeg simply
/// does not mark its wrappers `Send` — and exclusive ownership moves with
/// the value.
struct SendCodecpar(AVCodecParameters);

// SAFETY: see the type's doc — exclusively owned, thread-agnostic data.
unsafe impl Send for SendCodecpar {}

fn backend_slot(backend: HwBackend) -> usize {
    match backend {
        HwBackend::Vaapi => 0,
        HwBackend::Qsv => 1,
        HwBackend::Nvdec => 2,
        HwBackend::V4l2 => 3,
        #[cfg(target_os = "macos")]
        HwBackend::Videotoolbox => 4,
    }
}

/// A backend whose open timed out is never probed again in this process:
/// the abandoned thread and its device fd are leaked by the driver's own
/// refusal to answer, and every reopen would leak another set.
fn wedged(backend: HwBackend) -> &'static AtomicBool {
    static WEDGED: [AtomicBool; 5] = [const { AtomicBool::new(false) }; 5];
    &WEDGED[backend_slot(backend)]
}

/// The right to be the one probe running against a backend, held RAII-style.
///
/// One probe per backend at a time. Without this the wedge latch races: a
/// fleet's cameras all read not-wedged together and each spawns its own
/// doomed open before the first can time out and store, leaking one thread
/// and fd per camera — the exact set the latch bounds. It is a claim rather
/// than a lock because the deferred probe runs inside `decode_au` on a
/// dirty-CPU scheduler thread, where blocking on another camera's probe
/// would hold a scheduler the whole VM shares — a caller whose claim fails
/// keeps decoding in software and tries again on a later access unit.
struct ProbeClaim(HwBackend);

impl ProbeClaim {
    fn take(backend: HwBackend) -> Option<Self> {
        probe_claim_slot(backend)
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
            .then_some(Self(backend))
    }
}

impl Drop for ProbeClaim {
    fn drop(&mut self) {
        probe_claim_slot(self.0).store(false, Ordering::Release);
    }
}

fn probe_claim_slot(backend: HwBackend) -> &'static AtomicBool {
    static CLAIMS: [AtomicBool; 5] = [const { AtomicBool::new(false) }; 5];
    &CLAIMS[backend_slot(backend)]
}

/// Start one backend open on its own thread; the result arrives on the
/// channel. The claim must already be held and lives as long as the probe.
fn spawn_hw_open(
    backend: HwBackend,
    codecpar: SendCodecpar,
    spec: InputSpec,
    motion: Option<MotionConfig>,
) -> Result<mpsc::Receiver<Result<HwDecoder>>> {
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name(format!("hw-open-{backend}"))
        .spawn(move || {
            let SendCodecpar(codecpar) = codecpar;
            // A receiver that gave up dropped its end; the decoder drops
            // here with the failed send.
            let _ = tx.send(HwDecoder::open(backend, &codecpar, spec, motion));
        })
        .context("spawning the hardware open thread")?;
    Ok(rx)
}

/// [`HwDecoder::open`] under a deadline, synchronously — the *eager* path
/// (extradata already in the container/SDP), which runs on the plugin
/// binary's own per-stream threads or a once-per-open NIF call, where a
/// bounded wait is affordable. The budget is two deadlines total: at most
/// one predecessor's in-flight probe waited out, plus this caller's own —
/// so the wait is inside the bound, not stacked on top of it.
fn open_hw_bounded(
    backend: HwBackend,
    codecpar: SendCodecpar,
    spec: InputSpec,
    motion: Option<MotionConfig>,
) -> Result<HwDecoder> {
    let started = Instant::now();
    let budget = HW_OPEN_DEADLINE * 2;
    let claim = loop {
        if wedged(backend).load(Ordering::Relaxed) {
            bail!("timed out earlier in this process; not probing it again");
        }
        if let Some(claim) = ProbeClaim::take(backend) {
            break claim;
        }
        if started.elapsed() >= budget {
            bail!("another probe held {backend} past the deadline; falling back");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let _claim = claim;
    let rx = spawn_hw_open(backend, codecpar, spec, motion)?;
    let remaining = budget
        .saturating_sub(started.elapsed())
        .max(HW_OPEN_DEADLINE);
    match rx.recv_timeout(remaining.min(HW_OPEN_DEADLINE)) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            wedged(backend).store(true, Ordering::Relaxed);
            bail!(
                "did not open within {}s — abandoned as wedged, and not probed \
                 again in this process",
                HW_OPEN_DEADLINE.as_secs()
            );
        }
        // The thread can only drop `tx` without sending by dying first.
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            bail!("the open thread panicked before answering")
        }
    }
}

/// The in-band SPS and PPS of one access unit, if it carries them.
///
/// Both `None` for a mid-GOP join; cameras that send the sets in separate
/// access units are why the probe accumulates across calls rather than
/// demanding both at once.
fn parameter_sets(au: &[u8]) -> (Option<Vec<u8>>, Option<Vec<u8>>) {
    let mut sps = None;
    let mut pps = None;
    for nal in annexb_nals(au) {
        match nal.first().map(|byte| byte & 0x1f) {
            Some(7) => sps = Some(nal.to_vec()),
            Some(8) => pps = Some(nal.to_vec()),
            _ => {}
        }
    }
    (sps, pps)
}

/// H.264 extradata from a parameter-set pair: Annex-B start codes, SPS then
/// PPS — the form the `h264` and `h264_v4l2m2m` decoders accept.
fn extradata_from(sps: &[u8], pps: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(sps.len() + pps.len() + 8);
    for nal in [sps, pps] {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(nal);
    }
    out
}

/// The NAL payloads of an Annex-B buffer, start codes stripped.
fn annexb_nals(data: &[u8]) -> Vec<&[u8]> {
    // Index just past each three-byte start code; a four-byte code is a
    // three-byte one with a leading zero, found at its second byte.
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 2 < data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut nals = Vec::with_capacity(starts.len());
    for (n, &start) in starts.iter().enumerate() {
        let mut end = starts.get(n + 1).map_or(data.len(), |&next| next - 3);
        // The byte stream may pad a NAL with trailing zeros (a four-byte
        // start code contributes one). Trimming them is exact for the
        // parameter sets this scan feeds — their last byte holds the RBSP
        // stop bit — and merely cosmetic for slice NALs, whose payloads
        // (which may legitimately end in cabac_zero_words) nothing reads
        // past the header byte.
        while end > start && data[end - 1] == 0 {
            end -= 1;
        }
        nals.push(&data[start..end]);
    }
    nals
}

/// Software decode now, hardware once the stream provides its parameter sets.
///
/// Every step of the probe is non-blocking: the NIF path runs `send_packet`
/// inside `decode_au` on a dirty-CPU scheduler thread, so waiting there —
/// on a channel, on another camera's probe — would hold a scheduler the
/// whole VM shares. The open runs on its own thread while software keeps
/// decoding; its result is polled one `try_recv` per access unit; and the
/// handover to a successful open waits for the next keyframe, so hardware
/// starts cleanly and no frame between the two decoders is lost.
struct DeferredHwDecoder {
    active: ActiveDecoder,
    /// `Some` while the probe has not decided.
    pending: Option<PendingHw>,
}

enum ActiveDecoder {
    Sw(SwDecoder),
    Hw(HwDecoder),
    /// A named backend that could not open. This path refuses the silent
    /// software fallback, and the refusal must outlive the access unit that
    /// triggered it — the caller treats decode errors as tolerated — so the
    /// state makes every subsequent packet fail with the same
    /// [`DecoderRefusal`] instead of quietly decoding in software.
    Refused(String),
}

/// The deferred probe's spawner — [`spawn_hw_open`] in production, a
/// preloaded channel in unit tests, which must not probe whatever device
/// the test host happens to have (nor latch a slow one wedged for the rest
/// of the process).
type HwSpawner = fn(
    HwBackend,
    SendCodecpar,
    InputSpec,
    Option<MotionConfig>,
) -> Result<mpsc::Receiver<Result<HwDecoder>>>;

/// Where the probe stands; advanced by [`DeferredHwDecoder::consider`], at
/// most one step of real work per access unit.
enum Probe {
    /// Accumulating parameter sets — some cameras send SPS and PPS in
    /// separate access units, and demanding both from one would settle on
    /// software for a stream whose hardware was fine.
    Gathering {
        sps: Option<Vec<u8>>,
        pps: Option<Vec<u8>>,
        aus_left: u32,
    },
    /// The pair is complete; waiting for `backends[next]`'s turn (the
    /// per-backend claim may be another camera's for a moment).
    Claiming { extradata: Vec<u8>, next: usize },
    /// One open is running on its thread. The claim rides along so every
    /// exit — success, failure, timeout, this decoder dropped mid-probe —
    /// releases the backend.
    Opening {
        extradata: Vec<u8>,
        current: usize,
        rx: mpsc::Receiver<Result<HwDecoder>>,
        started: Instant,
        claim: ProbeClaim,
    },
    /// Opened; holding for the next keyframe so the handover is clean.
    /// Boxed: a decoder is hundreds of bytes, the other states are slim.
    Ready(Box<HwDecoder>),
}

struct PendingHw {
    backends: Vec<HwBackend>,
    spawner: HwSpawner,
    codecpar: SendCodecpar,
    spec: InputSpec,
    motion: Option<MotionConfig>,
    /// `--decoder` named a specific backend under [`NamedFallback::Refused`],
    /// so settling on software is a refusal rather than a fallback. The
    /// check upstream (`require_named_hardware`) can only see the open,
    /// which is before this decides — the probe enforces it itself.
    required: bool,
    probe: Probe,
}

/// What one advance of the probe decided.
enum Advance {
    /// Nothing to do until a later access unit; the probe stays.
    Wait,
    /// The probe is over without a hardware decoder.
    Settle(&'static str),
    /// The hardware decoder takes over, starting at this access unit.
    Switch(Box<HwDecoder>),
}

impl DeferredHwDecoder {
    fn new(
        sw: SwDecoder,
        backends: Vec<HwBackend>,
        spawner: HwSpawner,
        codecpar: AVCodecParameters,
        spec: InputSpec,
        motion: Option<MotionConfig>,
        required: bool,
    ) -> Self {
        let names: Vec<&str> = backends.iter().map(|b| b.name()).collect();
        note!(
            "hardware decode deferred: waiting for in-band SPS/PPS to try {}",
            names.join(", ")
        );
        Self {
            active: ActiveDecoder::Sw(sw),
            pending: Some(PendingHw {
                backends,
                spawner,
                codecpar: SendCodecpar(codecpar),
                spec,
                motion,
                required,
                probe: Probe::Gathering {
                    sps: None,
                    pps: None,
                    aus_left: DEFER_AU_LIMIT,
                },
            }),
        }
    }

    /// Advance the probe against one access unit — never blocking. On
    /// switch the active decoder is the hardware one and the caller's
    /// packet goes to it; on refusal (named backend, no open) the error is
    /// permanent.
    fn consider(&mut self, au: &[u8]) -> Result<()> {
        let Some(mut pending) = self.pending.take() else {
            return Ok(());
        };
        match pending.advance(au) {
            Ok(Advance::Wait) => {
                self.pending = Some(pending);
                Ok(())
            }
            Ok(Advance::Switch(decoder)) => {
                self.active = ActiveDecoder::Hw(*decoder);
                Ok(())
            }
            Ok(Advance::Settle(why)) => self.settle_on_software(&pending, why),
            Err(e) => {
                // A spawn or codecpar-clone failure is a host problem no
                // later access unit will cure.
                note!("hardware probe abandoned: {e:#}");
                self.settle_on_software(&pending, "the probe could not run")
            }
        }
    }

    /// The probe is over without a hardware decoder: keep software under
    /// `auto`, refuse when the operator named a backend.
    fn settle_on_software(&mut self, pending: &PendingHw, why: &str) -> Result<()> {
        if pending.required {
            let named = pending.backends.first().map_or("hardware", |b| b.name());
            let reason = format!(
                "decoder {named} was named but did not open ({why}), and this path \
                 refuses the software fallback — name decoder: auto to accept \
                 software decode"
            );
            note!("{reason}");
            self.active = ActiveDecoder::Refused(reason.clone());
            return Err(DecoderRefusal(reason).into());
        }
        note!("no hardware decoder opened ({why}); staying with software decode");
        Ok(())
    }
}

impl PendingHw {
    /// One step of the probe. Loops only over transitions that are pure
    /// state (a failed backend advancing to the next, a claim acquired and
    /// spawned, a preloaded result); every real wait exits with
    /// [`Advance::Wait`] until the next access unit.
    fn advance(&mut self, au: &[u8]) -> Result<Advance> {
        let mut completed = None;
        if let Probe::Gathering { sps, pps, aus_left } = &mut self.probe {
            let (in_sps, in_pps) = parameter_sets(au);
            if let Some(in_sps) = in_sps {
                *sps = Some(in_sps);
            }
            if let Some(in_pps) = in_pps {
                *pps = Some(in_pps);
            }
            if let (Some(sps), Some(pps)) = (sps.as_deref(), pps.as_deref()) {
                completed = Some(extradata_from(sps, pps));
            } else {
                *aus_left -= 1;
                if *aus_left == 0 {
                    return Ok(Advance::Settle("no access unit carried SPS/PPS in band"));
                }
                return Ok(Advance::Wait);
            }
        }
        if let Some(extradata) = completed {
            self.probe = Probe::Claiming { extradata, next: 0 };
        }
        // Each iteration owns the state outright — transitions are moves,
        // and a claim is released exactly where its `drop` is written. The
        // placeholder is only observable if a transition below panics, and
        // a fresh Gathering is a safe place to be left.
        loop {
            let placeholder = Probe::Gathering {
                sps: None,
                pps: None,
                aus_left: DEFER_AU_LIMIT,
            };
            match std::mem::replace(&mut self.probe, placeholder) {
                Probe::Gathering { .. } => unreachable!("handled above"),
                Probe::Claiming { extradata, next } => {
                    let Some(&backend) = self.backends.get(next) else {
                        return Ok(Advance::Settle("every backend refused this stream"));
                    };
                    if wedged(backend).load(Ordering::Relaxed) {
                        note!(
                            "hardware decoder {backend} unavailable: timed out earlier \
                             in this process; not probing it again"
                        );
                        self.probe = Probe::Claiming {
                            extradata,
                            next: next + 1,
                        };
                        continue;
                    }
                    let Some(claim) = ProbeClaim::take(backend) else {
                        // Another camera's probe holds the backend; its
                        // verdict (or the wedge latch) arrives within one
                        // deadline, and software decode covers the wait.
                        self.probe = Probe::Claiming { extradata, next };
                        return Ok(Advance::Wait);
                    };
                    // A `?` below drops `claim`, releasing the backend.
                    let mut clone = clone_codecpar(&self.codecpar.0)?;
                    set_extradata(&mut clone, &extradata)?;
                    let rx = (self.spawner)(backend, SendCodecpar(clone), self.spec, self.motion)?;
                    self.probe = Probe::Opening {
                        extradata,
                        current: next,
                        rx,
                        started: Instant::now(),
                        claim,
                    };
                }
                Probe::Opening {
                    extradata,
                    current,
                    rx,
                    started,
                    claim,
                } => {
                    let backend = self.backends[current];
                    let failed = match rx.try_recv() {
                        Ok(Ok(decoder)) => {
                            drop(claim);
                            self.probe = Probe::Ready(Box::new(decoder));
                            continue;
                        }
                        Ok(Err(e)) => e,
                        Err(mpsc::TryRecvError::Empty) => {
                            if started.elapsed() < HW_OPEN_DEADLINE {
                                self.probe = Probe::Opening {
                                    extradata,
                                    current,
                                    rx,
                                    started,
                                    claim,
                                };
                                return Ok(Advance::Wait);
                            }
                            // Latched before the claim drops, so a waiter
                            // that grabs the backend next sees the verdict
                            // rather than spawning its own doomed open.
                            wedged(backend).store(true, Ordering::Relaxed);
                            anyhow!(
                                "did not open within {}s — abandoned as wedged, and \
                                 not probed again in this process",
                                HW_OPEN_DEADLINE.as_secs()
                            )
                        }
                        // The thread can only drop `tx` without sending by
                        // dying first.
                        Err(mpsc::TryRecvError::Disconnected) => {
                            anyhow!("the open thread panicked before answering")
                        }
                    };
                    drop(claim);
                    note!("hardware decoder {backend} unavailable: {failed:#}");
                    self.probe = Probe::Claiming {
                        extradata,
                        next: current + 1,
                    };
                }
                Probe::Ready(decoder) => {
                    // Hand over at a keyframe so the hardware decoder starts
                    // where a decoder may; software carries every frame
                    // until then, so nothing is lost in between.
                    if contains_idr(au) {
                        return Ok(Advance::Switch(decoder));
                    }
                    self.probe = Probe::Ready(decoder);
                    return Ok(Advance::Wait);
                }
            }
        }
    }
}

/// Whether an access unit carries an IDR slice (NAL type 5) — the clean
/// start a fresh decoder needs.
fn contains_idr(au: &[u8]) -> bool {
    annexb_nals(au)
        .iter()
        .any(|nal| nal.first().is_some_and(|byte| byte & 0x1f == 5))
}

impl Decoder for DeferredHwDecoder {
    fn send_packet(&mut self, packet: &rsmpeg::avcodec::AVPacket) -> Result<()> {
        // An empty packet carries nothing to scan and should not run down
        // the probe's patience.
        if self.pending.is_some() && !packet.data.is_null() && packet.size > 0 {
            // SAFETY: libavcodec pairs a non-null data with its size.
            let au = unsafe { slice::from_raw_parts(packet.data, packet.size as usize) };
            self.consider(au)?;
        }
        match &mut self.active {
            ActiveDecoder::Sw(decoder) => decoder.send_packet(packet),
            ActiveDecoder::Hw(decoder) => decoder.send_packet(packet),
            ActiveDecoder::Refused(reason) => Err(DecoderRefusal(reason.clone()).into()),
        }
    }

    fn receive_frame(&mut self) -> Result<Option<AVFrame>> {
        match &mut self.active {
            ActiveDecoder::Sw(decoder) => decoder.receive_frame(),
            ActiveDecoder::Hw(decoder) => decoder.receive_frame(),
            ActiveDecoder::Refused(_) => Ok(None),
        }
    }

    fn to_tensor(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<Sampled>> {
        match &mut self.active {
            ActiveDecoder::Sw(decoder) => decoder.to_tensor(frame, pts_ns),
            ActiveDecoder::Hw(decoder) => decoder.to_tensor(frame, pts_ns),
            ActiveDecoder::Refused(_) => Ok(None),
        }
    }

    fn to_rgb(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<RgbSampled>> {
        match &mut self.active {
            ActiveDecoder::Sw(decoder) => decoder.to_rgb(frame, pts_ns),
            ActiveDecoder::Hw(decoder) => decoder.to_rgb(frame, pts_ns),
            ActiveDecoder::Refused(_) => Ok(None),
        }
    }

    fn hw_backend(&self) -> Option<HwBackend> {
        match &self.active {
            ActiveDecoder::Hw(decoder) => decoder.hw_backend(),
            _ => None,
        }
    }

    fn hw_pending(&self) -> bool {
        self.pending.is_some()
    }
}

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
    /// The GPU fast path for NV12 frames, where the build carries one.
    /// Tri-state so the EGL probe runs once per scaler, not per frame, and a
    /// mid-run GL failure degrades to swscale permanently rather than
    /// retrying into the same fault at frame rate.
    #[cfg(feature = "gles")]
    gl: GlState,
}

#[cfg(feature = "gles")]
enum GlState {
    Untried,
    Ready(Box<crate::glscale::GlScaler>),
    Off,
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
    pub fn new(spec: InputSpec, motion: Option<MotionConfig>) -> Result<Self> {
        Ok(Self {
            spec,
            target: None,
            motion: motion.map(MotionDetector::new),
            #[cfg(feature = "gles")]
            gl: GlState::Untried,
        })
    }

    /// The GPU path, or `None` for "use swscale" — not-NV12, no usable GL
    /// stack, or a GL fault mid-run (noted once, then permanently off: the
    /// remedy for a broken driver is not retrying it thirty times a second).
    ///
    /// This is where v4l2m2m's ~27 ms uncached-read floor is what remains of
    /// the ~50 ms CPU conversion: the upload's single sequential read of the
    /// capture buffer is unavoidable on this route, and everything after it —
    /// scale, YUV→RGB — moves to the GPU (`research/board-first-light.md`).
    /// The output is not bit-identical to swscale's (GPU bilinear, shader
    /// BT.601), so the x86 parity harness deliberately builds without this
    /// feature; on-board acceptance is detection sanity plus the perf win.
    #[cfg(feature = "gles")]
    fn gl_scale(&mut self, frame: &AVFrame, source: InputSize) -> Option<(Vec<u8>, Fit)> {
        if frame.format != ffi::AV_PIX_FMT_NV12 {
            return None;
        }
        if matches!(self.gl, GlState::Untried) {
            // Off *before* the probe: if anything below unwinds, the state
            // must not read as still-untried, or the next frame repeats the
            // fault at frame rate.
            self.gl = GlState::Off;
            self.gl = match crate::glscale::GlScaler::new(self.spec.size) {
                Ok(scaler) => {
                    note!("scaler: GPU (GLES) path active for NV12 frames");
                    GlState::Ready(Box::new(scaler))
                }
                Err(error) => {
                    note!("scaler: GPU path unavailable ({error:#}); staying on swscale");
                    GlState::Off
                }
            };
        }
        let GlState::Ready(scaler) = &mut self.gl else {
            return None;
        };
        let frame_size = source_size(frame).ok()?;
        let fit = self.spec.resize.fit(self.spec.size, source);
        let (y, y_stride, uv, uv_stride) = nv12_planes(frame)?;
        match scaler.scale_nv12(y, y_stride, uv, uv_stride, frame_size, fit.inner) {
            Ok(rgb) => Some((rgb, fit)),
            Err(error) => {
                note!("scaler: GPU scale failed ({error:#}); degrading to swscale");
                self.gl = GlState::Off;
                None
            }
        }
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

    pub fn tensor_from(
        &mut self,
        frame: &AVFrame,
        source: InputSize,
        pts_ns: Option<i64>,
    ) -> Result<Sampled> {
        let spec = self.spec;
        #[cfg(feature = "gles")]
        if let Some((rgb, fit)) = self.gl_scale(frame, source) {
            let stride = fit.inner.w * 3;
            let motion = observe(&mut self.motion, &rgb, stride, fit.inner, pts_ns);
            return Ok(Sampled {
                input: ModelInput {
                    tensor: pack_chw(&rgb, stride, fit, spec),
                    projection: fit.projection(source),
                },
                motion,
            });
        }
        self.ensure_target(frame, source)?;
        let target = self.target.as_mut().expect("target was just set");
        let fit = target.fit;
        let (plane, stride) = target.scale(frame)?;
        let motion = observe(&mut self.motion, plane, stride, fit.inner, pts_ns);
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
    pub fn rgb_from(
        &mut self,
        frame: &AVFrame,
        source: InputSize,
        pts_ns: Option<i64>,
    ) -> Result<RgbSampled> {
        #[cfg(feature = "gles")]
        if let Some((rgb, fit)) = self.gl_scale(frame, source) {
            let motion = observe(&mut self.motion, &rgb, fit.inner.w * 3, fit.inner, pts_ns);
            return Ok(RgbSampled {
                rgb,
                content: fit.inner,
                source,
                motion,
            });
        }
        self.ensure_target(frame, source)?;
        let target = self.target.as_mut().expect("target was just set");
        let fit = target.fit;
        let (plane, stride) = target.scale(frame)?;
        let motion = observe(&mut self.motion, plane, stride, fit.inner, pts_ns);
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
/// The two NV12 planes as slices, or `None` for a frame that does not carry
/// both — handed back to the caller as "use swscale", never an error, because
/// a frame shape this function does not recognise (negative linesizes
/// included: ffmpeg spells bottom-up images that way, and `try_from` refuses
/// them here) is exactly what the CPU path exists to handle.
#[cfg(feature = "gles")]
fn nv12_planes(frame: &AVFrame) -> Option<(&[u8], usize, &[u8], usize)> {
    let h = usize::try_from(frame.height).ok()?;
    let w = usize::try_from(frame.width).ok()?;
    let y_stride = usize::try_from(frame.linesize[0]).ok()?;
    let uv_stride = usize::try_from(frame.linesize[1]).ok()?;
    // Odd dimensions go to swscale: the GL upload takes floor(w/2) chroma
    // columns and floor-half rows, silently dropping the frame's last chroma
    // sample where swscale resolves the siting properly. (The slice claims
    // below stay within bounds either way — stride >= width bounds each claim
    // by stride * rows, the minimum allocation — so this is a quality gate,
    // not a safety one.)
    if h % 2 != 0 || w % 2 != 0 {
        return None;
    }
    if frame.data[0].is_null() || frame.data[1].is_null() || y_stride < w || uv_stride < w {
        return None;
    }
    // SAFETY: the pointers were just null-checked and the frame outlives the
    // returned borrows. The last row is claimed at `width`, not `stride`:
    // libavcodec's `apply_cropping` can shift `data[0]` right, and
    // `stride * height` would then end past the allocation by exactly the
    // crop — `stride * (h - 1) + width` is what every row-wise reader
    // (GL upload included) actually touches.
    unsafe {
        let uv_rows = h.div_ceil(2);
        Some((
            slice::from_raw_parts(frame.data[0] as *const u8, y_stride * (h - 1) + w),
            y_stride,
            slice::from_raw_parts(frame.data[1] as *const u8, uv_stride * (uv_rows - 1) + w),
            uv_stride,
        ))
    }
}

fn observe(
    motion: &mut Option<MotionDetector>,
    plane: &[u8],
    stride: usize,
    content: InputSize,
    pts_ns: Option<i64>,
) -> Option<MotionVerdict> {
    motion
        .as_mut()
        .map(|detector| detector.observe(&GrayThumb::from_rgb24(plane, stride, content), pts_ns))
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
            rgb: RgbScaler::new(spec, motion)?,
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

    fn to_tensor(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<Sampled>> {
        let source = source_size(&frame)?;
        self.rgb.tensor_from(&frame, source, pts_ns).map(Some)
    }

    fn to_rgb(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<RgbSampled>> {
        let source = source_size(&frame)?;
        self.rgb.rgb_from(&frame, source, pts_ns).map(Some)
    }

    fn hw_backend(&self) -> Option<HwBackend> {
        None
    }
}

/// Bound what a stream's SPS can make libavcodec allocate.
pub fn cap_frame_size(ctx: &mut AVCodecContext) {
    unsafe { ctx.deref_mut() }.max_pixels = MAX_PIXELS;
}

/// Packed RGB24 rows (`stride` may exceed the row width) -> CHW values,
/// placed into the model's input rectangle according to `fit`: f32 for the
/// float graph-IO contract, u8 codes when `spec.input_quant` says the
/// artifact takes its input quantized.
///
/// The scale target is always RGB24 because that is one pixel format for
/// swscale to reach from anything; the encoding decides only what happens on
/// the way into the planes — the affine, and for BGR which source byte each
/// plane draws from.
///
/// The padding goes through the same encoding as the pixels: the model was
/// trained on a padded picture, not on an out-of-range constant. On the u8
/// path that means encode *then quantize* — with a non-identity input scale,
/// writing the raw pad byte would poison every border. Under a stretch
/// `fit.inner` *is* the input, so there is no padding and the fill is
/// skipped rather than written and immediately overwritten.
fn pack_chw(plane: &[u8], stride: usize, fit: Fit, spec: InputSpec) -> TensorValues {
    let size = spec.size;
    let packing = spec.encoding.packing();
    let plane_len = size.w * size.h;
    let (ox, oy) = fit.offset;
    match spec.input_quant {
        None => {
            let mut tensor = vec![0f32; size.tensor_len()];
            if fit.inner != size {
                for (p, chunk) in tensor.chunks_exact_mut(plane_len).enumerate() {
                    chunk.fill(packing.value(p, fit.pad));
                }
            }
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
            TensorValues::F32(tensor)
        }
        // Same shape of loop over a per-plane byte->code table
        // (`quantized_lut`): the quantizer has 256 inputs per plane, so the
        // pixel loop is a lookup — and for RawBgr with identity qparams
        // (the 0..255 case) the table degenerates to a pure byte shuffle.
        Some(quant) => {
            let luts: [[u8; 256]; 3] = std::array::from_fn(|p| packing.quantized_lut(p, quant));
            let mut tensor = vec![0u8; size.tensor_len()];
            if fit.inner != size {
                for (p, chunk) in tensor.chunks_exact_mut(plane_len).enumerate() {
                    chunk.fill(luts[p][fit.pad as usize]);
                }
            }
            for y in 0..fit.inner.h {
                let row = &plane[y * stride..y * stride + fit.inner.w * 3];
                for x in 0..fit.inner.w {
                    let px = &row[x * 3..x * 3 + 3];
                    let at = (oy + y) * size.w + ox + x;
                    for (p, source) in packing.source.iter().enumerate() {
                        tensor[p * plane_len + at] = luts[p][px[*source] as usize];
                    }
                }
            }
            TensorValues::U8(tensor)
        }
    }
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
    // The refusal `source_size` made for the unsplit path, restated at the
    // boundary: a projection built for a zero-sized source divides by zero,
    // and under `Stretch` nothing downstream would notice — every box would
    // cross back as inf/NaN.
    if source.w == 0 || source.h == 0 {
        bail!("source geometry {source} has no usable dimension");
    }
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
            let pts_ns = frame_pts(&frame).map(|pts| rescale_ns(pts, time_base));
            // A frame we cannot convert costs one sample, not the process:
            // sws has no path for a mid-stream format change, a filter graph
            // rebuild can fail transiently, and restarting is expensive (model
            // load plus up to a minute of open retries).
            let Sampled { input, motion } = match decoder.to_tensor(frame, pts_ns) {
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

/// `time_base` ticks onto the nanosecond clock the motion detector's
/// calibration window is measured on ([`crate::motion::MotionDetector`]) —
/// the NIF path's frames already arrive dated in nanoseconds
/// (`Membrane.Time`), so nanoseconds are the one clock both producers can
/// spell a frame's age in.
pub fn rescale_ns(pts: i64, time_base: AVRational) -> i64 {
    av_rescale_q(pts, time_base, NS_TIMEBASE)
}

const NS_TIMEBASE: AVRational = AVRational {
    num: 1,
    den: 1_000_000_000,
};

/// [`rescale_90k`] over a caller-supplied `(num, den)`, refused rather than
/// trusted: `av_rescale_q` divides by the denominator and reads the sign of
/// both, so a zero or negative term is not a slightly wrong timestamp but an
/// arithmetic fault inside libavutil.
///
/// Public so a consumer with no libav of its own (the inference NIF) can
/// rescale a boundary-crossing pts without naming an [`AVRational`].
pub fn rescale_90k_checked(pts: i64, (num, den): (i32, i32)) -> Result<i64> {
    if num <= 0 || den <= 0 {
        bail!("time base {num}/{den} must be positive");
    }
    Ok(rescale_90k(pts, AVRational { num, den }))
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
            input_quant: None,
        }
    }

    fn unit_rgb(size: InputSize) -> InputSpec {
        spec(size, TensorEncoding::UnitRgb, ResizePolicy::Stretch)
    }

    /// The float arm's payload; a spec without `input_quant` packing codes
    /// would be the packer picking the wrong contract.
    fn f32s(tensor: TensorValues) -> Vec<f32> {
        match tensor {
            TensorValues::F32(values) => values,
            TensorValues::U8(_) => panic!("expected an f32 pack"),
        }
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
        f32s(pack_chw(
            plane,
            stride,
            ResizePolicy::Stretch.fit(size, size),
            spec,
        ))
    }

    #[test]
    fn rescales_pts_to_90khz() {
        let mut frame = AVFrame::new();
        frame.set_pts(1000);
        assert_eq!(pts_90k(&frame, PTS_TIMEBASE), 1000);
        assert_eq!(pts_90k(&frame, AVRational { num: 1, den: 1000 }), 90_000);
    }

    #[test]
    fn rescales_pts_to_nanoseconds() {
        // The motion detector's clock: a reversed rational or a wrong
        // NS_TIMEBASE here would stretch or shrink every calibration window
        // silently, so the conversion is pinned the way the 90 kHz one is.
        assert_eq!(
            rescale_ns(1000, AVRational { num: 1, den: 1000 }),
            1_000_000_000
        );
        // 450 000 RTP ticks is exactly the five-second calibration boundary.
        assert_eq!(rescale_ns(450_000, PTS_TIMEBASE), 5_000_000_000);
        // A caller already on the nanosecond clock passes through unchanged.
        assert_eq!(rescale_ns(123_456_789, NS_TIMEBASE), 123_456_789);
    }

    #[test]
    fn the_checked_rescale_refuses_the_time_bases_that_would_fault_libavutil() {
        for bad in [(0, 90_000), (1, 0), (-1, 90_000), (1, -90_000)] {
            assert!(rescale_90k_checked(1000, bad).is_err(), "{bad:?}");
        }
        assert_eq!(rescale_90k_checked(1000, (1, 1000)).unwrap(), 90_000);
        assert_eq!(rescale_90k_checked(1000, (1, 90_000)).unwrap(), 1000);
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
        let mut unsplit = RgbScaler::new(spec, motion).unwrap();
        let whole = unsplit.tensor_from(&frame, source, Some(0)).unwrap();

        let mut split = RgbScaler::new(spec, motion).unwrap();
        let sampled = split.rgb_from(&frame, source, Some(0)).unwrap();
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

        // A zero-sized source is refused before any fit is derived from it:
        // under `Stretch` the fit never reads the source, so without this
        // check a correctly-sized payload would sail through and the
        // projection would divide by zero — inf/NaN boxes, silently.
        let stretch = InputSpec {
            resize: ResizePolicy::Stretch,
            ..spec
        };
        let plane = vec![0u8; stretch.size.tensor_len()];
        for zeroed in [InputSize { w: 0, h: 80 }, InputSize { w: 100, h: 0 }] {
            let error = model_input_from_rgb(&plane, stretch.size, zeroed, stretch).unwrap_err();
            assert!(
                error.to_string().contains("no usable dimension"),
                "{error:#}"
            );
        }

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
        let decoder = SwDecoder::open(&codecpar, unit_rgb(InputSize::square(640)), None).unwrap();
        assert_eq!(decoder.ctx.max_pixels, MAX_PIXELS);
        // Generous enough for 8K, small enough that a 16384x16384 SPS fails.
        const { assert!(MAX_PIXELS > 7680 * 4320) };
        const { assert!(MAX_PIXELS < 16384 * 16384) };
    }

    fn h264_codecpar() -> AVCodecParameters {
        let mut codecpar = AVCodecParameters::new();
        unsafe {
            let raw = codecpar.deref_mut();
            raw.codec_id = ffi::AV_CODEC_ID_H264;
            raw.codec_type = ffi::AVMEDIA_TYPE_VIDEO;
        }
        codecpar
    }

    const SPS: &[u8] = &[0x67, 0x64, 0x00, 0x1f];
    const PPS: &[u8] = &[0x68, 0xee];
    const IDR: &[u8] = &[0x65, 0x88];

    /// Mixed three- and four-byte start codes, the way cameras actually
    /// interleave them; the four-byte code after the PPS also exercises the
    /// trailing-zero trim.
    fn keyframe_au() -> Vec<u8> {
        [&[0, 0, 0, 1][..], SPS, &[0, 0, 1], PPS, &[0, 0, 0, 1], IDR].concat()
    }

    #[test]
    fn parameter_sets_reads_both_kinds_of_start_code() {
        let (sps, pps) = parameter_sets(&keyframe_au());
        assert_eq!(sps.as_deref(), Some(SPS));
        assert_eq!(pps.as_deref(), Some(PPS));

        let idr_only = [&[0, 0, 0, 1][..], IDR].concat();
        assert_eq!(parameter_sets(&idr_only), (None, None));
        assert_eq!(parameter_sets(&[]), (None, None));

        let expected = [&[0, 0, 0, 1][..], SPS, &[0, 0, 0, 1], PPS].concat();
        assert_eq!(extradata_from(SPS, PPS), expected);
    }

    #[test]
    fn annexb_nals_survive_malformed_edges() {
        // A start code at the very end yields an empty NAL; empty NALs have
        // no header byte for `parameter_sets` to read.
        assert_eq!(annexb_nals(&[0, 0, 1]), vec![&[] as &[u8]]);
        assert_eq!(parameter_sets(&[0, 0, 1]), (None, None));
        // Zeros between codes belong to no payload.
        let zeros = [0u8, 0, 1, 0, 0, 0, 1, 0x65, 0x88];
        assert_eq!(annexb_nals(&zeros), vec![&[] as &[u8], &[0x65, 0x88]]);
        // No start code at all: nothing.
        assert!(annexb_nals(&[0x65, 0x88, 0x00]).is_empty());
    }

    #[test]
    fn cloned_codecpar_keeps_fidelity_and_takes_extradata() {
        let mut codecpar = h264_codecpar();
        unsafe {
            let raw = codecpar.deref_mut();
            raw.width = 640;
            raw.height = 360;
            raw.profile = 100;
            raw.level = 31;
        }
        let mut clone = clone_codecpar(&codecpar).unwrap();
        let extradata = extradata_from(SPS, PPS);
        set_extradata(&mut clone, &extradata).unwrap();
        assert_eq!(clone.width, 640);
        assert_eq!(clone.height, 360);
        // The fields the deferred probe never touches ride the copy —
        // the parity the old field-by-field rebuild silently dropped.
        assert_eq!(clone.profile, 100);
        assert_eq!(clone.level, 31);
        let carried =
            unsafe { slice::from_raw_parts(clone.extradata, clone.extradata_size as usize) };
        assert_eq!(carried, extradata);
        // The original is untouched.
        assert!(codecpar.extradata.is_null());
    }

    /// Deterministic failure: a unit test must not probe whatever device
    /// the host happens to have, and must never reach the process-wide
    /// wedge latch. The result is preloaded, so one `consider` sees it.
    fn failing_spawn(
        _: HwBackend,
        _: SendCodecpar,
        _: InputSpec,
        _: Option<MotionConfig>,
    ) -> Result<mpsc::Receiver<Result<HwDecoder>>> {
        let (tx, rx) = mpsc::channel();
        tx.send(Err(anyhow!("unit tests never probe the host's devices")))
            .unwrap();
        Ok(rx)
    }

    /// An open that never answers: the sender leaks, so `try_recv` reads
    /// Empty forever — the in-flight shape, without a thread or a device.
    fn stuck_spawn(
        _: HwBackend,
        _: SendCodecpar,
        _: InputSpec,
        _: Option<MotionConfig>,
    ) -> Result<mpsc::Receiver<Result<HwDecoder>>> {
        let (tx, rx) = mpsc::channel();
        std::mem::forget(tx);
        Ok(rx)
    }

    /// Advance until the probe decides. Bounded retries, not one call: the
    /// claim slots are process-wide, so another test's momentary claim on
    /// the same backend can legitimately answer an advance with "wait".
    fn settle(decoder: &mut DeferredHwDecoder, au: &[u8]) {
        for _ in 0..100 {
            decoder.consider(au).unwrap();
            if !decoder.hw_pending() {
                return;
            }
        }
        panic!("the probe never settled");
    }

    /// Each test drives its own backend so the process-wide claim slots
    /// never collide across concurrently running tests.
    fn deferred(backends: Vec<HwBackend>, spawner: HwSpawner, required: bool) -> DeferredHwDecoder {
        let codecpar = h264_codecpar();
        let spec = unit_rgb(InputSize::square(640));
        let sw = SwDecoder::open(&codecpar, spec, None).unwrap();
        DeferredHwDecoder::new(
            sw,
            backends,
            spawner,
            clone_codecpar(&codecpar).unwrap(),
            spec,
            None,
            required,
        )
    }

    #[test]
    fn a_deferred_probe_settles_on_software_when_no_backend_opens() {
        // The injected spawner fails every backend, so an unnamed probe
        // keeps the software decoder it was born with.
        let mut decoder = deferred(vec![HwBackend::Vaapi], failing_spawn, false);
        assert!(decoder.hw_pending());
        settle(&mut decoder, &keyframe_au());
        assert!(decoder.hw_backend().is_none());
        assert!(matches!(decoder.active, ActiveDecoder::Sw(_)));
    }

    #[test]
    fn a_deferred_probe_accumulates_parameter_sets_across_access_units() {
        let mut decoder = deferred(vec![HwBackend::Qsv], failing_spawn, false);
        let sps_alone = [&[0, 0, 0, 1][..], SPS].concat();
        decoder.consider(&sps_alone).unwrap();
        // Half a pair is not a decision.
        assert!(decoder.hw_pending());
        let pps_alone = [&[0, 0, 0, 1][..], PPS].concat();
        // The PPS completes the pair: the probe runs (and settles on
        // software, every spawned open failing).
        settle(&mut decoder, &pps_alone);
    }

    #[test]
    fn a_deferred_probe_gives_up_after_enough_bare_access_units() {
        let mut decoder = deferred(vec![HwBackend::Vaapi], failing_spawn, false);
        let idr_only = [&[0, 0, 0, 1][..], IDR].concat();
        for _ in 0..DEFER_AU_LIMIT - 1 {
            decoder.consider(&idr_only).unwrap();
            assert!(decoder.hw_pending());
        }
        decoder.consider(&idr_only).unwrap();
        assert!(!decoder.hw_pending());
        assert!(matches!(decoder.active, ActiveDecoder::Sw(_)));
    }

    #[test]
    fn one_probe_per_backend_and_a_dropped_probe_frees_its_claim() {
        // A holds the V4l2 claim with an open that never answers; B, on the
        // same backend, must keep software-decoding and wait its turn
        // rather than spawn a second probe or block.
        let mut holder = deferred(vec![HwBackend::V4l2], stuck_spawn, false);
        holder.consider(&keyframe_au()).unwrap();
        assert!(holder.hw_pending());

        let mut waiter = deferred(vec![HwBackend::V4l2], failing_spawn, false);
        waiter.consider(&keyframe_au()).unwrap();
        assert!(waiter.hw_pending(), "the claim is the holder's");

        // The holder's camera closes mid-probe; its Drop releases the
        // claim, and the waiter's next access unit runs (and settles).
        drop(holder);
        waiter.consider(&keyframe_au()).unwrap();
        assert!(!waiter.hw_pending());
        assert!(matches!(waiter.active, ActiveDecoder::Sw(_)));
    }

    /// One tightly packed AVPacket around `data`, as `send_packet` sees them.
    fn packet(data: &[u8]) -> rsmpeg::avcodec::AVPacket {
        let mut packet = rsmpeg::avcodec::AVPacket::new();
        // SAFETY: av_new_packet sizes the buffer (plus libav's padding) and
        // the copy stays within `data.len()`.
        unsafe {
            assert!(ffi::av_new_packet(packet.as_mut_ptr(), data.len() as i32) >= 0);
            std::ptr::copy_nonoverlapping(data.as_ptr(), (*packet.as_mut_ptr()).data, data.len());
        }
        packet
    }

    #[test]
    fn a_named_deferred_backend_that_cannot_open_refuses_software() {
        let mut decoder = deferred(vec![HwBackend::Nvdec], failing_spawn, true);
        let error = decoder.consider(&keyframe_au()).unwrap_err();
        assert!(error.to_string().contains("nvdec was named"), "{error:#}");
        // Permanent, and typed: the embedder tells this refusal apart from
        // tolerated decode errors by downcast, on every later packet.
        let later = decoder.send_packet(&packet(IDR)).unwrap_err();
        assert!(
            later.downcast_ref::<DecoderRefusal>().is_some(),
            "{later:#}"
        );
        // The drain contract stays honest: no frames, no busy-wait fuel.
        assert!(decoder.receive_frame().unwrap().is_none());
        assert!(!decoder.hw_pending());
        assert!(decoder.hw_backend().is_none());
    }

    #[test]
    fn an_unnamed_deferred_settle_stays_quietly_on_software() {
        let mut decoder = deferred(vec![HwBackend::Vaapi], failing_spawn, false);
        settle(&mut decoder, &keyframe_au());
        // Software decode continues through the trait after the settle: the
        // synthetic parameter sets are garbage to a real parser, but that is
        // a tolerated decode error, never a refusal.
        if let Err(error) = decoder.send_packet(&packet(&keyframe_au())) {
            assert!(
                error.downcast_ref::<DecoderRefusal>().is_none(),
                "{error:#}"
            );
        }
    }

    #[test]
    fn auto_with_no_extradata_defers_the_hardware_probe() {
        let codecpar = h264_codecpar();
        let decoder = open(
            DecoderKind::Auto,
            &codecpar,
            unit_rgb(InputSize::square(640)),
            None,
            NamedFallback::Refused,
        )
        .unwrap();
        assert_eq!(
            decoder.hw_pending(),
            !probe_order(DecoderKind::Auto).is_empty()
        );
        assert!(decoder.hw_backend().is_none());
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
        for px in plane.as_chunks_mut::<3>().0 {
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
        let tensor = f32s(pack_chw(
            &plane,
            stride,
            fit,
            spec(input, TensorEncoding::RawBgr, resize),
        ));

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
        let tensor = f32s(pack_chw(
            &plane,
            stride,
            fit,
            spec(input, TensorEncoding::UnitRgb, resize),
        ));
        let first_pad = fit.inner.h * input.w;
        assert!(
            (tensor[first_pad] - 114.0 / 255.0).abs() < 1e-6,
            "{}",
            tensor[first_pad]
        );
        assert!(tensor.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    /// The u8 arm with identity qparams (the RawBgr 0..255 case every
    /// converted artifact has today): the pack is the BGR byte shuffle plus
    /// the raw pad byte, no float math surviving into the tensor.
    #[test]
    fn a_u8_pack_with_identity_qparams_is_the_byte_shuffle() {
        use crate::infer::QuantParams;
        let input = InputSize::square(64);
        let resize = ResizePolicy::Letterbox { pad: 114 };
        let fit = resize.fit(input, InputSize { w: 128, h: 64 });
        let stride = fit.inner.w * 3;
        // Solid RGB (10, 20, 30): plane 0 must read B=30, plane 2 R=10.
        let plane: Vec<u8> = (0..stride * fit.inner.h / 3)
            .flat_map(|_| [10u8, 20, 30])
            .collect();
        let mut spec = spec(input, TensorEncoding::RawBgr, resize);
        spec.input_quant = Some(QuantParams {
            scale: 1.0,
            zero_point: 0,
        });
        let tensor = match pack_chw(&plane, stride, fit, spec) {
            TensorValues::U8(codes) => codes,
            TensorValues::F32(_) => panic!("input_quant must pack codes"),
        };
        assert_eq!(tensor.len(), input.tensor_len());
        let plane_len = input.w * input.h;
        assert_eq!(tensor[0], 30, "plane 0 is blue");
        assert_eq!(tensor[plane_len], 20);
        assert_eq!(tensor[2 * plane_len], 10, "plane 2 is red");
        // Pad rows carry the identity-quantized pad code: the byte itself.
        assert_eq!(tensor[fit.inner.h * input.w], 114);
    }

    /// A non-identity input scale must quantize the pad through the same
    /// encode-then-quantize path as the pixels — writing the raw 114 would
    /// poison every border (research edge case, pinned here).
    #[test]
    fn a_u8_pad_goes_through_encode_then_quantize() {
        use crate::infer::QuantParams;
        let input = InputSize::square(64);
        let resize = ResizePolicy::Letterbox { pad: 114 };
        let fit = resize.fit(input, InputSize { w: 128, h: 64 });
        let stride = fit.inner.w * 3;
        let plane = vec![0u8; stride * fit.inner.h];
        let mut spec = spec(input, TensorEncoding::RawBgr, resize);
        spec.input_quant = Some(QuantParams {
            scale: 0.5,
            zero_point: 3,
        });
        let tensor = match pack_chw(&plane, stride, fit, spec) {
            TensorValues::U8(codes) => codes,
            TensorValues::F32(_) => panic!("input_quant must pack codes"),
        };
        // quantize(encode(114)) = 114/0.5 + 3 = 231, the exporter-pinned
        // value — not 114.
        assert_eq!(tensor[fit.inner.h * input.w], 231);
        // Content zeros quantize to the zero-point, not to 0.
        assert_eq!(tensor[0], 3);
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
