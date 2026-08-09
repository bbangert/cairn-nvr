//! The person Re-ID embedder: a second model session over the detector's own
//! input tensor.
//!
//! An [`Embedder`] wraps a [`Backend`] the way [`Detector`](super::Detector)
//! does, minus everything detector-shaped: no profile sniffing, no output
//! layout resolution, no label checks. It needs an artifact that declares its
//! own input size (osnet-class: NCHW 1x3x256x128) and one statically-shaped
//! feature output, and it answers one question per crop — a unit-norm feature
//! vector.
//!
//! Crops come from the model-input tensor the detector already consumed a
//! clone of (the phase-4.1 spike's Path A: separability within 0.016 AUC of
//! full-resolution crops at a fifth of the marginal cost, and the canvas is a
//! sunk cost — the detector needed it regardless). No pixels survive a detect
//! pass otherwise; this is the one copy the feature pays for, and only when
//! an embedder is configured.
//!
//! The detector's tensor is in the *detector's* encoding — 0..255 BGR for a
//! yolox-class profile, 0..1 RGB for yolov8, ImageNet-normalized RGB for
//! rfdetr — so a crop is decoded back through that [`Packing`](super::encoding::Packing)'s inverse to
//! RGB bytes and re-encoded with the embedder's own (ImageNet RGB, the
//! osnet-family contract). Bilinear resampling happens in byte space between
//! the two.

use std::path::Path;

use anyhow::{bail, Context, Result};

use super::backend::onnxruntime::OrtBackend;
use super::backend::{Backend, BackendKind, InputTensor, SessionOptions};
use super::encoding::TensorEncoding;
use super::geometry::{InputSize, Projection};
use super::profile::InputSpec;

use crate::emit::Det;

/// The largest feature dimension the wire budget covers: 64 objects of
/// base64 int8 at 512 dims plus the worst-case base line stay inside
/// `MAX_LINE_BYTES` (the arithmetic is pinned in `emit.rs` tests). A larger
/// model would silently shed detections instead — refused here, at open.
pub const MAX_EMBEDDING_DIM: usize = 512;

/// A crop rectangle must keep at least this many canvas pixels per axis
/// after clamping to the content rect; anything smaller is letterbox lint,
/// not a person.
const MIN_CROP_PX: f64 = 8.0;

pub struct Embedder {
    backend: Box<dyn Backend>,
    input_size: InputSize,
    output_name: String,
    dim: usize,
}

impl Embedder {
    /// Opens the embedder artifact on the backend kind `--backend` named —
    /// which today means `ort`: the flag is shared with the detector, and a
    /// kind the embedder can't run on is refused here rather than silently
    /// downgraded. The model must declare a rank-4, 3-channel input (that is
    /// the crop geometry) and one statically-shaped output (that is the wire
    /// budget) — an artifact that declares neither can't be checked against
    /// either contract, so it is refused rather than trusted.
    pub fn open(model: &Path, backend: BackendKind) -> Result<Self> {
        let options = SessionOptions::default();
        let backend: Box<dyn Backend> = match backend {
            BackendKind::Ort => Box::new(OrtBackend::open(model, &options)?),
            // The detector runs on qnn; the embedder does not, yet — HTP takes
            // only full-op-coverage QDQ graphs and no QDQ embedder export
            // exists until the phase-3 quantization pipeline covers osnet.
            // Refused rather than quietly opened on the CPU EP, because a
            // backend the operator named and did not get is exactly the
            // silent fallback this crate refuses everywhere else.
            BackendKind::Qnn => bail!(
                "the embedder does not run on qnn yet (no QDQ embedder \
                 artifact) — drop --embedder-model or use --backend ort"
            ),
            kind @ BackendKind::Rknn => bail!(
                "backend {kind} is not yet implemented — only ort and qnn execute today. \
                 Its expected artifact is {} (see --backend).",
                kind.capabilities().artifact
            ),
        };
        let io = backend.io();

        if let Some(batch) = io.declared_input_batch {
            if batch != 1 {
                bail!(
                    "embedder {} declares a fixed batch of {batch}; this plugin \
                     runs one crop per pass (N=1) — re-export with batch 1 or a \
                     dynamic batch (the README's osnet recipe does exactly this)",
                    model.display()
                );
            }
        }

        let input_size = io.declared_input_size.with_context(|| {
            format!(
                "embedder {} does not declare a static NCHW 3-channel input; \
                 the crop size must come from the model",
                model.display()
            )
        })?;

        let output = match io.outputs.as_slice() {
            [only] => only,
            outputs => bail!(
                "embedder {} declares {} outputs; a feature extractor has one",
                model.display(),
                outputs.len()
            ),
        };
        let output_name = output.name.clone();

        let dim = output
            .dims
            .as_ref()
            .map(|dims| dims.iter().product::<i64>() as usize)
            .with_context(|| {
                format!(
                    "embedder {} does not declare a static output shape; \
                     the wire budget must be checkable at open",
                    model.display()
                )
            })?;

        if dim == 0 || dim > MAX_EMBEDDING_DIM {
            bail!(
                "embedder {} produces {dim}-dim features; the wire budget covers \
                 1..={MAX_EMBEDDING_DIM} (64 objects of base64 int8 must fit one line)",
                model.display()
            );
        }

        Ok(Self {
            backend,
            input_size,
            output_name,
            dim,
        })
    }

    /// One line's worth of self-description for the startup summary.
    pub fn summary(&self) -> String {
        format!(
            "input size={} dim={} backend={} ({})",
            self.input_size,
            self.dim,
            self.backend.kind(),
            self.backend.kind().capabilities()
        )
    }

    /// Crops one wire box out of the detector's input tensor and embeds it:
    /// a unit-norm feature vector, or `None` when the box holds too little
    /// canvas to crop (degenerate after clamping to the content rect).
    pub fn embed_crop(
        &mut self,
        tensor: &[f32],
        spec: &InputSpec,
        projection: &Projection,
        bbox: [f64; 4],
    ) -> Result<Option<Vec<f32>>> {
        let Some(crop) = crop_chw(tensor, spec, projection, bbox, self.input_size) else {
            return Ok(None);
        };

        let input = InputTensor {
            shape: [1, 3, self.input_size.h as i64, self.input_size.w as i64],
            values: crop,
        };
        let tensors = self.backend.run(input).context("running the embedder")?;
        let raw = tensors.get(&self.output_name)?;
        if raw.values.len() != self.dim {
            bail!(
                "embedder produced {} values where its declared shape promised {}",
                raw.values.len(),
                self.dim
            );
        }

        // A non-finite or zero norm is a property of this crop's numbers, not
        // of the configuration: skip the feature rather than kill the process
        // over one degenerate box.
        let norm = raw.values.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm == 0.0 {
            return Ok(None);
        }
        Ok(Some(raw.values.iter().map(|v| v / norm).collect()))
    }
}

/// Attaches features to every `person` detection in place: crop, embed,
/// quantize. One helper because both inference loops — single and
/// multiplexed — are the documented duplication and must do the same thing.
pub fn embed_persons(
    embedder: &mut Embedder,
    tensor: &[f32],
    spec: &InputSpec,
    projection: &Projection,
    dets: &mut [Det],
) -> Result<()> {
    for det in dets.iter_mut().filter(|det| det.label == "person") {
        if let Some(feature) = embedder.embed_crop(tensor, spec, projection, det.bbox)? {
            det.embedding = Some(quantize_base64(&feature));
        }
    }
    Ok(())
}

/// A unit-norm feature quantized for the wire: symmetric int8 at the fixed
/// scale 127 (components of a unit vector are already in -1..1), base64
/// standard alphabet. The host dequantizes with the same constant — no
/// per-detection scale rides the line.
pub fn quantize_base64(feature: &[f32]) -> String {
    let bytes: Vec<u8> = feature
        .iter()
        .map(|v| (v.clamp(-1.0, 1.0) * 127.0).round() as i8 as u8)
        .collect();
    base64_encode(&bytes)
}

// Standard-alphabet base64 with padding, hand-rolled over pulling the crate into
// the dependency list for one direction of one field. Cairn decodes an ndjson
// line's copy with `Base.decode64/1`; `cairn-native` decodes it in Rust, since a
// term can carry the bytes.
fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// The Path-A crop: a wire box forward-projected onto the model canvas,
/// clamped to the content rect, decoded from the detector's encoding to RGB
/// bytes, bilinearly resampled to the embedder's input size, and re-encoded
/// as ImageNet RGB (the osnet-family contract). `None` when the clamped
/// rectangle keeps fewer than [`MIN_CROP_PX`] canvas pixels on either axis.
fn crop_chw(
    tensor: &[f32],
    spec: &InputSpec,
    projection: &Projection,
    bbox: [f64; 4],
    out: InputSize,
) -> Option<Vec<f32>> {
    let (bx0, by0, bx1, by1) = projection.project_norm(bbox);
    let (cx0, cy0, cx1, cy1) = projection.content_rect();
    let x0 = bx0.max(cx0);
    let y0 = by0.max(cy0);
    let x1 = bx1.min(cx1).min(spec.size.w as f64);
    let y1 = by1.min(cy1).min(spec.size.h as f64);
    if x1 - x0 < MIN_CROP_PX || y1 - y0 < MIN_CROP_PX {
        return None;
    }

    let src = spec.size;
    let plane = src.w * src.h;
    let packing = spec.encoding.packing();
    // Plane index holding RGB channel c: the inverse of `Packing.source`.
    let mut plane_of = [0usize; 3];
    for (p, c) in packing.source.iter().enumerate() {
        plane_of[*c] = p;
    }

    let out_packing = TensorEncoding::ImageNetRgb.packing();
    // The re-encode below indexes `out_packing` by RGB channel directly,
    // which is only right while the embedder encoding's source order is the
    // identity — as ImageNet RGB's is.
    debug_assert_eq!(out_packing.source, [0, 1, 2]);
    let out_plane = out.w * out.h;
    let mut crop = vec![0f32; 3 * out_plane];

    // Sample centers are clamped into the content rect, not just the canvas:
    // an upscaled crop whose edge sits on the content boundary would
    // otherwise blend up to half a letterbox-pad pixel into its border rows.
    let fx_hi = (cx1 - 1.0).max(cx0).min((src.w - 1) as f64);
    let fy_hi = (cy1 - 1.0).max(cy0).min((src.h - 1) as f64);

    let sx = (x1 - x0) / out.w as f64;
    let sy = (y1 - y0) / out.h as f64;
    for ty in 0..out.h {
        let fy = (y0 + (ty as f64 + 0.5) * sy - 0.5).clamp(cy0, fy_hi);
        let y_lo = fy.floor() as usize;
        let y_hi = (y_lo + 1).min(src.h - 1);
        let wy = fy - y_lo as f64;
        for tx in 0..out.w {
            let fx = (x0 + (tx as f64 + 0.5) * sx - 0.5).clamp(cx0, fx_hi);
            let x_lo = fx.floor() as usize;
            let x_hi = (x_lo + 1).min(src.w - 1);
            let wx = fx - x_lo as f64;
            for c in 0..3 {
                let p = plane_of[c];
                let byte = |x: usize, y: usize| -> f64 {
                    f64::from(
                        (tensor[p * plane + y * src.w + x] - packing.bias[p]) / packing.scale[p],
                    )
                };
                let top = byte(x_lo, y_lo) * (1.0 - wx) + byte(x_hi, y_lo) * wx;
                let bottom = byte(x_lo, y_hi) * (1.0 - wx) + byte(x_hi, y_hi) * wx;
                let sampled = (top * (1.0 - wy) + bottom * wy) as f32;
                crop[c * out_plane + ty * out.w + tx] =
                    sampled * out_packing.scale[c] + out_packing.bias[c];
            }
        }
    }
    Some(crop)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infer::geometry::ResizePolicy;

    /// The embedder's qnn refusal must fire before any model access — proven
    /// by a path that does not exist — and name the way out, because a
    /// regression that fell through to a session open would silently put the
    /// embedder on whatever EP the fallthrough chose.
    #[test]
    fn qnn_is_refused_before_any_model_access() {
        let err = match Embedder::open(Path::new("does/not/exist"), BackendKind::Qnn) {
            Ok(_) => panic!("embedder opened on qnn"),
            Err(err) => err,
        };
        let msg = err.to_string();
        assert!(msg.contains("does not run on qnn"), "{msg}");
        assert!(msg.contains("--embedder-model"), "{msg}");
    }

    // RFC 4648 vectors, driven as bytes.
    #[test]
    fn base64_matches_the_rfc_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    fn decode_base64(s: &str) -> Vec<u8> {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let value = |c: u8| ALPHABET.iter().position(|a| *a == c).unwrap() as u32;
        let chars: Vec<u8> = s.bytes().filter(|c| *c != b'=').collect();
        let mut out = Vec::new();
        for chunk in chars.chunks(4) {
            let mut n = 0u32;
            for (i, c) in chunk.iter().enumerate() {
                n |= value(*c) << (18 - 6 * i);
            }
            let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
            out.extend_from_slice(&bytes[..chunk.len() - 1]);
        }
        out
    }

    /// The wire contract both sides hold: unit vector -> int8 at scale 127 ->
    /// base64, and back out with the same fixed constant.
    ///
    /// The bound is the measured fidelity of that choice, not a wish: a
    /// 512-dim unit vector's components sit near 1/sqrt(512), so the fixed
    /// scale spends ~11 int8 levels per component and the round trip lands at
    /// cosine ~0.9988. That distortion is ~2% of the identity gap the
    /// phase-4.1 spike measured (0.064 cosine between same- and
    /// different-person pairs) — a per-vector scale would shrink it 30x for
    /// one more wire field, and is the documented upgrade path if phase-5
    /// fusion turns out to need it.
    #[test]
    fn quantization_round_trips_within_tolerance() {
        // A deterministic not-axis-aligned unit vector.
        let raw: Vec<f32> = (0..512).map(|i| (i as f32 * 0.37).sin()).collect();
        let norm = raw.iter().map(|v| v * v).sum::<f32>().sqrt();
        let unit: Vec<f32> = raw.iter().map(|v| v / norm).collect();

        let encoded = quantize_base64(&unit);
        let bytes = decode_base64(&encoded);
        assert_eq!(bytes.len(), 512);
        let restored: Vec<f32> = bytes.iter().map(|b| f32::from(*b as i8) / 127.0).collect();

        let dot = unit.iter().zip(&restored).map(|(a, b)| a * b).sum::<f32>();
        let restored_norm = restored.iter().map(|v| v * v).sum::<f32>().sqrt();
        let cosine = dot / restored_norm;
        assert!(cosine > 0.998, "cosine {cosine}");
    }

    // An 8x8 UnitRgb canvas under stretch: the whole canvas is content, and a
    // solid color must crop to that color re-encoded as ImageNet RGB.
    #[test]
    fn a_solid_crop_re_encodes_into_imagenet_space() {
        let src = InputSize { w: 8, h: 8 };
        let spec = InputSpec {
            size: src,
            encoding: TensorEncoding::UnitRgb,
            resize: ResizePolicy::Stretch,
        };
        let projection = ResizePolicy::Stretch.project(src, src);
        // Solid (255, 128, 0) in UnitRgb: planes hold v/255.
        let plane = src.w * src.h;
        let mut tensor = vec![0f32; 3 * plane];
        tensor[..plane].fill(1.0);
        tensor[plane..2 * plane].fill(128.0 / 255.0);

        let out = InputSize { w: 4, h: 8 };
        let crop = crop_chw(&tensor, &spec, &projection, [0.0, 0.0, 1.0, 1.0], out).unwrap();

        let expect = |byte: f64, c: usize| {
            let mean = [0.485, 0.456, 0.406][c];
            let std = [0.229, 0.224, 0.225][c];
            ((byte / 255.0 - mean) / std) as f32
        };
        let out_plane = out.w * out.h;
        for (c, byte) in [(0usize, 255.0), (1, 128.0), (2, 0.0)] {
            for v in &crop[c * out_plane..(c + 1) * out_plane] {
                assert!((v - expect(byte, c)).abs() < 1e-4, "plane {c}: {v}");
            }
        }
    }

    // The same solid color fed as RawBgr must land on the same ImageNet
    // values: the crop inverts the detector's packing — including the channel
    // swap — before re-encoding.
    #[test]
    fn the_detector_encoding_is_inverted_channel_order_included() {
        let src = InputSize { w: 8, h: 8 };
        let spec = InputSpec {
            size: src,
            encoding: TensorEncoding::RawBgr,
            resize: ResizePolicy::Stretch,
        };
        let projection = ResizePolicy::Stretch.project(src, src);
        // Solid (255, 128, 0) RGB in RawBgr planes: plane 0 = B = 0,
        // plane 1 = G = 128, plane 2 = R = 255, all at 0..255 scale.
        let plane = src.w * src.h;
        let mut tensor = vec![0f32; 3 * plane];
        tensor[plane..2 * plane].fill(128.0);
        tensor[2 * plane..].fill(255.0);

        let out = InputSize { w: 4, h: 8 };
        let crop = crop_chw(&tensor, &spec, &projection, [0.0, 0.0, 1.0, 1.0], out).unwrap();

        let expect = |byte: f64, c: usize| {
            let mean = [0.485, 0.456, 0.406][c];
            let std = [0.229, 0.224, 0.225][c];
            ((byte / 255.0 - mean) / std) as f32
        };
        let out_plane = out.w * out.h;
        for (c, byte) in [(0usize, 255.0), (1, 128.0), (2, 0.0)] {
            for v in &crop[c * out_plane..(c + 1) * out_plane] {
                assert!((v - expect(byte, c)).abs() < 1e-4, "plane {c}: {v}");
            }
        }
    }

    // A letterboxed canvas: a box reaching into the padding is clamped to the
    // content rect, so no padding value leaks into a crop.
    #[test]
    fn crops_never_sample_the_letterbox_padding() {
        // 4:3 content in a square canvas: 16x12 content, 4 rows of pad below.
        let input = InputSize { w: 16, h: 16 };
        let source = InputSize { w: 160, h: 120 };
        let spec = InputSpec {
            size: input,
            encoding: TensorEncoding::UnitRgb,
            resize: ResizePolicy::Letterbox { pad: 114 },
        };
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(input, source);

        // Content solid white, padding at the encoding of 114.
        let plane = input.w * input.h;
        let mut tensor = vec![114.0 / 255.0; 3 * plane];
        for p in 0..3 {
            for y in 0..12 {
                for x in 0..16 {
                    tensor[p * plane + y * input.w + x] = 1.0;
                }
            }
        }

        // The full frame, which on the canvas ends where the content does.
        let out = InputSize { w: 4, h: 8 };
        let crop = crop_chw(&tensor, &spec, &projection, [0.0, 0.0, 1.0, 1.0], out).unwrap();

        let white = ((1.0 - 0.485) / 0.229) as f32;
        let tolerance = 0.05; // bilinear at the content edge stays inside content
        for v in &crop[..out.w * out.h] {
            assert!((v - white).abs() < tolerance, "sampled padding: {v}");
        }

        // The case the first version of this test could not catch: an
        // UPSCALED crop (fewer content pixels than output rows) whose edge
        // sits exactly on the content boundary. Unclamped sample centers
        // would blend up to half a pad pixel into the border rows here.
        // A larger canvas so the quarter-height crop clears MIN_CROP_PX:
        // 64x64 with 4:3 content = 64x48 content, 16 rows of pad.
        let input = InputSize { w: 64, h: 64 };
        let source = InputSize { w: 640, h: 480 };
        let spec = InputSpec {
            size: input,
            encoding: TensorEncoding::UnitRgb,
            resize: ResizePolicy::Letterbox { pad: 114 },
        };
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(input, source);
        let plane = input.w * input.h;
        let mut tensor = vec![114.0 / 255.0; 3 * plane];
        for p in 0..3 {
            for y in 0..48 {
                for x in 0..64 {
                    tensor[p * plane + y * input.w + x] = 1.0;
                }
            }
        }

        // Bottom quarter of the frame: 12 content rows into 16 output rows —
        // an upscale ending exactly on the content boundary at row 48.
        let bottom_quarter = [0.0, 0.75, 1.0, 0.25];
        let out = InputSize { w: 8, h: 16 };
        let crop = crop_chw(&tensor, &spec, &projection, bottom_quarter, out).unwrap();
        for v in &crop[..out.w * out.h] {
            assert!(
                (v - white).abs() < tolerance,
                "upscaled edge sampled padding: {v}"
            );
        }
    }

    #[test]
    fn a_degenerate_clamped_box_yields_no_crop() {
        let src = InputSize { w: 384, h: 384 };
        let spec = InputSpec {
            size: src,
            encoding: TensorEncoding::UnitRgb,
            resize: ResizePolicy::Stretch,
        };
        let projection = ResizePolicy::Stretch.project(src, src);
        let tensor = vec![0f32; 3 * src.w * src.h];
        let out = InputSize { w: 128, h: 256 };

        // Under 8 canvas pixels on the x axis.
        assert!(crop_chw(&tensor, &spec, &projection, [0.5, 0.5, 0.015, 0.2], out).is_none());
        // Zero-width.
        assert!(crop_chw(&tensor, &spec, &projection, [0.5, 0.5, 0.0, 0.2], out).is_none());
    }
}
