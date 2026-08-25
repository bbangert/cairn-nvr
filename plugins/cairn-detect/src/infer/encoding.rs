//! What a decoded frame's bytes become on the way into the model's tensor.
//!
//! None of this is declared by an ONNX graph — the channel order and the
//! 0..1-vs-0..255 scaling live in the model's training transform and an export
//! inherits them as unwritten preconditions.

use std::fmt;

/// How a decoded frame's bytes are packed into the model's input tensor.
///
/// Callers never match on this: they ask for a [`Packing`] and apply it. That
/// is what lets a mean/std-normalizing family be added as one more variant and
/// one more `packing` arm, with nothing else to touch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TensorEncoding {
    /// 0..1 RGB. Ultralytics (yolov8 / yolov10 / yolo11) divides by 255 in its
    /// preprocessing and works in RGB.
    UnitRgb,
    /// 0..255 BGR. YOLOX's `preproc` does no scaling at all and reads images
    /// through OpenCV, which hands back BGR.
    RawBgr,
    /// RGB scaled to 0..1 and then standardized by ImageNet's per-channel
    /// mean and standard deviation. RF-DETR's transform ends in a `Normalize`
    /// over [`IMAGENET_MEAN`]/[`IMAGENET_STD`] and its ONNX exports do *not*
    /// fold it into the graph — measured, not assumed: on one camera frame the
    /// same rfdetr-nano export scores its best box 0.14 fed 0..255, 0.48 fed
    /// 0..1, and 0.78 fed this. Only the last one is a detection.
    ImageNetRgb,
}

/// ImageNet's channel statistics in RGB order, over a 0..1 range.
///
/// Reproduced from RF-DETR's own `kornia_transforms.IMAGENET_MEAN`/`_STD`,
/// which is also what its exported `preprocessor_config.json` reports.
const IMAGENET_MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const IMAGENET_STD: [f32; 3] = [0.229, 0.224, 0.225];

impl TensorEncoding {
    /// The stable wire spelling, round-tripped by [`Self::parse_wire`]: how a
    /// resolved spec crosses a boundary that carries terms rather than types
    /// (an engine in one NIF library telling a decoder in another what to
    /// build for). Distinct from `Display`, which is prose for a startup line.
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::UnitRgb => "unit_rgb",
            Self::RawBgr => "raw_bgr",
            Self::ImageNetRgb => "imagenet_rgb",
        }
    }

    /// The inverse of [`Self::wire_name`], refusing anything else by name.
    pub fn parse_wire(name: &str) -> anyhow::Result<Self> {
        match name {
            "unit_rgb" => Ok(Self::UnitRgb),
            "raw_bgr" => Ok(Self::RawBgr),
            "imagenet_rgb" => Ok(Self::ImageNetRgb),
            other => anyhow::bail!("unknown tensor encoding {other:?}"),
        }
    }

    /// The per-plane affine and channel pick this encoding amounts to.
    pub fn packing(self) -> Packing {
        match self {
            Self::UnitRgb => Packing {
                source: [0, 1, 2],
                scale: [1.0 / 255.0; 3],
                bias: [0.0; 3],
            },
            Self::RawBgr => Packing {
                source: [2, 1, 0],
                scale: [1.0; 3],
                bias: [0.0; 3],
            },
            // (v/255 - mean) / std, distributed over the affine this type
            // already applies: scale 1/(255*std), bias -mean/std.
            Self::ImageNetRgb => Packing {
                source: [0, 1, 2],
                scale: [
                    1.0 / 255.0 / IMAGENET_STD[0],
                    1.0 / 255.0 / IMAGENET_STD[1],
                    1.0 / 255.0 / IMAGENET_STD[2],
                ],
                bias: [
                    -IMAGENET_MEAN[0] / IMAGENET_STD[0],
                    -IMAGENET_MEAN[1] / IMAGENET_STD[1],
                    -IMAGENET_MEAN[2] / IMAGENET_STD[2],
                ],
            },
        }
    }
}

/// An encoding reduced to arithmetic: for each output plane, which byte of an
/// RGB24 pixel feeds it and the affine applied on the way in.
///
/// Per-plane rather than scalar so a `mean`/`std` normalization is expressible
/// here without changing a single caller.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Packing {
    /// Index into an RGB24 pixel for output plane 0, 1, 2.
    pub source: [usize; 3],
    pub scale: [f32; 3],
    pub bias: [f32; 3],
}

impl Packing {
    /// One byte of one plane, encoded.
    pub fn value(&self, plane: usize, byte: u8) -> f32 {
        f32::from(byte) * self.scale[plane] + self.bias[plane]
    }

    /// One plane's byte -> uint8-code table for a quantized-input model:
    /// `quantize(value(plane, byte))` for all 256 bytes, computed once per
    /// pack so the pixel loop is a lookup instead of float math. For the
    /// identity-qparams RawBgr case (scale 1, zero-point 0 — every 0..255
    /// model the surgery converts today) the table degenerates to the
    /// identity and u8 packing is a pure byte shuffle.
    pub fn quantized_lut(&self, plane: usize, quant: QuantParams) -> [u8; 256] {
        std::array::from_fn(|byte| quant.quantize(self.value(plane, byte as u8)))
    }
}

/// One tensor edge's quantization affine, from the artifact's own stripped
/// QuantizeLinear/DequantizeLinear (`<model>.qparams.json` — see
/// [`super::qparams::IoQuant`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuantParams {
    pub scale: f32,
    pub zero_point: u8,
}

/// `Eq` holds because the sidecar loader refuses any non-finite-positive
/// scale — no NaN ever constructs one — and [`InputSpec`](super::InputSpec)
/// derives `Eq` over this type.
impl Eq for QuantParams {}

impl QuantParams {
    /// The removed QuantizeLinear's arithmetic, per ONNX spec: round half to
    /// even, then saturate to u8. Must match `u8_io_surgery.quantize_codes`
    /// exactly — the exporter's `--verify` and the campaign's parity leg both
    /// assume one quantizer.
    pub fn quantize(self, value: f32) -> u8 {
        ((value / self.scale).round_ties_even() + f32::from(self.zero_point)).clamp(0.0, 255.0)
            as u8
    }

    /// The removed DequantizeLinear's arithmetic.
    pub fn dequantize(self, code: u8) -> f32 {
        (f32::from(code) - f32::from(self.zero_point)) * self.scale
    }
}

/// A packed input tensor's payload: f32 for the float graph-IO contract every
/// profile has always had, u8 codes for a uint8-IO artifact (the packer
/// quantized through the input edge's [`QuantParams`] on the way in).
///
/// An enum rather than a generic because exactly one place chooses — the
/// packer, from `InputSpec::input_quant` — and everything between it and the
/// session boundary just carries the choice.
#[derive(Debug, Clone, PartialEq)]
pub enum TensorValues {
    F32(Vec<f32>),
    U8(Vec<u8>),
}

impl TensorValues {
    pub fn len(&self) -> usize {
        match self {
            Self::F32(v) => v.len(),
            Self::U8(v) => v.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The float view, `None` for u8 codes — how the embedder's crop source
    /// refuses a quantized detector tensor instead of inverting it wrong.
    pub fn as_f32(&self) -> Option<&[f32]> {
        match self {
            Self::F32(v) => Some(v),
            Self::U8(_) => None,
        }
    }

    pub fn as_u8(&self) -> Option<&[u8]> {
        match self {
            Self::U8(v) => Some(v),
            Self::F32(_) => None,
        }
    }
}

impl fmt::Display for TensorEncoding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::UnitRgb => "0..1 rgb",
            Self::RawBgr => "0..255 bgr",
            Self::ImageNetRgb => "imagenet-normalized rgb",
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every variant must round-trip: the wire name is how a resolved spec
    /// crosses between NIF libraries, and a variant that doesn't come back is
    /// an engine and a decoder silently built for different models.
    #[test]
    fn every_encoding_round_trips_through_its_wire_name() {
        for encoding in [
            TensorEncoding::UnitRgb,
            TensorEncoding::RawBgr,
            TensorEncoding::ImageNetRgb,
        ] {
            assert_eq!(
                TensorEncoding::parse_wire(encoding.wire_name()).unwrap(),
                encoding
            );
        }
        assert!(TensorEncoding::parse_wire("bgr").is_err());
        assert!(TensorEncoding::parse_wire("").is_err());
    }

    #[test]
    fn an_encoding_is_a_per_plane_affine_over_a_channel_pick() {
        let unit = TensorEncoding::UnitRgb.packing();
        assert_eq!(unit.source, [0, 1, 2]);
        assert_eq!(unit.value(0, 255), 1.0);
        assert_eq!(unit.value(2, 0), 0.0);

        let raw = TensorEncoding::RawBgr.packing();
        // plane 0 is blue, plane 2 is red
        assert_eq!(raw.source, [2, 1, 0]);
        assert_eq!(raw.value(0, 255), 255.0);
        assert_eq!(raw.value(1, 114), 114.0);
    }

    /// Pinned to the same cases as `test_u8_io_surgery.py`'s
    /// `test_quantize_codes_round_half_even_and_saturate`: the exporter's
    /// verify leg and this packer must be one quantizer or CPU-EP parity
    /// measures the difference between them instead of the artifact.
    #[test]
    fn quantize_matches_the_exporters_arithmetic() {
        let identity = QuantParams {
            scale: 1.0,
            zero_point: 0,
        };
        assert_eq!(identity.quantize(0.5), 0); // half to even, down
        assert_eq!(identity.quantize(1.5), 2); // half to even, up
        assert_eq!(identity.quantize(2.5), 2);
        assert_eq!(identity.quantize(-100.0), 0); // saturate low
        assert_eq!(identity.quantize(1000.0), 255); // saturate high
        let scaled = QuantParams {
            scale: 0.5,
            zero_point: 3,
        };
        assert_eq!(scaled.quantize(114.0), 231);
        assert_eq!(scaled.dequantize(231), 114.0);
    }

    /// The LUT is the quantizer applied to the encoding's affine — and for a
    /// 0..255 model with identity qparams it must degenerate to the byte
    /// itself, which is what makes u8 packing a pure shuffle there.
    #[test]
    fn quantized_lut_is_identity_for_raw_bgr_identity_qparams() {
        let packing = TensorEncoding::RawBgr.packing();
        let lut = packing.quantized_lut(
            0,
            QuantParams {
                scale: 1.0,
                zero_point: 0,
            },
        );
        for byte in 0..=255u8 {
            assert_eq!(lut[byte as usize], byte);
        }
        // Non-identity qparams must go through the real affine: scale 0.5
        // doubles the code, zero-point shifts it.
        let lut = packing.quantized_lut(
            0,
            QuantParams {
                scale: 0.5,
                zero_point: 3,
            },
        );
        assert_eq!(lut[114], 231);
        assert_eq!(lut[200], 255); // saturates
    }

    #[test]
    fn the_imagenet_encoding_is_standardization_folded_into_the_same_affine() {
        // (v/255 - mean) / std, which the per-plane scale and bias exist to
        // express without any caller learning a third code path.
        let packing = TensorEncoding::ImageNetRgb.packing();
        assert_eq!(packing.source, [0, 1, 2]);
        for plane in 0..3 {
            let expect =
                |byte: u8| (f32::from(byte) / 255.0 - IMAGENET_MEAN[plane]) / IMAGENET_STD[plane];
            for byte in [0u8, 1, 114, 200, 255] {
                let got = packing.value(plane, byte);
                assert!(
                    (got - expect(byte)).abs() < 1e-5,
                    "plane {plane} byte {byte}: {got} vs {}",
                    expect(byte)
                );
            }
        }
        // black is the most negative value and white the most positive, on
        // every plane — the sign convention a wrong mean/std would flip
        assert!(packing.value(0, 0) < -2.0 && packing.value(0, 255) > 2.0);
    }
}
