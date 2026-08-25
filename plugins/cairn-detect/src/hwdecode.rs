//! Hardware decode: decode on the video ASIC, keep surfaces in GPU memory.
//!
//! The whole point is what does *not* happen here: decoded surfaces stay on
//! the device at full frame rate, and only the samples that survive the
//! sample gate — `--sample-fps` frames a second, 5 by default — are scaled
//! to the model's input size *on the GPU* and then downloaded. Downloading
//! first and scaling on the CPU would move ~34 Mbps of full-resolution frames
//! through system memory and eat the entire saving, so a backend without a
//! GPU scaler is treated as unavailable rather than silently taking that
//! path.
//!
//! v4l2m2m is the exception on both counts, by the nature of the interface:
//! a stateful M2M codec decodes on the ASIC and hands back **system memory**
//! (`scale_filter()` is `None`, so nothing refuses it), and every sampled
//! frame is then scaled on the CPU — off an uncached capture buffer, which is
//! most of the per-camera CPU bill on such boards
//! (membrane-port `research/board-first-light.md`). It stays available
//! because ASIC decode is still the cheap half; making the scale cheap on
//! that path is its own work item (plan task 5.6).

use std::ffi::{CStr, CString};
use std::fmt;

use anyhow::{anyhow, bail, Context, Result};
use rsmpeg::avcodec::{AVCodec, AVCodecContext, AVCodecParameters, AVCodecRef};
use rsmpeg::avfilter::{AVFilter, AVFilterGraph, AVFilterInOut};
use rsmpeg::avutil::{AVFrame, AVHWDeviceContext};
use rsmpeg::error::RsmpegError;
use rsmpeg::ffi;

use crate::decode::{cap_frame_size, source_size, Decoder, RgbSampled, RgbScaler, Sampled};
use crate::infer::{InputSize, InputSpec};
use crate::motion::MotionConfig;
use crate::note;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HwBackend {
    Vaapi,
    Qsv,
    Nvdec,
    V4l2,
    #[cfg(target_os = "macos")]
    Videotoolbox,
}

/// Renders as the `--decoder` value, so log lines can be pasted back as a flag.
impl fmt::Display for HwBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl HwBackend {
    pub fn name(self) -> &'static str {
        match self {
            Self::Vaapi => "vaapi",
            Self::Qsv => "qsv",
            Self::Nvdec => "nvdec",
            Self::V4l2 => "v4l2",
            #[cfg(target_os = "macos")]
            Self::Videotoolbox => "videotoolbox",
        }
    }

    /// Device to open with `av_hwdevice_ctx_create`.
    ///
    /// `None` for v4l2m2m: it is a stateful M2M codec, not a device-context
    /// hwaccel — libavcodec drives the ASIC and hands back system memory.
    fn device_type(self) -> Option<ffi::AVHWDeviceType> {
        match self {
            Self::Vaapi => Some(ffi::AV_HWDEVICE_TYPE_VAAPI),
            Self::Qsv => Some(ffi::AV_HWDEVICE_TYPE_QSV),
            Self::Nvdec => Some(ffi::AV_HWDEVICE_TYPE_CUDA),
            Self::V4l2 => None,
            #[cfg(target_os = "macos")]
            Self::Videotoolbox => Some(ffi::AV_HWDEVICE_TYPE_VIDEOTOOLBOX),
        }
    }

    /// Decoder name suffix for backends that ship a wrapper codec rather than
    /// an hwaccel bolted onto the native decoder (`h264_qsv`, `h264_v4l2m2m`).
    fn decoder_suffix(self) -> Option<&'static str> {
        match self {
            Self::Qsv => Some("qsv"),
            Self::V4l2 => Some("v4l2m2m"),
            _ => None,
        }
    }

    /// GPU scaler filter. `None` means frames already land in system memory.
    fn scale_filter(self) -> Option<&'static str> {
        match self {
            Self::Vaapi => Some("scale_vaapi"),
            Self::Qsv => Some("scale_qsv"),
            Self::Nvdec => Some("scale_cuda"),
            Self::V4l2 => None,
            #[cfg(target_os = "macos")]
            Self::Videotoolbox => Some("scale_vt"),
        }
    }

    /// Filter graph run on sampled frames only.
    ///
    /// NV12 rather than RGB because every backend's scaler supports it; the
    /// NV12 -> RGB24 convert afterwards is a fraction of a megapixel of CPU
    /// work per sample. `format=nv12` after `hwdownload` pins the download
    /// format, which otherwise depends on the frames pool's software format.
    ///
    /// `target` is the *content* rectangle, not the model input: under a
    /// letterbox, those differ, and the GPU has to produce the aspect-preserving
    /// size or the padding added afterwards would be padding around an already
    /// distorted picture. The padding itself is added on the CPU while packing
    /// — no backend here has a portable hardware pad filter, and at the fitted
    /// size the fill is a few hundred KB of memset per sample.
    fn filter_spec(self, target: InputSize) -> Option<String> {
        self.scale_filter().map(|scale| {
            format!(
                "{scale}=w={}:h={}:format=nv12,hwdownload,format=nv12",
                target.w, target.h
            )
        })
    }
}

/// Identifies the frames a graph was configured for.
///
/// The pool pointer is part of it because `av_buffersrc_parameters_set` takes
/// its own reference on `hw_frames_ctx`: a decoder re-init at identical
/// geometry produces a *new* pool, and reusing the graph would both pin the
/// retired pool's GPU surfaces for the life of the process and feed the
/// scaler frames from a pool it was not built against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct GraphKey {
    width: i32,
    height: i32,
    format: i32,
    frames_ctx: usize,
}

fn graph_key(frame: &AVFrame) -> GraphKey {
    GraphKey {
        width: frame.width,
        height: frame.height,
        format: frame.format,
        frames_ctx: frame.hw_frames_ctx as usize,
    }
}

pub struct HwDecoder {
    ctx: AVCodecContext,
    backend: HwBackend,
    /// Built on the first hardware frame: the graph needs the decoder's frames
    /// pool, which does not exist until something has been decoded.
    graph: Option<(AVFilterGraph, GraphKey)>,
    spec: InputSpec,
    rgb: RgbScaler,
    /// Set once we have warned that the backend is not producing device frames.
    degraded: bool,
}

impl HwDecoder {
    pub fn open(
        backend: HwBackend,
        codecpar: &AVCodecParameters,
        spec: InputSpec,
        motion: Option<MotionConfig>,
    ) -> Result<Self> {
        if let Some(scale) = backend.scale_filter() {
            let name = CString::new(scale).expect("filter names are ascii");
            if AVFilter::get_by_name(&name).is_none() {
                bail!("this FFmpeg build has no {scale} filter, so sampled frames could only be scaled after a full-resolution download");
            }
        }

        let codec = find_codec(backend, codecpar.codec_id)?;
        let mut ctx = AVCodecContext::new(&codec);
        ctx.apply_codecpar(codecpar)
            .context("applying stream parameters to the decoder")?;

        if let Some(device_type) = backend.device_type() {
            let device = AVHWDeviceContext::create(device_type, None, None, 0)
                .map_err(|e| anyhow!("opening the {backend} device: {e}"))?;
            // With a device context attached, libavcodec's default get_format
            // picks the matching hardware pixel format, so decoded surfaces
            // stay on the device.
            ctx.set_hw_device_ctx(device);
        }
        cap_frame_size(&mut ctx);
        ctx.open(None)
            .map_err(|e| anyhow!("opening the {backend} decoder: {e}"))?;

        // The real target depends on the source geometry, which is only
        // certain once frames arrive; the stream's declared size is what the
        // graph will almost certainly be built for, so the startup line quotes
        // that rather than a shape nothing will use.
        match declared_size(codecpar).map(|source| spec.resize.fit(spec.size, source).inner) {
            Some(target) => match backend.filter_spec(target) {
                Some(filter) => note!(
                    "decoder: {backend} hardware ({}), sampled frames via \"{filter}\"",
                    codec.name().to_string_lossy()
                ),
                None => note!(
                    "decoder: {backend} hardware ({}), frames land in system memory",
                    codec.name().to_string_lossy()
                ),
            },
            None => note!(
                "decoder: {backend} hardware ({}), graph built on the first frame",
                codec.name().to_string_lossy()
            ),
        }

        Ok(Self {
            ctx,
            backend,
            graph: None,
            spec,
            rgb: RgbScaler::new(spec, motion)?,
            degraded: false,
        })
    }

    /// buffer -> GPU scale -> hwdownload -> buffersink.
    fn build_graph(&self, frame: &AVFrame, source: InputSize) -> Result<AVFilterGraph> {
        let target = self.spec.resize.fit(self.spec.size, source).inner;
        let spec = self
            .backend
            .filter_spec(target)
            .ok_or_else(|| anyhow!("{} has no filter graph", self.backend))?;
        let spec = CString::new(spec).expect("filter specs are ascii");

        let graph = AVFilterGraph::new();
        let source = AVFilter::get_by_name(c"buffer").ok_or_else(|| anyhow!("no buffer filter"))?;
        let sink =
            AVFilter::get_by_name(c"buffersink").ok_or_else(|| anyhow!("no buffersink filter"))?;

        // pix_fmt is the numeric hardware format (AV_PIX_FMT_VAAPI, ...);
        // timestamps here are irrelevant, the contract pts is taken from the
        // frame before it enters the graph.
        let args = CString::new(format!(
            "video_size={}x{}:pix_fmt={}:time_base=1/90000:pixel_aspect=1/1",
            frame.width, frame.height, frame.format
        ))
        .expect("buffer args are ascii");

        {
            let mut src_ctx = graph
                .create_filter_context(&source, c"in", Some(&args))
                .context("creating the graph source")?;

            // The graph needs the decoder's frames pool or the GPU scaler
            // fails with "No hardware context provided on input".
            //
            // SAFETY: the parameters struct is a flat `av_mallocz` (so
            // `av_free` is the right cleanup, and it runs on both paths), and
            // `av_buffersrc_parameters_set` takes its *own* reference on
            // `hw_frames_ctx` rather than adopting the frame's — the frame
            // outlives this call, so nothing is transferred and nothing leaks.
            unsafe {
                let params = ffi::av_buffersrc_parameters_alloc();
                if params.is_null() {
                    bail!("out of memory allocating buffersrc parameters");
                }
                (*params).hw_frames_ctx = frame.hw_frames_ctx;
                let ret = ffi::av_buffersrc_parameters_set(src_ctx.as_mut_ptr(), params);
                ffi::av_free(params.cast());
                if ret < 0 {
                    bail!("attaching the hardware frames pool to the graph failed ({ret})");
                }
            }

            let mut sink_ctx = graph
                .create_filter_context(&sink, c"out", None)
                .context("creating the graph sink")?;

            let outputs = AVFilterInOut::new(c"in", &mut src_ctx, 0);
            let inputs = AVFilterInOut::new(c"out", &mut sink_ctx, 0);
            graph
                .parse_ptr(&spec, Some(inputs), Some(outputs))
                .with_context(|| format!("parsing filter graph {spec:?}"))?;
        }

        graph
            .config()
            .with_context(|| format!("configuring filter graph {spec:?}"))?;
        Ok(graph)
    }
}

fn find_codec(backend: HwBackend, codec_id: ffi::AVCodecID) -> Result<AVCodecRef<'static>> {
    match backend.decoder_suffix() {
        Some(suffix) => {
            let base = unsafe { CStr::from_ptr(ffi::avcodec_get_name(codec_id)) }.to_string_lossy();
            let name = CString::new(format!("{base}_{suffix}")).expect("codec names are ascii");
            AVCodec::find_decoder_by_name(&name).ok_or_else(|| {
                anyhow!(
                    "this FFmpeg build has no {} decoder",
                    name.to_string_lossy()
                )
            })
        }
        None => AVCodec::find_decoder(codec_id)
            .ok_or_else(|| anyhow!("no decoder for codec id {codec_id}")),
    }
}

impl Decoder for HwDecoder {
    fn send_packet(&mut self, packet: &rsmpeg::avcodec::AVPacket) -> Result<()> {
        match self.ctx.send_packet(Some(packet)) {
            Ok(()) => Ok(()),
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
        match self.scaled(frame)? {
            Some((frame, source)) => self.rgb.tensor_from(&frame, source, pts_ns).map(Some),
            None => Ok(None),
        }
    }

    fn to_rgb(&mut self, frame: AVFrame, pts_ns: Option<i64>) -> Result<Option<RgbSampled>> {
        match self.scaled(frame)? {
            Some((frame, source)) => self.rgb.rgb_from(&frame, source, pts_ns).map(Some),
            None => Ok(None),
        }
    }

    fn hw_backend(&self) -> Option<HwBackend> {
        Some(self.backend)
    }
}

impl HwDecoder {
    /// The frame [`RgbScaler`] takes, on whichever path this backend is on:
    /// the system-memory frame itself, or the GPU-scaled download. `None`
    /// means the filter graph held this frame back (EAGAIN with nothing
    /// drained) — skip the sample. The [`InputSize`] is the geometry the
    /// camera sent, read before the graph consumes the frame, because the
    /// downloaded frame is already scaled.
    fn scaled(&mut self, frame: AVFrame) -> Result<Option<(AVFrame, InputSize)>> {
        let source = source_size(&frame)?;
        if frame.hw_frames_ctx.is_null() {
            // v4l2m2m decodes on the ASIC but returns system memory, so this
            // is its normal path. For every other backend it means the codec
            // opened with a device attached and then chose a software pixel
            // format anyway (unsupported profile, missing hwaccel in the
            // build) — the startup line claiming hardware decode is now wrong,
            // and we are scaling a full-resolution frame on the CPU.
            if !self.degraded && self.backend.scale_filter().is_some() {
                self.degraded = true;
                note!(
                    "decoder: {} produced software frames; hardware decode degraded to \
                     full-resolution CPU scaling (check the codec profile and that this \
                     FFmpeg build has the {} hwaccel)",
                    self.backend,
                    self.backend
                );
            }
            return Ok(Some((frame, source)));
        }

        let key = graph_key(&frame);
        if self.graph.as_ref().map(|(_, k)| *k) != Some(key) {
            self.graph = Some((self.build_graph(&frame, source)?, key));
        }
        let (graph, _) = self.graph.as_ref().expect("graph was just built");

        let Some(downloaded) = ({
            let mut src = graph
                .get_filter(c"in")
                .ok_or_else(|| anyhow!("filter graph lost its source"))?;
            src.buffersrc_add_frame(Some(frame), None)
                .context("feeding a sampled frame to the GPU scaler")?;
            let mut sink = graph
                .get_filter(c"out")
                .ok_or_else(|| anyhow!("filter graph lost its sink"))?;
            // Drain rather than take one frame: the chain is 1:1 in practice,
            // but a graph that ever emitted two for one input would leave the
            // extra queued and every later sample would return the previous
            // sample's image against the current sample's pts — permanently
            // stale, and silent. EAGAIN with nothing drained means the graph
            // is holding this frame back; skip the sample.
            let mut latest = None;
            loop {
                match sink.buffersink_get_frame(None) {
                    Ok(frame) => latest = Some(frame),
                    Err(RsmpegError::BufferSinkDrainError) => break,
                    Err(e) => {
                        return Err(e).context("reading the downloaded frame");
                    }
                }
            }
            latest
        }) else {
            return Ok(None);
        };

        Ok(Some((downloaded, source)))
    }
}

/// Geometry the stream's parameter sets declare, when they declare a usable
/// one. Only the startup log reads it; every graph is built from a real frame.
fn declared_size(codecpar: &AVCodecParameters) -> Option<InputSize> {
    (codecpar.width > 0 && codecpar.height > 0).then(|| InputSize {
        w: codecpar.width as usize,
        h: codecpar.height as usize,
    })
}

#[cfg(test)]
mod tests {
    use rsmpeg::UnsafeDerefMut;

    use super::*;

    #[test]
    fn backend_names_match_the_decoder_flag() {
        assert_eq!(HwBackend::Vaapi.to_string(), "vaapi");
        assert_eq!(HwBackend::Nvdec.to_string(), "nvdec");
        assert_eq!(HwBackend::V4l2.to_string(), "v4l2");
    }

    #[test]
    fn gpu_backends_scale_before_downloading() {
        // hwdownload must never come before the scaler, or a full-resolution
        // frame crosses the bus.
        for backend in [HwBackend::Vaapi, HwBackend::Qsv, HwBackend::Nvdec] {
            let spec = backend
                .filter_spec(InputSize::square(640))
                .expect("gpu backends have a graph");
            let scale = spec.find(backend.scale_filter().unwrap()).unwrap();
            let download = spec.find("hwdownload").unwrap();
            assert!(scale < download, "{backend}: {spec}");
            assert!(spec.contains("w=640:h=640"), "{spec}");
        }
    }

    #[test]
    fn filter_specs_are_the_documented_ones() {
        let square = InputSize::square(640);
        assert_eq!(
            HwBackend::Vaapi.filter_spec(square).unwrap(),
            "scale_vaapi=w=640:h=640:format=nv12,hwdownload,format=nv12"
        );
        assert_eq!(
            HwBackend::Qsv.filter_spec(square).unwrap(),
            "scale_qsv=w=640:h=640:format=nv12,hwdownload,format=nv12"
        );
        assert_eq!(
            HwBackend::Nvdec.filter_spec(square).unwrap(),
            "scale_cuda=w=640:h=640:format=nv12,hwdownload,format=nv12"
        );
    }

    #[test]
    fn a_non_square_input_keeps_w_and_h_apart() {
        // Transposing here would scale to the wrong aspect *and* mismatch the
        // tensor the same size builds, so the axes are asserted separately.
        assert_eq!(
            HwBackend::Vaapi
                .filter_spec(InputSize { w: 640, h: 352 })
                .unwrap(),
            "scale_vaapi=w=640:h=352:format=nv12,hwdownload,format=nv12"
        );
    }

    #[test]
    fn v4l2m2m_has_no_graph() {
        assert!(HwBackend::V4l2
            .filter_spec(InputSize::square(640))
            .is_none());
        assert!(HwBackend::V4l2.device_type().is_none());
    }

    #[test]
    fn wrapper_codecs_get_a_suffixed_decoder_name() {
        assert_eq!(HwBackend::Qsv.decoder_suffix(), Some("qsv"));
        assert_eq!(HwBackend::V4l2.decoder_suffix(), Some("v4l2m2m"));
        assert_eq!(HwBackend::Vaapi.decoder_suffix(), None);
    }

    #[test]
    fn graph_key_separates_pools_at_identical_geometry() {
        let pool_a = GraphKey {
            width: 2560,
            height: 1920,
            format: ffi::AV_PIX_FMT_VAAPI,
            frames_ctx: 0x1000,
        };
        let pool_b = GraphKey {
            frames_ctx: 0x2000,
            ..pool_a
        };
        assert_ne!(
            pool_a, pool_b,
            "a decoder re-init at the same geometry must rebuild the graph"
        );
        assert_eq!(pool_a, GraphKey { ..pool_a });
        assert_ne!(
            pool_a,
            GraphKey {
                height: 1080,
                ..pool_a
            }
        );
    }

    #[test]
    fn graph_key_reads_the_frame_pool_pointer() {
        // A software frame has no pool, so its key carries a null pointer.
        let mut frame = AVFrame::new();
        frame.set_width(640);
        frame.set_height(480);
        frame.set_format(ffi::AV_PIX_FMT_NV12);
        let key = graph_key(&frame);
        assert_eq!(key.frames_ctx, 0);
        assert_eq!(key.width, 640);
        assert_eq!(key.format, ffi::AV_PIX_FMT_NV12);
    }

    #[test]
    fn missing_hardware_reports_rather_than_panics() {
        // No /dev/dri and no CUDA in CI, so every device open fails here; on
        // a box that has the hardware it succeeds. Either way it must return
        // rather than panic, because `open` turns the error into a fallback.
        let mut codecpar = AVCodecParameters::new();
        unsafe {
            let raw = codecpar.deref_mut();
            raw.codec_id = ffi::AV_CODEC_ID_H264;
            raw.codec_type = ffi::AVMEDIA_TYPE_VIDEO;
            raw.width = 1920;
            raw.height = 1080;
        }
        for backend in [HwBackend::Vaapi, HwBackend::Qsv, HwBackend::Nvdec] {
            let _ = HwDecoder::open(
                backend,
                &codecpar,
                InputSpec {
                    size: InputSize::square(640),
                    encoding: crate::infer::TensorEncoding::UnitRgb,
                    resize: crate::infer::ResizePolicy::Stretch,
                    input_quant: None,
                },
                None,
            );
        }
    }
}
