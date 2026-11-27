//! Still images through the pipeline's own preprocess, inference and decode,
//! for scoring a profile on COCO against a Python reference decode.
//!
//! The binary only takes H.264 RTP, so stills cannot reach these through its
//! CLI. This drives the same items the pipeline calls per sample:
//! [`RgbScaler::tensor_from`] (the profile's resize, on swscale bilinear, and
//! the tensor packing), then [`Detector::detect`] (ORT on the CPU, then
//! `decode_output` and its NMS). Nothing here resizes or decodes on its own.
//! The pipeline's frames are YUV and these are RGB24, so swscale runs the same
//! scale without its colour conversion.
//!
//! Each manifest line is `image_id width height path`, the file being raw
//! RGB24 at `width x height`. With `--prescaled` it is instead already the
//! fit's content rectangle, packed by [`model_input_from_rgb`] — the decode
//! split's seam — which takes swscale out of a comparison against another
//! resizer.
//!
//! Output is one ndjson line per detection: `image_id`, `label`, `score`, and
//! `bbox` `[x, y, w, h]` in source pixels. These are wire detections, so the
//! wire's rounding (score to 3 places, normalized bbox to 4) and its
//! per-frame cap (`infer::MAX_DETS`, 32 when written) are in them: AP from
//! this is the shipping decode's, not the model's at COCO's usual 100 or 300
//! detections.
//!
//! ```text
//! cargo run --release --example coco_dets -- --model v9-t-fused.onnx \
//!   --model-profile yolov9split --labels coco.names \
//!   --min-score-json '{"default": 0.001}' --manifest frames.txt --out dets.ndjson
//! ```

use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use cairn_detect::decode::{model_input_from_rgb, RgbScaler};
use cairn_detect::infer::{BackendKind, Detector, InputSize, Labels, ModelProfile, ScoreFloors};
use clap::Parser;
use rsmpeg::avutil::AVFrame;
use rsmpeg::ffi;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    model: PathBuf,
    #[arg(long, value_parser = ModelProfile::parse)]
    model_profile: Option<ModelProfile>,
    #[arg(long)]
    labels: PathBuf,
    /// As the binary's flag. Its `default` is 0.5 when absent — the shipping
    /// floor, far too high to score AP at.
    #[arg(long, default_value = "{}")]
    min_score_json: String,
    #[arg(long)]
    manifest: PathBuf,
    #[arg(long)]
    out: PathBuf,
    #[arg(long)]
    prescaled: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let labels = Labels::load(Some(&args.labels))?;
    let floors = ScoreFloors::parse(&args.min_score_json)?;
    let mut detector = Detector::open(
        &args.model,
        BackendKind::Ort,
        None,
        args.model_profile,
        &labels,
        false,
        Default::default(),
        None,
    )?;
    let spec = detector.input_spec();
    eprintln!(
        "profile {} input {} {}",
        detector.profile().name,
        spec.size,
        spec.resize
    );
    let mut scaler = RgbScaler::new(spec, None)?;
    let mut out = BufWriter::new(File::create(&args.out)?);
    let (mut images, mut dets) = (0usize, 0usize);
    for line in BufReader::new(File::open(&args.manifest)?).lines() {
        let line = line?;
        let fields: Vec<&str> = line.split_whitespace().collect();
        let [id, w, h, path] = fields[..] else {
            bail!("manifest line {line:?}: want `image_id width height path`");
        };
        let id: u64 = id.parse()?;
        let source = InputSize {
            w: w.parse()?,
            h: h.parse()?,
        };
        let rgb = std::fs::read(path).with_context(|| format!("reading {path}"))?;
        let input = if args.prescaled {
            let content = spec.resize.fit(spec.size, source).inner;
            model_input_from_rgb(&rgb, content, source, spec)?
        } else {
            scaler
                .tensor_from(&rgb_frame(&rgb, source)?, source, None)?
                .input
        };
        for det in detector.detect(input.tensor, input.projection, &labels, &floors)? {
            let [x, y, bw, bh] = det.bbox;
            let (sw, sh) = (source.w as f64, source.h as f64);
            let bbox = [x * sw, y * sh, bw * sw, bh * sh];
            let row = serde_json::json!({
                "image_id": id, "label": det.label, "score": det.score, "bbox": bbox,
            });
            writeln!(out, "{row}")?;
            dets += 1;
        }
        images += 1;
        if images % 500 == 0 {
            eprintln!("{images} images");
        }
    }
    out.flush()?;
    eprintln!("{images} images, {dets} detections");
    Ok(())
}

/// Raw RGB24 bytes as the frame swscale takes, rows at the frame's own stride.
fn rgb_frame(rgb: &[u8], size: InputSize) -> Result<AVFrame> {
    let row = size.w * 3;
    if rgb.len() != row * size.h {
        bail!("{} bytes is not RGB24 at {size}", rgb.len());
    }
    let mut frame = AVFrame::new();
    frame.set_width(size.w as i32);
    frame.set_height(size.h as i32);
    frame.set_format(ffi::AV_PIX_FMT_RGB24);
    frame
        .alloc_buffer()
        .context("allocating the source frame")?;
    let stride = frame.linesize[0] as usize;
    let data = frame.data_mut()[0];
    for (y, src) in rgb.chunks_exact(row).enumerate() {
        // SAFETY: `alloc_buffer` sized plane 0 for `height` rows of `stride`
        // bytes, and `stride >= row` for RGB24 at this width.
        unsafe { std::ptr::copy_nonoverlapping(src.as_ptr(), data.add(y * stride), row) };
    }
    Ok(frame)
}
