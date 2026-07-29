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
