//! ONNX inference and postprocess.
//!
//! Everything that differs between detector families is stated once, as data,
//! in a [`ModelProfile`]: how frames must be *fed* to the model ([`InputSpec`])
//! and how its output must be read ([`OutputSpec`]). Adding a family is adding
//! a profile to [`PROFILES`]; the code below is family-agnostic.
//!
//! A profile is either named on the command line (`--model-profile`) or
//! sniffed from the model's own I/O. Sniffing is deliberately strict: a shape
//! that fits *two* built-in profiles is an error naming both, never a silent
//! pick — the two are decoded completely differently and the wrong one emits
//! plausible garbage rather than failing.
//!
//! None of the input half is declared by an ONNX graph. The channel order, the
//! 0..1-vs-0..255 scaling and the resize policy live in the model's training
//! transform and an export inherits them as unwritten preconditions. Feeding
//! the wrong ones is not a small accuracy loss: YOLOX-Nano fed 0..1 RGB
//! returns no detection at all above 0.3 on a frame where 0..255 BGR finds a
//! car and a potted plant.

use std::collections::HashMap;
use std::fmt;
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use ort::session::Session;
use ort::value::{Tensor, ValueType};

use crate::emit::Det;

pub const MAX_DETS: usize = 32;

/// Ceiling on either input dimension, enforced wherever a size is resolved.
///
/// Nothing downstream re-checks it: the resolved size is cast to `i32` for
/// FFmpeg frame and scaler geometry. Without a bound, a typo'd `--input-size`
/// or a model declaring nonsense truncates on the cast instead of failing at
/// startup. 8192 is far past any real detector input — Ultralytics tops out
/// around 1280 — and leaves the cast well inside its type.
///
/// This bounds each axis and *not* the allocation: see [`MAX_INPUT_PIXELS`],
/// which is the one that bounds memory.
const MAX_INPUT_DIM: usize = 8192;

/// Ceiling on the input *area*, enforced alongside [`MAX_INPUT_DIM`].
///
/// A per-axis bound says nothing about how much memory a size asks for, and
/// the size can come straight off the model: `declared_input_size` reads
/// `shape[2]`/`shape[3]` of an untrusted ONNX. At `8192x8192` — inside the
/// per-axis limit — the first frame allocates a 768 MiB `pack_chw` tensor and
/// a 192 MiB RGB24 AVFrame, per decode thread, plus one tensor parked in each
/// multiplexed member's slot. Four cameras is over 4 GB of steady-state RSS on
/// the NVR host, all of it decided by a file the operator downloaded.
///
/// So the model-declared path gets the rule `decode::MAX_PIXELS` already
/// applies to camera frames: bound the area. 4 Mpx is `2048x2048`, an order of
/// magnitude past RF-DETR-Large's 704 and Ultralytics' 1280.
const MAX_INPUT_PIXELS: usize = 4 * 1024 * 1024;

/// The model's input geometry, resolved once at startup.
///
/// Every scaler, GPU filter graph and tensor in the process is built for
/// exactly this, so it is settled before any of them exist — a mismatch is a
/// runtime failure on the first frame, not something the pipeline recovers
/// from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputSize {
    pub w: usize,
    pub h: usize,
}

impl InputSize {
    pub const fn square(size: usize) -> Self {
        Self { w: size, h: size }
    }

    /// `--input-size` value: `N` for a square N×N, or `WxH`.
    ///
    /// Written as a `clap` value parser, so its errors are the ones the user
    /// sees on a bad flag.
    pub fn parse(spec: &str) -> Result<Self> {
        let spec = spec.trim();
        match spec.split_once(['x', 'X']) {
            Some((w, h)) => Ok(Self {
                w: dim(w)?,
                h: dim(h)?,
            }),
            None => Ok(Self::square(dim(spec)?)),
        }
    }

    /// Elements in the CHW f32 tensor a frame of this size packs into.
    pub fn tensor_len(self) -> usize {
        3 * self.w * self.h
    }
}

/// `usize::from_str` already rejects a sign and any non-digit; only zero needs
/// its own check, and it needs one because a 0-wide scaler fails much later.
fn dim(text: &str) -> Result<usize> {
    let value: usize = text
        .trim()
        .parse()
        .with_context(|| format!("input size {text:?} is not a number"))?;
    if value == 0 {
        bail!("input size must be positive, got {text:?}");
    }
    Ok(value)
}

impl fmt::Display for InputSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.w, self.h)
    }
}

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

/// How a source frame is made to fit the model's input rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResizePolicy {
    /// Scale each axis independently to fill the input exactly. Cheap and
    /// correct only for a model trained the same way.
    Stretch,
    /// Scale by the smaller of the two ratios and fill the remainder with
    /// `pad`, preserving aspect. The content goes at the top-left corner and
    /// the padding lands bottom-right, which is what YOLOX's own `preproc`
    /// does (`padded_img[: int(h*r), : int(w*r)] = resized`).
    Letterbox { pad: u8 },
}

impl fmt::Display for ResizePolicy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Stretch => f.write_str("stretch"),
            Self::Letterbox { pad } => write!(f, "letterbox (pad {pad})"),
        }
    }
}

impl ResizePolicy {
    /// Where a `source`-sized frame lands inside an `input`-sized tensor.
    pub fn fit(self, input: InputSize, source: InputSize) -> Fit {
        match self {
            Self::Stretch => Fit {
                inner: input,
                offset: (0, 0),
                pad: 0,
            },
            Self::Letterbox { pad } => {
                let ratio = f64::min(
                    input.w as f64 / source.w as f64,
                    input.h as f64 / source.h as f64,
                );
                Fit {
                    inner: InputSize {
                        w: scaled_dim(source.w, ratio, input.w),
                        h: scaled_dim(source.h, ratio, input.h),
                    },
                    offset: (0, 0),
                    pad,
                }
            }
        }
    }

    /// The un-projection a `source`-sized frame implies under this policy.
    ///
    /// The pipeline itself goes through [`Fit`], which it needs anyway to
    /// build the scaler; this is the same thing for a caller that only wants
    /// the coordinate mapping.
    #[cfg(test)]
    pub fn project(self, input: InputSize, source: InputSize) -> Projection {
        self.fit(input, source).projection(source)
    }
}

/// A letterboxed side length: `floor(side * ratio)`, forced even and clamped
/// into `1..=limit`.
///
/// Even because the hardware path scales into NV12, whose chroma planes are
/// half resolution on both axes — an odd side there is either rejected by the
/// GPU scaler or silently rounded, and a silent round would shift every box by
/// the rounding it did not tell us about. Losing up to one pixel of content to
/// the pad is the cheaper side of that trade, and it costs nothing in accuracy
/// because [`Fit::projection`] is derived from the side we actually produced,
/// not from `ratio`.
fn scaled_dim(side: usize, ratio: f64, limit: usize) -> usize {
    let scaled = (side as f64 * ratio).floor().max(0.0) as usize;
    let even = (scaled.min(limit) / 2) * 2;
    even.max(2).min(limit).max(1)
}

/// Where the scaled frame sits inside the input rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fit {
    /// Size the source is scaled to. Equal to the input under `Stretch`.
    pub inner: InputSize,
    /// Top-left corner of that content within the input rectangle.
    pub offset: (usize, usize),
    /// Fill for everything outside `inner`.
    pub pad: u8,
}

impl Fit {
    /// The inverse of this fit: model-space pixels back to the source frame.
    pub fn projection(self, source: InputSize) -> Projection {
        Projection {
            scale: (
                self.inner.w as f64 / source.w as f64,
                self.inner.h as f64 / source.h as f64,
            ),
            offset: (self.offset.0 as f64, self.offset.1 as f64),
            source: (source.w as f64, source.h as f64),
        }
    }
}

/// Model-space box -> normalized original-frame box.
///
/// Every decode path takes one of these rather than an [`InputSize`], because
/// under a letterbox the model's coordinate space is *not* the frame's: part
/// of it is padding that never held any pixels. Dividing by the input size
/// there — the stretch rule — reports every box short and shifted. Making the
/// un-projection a value the decoder is handed is what makes forgetting it
/// impossible.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Projection {
    /// Model pixels per source pixel, per axis.
    scale: (f64, f64),
    /// Top-left of the content in model space.
    offset: (f64, f64),
    /// Original frame size, which the result is normalized by.
    source: (f64, f64),
}

impl Projection {
    /// `[x0, y0, x1, y1]` in model pixels -> the same box normalized 0..1
    /// against the original frame. Not clamped: [`det_from`] does that.
    pub fn unproject(&self, corners: [f64; 4]) -> [f64; 4] {
        let x = |v: f64| (v - self.offset.0) / self.scale.0 / self.source.0;
        let y = |v: f64| (v - self.offset.1) / self.scale.1 / self.source.1;
        [x(corners[0]), y(corners[1]), x(corners[2]), y(corners[3])]
    }

    /// The stretch projection for an input size, for callers with no frame in
    /// hand. Sound because under `Stretch` the source cancels out entirely.
    #[cfg(test)]
    pub fn stretch(input: InputSize) -> Self {
        ResizePolicy::Stretch.project(input, input)
    }
}

/// Everything a decoder needs to build a tensor this model will accept.
///
/// Carried as one value because the three parts are settled together at
/// startup and every scaler and GPU filter graph in the process is built for
/// all of them at once. In a built-in profile `size` is only a fallback: the
/// model's own declared geometry and `--input-size` both outrank it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputSpec {
    pub size: InputSize,
    pub encoding: TensorEncoding,
    pub resize: ResizePolicy,
}

/// Where the resolved [`InputSize`] came from, for the startup line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSizeSource {
    Model,
    Flag,
    Profile,
}

impl fmt::Display for InputSizeSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Model => "from model",
            Self::Flag => "from --input-size",
            Self::Profile => "from --model-profile default",
        })
    }
}

/// The model outputs one decode reads, in the roles its layout reads them.
///
/// Generic over what is carried so a layout's role structure is stated exactly
/// once and then reused at every stage: `Outputs<()>` is the role set itself,
/// `Outputs<Declared>` is what the export offers for those roles,
/// `Outputs<Vec<i64>>` their shapes, `Outputs<Raw>` the tensors a decode
/// reads. A single-output family never mentions any of this — its layout says
/// [`Outputs::One`] and everything downstream keeps working on one tensor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outputs<T> {
    /// One tensor, whatever the export calls it. Every grid, raw-classes and
    /// end-to-end head: the box and the class scores share it.
    One(T),
    /// DETR's pair, which cannot be one tensor because the boxes are a
    /// regression over queries and the logits a classification over the same
    /// queries, with different trailing extents.
    BoxesAndLogits { boxes: T, logits: T },
}

/// A layout's role structure with nothing attached.
pub type Roles = Outputs<()>;
/// The shape of each tensor a layout reads.
pub type Shapes = Outputs<Vec<i64>>;

impl<T> Outputs<T> {
    /// Rebuild the same roles over a different payload.
    fn map<U>(&self, mut f: impl FnMut(&T) -> U) -> Outputs<U> {
        match self {
            Self::One(one) => Outputs::One(f(one)),
            Self::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: f(boxes),
                logits: f(logits),
            },
        }
    }

    /// The same, for a payload that may be missing — `None` if any role's is.
    fn try_map<U>(&self, mut f: impl FnMut(&T) -> Option<U>) -> Option<Outputs<U>> {
        Some(match self {
            Self::One(one) => Outputs::One(f(one)?),
            Self::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: f(boxes)?,
                logits: f(logits)?,
            },
        })
    }

    /// Every role's payload, in the order an error message lists them.
    fn each(&self) -> Vec<&T> {
        match self {
            Self::One(one) => vec![one],
            Self::BoxesAndLogits { boxes, logits } => vec![boxes, logits],
        }
    }
}

/// How a detect head's output tensor is laid out.
///
/// The counts here (`nc`, and the anchor total the strides imply) are read off
/// the model's real output shape by [`fit_layout`]; a built-in profile carries
/// COCO's 80 only as the shape of the thing to fit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    /// `[1, N, 6]` rows of `[x1, y1, x2, y2, score, class_id]` in input
    /// pixels, already de-duplicated by the model (yolov10, YOLO26).
    EndToEnd,
    /// `[1, 4 + nc, A]` channels-first over A anchors: `cx, cy, w, h` in input
    /// pixels then `nc` class scores, no objectness (yolov8, yolo11).
    RawClasses { nc: usize },
    /// `[1, A, 5 + nc]` anchor-major, one anchor per cell of each stride's
    /// grid, the grids concatenated in `strides` order. `x, y` are offsets
    /// inside the anchor's own cell and `w, h` are log extents, both relative
    /// to that cell's stride; column 4 is objectness (yolox).
    GridObjectness {
        nc: usize,
        strides: &'static [usize],
    },
    /// DETR set prediction over a fixed number of object queries, across two
    /// tensors: `[1, Q, 4]` normalized `cx, cy, w, h` and `[1, Q, nc]` raw
    /// per-class logits.
    ///
    /// Nothing about this is a grid. There is no stride, no cell offset, no
    /// `exp` on the extents and no anchor: a query is a learned slot and its
    /// box is already the whole picture's coordinates, 0..1. Duplicates are
    /// suppressed by the bipartite matching the model was trained under, so
    /// there is no NMS either — running one would merge the distinct boxes two
    /// queries legitimately place on neighbouring objects.
    DetrQueries { nc: usize },
}

impl Layout {
    /// Classes the head emits, where the shape says.
    pub fn classes(self) -> Option<usize> {
        match self {
            Self::EndToEnd => None,
            Self::RawClasses { nc }
            | Self::GridObjectness { nc, .. }
            | Self::DetrQueries { nc } => Some(nc),
        }
    }

    /// Which of the model's outputs this layout reads, and as what.
    pub fn roles(self) -> Roles {
        match self {
            Self::EndToEnd | Self::RawClasses { .. } | Self::GridObjectness { .. } => {
                Outputs::One(())
            }
            Self::DetrQueries { .. } => Outputs::BoxesAndLogits {
                boxes: (),
                logits: (),
            },
        }
    }

    /// The output shape this layout expects, for error messages.
    fn expected(self, size: InputSize) -> String {
        match self {
            Self::EndToEnd => "[1, N, 6]".to_string(),
            Self::RawClasses { .. } => "[1, 4 + nc, A] with A far longer than 4 + nc".to_string(),
            Self::GridObjectness { strides, .. } => format!(
                "[1, {}, 5 + nc] at input {size}",
                grid_anchors(size, strides)
            ),
            Self::DetrQueries { .. } => "[1, Q, 4] boxes with [1, Q, nc] logits".to_string(),
        }
    }
}

impl fmt::Display for Layout {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EndToEnd => f.write_str("end-to-end [1, N, 6]"),
            Self::RawClasses { nc } => write!(f, "raw-classes [1, 4 + {nc}, A]"),
            Self::GridObjectness { nc, strides } => {
                let strides: Vec<String> = strides.iter().map(usize::to_string).collect();
                write!(
                    f,
                    "grid-objectness [1, A, 5 + {nc}] strides {}",
                    strides.join("/")
                )
            }
            Self::DetrQueries { nc } => write!(f, "detr-queries [1, Q, 4] + [1, Q, {nc}]"),
        }
    }
}

/// How an anchor's score is built from the columns the layout offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScoreComposition {
    /// The argmax class score stands alone (Ultralytics heads).
    Class,
    /// `objectness * class_score`. A YOLOX class score is confidently high on
    /// background cells that objectness is what rejects, so reading the class
    /// score alone keeps boxes the model meant to discard.
    ///
    /// Requires a layout with an objectness column ([`Layout::GridObjectness`]);
    /// with [`Layout::RawClasses`] there is none and this behaves as `Class`.
    ObjTimesClass,
    /// The argmax class *logit*, squashed by a sigmoid.
    ///
    /// Every other family here sigmoids inside the graph and hands out
    /// probabilities; a DETR export hands out raw logits and leaves the
    /// squash to its postprocess (`prob = out_logits.sigmoid()`), so a score
    /// floor applied to them directly would compare 0.5 against a number
    /// living in roughly -12..+2.
    ///
    /// Requires a layout whose scores are logits ([`Layout::DetrQueries`]).
    /// The grid and raw heads sigmoid inside the graph, so under those this
    /// behaves as `Class` rather than squashing a probability twice.
    SigmoidClass,
}

impl fmt::Display for ScoreComposition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Class => "class",
            Self::ObjTimesClass => "objectness x class",
            Self::SigmoidClass => "sigmoid(class logit)",
        })
    }
}

/// Class-aware greedy NMS parameters, for heads that emit raw proposals.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NmsSpec {
    /// IoU above which two same-class boxes are the same detection.
    pub iou: f64,
    /// Candidates carried into NMS, after sorting by score.
    ///
    /// A 640x640 raw head offers 8400 anchors and NMS is O(k^2); the cap
    /// bounds that at a few thousand IoU computations. It is applied *after*
    /// the score sort, so it can only ever discard the weakest candidates —
    /// and only ones already past their own class's floor, because every
    /// layout that reaches NMS gates per class at candidate time
    /// ([`candidates_from`]). Truncating before that gate would let a flood of
    /// high-scoring boxes in excluded classes push out the one class an
    /// allowlist configuration asked for.
    pub max_candidates: usize,
}

/// Ultralytics' own default for a detect head, and YOLOX's demo value too.
const DEFAULT_NMS: NmsSpec = NmsSpec {
    iou: 0.45,
    max_candidates: 300,
};

/// How this model's output is read.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OutputSpec {
    pub layout: Layout,
    pub score: ScoreComposition,
    /// `None` for a head that has already de-duplicated inside the model.
    pub nms: Option<NmsSpec>,
}

/// One detector family, start to finish.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelProfile {
    pub name: &'static str,
    /// Other names `--model-profile` accepts for this exact profile.
    ///
    /// An alias is a *name*, never a second entry in [`PROFILES`]: several
    /// Ultralytics generations export byte-identical tensor layouts, and
    /// listing each as its own profile would make every ordinary detect head
    /// sniff as three candidates and hard-error on an ambiguity that does not
    /// exist. Naming them here keeps `--model-profile yolo11` working while
    /// sniffing still sees one profile per distinct decode.
    pub aliases: &'static [&'static str],
    pub input: InputSpec,
    pub output: OutputSpec,
    /// The resolutions this family's variants are trained at, for a family
    /// whose exports leave their spatial axes dynamic.
    ///
    /// `Some` means `input.size` is *not* a usable default and
    /// [`resolve_input_size`] must refuse rather than fall back to it. The
    /// consequence of guessing is not a wrong-but-working run: an RF-DETR
    /// `small` export fed Nano's 384 produces zero detections and zero
    /// warnings, and nothing in the graph says which variant it is — every
    /// variant declares the same 300 queries and 91 logits. So the text here
    /// is what the error offers instead of a guess.
    pub variant_sizes: Option<&'static str>,
}

/// Megvii YOLOX (nano / tiny / s). Apache-2.0, the documented default.
pub const YOLOX: ModelProfile = ModelProfile {
    name: "yolox",
    aliases: &[],
    input: InputSpec {
        size: InputSize::square(416),
        encoding: TensorEncoding::RawBgr,
        resize: ResizePolicy::Letterbox { pad: 114 },
    },
    output: OutputSpec {
        layout: Layout::GridObjectness {
            nc: 80,
            strides: &[8, 16, 32],
        },
        score: ScoreComposition::ObjTimesClass,
        nms: Some(DEFAULT_NMS),
    },
    variant_sizes: None,
};

/// Ultralytics end-to-end / NMS-free heads (yolov10, YOLO26).
///
/// `yolo26` is an **unverified** alias: YOLO26 is documented as end-to-end and
/// NMS-free like yolov10, but no YOLO26 export has been run against this
/// decode — its weights are AGPL-3.0 and none is distributed here. If a real
/// one turns out to emit a different row width, sniffing rejects it outright
/// rather than decoding it wrong, and `--model-profile yolo26` fails the same
/// `fit_output` check.
pub const YOLOV10: ModelProfile = ModelProfile {
    name: "yolov10",
    aliases: &["yolo26"],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
    },
    output: OutputSpec {
        layout: Layout::EndToEnd,
        score: ScoreComposition::Class,
        nms: None,
    },
    variant_sizes: None,
};

/// Stock Ultralytics detect exports.
///
/// yolov8, yolov9, yolo11 and yolov11 are all this one profile: every
/// generation's detect head exports the same `[1, 4 + nc, A]` channels-first
/// tensor with no objectness, fed 0..1 RGB stretched to a square, and needs
/// the same NMS afterwards. They differ in weights and backbone, which is not
/// something a decode can see. Verified against a yolov8n export; the others
/// are the same tensor contract by construction, and any export that is not is
/// rejected by `fit_output` rather than decoded wrong.
pub const YOLOV8: ModelProfile = ModelProfile {
    name: "yolov8",
    aliases: &["yolov9", "yolo11", "yolov11"],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
    },
    output: OutputSpec {
        layout: Layout::RawClasses { nc: 80 },
        score: ScoreComposition::Class,
        nms: Some(DEFAULT_NMS),
    },
    variant_sizes: None,
};

/// Roboflow RF-DETR (nano / small / base / medium / large). Apache-2.0.
///
/// The size here is Nano's, and it is deliberately *not* a default: every
/// RF-DETR export leaves its input spatial axes dynamic, so a larger variant
/// fed 384 runs to completion and detects nothing. `variant_sizes` is what
/// makes [`resolve_input_size`] refuse to guess and ask for `--input-size`.
pub const RFDETR: ModelProfile = ModelProfile {
    name: "rfdetr",
    aliases: &["rf-detr"],
    input: InputSpec {
        size: InputSize::square(384),
        encoding: TensorEncoding::ImageNetRgb,
        resize: ResizePolicy::Stretch,
    },
    output: OutputSpec {
        // 91 is COCO's *id* space, not its class count: RF-DETR indexes
        // logits by the raw COCO category id (1 = person, 3 = car, 64 =
        // potted plant), leaving 0 and the eleven retired ids unused. A
        // `--labels` file for it therefore has 91 lines, not 80.
        layout: Layout::DetrQueries { nc: 91 },
        score: ScoreComposition::SigmoidClass,
        nms: None,
    },
    variant_sizes: Some("nano 384, small 512, base 560, medium 576, large 704"),
};

/// Every profile `--model-profile` accepts and sniffing considers, in the
/// order an ambiguity error lists them.
pub const PROFILES: &[ModelProfile] = &[YOLOX, YOLOV10, YOLOV8, RFDETR];

impl ModelProfile {
    /// `--model-profile` value parser, so a typo's error names the real set.
    pub fn parse(name: &str) -> Result<Self> {
        let wanted = name.trim().to_ascii_lowercase();
        PROFILES
            .iter()
            .find(|profile| profile.name == wanted || profile.aliases.contains(&wanted.as_str()))
            .copied()
            .ok_or_else(|| {
                anyhow!(
                    "unknown model profile {name:?}; expected one of {}",
                    names()
                )
            })
    }
}

/// Every accepted `--model-profile` value, aliases shown against the profile
/// they resolve to so the error says what `yolo11` will actually do.
fn names() -> String {
    PROFILES
        .iter()
        .map(|profile| match profile.aliases {
            [] => profile.name.to_string(),
            aliases => format!("{} (or {})", profile.name, aliases.join(", ")),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

impl fmt::Display for ModelProfile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name)
    }
}

/// Anchors a grid head produces at `size`: one per cell of each stride's grid.
///
/// This is both the decode table's length and the thing that tells a YOLOX
/// output apart from the other `[1, A, 5 + nc]` head in the wild — yolov5,
/// whose three anchor boxes per cell make A exactly 3x this and whose boxes
/// are already in pixels. Decoding one as the other would emit plausible
/// garbage, so the count is checked rather than assumed.
fn grid_anchors(size: InputSize, strides: &[usize]) -> usize {
    strides
        .iter()
        .map(|stride| (size.w / stride) * (size.h / stride))
        .sum()
}

/// A grid head only decodes at a size its strides divide.
///
/// [`grid_anchors`] floor-divides, and so does the walk in
/// [`grid_objectness`]. At a size the coarsest stride does not divide, both
/// agree with each other and neither agrees with the model: a real head lays
/// its cells out by the ceiling its own downsampling produced. The total-count
/// check in [`validate_layout`] catches that whenever the two totals differ,
/// but they can coincide — and when they do every box lands in the wrong cell,
/// which is wrong coordinates with nothing on stderr. So the size is rejected
/// at startup instead, where the operator who typed it is still watching.
fn check_grid_divides_input(layout: Layout, size: InputSize) -> Result<()> {
    let Layout::GridObjectness { strides, .. } = layout else {
        return Ok(());
    };
    let Some(&coarsest) = strides.iter().max() else {
        return Ok(());
    };
    if !size.w.is_multiple_of(coarsest) || !size.h.is_multiple_of(coarsest) {
        bail!(
            "input size {size} is not a multiple of {coarsest}, the coarsest stride of a \
             grid-objectness head — its cells would be walked in a layout the model does not \
             use, putting every box in the wrong cell. Round each axis to a multiple of \
             {coarsest}."
        );
    }
    Ok(())
}

/// One of the model's outputs, as its own metadata declares it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declared {
    pub name: String,
    /// Dims when the export pins the ones that identify a layout, `None`
    /// otherwise. See [`static_output_dims`].
    pub dims: Option<Vec<i64>>,
}

/// The model's outputs, for an error that has to say what it actually found.
fn describe_outputs(declared: &[Declared]) -> String {
    if declared.is_empty() {
        return "no outputs".to_string();
    }
    declared
        .iter()
        .map(|output| match &output.dims {
            Some(dims) => format!("{:?} {dims:?}", output.name),
            None => format!("{:?} (dynamic)", output.name),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Output dims when the export pins the ones that matter, `None` when it does
/// not.
///
/// A symbolic *batch* axis is not a dynamic layout. This plugin feeds exactly
/// one frame per run, so axis 0 is 1 whatever the export left there, and
/// refusing to read the rest would leave every RF-DETR export — which pins
/// `[?, 300, 4]` and `[?, 300, 91]` and nothing else — unsniffable for a
/// reason that says nothing about how it decodes. Every *other* axis carries
/// a count a layout is identified by, and a symbolic one there really does
/// leave nothing to go on.
fn static_output_dims(dtype: &ValueType) -> Option<Vec<i64>> {
    let ValueType::Tensor { shape, .. } = dtype else {
        return None;
    };
    let mut dims = shape.to_vec();
    let (batch, rest) = dims.split_first_mut()?;
    if !rest.iter().all(|d| *d > 0) {
        return None;
    }
    if *batch < 0 {
        *batch = 1;
    }
    Some(dims)
}

/// Bind a layout's roles to this model's actual outputs.
///
/// [`Outputs::One`] takes the model's first output, exactly as every
/// single-output family always has: an export with auxiliary outputs stays
/// readable rather than becoming newly fatal.
///
/// [`Outputs::BoxesAndLogits`] reads the roles off the *shapes* rather than
/// the names, because the two RF-DETR export toolchains disagree about names
/// and agree about shapes — Roboflow's own `export()` emits `dets`/`labels`,
/// the transformers/onnx-community conversion emits `pred_boxes`/`logits`, and
/// a name table would reject whichever it did not list. The rank-3 output
/// whose last axis is 4 is the boxes; the rank-3 output over the same query
/// axis is the logits. Two candidates for a role (a genuinely 4-class DETR
/// would do it) or none is an error naming what the model offers, never a
/// guess at which is which.
///
/// An export that pins *no* shape at all — `optimum`'s `dynamic_axes` will
/// happily leave the query axis symbolic, giving `[?, ?, 4]` / `[?, ?, 91]` —
/// leaves the shape rule nothing to read, and falls back to
/// [`bind_detr_by_name`]. See its comment for why that is safe here and not a
/// general licence to bind by name.
fn bind(roles: Roles, declared: &[Declared]) -> Result<Outputs<Declared>> {
    match roles {
        Outputs::One(()) => declared
            .first()
            .cloned()
            .map(Outputs::One)
            .ok_or_else(|| anyhow!("model has no outputs")),
        Outputs::BoxesAndLogits { .. } => {
            let (mut boxes, mut logits) = (None, None);
            let mut clash = false;
            for output in declared {
                let Some(dims) = output.dims.as_deref() else {
                    continue;
                };
                if dims.len() != 3 || dims[0] != 1 || dims[1] < 1 || dims[2] < 1 {
                    continue;
                }
                let slot = if dims[2] == 4 {
                    &mut boxes
                } else {
                    &mut logits
                };
                clash |= slot.is_some();
                *slot = Some(output.clone());
            }
            let paired = match (boxes, logits) {
                (Some(boxes), Some(logits)) if !clash => {
                    let queries = |output: &Declared| output.dims.as_ref().map(|d| d[1]);
                    (queries(&boxes) == queries(&logits))
                        .then_some(Outputs::BoxesAndLogits { boxes, logits })
                }
                _ => None,
            };
            // Only when the export pins nothing: a model that declares shapes
            // and does not fit is a mismatch to report, not a name to guess at.
            let unshaped = declared.iter().all(|output| output.dims.is_none());
            paired
                .or_else(|| unshaped.then(|| bind_detr_by_name(declared)).flatten())
                .ok_or_else(|| {
                    anyhow!(
                        "expected one [1, Q, 4] box output and one [1, Q, nc] logit output over \
                         the same Q queries, but the model offers {}{}",
                        describe_outputs(declared),
                        // The shape rule had nothing to read, so say what the
                        // fallback wanted rather than repeating shapes.
                        if unshaped {
                            "; with no shape to read the roles from, the names have to say which \
                             is which (pred_boxes/logits or dets/labels)"
                        } else {
                            ""
                        }
                    )
                })
        }
    }
}

/// Bind a DETR pair by name, for an export that pins neither shape.
///
/// This is the fallback the shape rule refuses to be: names are a weaker
/// signal, and the two RF-DETR exporters disagree about them, which is exactly
/// why `bind` reads shapes first. It is safe as a *last* resort because the
/// binding is not trusted — [`decode_output`] re-runs [`validate_layout`]
/// against the real runtime dims on every frame, so a pair bound the wrong way
/// round fails loudly on the first output (the boxes tensor would not have a
/// last axis of 4) instead of decoding garbage. Without it, an export whose
/// query axis is symbolic cannot be run at all, not even with
/// `--model-profile rfdetr`, and the error blames the profile rather than the
/// export.
///
/// Both known exporters are covered — Roboflow's `dets`/`labels` and the
/// transformers conversion's `pred_boxes`/`logits`. A name that claims both
/// roles or neither settles nothing, and two claims on one role is an
/// ambiguity to report rather than an order to trust.
fn bind_detr_by_name(declared: &[Declared]) -> Option<Outputs<Declared>> {
    let (mut boxes, mut logits) = (None, None);
    for output in declared {
        let name = output.name.to_ascii_lowercase();
        let says_boxes = name.contains("box") || name.contains("det");
        let says_logits =
            name.contains("logit") || name.contains("label") || name.contains("score");
        let slot = match (says_boxes, says_logits) {
            (true, false) => &mut boxes,
            (false, true) => &mut logits,
            _ => continue,
        };
        if slot.is_some() {
            return None;
        }
        *slot = Some(output.clone());
    }
    Some(Outputs::BoxesAndLogits {
        boxes: boxes?,
        logits: logits?,
    })
}

/// The shapes bound to a layout's roles, when the export pins all of them.
fn static_shapes(roles: Roles, declared: &[Declared]) -> Option<Shapes> {
    bind(roles, declared)
        .ok()?
        .try_map(|output| output.dims.clone())
}

/// The bound shapes, as an error message lists them.
fn show(shapes: &Shapes) -> String {
    shapes
        .each()
        .into_iter()
        .map(|dims| format!("{dims:?}"))
        .collect::<Vec<_>>()
        .join(" + ")
}

/// Read a layout's own counts off a real output shape, or say why it does not
/// fit.
///
/// Nothing here guesses: the layout kind is given, and this only fills in what
/// the shape declares (`nc`) and refuses shapes the kind cannot describe.
fn fit_layout(layout: Layout, shapes: &Shapes, size: InputSize) -> Result<Layout> {
    // Every arm requires the roles to match first, so a two-tensor shape can
    // never be read as a one-tensor head or the reverse.
    let fitted = match (layout, shapes) {
        (Layout::EndToEnd, Outputs::One(dims)) if rank3(dims) && dims[2] == 6 => {
            Some(Layout::EndToEnd)
        }
        // The anchor axis of a channels-first head runs into the thousands
        // against a channel axis of `4 + nc`, which is what orients it.
        (Layout::RawClasses { .. }, Outputs::One(dims))
            if rank3(dims) && dims[1] >= 5 && dims[2] > dims[1] * 4 =>
        {
            Some(Layout::RawClasses {
                nc: (dims[1] - 4) as usize,
            })
        }
        (Layout::GridObjectness { strides, .. }, Outputs::One(dims))
            if rank3(dims) && dims[2] >= 6 && dims[1] == grid_anchors(size, strides) as i64 =>
        {
            Some(Layout::GridObjectness {
                nc: (dims[2] - 5) as usize,
                strides,
            })
        }
        (Layout::DetrQueries { .. }, Outputs::BoxesAndLogits { boxes, logits })
            if rank3(boxes)
                && rank3(logits)
                && boxes[2] == 4
                && logits[2] >= 1
                && boxes[1] == logits[1] =>
        {
            Some(Layout::DetrQueries {
                nc: logits[2] as usize,
            })
        }
        _ => None,
    };
    fitted.ok_or_else(|| {
        anyhow!(
            "output shape {} does not fit {layout}; expected {}",
            show(shapes),
            layout.expected(size)
        )
    })
}

/// A single-frame rank-3 output, the shape every layout here indexes.
fn rank3(dims: &[i64]) -> bool {
    dims.len() == 3 && dims[0] == 1
}

/// Does a *resolved* layout describe `dims` exactly?
///
/// Deliberately not [`fit_layout`]: that one discriminates between kinds and
/// leans on heuristics ("the anchor axis is far longer than the channel axis")
/// to do it. Once the kind and its counts are settled, the only question left
/// is whether this tensor has the extents that layout indexes by — a head with
/// one anchor is perfectly decodable and the sniffing heuristic would refuse
/// it.
fn validate_layout(layout: Layout, shapes: &Shapes, size: InputSize) -> Result<()> {
    let ok = match (layout, shapes) {
        (Layout::EndToEnd, Outputs::One(dims)) => rank3(dims) && dims[2] == 6,
        (Layout::RawClasses { nc }, Outputs::One(dims)) => {
            rank3(dims) && dims[1] == (4 + nc) as i64
        }
        (Layout::GridObjectness { nc, strides }, Outputs::One(dims)) => {
            rank3(dims)
                && dims[1] == grid_anchors(size, strides) as i64
                && dims[2] == (5 + nc) as i64
        }
        (Layout::DetrQueries { nc }, Outputs::BoxesAndLogits { boxes, logits }) => {
            rank3(boxes)
                && rank3(logits)
                && boxes[2] == 4
                && boxes[1] == logits[1]
                && logits[2] == nc as i64
        }
        _ => false,
    };
    if !ok {
        bail!(
            "expected a {layout} output at input {size}, got {}",
            show(shapes)
        );
    }
    Ok(())
}

/// The same, for a whole output half.
fn fit_output(spec: OutputSpec, shapes: &Shapes, size: InputSize) -> Result<OutputSpec> {
    Ok(OutputSpec {
        layout: fit_layout(spec.layout, shapes, size)?,
        ..spec
    })
}

/// Which built-in profiles this output shape could be.
///
/// Returning every match rather than the first is the whole point: at 640x384
/// a `[1, 5040, 6]` output is a 1-class yolox grid head *and* an end-to-end
/// `[1, N, 6]` row set, because 5040 is exactly that input's anchor count and
/// 6 is exactly the end-to-end row width. Picking one silently would read four
/// numbers that are cell offsets and log extents as final pixel corners, or
/// the reverse — plausible boxes, wrong ones.
///
/// (`[1, 8400, 84]` at 640 is *not* an example of this: `RawClasses` requires
/// `dims[2] > dims[1] * 4`, which an anchor-major shape fails, so that one
/// sniffs as yolox alone.)
fn sniff(declared: &[Declared], size: InputSize) -> Vec<ModelProfile> {
    PROFILES
        .iter()
        .filter_map(|profile| {
            let shapes = static_shapes(profile.output.layout.roles(), declared)?;
            fit_output(profile.output, &shapes, size)
                .ok()
                .map(|output| ModelProfile { output, ..*profile })
        })
        .collect()
}

/// Settle which profile this model is run under.
///
/// `explicit` is `--model-profile`; it wins outright and is then *validated*
/// against the model's real output, because a profile that does not describe
/// the model is worse than no profile at all.
fn resolve_profile(
    explicit: Option<ModelProfile>,
    declared: &[Declared],
    size: InputSize,
    model: &Path,
) -> Result<(ModelProfile, Outputs<String>, Option<OutputSpec>)> {
    let Some(profile) = explicit else {
        return sniff_profile(declared, size, model);
    };
    let mismatch = || {
        format!(
            "--model-profile {profile} does not describe model {}",
            model.display()
        )
    };
    // A profile that names roles the model does not offer is settled here,
    // before any frame is packed for it.
    let bound = bind(profile.output.layout.roles(), declared).with_context(mismatch)?;
    let output = match bound.try_map(|output| output.dims.clone()) {
        Some(shapes) => Some(fit_output(profile.output, &shapes, size).with_context(mismatch)?),
        // A dynamic output shape declares nothing to validate against; the
        // input half is still fully known, so frames can be packed correctly
        // and only `nc` waits for the first real output. This covers the
        // two-tensor families as well as the one-tensor ones: `bind` has
        // already settled the roles above — by shape where the export pins
        // them, by name where it pins nothing — and `decode_output` re-checks
        // the layout against the real dims on every frame, so a deferral that
        // guessed wrong fails on the first output rather than decoding it.
        None => None,
    };
    Ok((profile, bound.map(|output| output.name.clone()), output))
}

/// The `--model-profile`-less half of [`resolve_profile`].
fn sniff_profile(
    declared: &[Declared],
    size: InputSize,
    model: &Path,
) -> Result<(ModelProfile, Outputs<String>, Option<OutputSpec>)> {
    let mut candidates = sniff(declared, size);
    let named = |profiles: &[ModelProfile], sep: &str| {
        profiles
            .iter()
            .map(|p| p.name)
            .collect::<Vec<_>>()
            .join(sep)
    };
    match candidates.len() {
        1 => {
            let profile = candidates.remove(0);
            let bound = bind(profile.output.layout.roles(), declared)?;
            Ok((
                profile,
                bound.map(|output| output.name.clone()),
                Some(profile.output),
            ))
        }
        // Nothing bound *and* pinned its shapes for any profile: there is no
        // shape here to have found unsupported, only an export that declined
        // to declare one.
        0 if !PROFILES
            .iter()
            .any(|p| static_shapes(p.output.layout.roles(), declared).is_some()) =>
        {
            bail!(
                "model {} leaves its output shape dynamic, so there is nothing to sniff a \
                 profile from — and the encoding and resize policy have to be settled before \
                 the first frame is converted. Pass --model-profile <{}>.",
                model.display(),
                names()
            )
        }
        0 => bail!(
            "model {} has unsupported outputs {} at input {size}; expected {}",
            model.display(),
            describe_outputs(declared),
            PROFILES
                .iter()
                .map(|p| format!("{} ({})", p.output.layout.expected(size), p.name))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        _ => bail!(
            "model {} has outputs {}, which at input {size} fit more than one profile: {}. \
             Nothing in the shapes says which, and they decode differently — pass \
             --model-profile <{}> to say.",
            model.display(),
            describe_outputs(declared),
            named(&candidates, " and "),
            named(&candidates, "|")
        ),
    }
}

/// A label file that does not describe the model's classes is a fault, not a
/// degraded output.
///
/// [`Labels::label_for`] indexes the file *positionally*, so a count mismatch
/// is not "some ids render as numbers" — it is every detection carrying
/// another class's name. The two documented models make the trap concrete:
/// YOLOX emits dense COCO-80 class indices and RF-DETR emits the raw COCO
/// category id (1 = person, 3 = car), so `coco.names` against an RF-DETR
/// export renders every person as `bicycle` and every car as `motorcycle`.
/// Nothing downstream can tell: Cairn records events, crops snapshots and
/// drives Home Assistant under the wrong label, and the per-label score floors
/// gate the wrong class on the way. Swapping `--model` and forgetting
/// `--labels` is the likely operator path and its symptom is plausible data,
/// so it fails at startup instead.
///
/// Only a *count* mismatch is detectable from here; a same-length file in the
/// wrong order is not, and no check can find it.
fn check_label_count(layout: Layout, labels: &Labels, allow_mismatch: bool) -> Result<()> {
    let Some(classes) = layout.classes() else {
        return Ok(());
    };
    let provided = labels.count();
    // 0 is "--labels was not given", which is supported: ids render as numbers.
    if provided == 0 || provided == classes || allow_mismatch {
        return Ok(());
    }
    bail!(
        "--labels lists {provided} names but the model has {classes} classes. Labels are indexed \
         by class id, so every detection would be emitted under another class's name — and the \
         per-label min_score floors would gate the wrong class. coco.names is the 80-entry dense \
         COCO class list (yolox, yolov8/v10); coco91.names is the 91-slot COCO *category id* \
         space RF-DETR indexes its logits by. Pass --allow-label-mismatch to run anyway."
    )
}

/// Per-class score floor from `--min-score-json`. Cairn enforces these again
/// downstream; gating here just keeps the ndjson small.
#[derive(Debug, Clone)]
pub struct ScoreFloors {
    default: f64,
    by_label: HashMap<String, f64>,
}

impl ScoreFloors {
    pub fn parse(json: &str) -> Result<Self> {
        let raw: HashMap<String, f64> = serde_json::from_str(json)
            .context("--min-score-json is not a JSON object of number")?;
        Ok(Self::from_map(raw))
    }

    /// Same floors from an already-decoded map (the `--cameras-json` form).
    pub fn from_map(raw: HashMap<String, f64>) -> Self {
        Self {
            default: raw.get("default").copied().unwrap_or(0.5),
            by_label: raw,
        }
    }

    pub fn floor_for(&self, label: &str) -> f64 {
        self.by_label.get(label).copied().unwrap_or(self.default)
    }

    /// The lowest floor any label could be held to.
    ///
    /// Only [`Layout::EndToEnd`] needs it: its class id is a number in the
    /// output row rather than an index into a known `nc`, so there is no
    /// per-class floor table to look one up in. It has to be the floor no
    /// configured label can undercut — anything higher would silently drop
    /// detections a per-label floor admits.
    pub fn min_floor(&self) -> f64 {
        self.by_label.values().copied().fold(self.default, f64::min)
    }
}

#[derive(Debug)]
pub struct Labels(Vec<String>);

/// Cap on the `--labels` file, which is operator-supplied and otherwise read
/// whole: `--labels /dev/zero` would never return.
const MAX_LABELS_BYTES: u64 = 1 << 20;

/// Cap on entries, for the same reason from the other direction. Past any real
/// class space — the largest here is COCO's 91-slot id space, and Open Images
/// tops out around 600.
const MAX_LABELS: usize = 4096;

impl Labels {
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let Some(path) = path else {
            return Ok(Self(Vec::new()));
        };
        let read = || -> std::io::Result<String> {
            use std::io::Read;
            let mut text = String::new();
            std::fs::File::open(path)?
                .take(MAX_LABELS_BYTES + 1)
                .read_to_string(&mut text)?;
            Ok(text)
        };
        let text = read().with_context(|| format!("reading labels from {}", path.display()))?;
        if text.len() as u64 > MAX_LABELS_BYTES {
            bail!(
                "labels file {} is over {MAX_LABELS_BYTES} bytes; it is read whole and indexed by \
                 class id, so it is a class list, not a corpus",
                path.display()
            );
        }
        // Positions are the class ids, so a blank line is an *unnamed slot*,
        // not something to skip: filtering one out would shift every later
        // label by one, permanently and silently. A gap is the natural way to
        // write a retired id in a COCO-91 file, and `label_for` already renders
        // an empty entry the way it renders a missing one — as the bare id.
        // Only the trailing newline every text file ends with is dropped.
        let mut names: Vec<String> = text.lines().map(|line| line.trim().to_string()).collect();
        while names.last().is_some_and(String::is_empty) {
            names.pop();
        }
        if names.len() > MAX_LABELS {
            bail!(
                "labels file {} lists {} names, over the {MAX_LABELS} cap",
                path.display(),
                names.len()
            );
        }
        Ok(Self(names))
    }

    /// Names loaded; 0 when `--labels` was not given.
    pub fn count(&self) -> usize {
        self.0.len()
    }

    /// Unknown class ids fall back to their numeric id, so a mismatched label
    /// file degrades the output instead of hiding detections. An *unnamed*
    /// slot — a blank line, which a gap-id file writes for a retired id —
    /// falls back the same way rather than emitting `""`, which the host
    /// refuses.
    pub fn label_for(&self, class_id: usize) -> String {
        self.0
            .get(class_id)
            .filter(|name| !name.is_empty())
            .cloned()
            .unwrap_or_else(|| class_id.to_string())
    }
}

/// Spatial dims declared by a `[N, 3, H, W]` model input, if it pins them.
///
/// Only a confidently NCHW 3-channel shape yields a size. Everything else —
/// a non-tensor input, a rank other than 4, an NHWC `[1, H, W, 3]`, a dynamic
/// or non-3 channel axis, and the common case of an export with dynamic
/// spatial axes (which onnxruntime reports as `-1`) — returns `None` and
/// leaves the size to `--input-size` or the profile's default.
///
/// The channel axis is checked rather than skipped over because the whole
/// pipeline hardcodes 3-channel RGB: [`RgbScaler`] emits RGB24 and
/// [`InputSize::tensor_len`] packs `3 * w * h`. Without the check an NHWC
/// export reads as `w = 3`, which builds a 3-pixel-wide scaler and a garbage
/// tensor before onnxruntime ever sees the mismatch.
///
/// [`RgbScaler`]: crate::decode::RgbScaler
fn declared_input_size(dtype: &ValueType) -> Option<InputSize> {
    let ValueType::Tensor { shape, .. } = dtype else {
        return None;
    };
    if shape.len() != 4 || shape[1] != 3 {
        return None;
    }
    let (h, w) = (shape[2], shape[3]);
    if h <= 0 || w <= 0 {
        return None;
    }
    Some(InputSize {
        w: w as usize,
        h: h as usize,
    })
}

/// Settle the size the whole pipeline is built for.
///
/// A flag that contradicts a model's static shape is rejected here rather
/// than left to fail inside `Session::run` on the first sampled frame, where
/// the message is onnxruntime's and the process has already been running for
/// a minute. A profile's own size is only a last resort: it is a family
/// default, not a statement about this export.
///
/// A profile carrying [`ModelProfile::variant_sizes`] has no usable default at
/// all, so it supplies none: for a family whose every export leaves its spatial
/// axes dynamic, one variant's resolution guessed at another's is not a
/// wrong-but-working run, it is a camera that silently detects nothing. The
/// error lists the resolutions instead of picking one.
fn resolve_input_size(
    declared: Option<InputSize>,
    requested: Option<InputSize>,
    profile: Option<ModelProfile>,
    model: &Path,
) -> Result<(InputSize, InputSizeSource)> {
    let fallback = profile
        .filter(|profile| profile.variant_sizes.is_none())
        .map(|profile| profile.input.size);
    let (size, source) = match (requested, declared) {
        (Some(requested), Some(declared)) if requested != declared => bail!(
            "--input-size {requested} contradicts model {}, whose input is {declared}",
            model.display()
        ),
        (Some(requested), _) => (requested, InputSizeSource::Flag),
        (None, Some(declared)) => (declared, InputSizeSource::Model),
        (None, None) => match (fallback, profile.and_then(|p| p.variant_sizes)) {
            (Some(fallback), _) => (fallback, InputSizeSource::Profile),
            // The profile is known and still cannot answer: say so, and say
            // what the answer is likely to be, rather than reporting a bare
            // "does not pin" that reads as if the profile were missing too.
            (None, Some(sizes)) => bail!(
                "model {} does not pin its input width and height, and the {} profile has no \
                 default to fall back on — every export in the family leaves its spatial axes \
                 dynamic and declares nothing that says which variant it is. Pass --input-size \
                 WxH (or N); the variants are trained at {sizes}. A wrong size here is silent: \
                 the model runs and detects nothing.",
                model.display(),
                profile.map(|p| p.name).unwrap_or_default(),
            ),
            (None, None) => bail!(
                "model {} does not pin its input width and height; pass --input-size WxH (or N)",
                model.display()
            ),
        },
    };
    // Every provenance funnels through here, so both ceilings cover a model's
    // declared dims as well as a typo'd flag. Zero is already impossible:
    // `dim` rejects it on the flag and `declared_input_size` requires `> 0`.
    if size.w > MAX_INPUT_DIM || size.h > MAX_INPUT_DIM {
        bail!("input size {size} ({source}) exceeds the {MAX_INPUT_DIM} per-dimension limit");
    }
    // The per-axis bound is about casts; this one is about memory, and a size
    // inside the first can be far outside the second (8192x8192 is a 1 GB
    // working set per camera). `saturating_mul` because the product is exactly
    // what is being questioned.
    let pixels = size.w.saturating_mul(size.h);
    if pixels > MAX_INPUT_PIXELS {
        bail!(
            "input size {size} ({source}) is {pixels} pixels, over the {MAX_INPUT_PIXELS}-pixel \
             limit (2048x2048): the CHW f32 tensor alone would be {} MB, per camera",
            pixels.saturating_mul(3 * std::mem::size_of::<f32>()) / (1024 * 1024),
        );
    }
    Ok((size, source))
}

pub struct Detector {
    session: Session,
    input_name: String,
    /// The model's own name for each tensor this profile's layout reads,
    /// settled at startup so a decode never looks one up by index.
    outputs: Outputs<String>,
    profile: ModelProfile,
    input_size: InputSize,
    input_size_source: InputSizeSource,
    /// `None` until the first output settles `nc`, which only happens for an
    /// export that leaves its output shape dynamic.
    output: Option<OutputSpec>,
    /// `--allow-label-mismatch`, carried because a deferred layout only
    /// settles `nc` on the first real output — see [`check_label_count`].
    allow_label_mismatch: bool,
}

impl Detector {
    /// `requested` is `--input-size`, `profile` is `--model-profile`; absent,
    /// the profile is sniffed from the model's own I/O. `labels` is read to
    /// reject a class-count mismatch, which would mislabel every detection.
    pub fn open(
        model: &Path,
        requested: Option<InputSize>,
        profile: Option<ModelProfile>,
        labels: &Labels,
        allow_label_mismatch: bool,
    ) -> Result<Self> {
        // ort's builder errors carry the builder itself for recovery, which
        // makes them neither Send nor Sync; flatten them to a message.
        let session = Session::builder()
            .map_err(|e| anyhow!("creating an onnxruntime session builder: {e}"))?
            .with_execution_providers([ort::ep::CPU::default().build()])
            .map_err(|e| anyhow!("registering the CPU execution provider: {e}"))?
            .commit_from_file(model)
            .with_context(|| format!("loading model {}", model.display()))?;
        // Both names are resolved at startup so a model with the wrong shape
        // fails here with a clear message rather than by index inside the
        // inference thread on the first frame.
        let input = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no inputs", model.display()))?;
        let input_name = input.name().to_string();
        let (input_size, input_size_source) = resolve_input_size(
            declared_input_size(input.dtype()),
            requested,
            profile,
            model,
        )?;
        let declared: Vec<Declared> = session
            .outputs()
            .iter()
            .map(|output| Declared {
                name: output.name().to_string(),
                dims: static_output_dims(output.dtype()),
            })
            .collect();
        if declared.is_empty() {
            bail!("model {} has no outputs", model.display());
        }
        let (profile, outputs, output) = resolve_profile(profile, &declared, input_size, model)?;
        check_grid_divides_input(profile.output.layout, input_size)?;
        if let Some(output) = output {
            check_label_count(output.layout, labels, allow_label_mismatch)?;
        }
        Ok(Self {
            session,
            input_name,
            outputs,
            profile,
            input_size,
            input_size_source,
            output,
            allow_label_mismatch,
        })
    }

    pub fn input_name(&self) -> &str {
        &self.input_name
    }

    pub fn profile(&self) -> ModelProfile {
        self.profile
    }

    /// Everything a decoder needs to build a tensor this model accepts,
    /// with the size the *model* resolved to rather than the profile default.
    pub fn input_spec(&self) -> InputSpec {
        InputSpec {
            size: self.input_size,
            ..self.profile.input
        }
    }

    pub fn input_size_source(&self) -> InputSizeSource {
        self.input_size_source
    }

    /// Startup description of the output layout, deferred when the export
    /// leaves its output shape dynamic.
    pub fn layout_summary(&self) -> String {
        match self.output {
            Some(output) => format!("{} (from model)", output.layout),
            None => format!("{} (nc from first output)", self.profile.output.layout),
        }
    }

    pub fn detect(
        &mut self,
        tensor: Vec<f32>,
        projection: Projection,
        labels: &Labels,
        floors: &ScoreFloors,
    ) -> Result<Vec<Det>> {
        let shape = [1i64, 3, self.input_size.h as i64, self.input_size.w as i64];
        let input = Tensor::from_array((shape, tensor)).context("building the input tensor")?;
        let outputs = self
            .session
            .run(ort::inputs![self.input_name.as_str() => input])
            .context("running inference")?;
        // Extract every role this profile reads, by the name settled at
        // startup, so a two-tensor family never depends on output ordering.
        let extract = |name: &String| -> Result<Raw> {
            let (shape, values) = outputs
                .get(name.as_str())
                .ok_or_else(|| anyhow!("model produced no output named {name}"))?
                .try_extract_tensor::<f32>()
                .with_context(|| format!("model output {name} is not an f32 tensor"))?;
            Ok(Raw {
                dims: shape.iter().copied().collect(),
                values,
            })
        };
        let raw = match &self.outputs {
            Outputs::One(name) => Outputs::One(extract(name)?),
            Outputs::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: extract(boxes)?,
                logits: extract(logits)?,
            },
        };
        let shapes = raw.map(|tensor| tensor.dims.clone());
        let output = match self.output {
            Some(output) => output,
            None => {
                let output = fit_output(self.profile.output, &shapes, self.input_size)
                    .with_context(|| format!("--model-profile {}", self.profile))?;
                check_label_count(output.layout, labels, self.allow_label_mismatch)?;
                eprintln!("output layout: {} (from first output)", output.layout);
                self.output = Some(output);
                output
            }
        };
        decode_output(output, &raw, labels, floors, self.input_size, &projection)
    }
}

/// One extracted output tensor: the values and the shape they came with.
struct Raw<'a> {
    dims: Vec<i64>,
    values: &'a [f32],
}

/// Read one output tensor into contract detections.
///
/// The dims are re-checked against the layout even when it came from metadata:
/// an export whose declared shape and real shape disagree would otherwise
/// index a tensor by the wrong stride and emit plausible garbage.
fn decode_output(
    output: OutputSpec,
    raw: &Outputs<Raw>,
    labels: &Labels,
    floors: &ScoreFloors,
    size: InputSize,
    projection: &Projection,
) -> Result<Vec<Det>> {
    validate_layout(output.layout, &raw.map(|tensor| tensor.dims.clone()), size)?;
    let candidates = candidates_from(output, raw, size, labels, floors)?;
    Ok(finish(candidates, output.nms, labels, floors, projection))
}

/// The floor each of a layout's `nc` classes is held to, resolved once per
/// decode rather than per anchor.
///
/// [`ScoreFloors`] is keyed by label and [`Labels::label_for`] allocates, so
/// looking a floor up inside a `Q x nc` or `A x nc` loop would allocate tens of
/// thousands of strings a frame. The class id is the only thing a decode has,
/// and this is the map between them.
///
/// Built per decode rather than cached on [`Detector`] because the floors are
/// per *camera*: one multiplexed process serves a group whose members each
/// carry their own `min_score`, so a table cached beside the session would be
/// the wrong one for every member but the first.
fn class_floors(nc: usize, labels: &Labels, floors: &ScoreFloors) -> Vec<f64> {
    (0..nc)
        .map(|class_id| floors.floor_for(&labels.label_for(class_id)))
        .collect()
}

/// One proposal in model-space pixels, before NMS and un-projection.
struct Candidate {
    score: f64,
    class_id: usize,
    /// `[x0, y0, x1, y1]`.
    corners: [f64; 4],
}

/// Pull every anchor/row the layout offers above its floor into candidates.
///
/// Every layout that knows a candidate's class id at candidate time gates on
/// that class's *own* floor here, not on a common lower bound. That is what
/// keeps [`finish`]'s `truncate(max_candidates)` honest: it must only ever see
/// candidates that could survive, or a flood of high-scoring boxes in classes
/// the operator excluded (`default: 1.0` as an allowlist is the documented
/// pattern) crowds out the one class they asked for, silently.
///
/// [`Layout::EndToEnd`] is the exception and cannot join them: its class id is
/// a number in the output row rather than an index into a known `nc`, so there
/// is no floor table to look up. It cuts on the lowest floor any label could
/// carry instead — sound because that layout is NMS-free by construction, so
/// nothing truncates its candidates and the real per-label gate in [`finish`]
/// sees them all.
fn candidates_from(
    output: OutputSpec,
    raw: &Outputs<Raw>,
    size: InputSize,
    labels: &Labels,
    floors: &ScoreFloors,
) -> Result<Vec<Candidate>> {
    // `validate_layout` has already agreed the roles, so a mismatch here is
    // unreachable rather than a case to handle.
    match (output.layout, raw) {
        (Layout::EndToEnd, Outputs::One(one)) => Ok(end_to_end(one.values, floors.min_floor())),
        (Layout::RawClasses { nc }, Outputs::One(one)) => {
            let anchors = one.dims[2] as usize;
            require_values(one.values.len(), 4 + nc, anchors, &one.dims)?;
            Ok(raw_classes(
                one.values,
                nc,
                anchors,
                size,
                output.score,
                &class_floors(nc, labels, floors),
            ))
        }
        (Layout::GridObjectness { nc, strides }, Outputs::One(one)) => {
            let anchors = grid_anchors(size, strides);
            require_values(one.values.len(), anchors, 5 + nc, &one.dims)?;
            Ok(grid_objectness(
                one.values,
                nc,
                strides,
                size,
                output.score,
                &class_floors(nc, labels, floors),
            ))
        }
        (Layout::DetrQueries { nc }, Outputs::BoxesAndLogits { boxes, logits }) => {
            let queries = logits.dims[1] as usize;
            require_values(boxes.values.len(), queries, 4, &boxes.dims)?;
            require_values(logits.values.len(), queries, nc, &logits.dims)?;
            Ok(detr_queries(
                boxes.values,
                logits.values,
                nc,
                queries,
                size,
                output.score,
                &class_floors(nc, labels, floors),
            ))
        }
        (layout, raw) => bail!(
            "{layout} cannot be read from {}",
            show(&raw.map(|tensor| tensor.dims.clone()))
        ),
    }
}

/// Does this tensor carry the `rows * row` values the layout is about to index?
///
/// The product is `checked_mul` rather than `*` because both factors come off
/// a *runtime* tensor shape. onnxruntime's extents are consistent with the
/// buffer it hands back, so a wrap is unreachable today — but this is the one
/// place the "trust the dims" pattern is not defended, and a wrapped `need`
/// would pass the length check and let the decode loop walk off the slice.
fn require_values(have: usize, rows: usize, row: usize, dims: &[i64]) -> Result<()> {
    let need = rows
        .checked_mul(row)
        .ok_or_else(|| anyhow!("output {dims:?} declares an impossible element count"))?;
    if have < need {
        bail!("output {dims:?} declares {need} values but carries {have}");
    }
    Ok(())
}

/// `[1, N, 6]` rows of `[x1, y1, x2, y2, score, class_id]`, already final.
fn end_to_end(rows: &[f32], prefilter: f64) -> Vec<Candidate> {
    rows.chunks_exact(6)
        .filter_map(|row| {
            // NaN survives `score < floor` (the comparison is false) and
            // serde_json writes non-finite floats as `null` — one such row
            // would take the whole line, and every valid detection on it,
            // out of the contract.
            if !row.iter().all(|v| v.is_finite()) {
                return None;
            }
            let score = f64::from(row[4]);
            if score < prefilter {
                return None;
            }
            Some(Candidate {
                score,
                class_id: row[5].max(0.0).round() as usize,
                corners: [
                    f64::from(row[0]),
                    f64::from(row[1]),
                    f64::from(row[2]),
                    f64::from(row[3]),
                ],
            })
        })
        .collect()
}

/// `[1, 4 + nc, A]` channels-first: channel `c` of anchor `a` is at
/// `c * anchors + a`. Rows 0..4 are `cx, cy, w, h` in input pixels; rows 4..
/// are per-class scores, already sigmoided.
///
/// `floors` is one floor per class id, from [`class_floors`]: the argmax names
/// the class, so this head can hold each candidate to its own floor rather
/// than to a common lower bound — see [`candidates_from`].
fn raw_classes(
    values: &[f32],
    nc: usize,
    anchors: usize,
    size: InputSize,
    score: ScoreComposition,
    floors: &[f64],
) -> Vec<Candidate> {
    // This layout has no objectness column, so the composition has nothing to
    // fold in either way — see `ScoreComposition::ObjTimesClass`.
    let _ = score;
    let mut candidates = Vec::new();
    for a in 0..anchors {
        let (class_id, score) = argmax(nc, |c| f64::from(values[(4 + c) * anchors + a]));
        // A NaN score wins `total_cmp`'s argmax, so it is rejected here rather
        // than left to be compared against a floor (where every comparison is
        // false) and serialized as `null`, which would take the whole output
        // line out of the contract.
        //
        // `floors` carries one entry per class by construction and `argmax`
        // ranges over the same `nc`, so the lookup is total.
        if score.is_nan() || floors.get(class_id).is_none_or(|floor| score < *floor) {
            continue;
        }
        let cx = f64::from(values[a]);
        let cy = f64::from(values[anchors + a]);
        let w = f64::from(values[2 * anchors + a]);
        let h = f64::from(values[3 * anchors + a]);
        if let Some(corners) = centered(cx, cy, w, h, size) {
            candidates.push(Candidate {
                score,
                class_id,
                corners,
            });
        }
    }
    candidates
}

/// `[1, A, 5 + nc]` anchor-major: anchor `a` occupies `5 + nc` contiguous
/// entries at `a * (5 + nc)`.
///
/// The first four are *not* pixels — `x, y` are an offset inside the anchor's
/// own grid cell and `w, h` are log extents, both relative to that cell's
/// stride, which is why they need the grid walked in the same order the model
/// concatenated it (all of the first stride's cells row-major, then the next).
/// Entry 4 is objectness and the rest are class scores, both already sigmoided.
///
/// `floors` is one floor per class id, from [`class_floors`]: the argmax names
/// the class, so this head can hold each candidate to its own floor rather
/// than to a common lower bound — see [`candidates_from`].
fn grid_objectness(
    values: &[f32],
    nc: usize,
    strides: &[usize],
    size: InputSize,
    score: ScoreComposition,
    floors: &[f64],
) -> Vec<Candidate> {
    let row = 5 + nc;
    let mut candidates = Vec::new();
    let mut anchor = 0usize;
    for stride in strides {
        let (cols, rows) = (size.w / stride, size.h / stride);
        let stride = *stride as f64;
        for gy in 0..rows {
            for gx in 0..cols {
                let base = anchor * row;
                anchor += 1;
                let objectness = match score {
                    ScoreComposition::ObjTimesClass => f64::from(values[base + 4]),
                    ScoreComposition::Class | ScoreComposition::SigmoidClass => 1.0,
                };
                let (class_id, class_score) = argmax(nc, |c| f64::from(values[base + 5 + c]));
                // NaN wins total_cmp's argmax and survives every comparison
                // against a floor, then serializes as `null` and takes the
                // whole output line out of the contract.
                //
                // `floors` carries one entry per class by construction and
                // `argmax` ranges over the same `nc`, so the lookup is total.
                let score = objectness * class_score;
                if score.is_nan() || floors.get(class_id).is_none_or(|floor| score < *floor) {
                    continue;
                }
                let cx = (f64::from(values[base]) + gx as f64) * stride;
                let cy = (f64::from(values[base + 1]) + gy as f64) * stride;
                // exp() turns a large logit into inf rather than a wrong
                // number, so `centered`'s finite check catches it.
                let w = f64::from(values[base + 2]).exp() * stride;
                let h = f64::from(values[base + 3]).exp() * stride;
                if let Some(corners) = centered(cx, cy, w, h, size) {
                    candidates.push(Candidate {
                        score,
                        class_id,
                        corners,
                    });
                }
            }
        }
    }
    candidates
}

/// DETR set prediction: `[1, Q, 4]` normalized `cx, cy, w, h` alongside
/// `[1, Q, nc]` raw class logits over the same queries.
///
/// The boxes are scaled up into model pixels rather than reported as they
/// stand, so the same [`Projection`] that un-does a letterbox for every other
/// family un-does it here too. Under this profile's `Stretch` the two cancel
/// exactly; the point is that a DETR run against a padded frame is not
/// silently off by the padding.
///
/// One candidate per query: the best-scoring class that clears *its own*
/// floor, which is not always the query's argmax.
///
/// RF-DETR's own postprocess takes the top k of the flattened query x class
/// matrix, so one query can leave under several labels. Plain argmax matches
/// that for everything that survives a *uniform* floor — sigmoid is monotonic,
/// so the argmax class is the only one that can clear a floor its runners-up
/// do not. Cairn's floors are not uniform: `default: 1.0` as an allowlist with
/// `person: 0.6` is the documented pattern, and under `car: 0.9, truck: 0.4` a
/// query scoring car 0.85 / truck 0.60 is a truck the argmax throws away with
/// its box. Scoring every class against its own floor costs nothing — the loop
/// already reads all `nc` logits — and collapses to argmax when the floors are
/// uniform.
///
/// `floors` is one floor per class id, from [`class_floors`]. The per-label
/// gate in [`finish`] re-applies it after NMS; picking here only decides which
/// label the box leaves under.
fn detr_queries(
    boxes: &[f32],
    logits: &[f32],
    nc: usize,
    queries: usize,
    size: InputSize,
    score: ScoreComposition,
    floors: &[f64],
) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    for query in 0..queries {
        let mut best: Option<(usize, f64)> = None;
        let mut poisoned = false;
        // `zip` rather than indexing: `floors` carries one entry per class by
        // construction, and pairing them is what says so without a panic path.
        for (class_id, floor) in (0..nc).zip(floors) {
            let logit = f64::from(logits[query * nc + class_id]);
            let value = match score {
                ScoreComposition::SigmoidClass => sigmoid(logit),
                // An export that already squashed its logits, read as it stands.
                ScoreComposition::Class | ScoreComposition::ObjTimesClass => logit,
            };
            // A NaN poisons the whole query, not just its own class: it
            // survives every comparison against a floor and serializes as
            // `null`, which would take the entire output line — and every real
            // detection on it — out of the contract.
            if value.is_nan() {
                poisoned = true;
                break;
            }
            if value >= *floor && best.is_none_or(|(_, high)| value > high) {
                best = Some((class_id, value));
            }
        }
        if poisoned {
            continue;
        }
        let Some((class_id, score)) = best else {
            continue;
        };
        let row = &boxes[query * 4..query * 4 + 4];
        let (w, h) = (size.w as f64, size.h as f64);
        if let Some(corners) = centered(
            f64::from(row[0]) * w,
            f64::from(row[1]) * h,
            f64::from(row[2]) * w,
            f64::from(row[3]) * h,
            size,
        ) {
            candidates.push(Candidate {
                score,
                class_id,
                corners,
            });
        }
    }
    candidates
}

/// The squash a DETR head leaves to its postprocess.
///
/// Saturates instead of overflowing — an infinite logit lands on 0 or 1, both
/// of which a score floor compares meaningfully — so NaN is the only input the
/// caller still has to reject.
fn sigmoid(logit: f64) -> f64 {
    1.0 / (1.0 + (-logit).exp())
}

/// Argmax over `n` scores. `total_cmp` orders NaN, so a NaN wins — every
/// caller rejects the result rather than letting one reach the output.
fn argmax(n: usize, score: impl Fn(usize) -> f64) -> (usize, f64) {
    (0..n)
        .map(|c| (c, score(c)))
        .max_by(|x, y| x.1.total_cmp(&y.1))
        .expect("a detect head has at least one class")
}

/// Center/extent -> corners, dropping anything non-finite or absurdly large.
///
/// The extent bound is not tidiness. `exp()` in the grid decode stays finite up
/// to `exp(88)`, so a broken or int8-collapsed export can emit a box of `1e38`
/// model pixels that every finite check accepts and [`det_from`]'s clamp then
/// turns into exactly `[0, 0, 1, 1]` — a full-frame detection, which is the
/// worst possible false positive for something that drives recording. Nothing
/// real is `MAX_EXTENT` times the input rectangle, so cutting there costs
/// nothing and removes the failure mode.
fn centered(cx: f64, cy: f64, w: f64, h: f64, size: InputSize) -> Option<[f64; 4]> {
    /// How far past the input rectangle an extent may still be a real box.
    /// Generous: a letterboxed decode legitimately puts boxes outside the
    /// content rectangle, and un-projection is what brings them back.
    const MAX_EXTENT: f64 = 4.0;
    let finite = cx.is_finite() && cy.is_finite() && w.is_finite() && h.is_finite();
    let bounded = w <= MAX_EXTENT * size.w as f64 && h <= MAX_EXTENT * size.h as f64;
    (finite && bounded).then(|| [cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0])
}

/// Where every layout converges: NMS if the head needs it, then the per-label
/// floor, un-projection, score order and the [`MAX_DETS`] cap.
fn finish(
    mut candidates: Vec<Candidate>,
    spec: Option<NmsSpec>,
    labels: &Labels,
    floors: &ScoreFloors,
    projection: &Projection,
) -> Vec<Det> {
    let kept = match spec {
        Some(spec) => {
            candidates.sort_by(|a, b| b.score.total_cmp(&a.score));
            candidates.truncate(spec.max_candidates);
            nms(candidates, spec.iou)
        }
        None => candidates,
    };
    let dets = kept
        .into_iter()
        .filter_map(|candidate| {
            let label = labels.label_for(candidate.class_id);
            // Re-applied here because [`Layout::EndToEnd`] cannot gate at
            // candidate time (it has no class table) and because this is the
            // one place every layout converges. For the rest it is a no-op:
            // they gated on the same floor already, and NMS only ever drops a
            // box weaker than one of its own class, which shares it.
            (candidate.score >= floors.floor_for(&label)).then(|| {
                (
                    candidate.score,
                    det_from(candidate.corners, candidate.score, label, projection),
                )
            })
        })
        .collect();
    top_dets(dets)
}

/// Class-aware greedy NMS.
///
/// Only a stronger box of the *same* class suppresses one, so two classes
/// firing on the same object both survive — merging them would lose the
/// weaker label entirely, and Cairn's per-label floors are what decide
/// whether it matters.
///
/// `candidates` must already be sorted by descending score.
fn nms(candidates: Vec<Candidate>, threshold: f64) -> Vec<Candidate> {
    let mut kept: Vec<Candidate> = Vec::new();
    for candidate in candidates {
        let suppressed = kept.iter().any(|keeper| {
            keeper.class_id == candidate.class_id
                && iou(&keeper.corners, &candidate.corners) >= threshold
        });
        if !suppressed {
            kept.push(candidate);
        }
    }
    kept
}

/// Intersection over union of two `[x0, y0, x1, y1]` boxes.
fn iou(a: &[f64; 4], b: &[f64; 4]) -> f64 {
    let overlap_w = (a[2].min(b[2]) - a[0].max(b[0])).max(0.0);
    let overlap_h = (a[3].min(b[3]) - a[1].max(b[1])).max(0.0);
    let overlap = overlap_w * overlap_h;
    let area = |r: &[f64; 4]| (r[2] - r[0]).max(0.0) * (r[3] - r[1]).max(0.0);
    let union = area(a) + area(b) - overlap;
    if union <= 0.0 {
        0.0
    } else {
        overlap / union
    }
}

/// Model-space corners -> the contract's normalized `[x, y, w, h]`.
///
/// Contract: bbox normalized 0..1 against the *original* frame — which is what
/// the projection knows and the input size does not.
fn det_from(corners: [f64; 4], score: f64, label: String, projection: &Projection) -> Det {
    let normalized = projection.unproject(corners);
    let x0 = normalized[0].clamp(0.0, 1.0);
    let y0 = normalized[1].clamp(0.0, 1.0);
    let x1 = normalized[2].clamp(0.0, 1.0);
    let y1 = normalized[3].clamp(0.0, 1.0);
    Det {
        // `--labels` is arbitrary user text and the host refuses a label it
        // cannot print; shaping it here keeps the detection instead.
        label: crate::emit::shape_label(&label),
        // Same reason as the bbox clamp below: the host's `validate_det`
        // requires a 0..1 score and drops the whole detection otherwise, so a
        // corrupt or badly-quantized export emitting 3.7 would lose a real
        // detection rather than report an odd number. Non-finite scores are
        // already rejected upstream, which is what makes `clamp` total here.
        score: round_to(score.clamp(0.0, 1.0), 3),
        bbox: [
            round_to(x0, 4),
            round_to(y0, 4),
            round_to((x1 - x0).max(0.0), 4),
            round_to((y1 - y0).max(0.0), 4),
        ],
    }
}

/// Score-order and cap, where every layout converges.
fn top_dets(mut dets: Vec<(f64, Det)>) -> Vec<Det> {
    // yolov10 exports are already score-ordered; sorting keeps the MAX_DETS
    // cut meaningful for exports that are not, and NMS output never is.
    dets.sort_by(|a, b| b.0.total_cmp(&a.0));
    dets.truncate(MAX_DETS);
    dets.into_iter().map(|(_, det)| det).collect()
}

fn round_to(value: f64, places: u32) -> f64 {
    let factor = 10f64.powi(places as i32);
    (value * factor).round() / factor
}

#[cfg(test)]
mod golden;

#[cfg(test)]
mod tests {
    use super::*;

    fn labels() -> Labels {
        Labels(vec!["person".into(), "bicycle".into(), "car".into()])
    }

    fn floors(json: &str) -> ScoreFloors {
        ScoreFloors::parse(json).unwrap()
    }

    fn open() -> ScoreFloors {
        floors("{}")
    }

    /// The shapes of a one-tensor head, as a layout reads them.
    fn one(dims: &[i64]) -> Shapes {
        Outputs::One(dims.to_vec())
    }

    /// A model declaring exactly one static output, as sniffing sees it.
    fn declared(dims: &[i64]) -> Vec<Declared> {
        vec![Declared {
            name: "output".into(),
            dims: Some(dims.to_vec()),
        }]
    }

    /// A model that pins nothing about its output.
    fn dynamic() -> Vec<Declared> {
        vec![Declared {
            name: "output".into(),
            dims: None,
        }]
    }

    /// An RF-DETR-shaped model: boxes and logits over the same queries, under
    /// the names the transformers/onnx-community conversion uses.
    fn declared_detr(queries: i64, nc: i64) -> Vec<Declared> {
        vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, queries, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, queries, nc]),
            },
        ]
    }

    fn detr_shapes(queries: i64, nc: i64) -> Shapes {
        Outputs::BoxesAndLogits {
            boxes: vec![1, queries, 4],
            logits: vec![1, queries, nc],
        }
    }

    const SQUARE: InputSize = InputSize::square(640);
    /// What `yolox_nano.onnx` from the Megvii 0.1.1rc0 release declares.
    const YOLOX_416: InputSize = InputSize::square(416);
    /// 8^2 + 4^2 + 2^2 = 84 anchors: small enough to reason about by hand.
    const TINY: InputSize = InputSize::square(64);
    const STRIDES: &[usize] = &[8, 16, 32];

    /// Decode as a resolved profile would, under the stretch projection its
    /// input size implies.
    fn decode(
        output: OutputSpec,
        values: &[f32],
        dims: &[i64],
        floors: &ScoreFloors,
        size: InputSize,
    ) -> Vec<Det> {
        decode_output(
            output,
            &raw_one(values, dims),
            &labels(),
            floors,
            size,
            &Projection::stretch(size),
        )
        .unwrap()
    }

    /// One tensor in the role a single-output layout reads.
    fn raw_one<'a>(values: &'a [f32], dims: &[i64]) -> Outputs<Raw<'a>> {
        Outputs::One(Raw {
            dims: dims.to_vec(),
            values,
        })
    }

    /// A DETR pair, in the roles [`Layout::DetrQueries`] reads.
    fn raw_detr<'a>(
        boxes: &'a [f32],
        logits: &'a [f32],
        queries: i64,
        nc: i64,
    ) -> Outputs<Raw<'a>> {
        Outputs::BoxesAndLogits {
            boxes: Raw {
                dims: vec![1, queries, 4],
                values: boxes,
            },
            logits: Raw {
                dims: vec![1, queries, nc],
                values: logits,
            },
        }
    }

    // ---- score floors, labels, input size parsing -------------------------

    #[test]
    fn floors_default_to_half() {
        assert_eq!(open().floor_for("person"), 0.5);
    }

    #[test]
    fn floors_are_per_label_with_a_default() {
        let floors = floors(r#"{"default":0.4,"person":0.8}"#);
        assert_eq!(floors.floor_for("person"), 0.8);
        assert_eq!(floors.floor_for("car"), 0.4);
    }

    #[test]
    fn floors_reject_non_objects() {
        assert!(ScoreFloors::parse("[]").is_err());
        assert!(ScoreFloors::parse(r#"{"person":"high"}"#).is_err());
    }

    #[test]
    fn unknown_class_ids_fall_back_to_the_number() {
        assert_eq!(labels().label_for(0), "person");
        assert_eq!(labels().label_for(77), "77");
    }

    #[test]
    fn a_bare_number_is_a_square() {
        assert_eq!(InputSize::parse("640").unwrap(), SQUARE);
        assert_eq!(InputSize::parse(" 320 ").unwrap(), InputSize::square(320));
        assert_eq!(SQUARE.to_string(), "640x640");
        assert_eq!(SQUARE.tensor_len(), 3 * 640 * 640);
    }

    #[test]
    fn wxh_keeps_the_axes_in_order() {
        assert_eq!(
            InputSize::parse("640x352").unwrap(),
            InputSize { w: 640, h: 352 }
        );
        // uppercase because `--input-size 640X352` is a plausible typo, not
        // a different format
        assert_eq!(
            InputSize::parse("640X352").unwrap(),
            InputSize { w: 640, h: 352 }
        );
        assert_eq!(InputSize::parse("640x352").unwrap().to_string(), "640x352");
    }

    #[test]
    fn rejects_zero_and_garbage_sizes() {
        for spec in ["0", "0x640", "640x0", "", "x", "640x", "x640", "-640"] {
            assert!(InputSize::parse(spec).is_err(), "{spec:?} parsed");
        }
        assert!(InputSize::parse("640.0").is_err());
        assert!(InputSize::parse("640x352x1").is_err());
    }

    // ---- resize policy and projection -------------------------------------

    /// The 16:9 source the fix exists for: 1920x1080 into a 416x416 model.
    const WIDE: InputSize = InputSize { w: 1920, h: 1080 };

    #[test]
    fn stretch_fills_the_whole_input_and_ignores_the_source() {
        for source in [WIDE, InputSize { w: 2560, h: 1920 }, YOLOX_416] {
            let fit = ResizePolicy::Stretch.fit(YOLOX_416, source);
            assert_eq!(fit.inner, YOLOX_416);
            assert_eq!(fit.offset, (0, 0));
        }
    }

    #[test]
    fn letterbox_scales_by_the_smaller_ratio_and_pads_bottom_right() {
        // min(416/1920, 416/1080) = 0.21667 -> 416 x 234, 182 rows of pad
        // under it. Content at the origin is what YOLOX's own preproc does:
        // `padded_img[: int(h*r), : int(w*r)] = resized`.
        let fit = ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, WIDE);
        assert_eq!(fit.inner, InputSize { w: 416, h: 234 });
        assert_eq!(fit.offset, (0, 0));
        assert_eq!(fit.pad, 114);
        // the aspect the model sees is the camera's, to within the even-side
        // rounding: 416/234 = 1.778 against 1920/1080 = 1.778
        let seen = fit.inner.w as f64 / fit.inner.h as f64;
        let real = WIDE.w as f64 / WIDE.h as f64;
        assert!((seen - real).abs() < 0.01, "{seen} vs {real}");
    }

    #[test]
    fn letterbox_sides_are_even_and_never_exceed_the_input() {
        // A source whose exact fit is odd still lands on an even side, because
        // the hardware path scales into NV12 and a silently rounded side would
        // shift every box.
        let odd = ResizePolicy::Letterbox { pad: 114 }.fit(InputSize::square(101), WIDE);
        assert_eq!(odd.inner.w % 2, 0);
        assert_eq!(odd.inner.h % 2, 0);
        assert!(odd.inner.w <= 101 && odd.inner.h <= 101);
        // a square source fills the square input exactly
        let square = ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, InputSize::square(1080));
        assert_eq!(square.inner, YOLOX_416);
        // an absurdly thin source still leaves a usable side
        let sliver =
            ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, InputSize { w: 4000, h: 2 });
        assert!(sliver.inner.h >= 1 && sliver.inner.w <= 416);
    }

    #[test]
    fn a_full_frame_box_round_trips_under_both_policies() {
        // The property that makes a projection right: whatever the model sees
        // of the whole frame must come back as the whole frame.
        for source in [WIDE, InputSize { w: 2560, h: 1920 }, SQUARE] {
            for policy in [ResizePolicy::Stretch, ResizePolicy::Letterbox { pad: 114 }] {
                let fit = policy.fit(YOLOX_416, source);
                let projection = fit.projection(source);
                let whole = [0.0, 0.0, fit.inner.w as f64, fit.inner.h as f64];
                let back = projection.unproject(whole);
                assert_eq!(back[0], 0.0, "{policy} {source}");
                assert_eq!(back[1], 0.0, "{policy} {source}");
                assert!((back[2] - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
                assert!((back[3] - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
            }
        }
    }

    #[test]
    fn stretch_un_projection_is_a_divide_by_the_input_size() {
        // The pre-existing rule, unchanged: independent of the source frame.
        let projection = ResizePolicy::Stretch.project(SQUARE, WIDE);
        assert_eq!(
            projection.unproject([64.0, 128.0, 192.0, 320.0]),
            [0.1, 0.2, 0.3, 0.5]
        );
        // ...and the same box under the same input from a different source
        let other = ResizePolicy::Stretch.project(SQUARE, InputSize::square(720));
        assert_eq!(
            other.unproject([64.0, 128.0, 192.0, 320.0]),
            projection.unproject([64.0, 128.0, 192.0, 320.0])
        );
    }

    #[test]
    fn letterbox_un_projection_ignores_the_padding() {
        // 1920x1080 -> 416x234 content with 182 rows of pad below it. A box
        // filling the content's lower half is the frame's lower half.
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, WIDE);
        let back = projection.unproject([0.0, 117.0, 416.0, 234.0]);
        assert!((back[0] - 0.0).abs() < 1e-9, "{back:?}");
        assert!((back[1] - 0.5).abs() < 1e-9, "{back:?}");
        assert!((back[2] - 1.0).abs() < 1e-9, "{back:?}");
        assert!((back[3] - 1.0).abs() < 1e-9, "{back:?}");
        // A box down in the padding un-projects past the bottom of the frame,
        // which `det_from` clamps away rather than reporting as content.
        assert!(projection.unproject([0.0, 300.0, 10.0, 320.0])[1] > 1.0);
    }

    #[test]
    fn stretch_and_letterbox_disagree_on_a_16_by_9_frame() {
        // The bug this fix exists for, stated as a number: a box that is
        // square in the camera's frame is decoded from a model that saw it
        // squashed to 9/16 of its height under stretch, so reading it back
        // with the stretch rule stretches it again.
        let source = WIDE;
        let letterbox = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, source);
        let stretch = ResizePolicy::Stretch.project(YOLOX_416, source);
        // the same model-space box read both ways
        let box_ = [104.0, 58.0, 312.0, 176.0];
        let good = letterbox.unproject(box_);
        let bad = stretch.unproject(box_);
        assert!((good[0] - bad[0]).abs() < 1e-9, "x is unaffected");
        // The letterboxed picture only occupies the top 234 of 416 rows, so
        // reading it with the stretch rule squashes every box's height by
        // exactly the aspect ratio, 1080/1920.
        let good_h = good[3] - good[1];
        let bad_h = bad[3] - bad[1];
        assert!(
            (bad_h / good_h - 1080.0 / 1920.0).abs() < 0.001,
            "{bad_h} vs {good_h}"
        );
        // and every box is pulled toward the top of the frame as well
        assert!(bad[1] < good[1], "{bad:?} vs {good:?}");
    }

    // ---- profiles: layout fitting, sniffing, ambiguity ---------------------

    fn tensor_type(dims: &[i64]) -> ValueType {
        ValueType::Tensor {
            ty: ort::value::TensorElementType::Float32,
            shape: ort::value::Shape::new(dims.to_vec()),
            dimension_symbols: ort::value::SymbolicDimensions::new(
                dims.iter().map(|_| String::default()),
            ),
        }
    }

    #[test]
    fn every_built_in_profile_is_reachable_by_name() {
        for profile in PROFILES {
            assert_eq!(ModelProfile::parse(profile.name).unwrap(), *profile);
        }
        assert_eq!(ModelProfile::parse("  YOLOX ").unwrap(), YOLOX);
        assert_eq!(ModelProfile::parse("RFDETR").unwrap(), RFDETR);
        let err = ModelProfile::parse("yolov7").unwrap_err().to_string();
        for expected in ["yolox", "yolov10", "yolov8", "rfdetr"] {
            assert!(err.contains(expected), "{err}");
        }
        // and the error names the aliases too, because `yolo11` resolving to
        // the yolov8 profile is exactly the thing a reader needs told
        assert!(err.contains("yolo11"), "{err}");
    }

    #[test]
    fn the_ultralytics_generations_are_aliases_of_one_profile_not_profiles() {
        // Every one of these exports the same tensor, so each is a *name* for
        // the yolov8 profile. Were they separate entries in `PROFILES`, an
        // ordinary `[1, 84, 8400]` head would sniff as four candidates and
        // hard-error on an ambiguity that does not exist.
        for name in ["yolov8", "yolov9", "yolo11", "yolov11"] {
            assert_eq!(ModelProfile::parse(name).unwrap(), YOLOV8, "{name}");
        }
        // yolo26 is end-to-end like yolov10 — UNVERIFIED against a real
        // export, which is why it is an alias rather than its own decode.
        assert_eq!(ModelProfile::parse("yolo26").unwrap(), YOLOV10);
        assert_eq!(ModelProfile::parse("rf-detr").unwrap(), RFDETR);
        // an alias resolves to the profile's canonical identity, so the
        // startup line and every error say `yolov8`, not the alias
        assert_eq!(ModelProfile::parse("yolo11").unwrap().to_string(), "yolov8");
        // ...and one profile per distinct decode keeps sniffing unambiguous
        assert_eq!(PROFILES.len(), 4);
        assert_eq!(sniff(&declared(&[1, 84, 8400]), SQUARE).len(), 1);
        assert_eq!(sniff(&declared(&[1, 300, 6]), SQUARE).len(), 1);
    }

    #[test]
    fn the_built_in_profiles_are_the_documented_steps() {
        assert_eq!(YOLOX.input.encoding, TensorEncoding::RawBgr);
        assert_eq!(YOLOX.input.resize, ResizePolicy::Letterbox { pad: 114 });
        assert_eq!(YOLOX.input.size, YOLOX_416);
        assert_eq!(
            YOLOX.output.layout,
            Layout::GridObjectness {
                nc: 80,
                strides: &[8, 16, 32]
            }
        );
        assert_eq!(YOLOX.output.score, ScoreComposition::ObjTimesClass);
        assert_eq!(YOLOX.output.nms, Some(DEFAULT_NMS));

        assert_eq!(YOLOV10.input.encoding, TensorEncoding::UnitRgb);
        assert_eq!(YOLOV10.input.resize, ResizePolicy::Stretch);
        assert_eq!(YOLOV10.output.layout, Layout::EndToEnd);
        assert_eq!(YOLOV10.output.score, ScoreComposition::Class);
        assert!(YOLOV10.output.nms.is_none());

        assert_eq!(YOLOV8.input.encoding, TensorEncoding::UnitRgb);
        assert_eq!(YOLOV8.input.resize, ResizePolicy::Stretch);
        assert_eq!(YOLOV8.output.layout, Layout::RawClasses { nc: 80 });
        assert_eq!(YOLOV8.output.score, ScoreComposition::Class);
        assert_eq!(YOLOV8.output.nms, Some(DEFAULT_NMS));

        // Measured against onnx-community/rfdetr_nano-ONNX, not assumed: the
        // export's own `preprocessor_config.json` and RF-DETR's
        // `kornia_transforms` agree on ImageNet mean/std, its square
        // `A.Resize` is a stretch, its `postprocess` sigmoids raw logits, and
        // set prediction means no NMS.
        assert_eq!(RFDETR.input.encoding, TensorEncoding::ImageNetRgb);
        assert_eq!(RFDETR.input.resize, ResizePolicy::Stretch);
        assert_eq!(RFDETR.input.size, InputSize::square(384));
        assert_eq!(RFDETR.output.layout, Layout::DetrQueries { nc: 91 });
        assert_eq!(RFDETR.output.score, ScoreComposition::SigmoidClass);
        assert!(RFDETR.output.nms.is_none());
        // it is the only family here that reads more than one tensor
        for profile in PROFILES {
            let two = matches!(
                profile.output.layout.roles(),
                Outputs::BoxesAndLogits { .. }
            );
            assert_eq!(two, profile.name == "rfdetr", "{}", profile.name);
        }
    }

    #[test]
    fn the_nms_defaults_are_the_upstream_ones() {
        // Asserted by literal value, not by symbol. Every other test that
        // mentions these writes `DEFAULT_NMS.max_candidates + 200` or similar,
        // so a changed value stays self-consistent and nothing notices — and
        // the golden fixtures pin `iou` only to the band the planted overlaps
        // straddle (their IoUs are 0.679 and 0.600), so a typo'd 0.5 would
        // suppress and keep exactly the same boxes.
        //
        // 0.45 is Ultralytics' own default for a detect head and YOLOX's demo
        // value; 300 is the candidate cap that bounds NMS's O(k^2) against a
        // 640x640 head's 8400 anchors.
        assert_eq!(DEFAULT_NMS.iou, 0.45);
        assert_eq!(DEFAULT_NMS.max_candidates, 300);
    }

    #[test]
    fn a_row_width_of_six_is_the_end_to_end_layout() {
        // yolov10n's own export
        assert_eq!(sniff(&declared(&[1, 300, 6]), SQUARE), vec![YOLOV10]);
        assert_eq!(
            fit_layout(Layout::EndToEnd, &one(&[1, 300, 6]), SQUARE).unwrap(),
            Layout::EndToEnd
        );
    }

    #[test]
    fn a_long_anchor_axis_is_the_raw_detect_head() {
        // coco yolov8n at 640x640
        let sniffed = sniff(&declared(&[1, 84, 8400]), SQUARE);
        assert_eq!(sniffed.len(), 1);
        assert_eq!(sniffed[0].name, "yolov8");
        assert_eq!(sniffed[0].output.layout, Layout::RawClasses { nc: 80 });
        // a single-class model at a small input still has far more anchors
        // than channels
        assert_eq!(
            fit_layout(
                Layout::RawClasses { nc: 80 },
                &one(&[1, 5, 189]),
                InputSize::square(128)
            )
            .unwrap(),
            Layout::RawClasses { nc: 1 }
        );
    }

    #[test]
    fn the_grid_anchor_count_is_what_names_the_yolox_layout() {
        // yolox_nano.onnx from the Megvii 0.1.1rc0 release: 416x416 input,
        // 52^2 + 26^2 + 13^2 = 3549 anchors, 5 + 80 columns
        assert_eq!(grid_anchors(YOLOX_416, STRIDES), 3549);
        let sniffed = sniff(&declared(&[1, 3549, 85]), YOLOX_416);
        assert_eq!(sniffed.len(), 1);
        assert_eq!(sniffed[0].name, "yolox");
        assert_eq!(
            sniffed[0].output.layout,
            Layout::GridObjectness {
                nc: 80,
                strides: STRIDES
            }
        );
        assert_eq!(grid_anchors(SQUARE, STRIDES), 8400);
    }

    #[test]
    fn a_shape_that_fits_two_profiles_is_an_error_naming_both() {
        // A 1-class yolox head is `[1, A, 6]`, and 6 is also the end-to-end
        // row width. At 640x384 that is 5040 anchors either way and nothing in
        // the shape says which — one decodes boxes out of a stride grid, the
        // other reads them as final pixel corners, so picking silently emits
        // plausible garbage.
        let wide = InputSize { w: 640, h: 384 };
        assert_eq!(grid_anchors(wide, STRIDES), 80 * 48 + 40 * 24 + 20 * 12);
        assert_eq!(
            sniff(&declared(&[1, 5040, 6]), wide)
                .iter()
                .map(|p| p.name)
                .collect::<Vec<_>>(),
            vec!["yolox", "yolov10"]
        );
        let err = resolve_profile(None, &declared(&[1, 5040, 6]), wide, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("yolox"), "{err}");
        assert!(err.contains("yolov10"), "{err}");
        assert!(err.contains("--model-profile"), "{err}");
        assert!(err.contains("[1, 5040, 6]"), "{err}");
        // the same collision at the default square input
        assert_eq!(sniff(&declared(&[1, 8400, 6]), SQUARE).len(), 2);
    }

    #[test]
    fn a_transposed_looking_shape_is_yolox_alone_because_ultralytics_is_channels_first() {
        // Worth pinning: `[1, 8400, 84]` at 640 *looks* like it could be
        // either family, and it is a 79-class yolox. It is not ambiguous
        // because a stock Ultralytics detect head is channels-first — its
        // anchor axis is the long one — so `RawClasses` refuses this
        // orientation outright rather than reading nc as 8396.
        let sniffed = sniff(&declared(&[1, 8400, 84]), SQUARE);
        assert_eq!(sniffed.len(), 1, "{sniffed:?}");
        assert_eq!(sniffed[0].name, "yolox");
        assert_eq!(
            sniffed[0].output.layout,
            Layout::GridObjectness {
                nc: 79,
                strides: STRIDES
            }
        );
        // adding a transposed-Ultralytics profile would make this genuinely
        // ambiguous, and the resolution above is what would then catch it
        assert!(fit_layout(Layout::RawClasses { nc: 80 }, &one(&[1, 8400, 84]), SQUARE).is_err());
    }

    #[test]
    fn an_explicit_profile_resolves_a_shape_that_is_otherwise_ambiguous() {
        let (profile, _names, output) = resolve_profile(
            Some(YOLOX),
            &declared(&[1, 8400, 84]),
            SQUARE,
            Path::new("m.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "yolox");
        assert_eq!(
            output.unwrap().layout,
            Layout::GridObjectness {
                nc: 79,
                strides: STRIDES
            }
        );
        // ...and the other reading of the same shape is available too
        let (profile, _names, output) = resolve_profile(
            Some(YOLOV10),
            &declared(&[1, 5040, 6]),
            InputSize { w: 640, h: 384 },
            Path::new("m.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "yolov10");
        assert_eq!(output.unwrap().layout, Layout::EndToEnd);
    }

    #[test]
    fn an_explicit_profile_that_does_not_fit_the_model_fails_loudly() {
        // yolox at an input size whose grid the output does not match: 3549
        // anchors are 416's, not 640's
        let err = resolve_profile(
            Some(YOLOX),
            &declared(&[1, 3549, 85]),
            SQUARE,
            Path::new("m.onnx"),
        )
        .unwrap_err();
        let text = format!("{err:#}");
        assert!(text.contains("--model-profile yolox"), "{text}");
        assert!(text.contains("[1, 8400, 5 + nc]"), "{text}");
        // an end-to-end profile pointed at a raw head
        assert!(resolve_profile(
            Some(YOLOV10),
            &declared(&[1, 84, 8400]),
            SQUARE,
            Path::new("m.onnx")
        )
        .is_err());
        // a channels-first profile pointed at an anchor-major head
        assert!(resolve_profile(
            Some(YOLOV8),
            &declared(&[1, 8400, 84]),
            SQUARE,
            Path::new("m.onnx")
        )
        .is_err());
    }

    #[test]
    fn an_unrecognizable_shape_names_every_profile() {
        for (dims, size) in [
            (vec![1, 84, 84], SQUARE),      // no axis long enough to be anchors
            (vec![1, 3, 640, 640], SQUARE), // rank 4
            // yolov5 at 640: same rank and row width as a yolox head, but
            // three anchor boxes per cell make A exactly 3x a yolox's, and
            // its boxes are already in pixels — decoding it against the yolox
            // grid would emit plausible garbage
            (vec![1, 25200, 85], SQUARE),
            // a real yolox shape read against the wrong input size
            (vec![1, 3549, 85], SQUARE),
            (vec![1, 8400, 85], YOLOX_416),
            (vec![2, 84, 8400], SQUARE), // batched
        ] {
            assert!(
                sniff(&declared(&dims), size).is_empty(),
                "{dims:?} matched something"
            );
            let err = resolve_profile(None, &declared(&dims), size, Path::new("m.onnx"))
                .unwrap_err()
                .to_string();
            assert!(err.contains("yolox"), "{err}");
            assert!(err.contains("yolov10"), "{err}");
            assert!(err.contains("yolov8"), "{err}");
        }
    }

    #[test]
    fn a_static_output_shape_settles_the_profile_at_startup() {
        let dims = static_output_dims(&tensor_type(&[1, 84, 8400])).unwrap();
        assert_eq!(sniff(&declared(&dims), SQUARE)[0].name, "yolov8");
        let dims = static_output_dims(&tensor_type(&[1, 3549, 85])).unwrap();
        assert_eq!(sniff(&declared(&dims), YOLOX_416)[0].name, "yolox");
    }

    #[test]
    fn a_dynamic_output_shape_needs_the_flag_and_settles_nc_later() {
        assert!(static_output_dims(&tensor_type(&[1, 84, -1])).is_none());
        assert!(static_output_dims(&tensor_type(&[-1, -1, -1])).is_none());
        // nothing to sniff, and the encoding has to be known before the first
        // frame is converted, so this is a startup failure rather than a guess
        let err = resolve_profile(None, &dynamic(), SQUARE, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("--model-profile"), "{err}");
        assert!(err.contains("yolox"), "{err}");
        // with the flag, the input half is settled now and nc waits
        let (profile, _names, output) =
            resolve_profile(Some(YOLOX), &dynamic(), SQUARE, Path::new("m.onnx")).unwrap();
        assert_eq!(profile.input.encoding, TensorEncoding::RawBgr);
        assert!(output.is_none());
    }

    // ---- end-to-end layout ------------------------------------------------

    fn row(x1: f32, y1: f32, x2: f32, y2: f32, score: f32, class_id: f32) -> [f32; 6] {
        [x1, y1, x2, y2, score, class_id]
    }

    fn e2e(rows: &[f32], floors: &ScoreFloors, size: InputSize) -> Vec<Det> {
        let dims = [1, (rows.len() / 6) as i64, 6];
        decode(YOLOV10.output, rows, &dims, floors, size)
    }

    #[test]
    fn normalizes_and_rounds_boxes() {
        let dets = e2e(
            &row(64.0, 128.0, 192.0, 320.0, 0.876_54, 0.0),
            &open(),
            SQUARE,
        );
        assert_eq!(
            dets,
            vec![Det {
                label: "person".into(),
                score: 0.877,
                bbox: [0.1, 0.2, 0.2, 0.3],
            }]
        );
    }

    #[test]
    fn normalizes_each_axis_by_its_own_side() {
        // The same box under a 320x160 input: x by 320, y by 160.
        let dets = e2e(
            &row(32.0, 32.0, 160.0, 80.0, 0.9, 0.0),
            &open(),
            InputSize { w: 320, h: 160 },
        );
        assert_eq!(dets[0].bbox, [0.1, 0.2, 0.4, 0.3]);
    }

    #[test]
    fn gates_on_the_per_class_floor() {
        let floors = floors(r#"{"default":0.5,"person":0.9}"#);
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 0.0)); // person, under 0.9
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 2.0)); // car, over 0.5
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.40, 2.0)); // car, under 0.5
        let dets = e2e(&rows, &floors, SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
    }

    #[test]
    fn clamps_boxes_to_the_frame() {
        let dets = e2e(
            &row(-320.0, -640.0, 1280.0, 1280.0, 0.9, 2.0),
            &open(),
            SQUARE,
        );
        assert_eq!(dets[0].bbox, [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn drops_non_finite_rows() {
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, f32::NAN, 0.0));
        rows.extend_from_slice(&row(f32::NAN, 0.0, 64.0, 64.0, 0.9, 0.0));
        rows.extend_from_slice(&row(0.0, 0.0, f32::INFINITY, 64.0, 0.9, 0.0));
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.9, 2.0));
        let dets = e2e(&rows, &open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        let json = serde_json::to_string(&dets).unwrap();
        assert!(!json.contains("null"), "{json}");
    }

    #[test]
    fn caps_and_sorts_detections() {
        let mut rows = Vec::new();
        for i in 0..(MAX_DETS + 10) {
            let score = 0.6 + i as f32 / 1000.0;
            rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, score, 2.0));
        }
        let dets = e2e(&rows, &open(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets[0].score > dets[MAX_DETS - 1].score);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn an_end_to_end_head_is_not_run_through_nms() {
        // Three identical boxes of one class: NMS would collapse them, and
        // the yolov10 profile does not ask for it because the model already
        // did the de-duplication.
        assert!(YOLOV10.output.nms.is_none());
        let mut rows = Vec::new();
        for _ in 0..3 {
            rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.9, 2.0));
        }
        assert_eq!(e2e(&rows, &open(), SQUARE).len(), 3);
    }

    // ---- raw-classes layout ------------------------------------------------

    /// Channels-first `[1, 4 + nc, A]`, one entry per anchor.
    fn v8_output(nc: usize, anchors: &[(f32, f32, f32, f32, usize, f32)]) -> Vec<f32> {
        let a = anchors.len();
        let mut out = vec![0f32; (4 + nc) * a];
        for (i, &(cx, cy, w, h, class, score)) in anchors.iter().enumerate() {
            out[i] = cx;
            out[a + i] = cy;
            out[2 * a + i] = w;
            out[3 * a + i] = h;
            out[(4 + class) * a + i] = score;
        }
        out
    }

    fn v8_spec(nc: usize) -> OutputSpec {
        OutputSpec {
            layout: Layout::RawClasses { nc },
            ..YOLOV8.output
        }
    }

    fn v8(
        nc: usize,
        anchors: &[(f32, f32, f32, f32, usize, f32)],
        floors: &ScoreFloors,
        size: InputSize,
    ) -> Vec<Det> {
        let values = v8_output(nc, anchors);
        let dims = [1, (4 + nc) as i64, anchors.len() as i64];
        decode(v8_spec(nc), &values, &dims, floors, size)
    }

    #[test]
    fn decodes_raw_boxes_from_centers() {
        // cx=320 cy=320 w=128 h=192 -> corners 256,224..384,416
        let dets = v8(3, &[(320.0, 320.0, 128.0, 192.0, 0, 0.9)], &open(), SQUARE);
        assert_eq!(
            dets,
            vec![Det {
                label: "person".into(),
                score: 0.9,
                bbox: [0.4, 0.35, 0.2, 0.3],
            }]
        );
    }

    #[test]
    fn picks_the_argmax_class_per_anchor() {
        let mut values = v8_output(3, &[(320.0, 320.0, 64.0, 64.0, 2, 0.8)]);
        // a weaker person score on the same anchor must not win
        values[4] = 0.6;
        let dets = decode(v8_spec(3), &values, &[1, 7, 1], &open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.8);
    }

    #[test]
    fn nms_collapses_same_class_overlap_but_keeps_other_classes() {
        let dets = v8(
            3,
            &[
                // three near-identical person boxes: one detection
                (320.0, 320.0, 200.0, 200.0, 0, 0.90),
                (322.0, 318.0, 198.0, 202.0, 0, 0.85),
                (318.0, 322.0, 202.0, 198.0, 0, 0.80),
                // a car on the same object: a different class is never
                // suppressed by a person
                (320.0, 320.0, 200.0, 200.0, 2, 0.70),
                // a person far away: no overlap, survives
                (80.0, 80.0, 60.0, 60.0, 0, 0.60),
            ],
            &open(),
            SQUARE,
        );
        let mut seen: Vec<(&str, f64)> = dets.iter().map(|d| (d.label.as_str(), d.score)).collect();
        seen.sort_by(|a, b| b.1.total_cmp(&a.1));
        assert_eq!(seen, vec![("person", 0.9), ("car", 0.7), ("person", 0.6)]);
    }

    #[test]
    fn an_out_of_range_score_is_clamped_rather_than_dropped_by_the_host() {
        // The host's `validate_det` requires a 0..1 score and drops the whole
        // detection otherwise, which is the one failure mode this module
        // exists to prevent — same reason the bbox is clamped and the label
        // shaped. A badly-quantized export emitting 3.7 is a real detection
        // reported oddly, not a detection to lose.
        let dets = v8(
            3,
            &[
                (320.0, 320.0, 64.0, 64.0, 0, 3.7),
                (80.0, 80.0, 64.0, 64.0, 2, -0.5),
            ],
            &floors(r#"{"default":-1.0}"#),
            SQUARE,
        );
        // ordered by the *unclamped* score, so the 3.7 is still the strongest
        assert_eq!(dets.len(), 2);
        assert_eq!(dets[0].label, "person");
        assert_eq!(dets[0].score, 1.0);
        assert_eq!(dets[1].score, 0.0);
    }

    #[test]
    fn a_box_far_larger_than_the_input_is_not_a_full_frame_detection() {
        // `exp(logit) * stride` stays finite to about 1e38, so an int8-
        // collapsed or corrupt export can emit a box of 1e30 model pixels.
        // Every finite check accepts it and `det_from`'s clamp turns it into
        // exactly [0, 0, 1, 1] — a whole-frame detection, the worst possible
        // false positive for something that triggers recording.
        assert!(centered(320.0, 320.0, 1e30, 1e30, SQUARE).is_none());
        assert!(centered(320.0, 320.0, 64.0, 1e30, SQUARE).is_none());
        let dets = v8(
            3,
            &[
                (320.0, 320.0, 1e30, 1e30, 0, 0.99),
                (80.0, 80.0, 64.0, 64.0, 2, 0.9),
            ],
            &open(),
            SQUARE,
        );
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        // a box merely outside the input rectangle is still a real box: a
        // letterboxed decode puts them there and un-projection brings them back
        assert!(centered(320.0, 320.0, 2.0 * SQUARE.w as f64, 64.0, SQUARE).is_some());
    }

    #[test]
    fn iou_is_symmetric_and_bounded() {
        let a = [0.0, 0.0, 10.0, 10.0];
        assert_eq!(iou(&a, &a), 1.0);
        assert_eq!(iou(&a, &[20.0, 20.0, 30.0, 30.0]), 0.0);
        // half-overlap: 50 shared of 150 union
        let b = [5.0, 0.0, 15.0, 10.0];
        assert!((iou(&a, &b) - 1.0 / 3.0).abs() < 1e-12);
        assert_eq!(iou(&a, &b), iou(&b, &a));
        // a degenerate box shares no area with anything
        assert_eq!(iou(&a, &[1.0, 1.0, 1.0, 1.0]), 0.0);
    }

    #[test]
    fn raw_boxes_normalize_per_axis_too() {
        let size = InputSize { w: 320, h: 160 };
        // cx=160 cy=80 w=64 h=32 -> 128,64..192,96
        let dets = v8(3, &[(160.0, 80.0, 64.0, 32.0, 0, 0.9)], &open(), size);
        assert_eq!(dets[0].bbox, [0.4, 0.4, 0.2, 0.2]);
    }

    #[test]
    fn the_prefilter_never_cuts_above_a_configured_floor() {
        // the lowest configured floor is what the prefilter may cut at
        let floors = floors(r#"{"default":0.5,"car":0.02}"#);
        assert_eq!(floors.min_floor(), 0.02);
        let dets = v8(
            3,
            &[
                (320.0, 320.0, 64.0, 64.0, 2, 0.03), // car, over its own 0.02
                (80.0, 80.0, 64.0, 64.0, 0, 0.03),   // person, under the 0.5 default
            ],
            &floors,
            SQUARE,
        );
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.03);
    }

    #[test]
    fn a_raw_head_gates_per_class_before_the_nms_truncation() {
        // The documented allowlist pattern: everything excluded, one class
        // admitted. `truncate(max_candidates)` runs on score alone, so a flood
        // of stronger candidates in an excluded class must not be able to push
        // the admitted one out of the cut — they are all discarded anyway, and
        // losing the person is silent, with nothing on stderr and no line.
        let floors = floors(r#"{"default":1.0,"person":0.6}"#);
        let mut anchors: Vec<_> = (0..(DEFAULT_NMS.max_candidates + 200))
            .map(|i| {
                // distinct cars, every one of them stronger than the person
                // and every one of them under the 1.0 that excludes cars
                let x = (i % 600) as f32;
                let y = (i / 600) as f32;
                (x, y, 4.0, 4.0, 2usize, 0.99)
            })
            .collect();
        anchors.push((320.0, 320.0, 64.0, 64.0, 0, 0.65));
        let dets = v8(3, &anchors, &floors, SQUARE);
        assert_eq!(
            dets,
            vec![Det {
                label: "person".into(),
                score: 0.65,
                bbox: [0.45, 0.45, 0.1, 0.1],
            }]
        );
    }

    #[test]
    fn a_grid_head_gates_per_class_before_the_nms_truncation() {
        // The same, for the other head that truncates. 640x640 is 8400
        // anchors, so there is room to bury the one admitted class under 300+
        // stronger excluded ones.
        let floors = floors(r#"{"default":1.0,"person":0.6}"#);
        let mut out = GridOutput::new(SQUARE, 3);
        let mut buried = 0;
        for gy in 0..20 {
            for gx in 0..20 {
                out.put((32, gx, gy), [0.0, 0.0, 0.0, 0.0], 1.0, 2, 0.99);
                buried += 1;
            }
        }
        assert!(buried > DEFAULT_NMS.max_candidates);
        out.put((8, 40, 40), [0.5, 0.5, 0.0, 0.0], 1.0, 0, 0.65);
        let dets = out.decode(&floors);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "person");
        assert_eq!(dets[0].score, 0.65);
    }

    #[test]
    fn a_flood_of_raw_anchors_still_fits_the_contract() {
        // Distinct, non-overlapping boxes so NMS keeps every one of them:
        // the MAX_DETS cap, not NMS, is what has to hold the line.
        let anchors: Vec<_> = (0..(DEFAULT_NMS.max_candidates + 500))
            .map(|i| {
                let x = (i % 600) as f32;
                let y = (i / 600) as f32;
                (x, y, 0.5, 0.5, i % 3, 0.6 + (i % 100) as f32 / 1000.0)
            })
            .collect();
        let dets = v8(3, &anchors, &open(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn raw_non_finite_anchors_never_reach_the_output() {
        let mut values = v8_output(
            3,
            &[
                (f32::NAN, 320.0, 64.0, 64.0, 0, 0.9),
                (320.0, f32::INFINITY, 64.0, 64.0, 0, 0.9),
                (80.0, 80.0, 64.0, 64.0, 2, 0.9),
            ],
        );
        // a NaN class score wins total_cmp's argmax, so it needs its own guard
        values[4 * 3] = f32::NAN;
        let dets = decode(v8_spec(3), &values, &[1, 7, 3], &open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        let json = serde_json::to_string(&dets).unwrap();
        assert!(!json.contains("null"), "{json}");
    }

    // ---- grid-objectness layout --------------------------------------------

    /// Anchor-major `[1, A, 5 + nc]`, addressed by grid cell so a test can
    /// say which stride and which cell a box came out of.
    struct GridOutput {
        size: InputSize,
        classes: usize,
        values: Vec<f32>,
    }

    impl GridOutput {
        fn new(size: InputSize, classes: usize) -> Self {
            Self {
                size,
                classes,
                values: vec![0f32; grid_anchors(size, STRIDES) * (5 + classes)],
            }
        }

        /// Independently of `grid_objectness`'s own walk: strides in order,
        /// each grid row-major.
        fn base_of(&self, stride: usize, gx: usize, gy: usize) -> usize {
            let mut anchor = 0;
            for s in STRIDES {
                let (cols, rows) = (self.size.w / s, self.size.h / s);
                if *s == stride {
                    assert!(gx < cols && gy < rows, "cell {gx},{gy} is off stride {s}");
                    return (anchor + gy * cols + gx) * (5 + self.classes);
                }
                anchor += cols * rows;
            }
            panic!("{stride} is not a stride of this profile");
        }

        /// `raw` is what the model emits: `x, y` offsets inside the cell and
        /// `w, h` in log space, all relative to the cell's stride.
        fn put(
            &mut self,
            (stride, gx, gy): (usize, usize, usize),
            raw: [f32; 4],
            objectness: f32,
            class: usize,
            class_score: f32,
        ) -> &mut Self {
            let base = self.base_of(stride, gx, gy);
            self.values[base..base + 4].copy_from_slice(&raw);
            self.values[base + 4] = objectness;
            self.values[base + 5 + class] = class_score;
            self
        }

        fn spec(&self) -> OutputSpec {
            OutputSpec {
                layout: Layout::GridObjectness {
                    nc: self.classes,
                    strides: STRIDES,
                },
                ..YOLOX.output
            }
        }

        fn dims(&self) -> [i64; 3] {
            [
                1,
                grid_anchors(self.size, STRIDES) as i64,
                (5 + self.classes) as i64,
            ]
        }

        fn decode(&self, floors: &ScoreFloors) -> Vec<Det> {
            decode(self.spec(), &self.values, &self.dims(), floors, self.size)
        }
    }

    #[test]
    fn grid_boxes_come_out_of_the_cell_they_were_emitted_in() {
        // stride 8, cell (4, 2), centered half a cell in x and a quarter in y:
        // cx = (0.5 + 4) * 8 = 36, cy = (0.25 + 2) * 8 = 18. exp(0) * 8 = 8
        // on both extents, so corners are 32,14..40,22.
        let mut out = GridOutput::new(TINY, 3);
        out.put((8, 4, 2), [0.5, 0.25, 0.0, 0.0], 0.8, 0, 0.75);
        assert_eq!(
            out.decode(&open()),
            vec![Det {
                label: "person".into(),
                score: 0.6, // 0.8 objectness * 0.75 class
                bbox: [0.5, 0.2188, 0.125, 0.125],
            }]
        );
    }

    #[test]
    fn the_final_score_is_objectness_times_the_class_score() {
        // The anchor with the far better class score loses on objectness.
        // Reading the class score alone — the `Class` composition — would keep
        // it and drop the other.
        let mut out = GridOutput::new(TINY, 3);
        out.put((8, 1, 1), [0.0, 0.0, 0.0, 0.0], 0.10, 0, 0.99).put(
            (8, 6, 6),
            [0.0, 0.0, 0.0, 0.0],
            0.90,
            2,
            0.80,
        );
        let dets = out.decode(&open());
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.72);

        // ...and the same output read with `Class` keeps the other one, which
        // is exactly what the composition is for.
        let spec = OutputSpec {
            score: ScoreComposition::Class,
            ..out.spec()
        };
        let dets = decode(spec, &out.values, &out.dims(), &open(), TINY);
        let mut seen: Vec<&str> = dets.iter().map(|d| d.label.as_str()).collect();
        seen.sort_unstable();
        assert_eq!(seen, vec!["car", "person"]);
    }

    #[test]
    fn the_argmax_is_over_class_scores_and_objectness_scales_all_of_them() {
        let mut out = GridOutput::new(TINY, 3);
        let base = out.base_of(8, 3, 3);
        out.values[base + 4] = 0.8;
        out.values[base + 5] = 0.6; // person
        out.values[base + 7] = 0.9; // car wins
        let dets = out.decode(&open());
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.72);
    }

    #[test]
    fn the_grids_are_walked_in_the_order_the_model_concatenated_them() {
        // Strides 8, 16, 32, each grid row-major. Reading them in any other
        // order puts these three boxes in the wrong places, and the centers
        // are far enough apart that no near-miss passes.
        let mut out = GridOutput::new(TINY, 3);
        out
            // first anchor of all: stride 8, cell (0,0) -> center 0,0
            .put((8, 0, 0), [0.0, 0.0, 0.0, 0.0], 1.0, 0, 0.9)
            // stride 16, cell (3,0) -> center 48,0
            .put((16, 3, 0), [0.0, 0.0, 0.0, 0.0], 1.0, 1, 0.9)
            // last anchor of all: stride 32, cell (1,1) -> center 32,32
            .put((32, 1, 1), [0.0, 0.0, 0.0, 0.0], 1.0, 2, 0.9);
        let mut seen: Vec<(String, [f64; 4])> = out
            .decode(&open())
            .into_iter()
            .map(|d| (d.label, d.bbox))
            .collect();
        seen.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            seen,
            vec![
                // 48,0 with an exp(0)*16 = 16 box -> 40,-8..56,8, clamped
                ("bicycle".to_string(), [0.625, 0.0, 0.25, 0.125]),
                // 32,32 with an exp(0)*32 = 32 box -> 16,16..48,48
                ("car".to_string(), [0.25, 0.25, 0.5, 0.5]),
                // 0,0 with an exp(0)*8 = 8 box -> -4,-4..4,4, clamped
                ("person".to_string(), [0.0, 0.0, 0.0625, 0.0625]),
            ]
        );
        // and the walk covers every anchor exactly once
        assert_eq!(
            out.values.len() / (5 + out.classes),
            grid_anchors(TINY, STRIDES)
        );
    }

    #[test]
    fn grid_extents_are_log_scale() {
        // exp(ln 4) * 8 = 32 wide against exp(0) * 8 = 8 tall.
        let mut out = GridOutput::new(TINY, 3);
        out.put((8, 4, 4), [0.0, 0.0, 4f32.ln(), 0.0], 1.0, 0, 0.9);
        let dets = out.decode(&open());
        // center 32,32; 32x8 -> 16,28..48,36
        assert_eq!(dets[0].bbox, [0.25, 0.4375, 0.5, 0.125]);
    }

    #[test]
    fn grid_boxes_normalize_per_axis_too() {
        // 8*4 + 4*2 + 2*1 = 42 anchors
        let size = InputSize { w: 64, h: 32 };
        let mut out = GridOutput::new(size, 3);
        // stride 8, cell (3, 1) -> center 28,12; exp(0)*8 box -> 24,8..32,16
        out.put((8, 3, 1), [0.5, 0.5, 0.0, 0.0], 1.0, 0, 0.9);
        let dets = out.decode(&open());
        assert_eq!(dets[0].bbox, [0.375, 0.25, 0.125, 0.25]);
    }

    #[test]
    fn grid_clamps_boxes_to_the_frame() {
        // A box wider than the input on both axes, centered: -32..96 over a
        // 64px input, which clamps to the whole frame. Twice the input rather
        // than the `exp(4)` = 27x it used to be, because `centered` now drops
        // an extent that far out — see
        // `a_box_far_larger_than_the_input_is_not_a_full_frame_detection`.
        let mut out = GridOutput::new(TINY, 3);
        out.put((32, 0, 0), [1.0, 1.0, 4f32.ln(), 4f32.ln()], 1.0, 2, 0.9);
        assert_eq!(out.decode(&open())[0].bbox, [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn grid_reuses_the_same_nms() {
        let mut out = GridOutput::new(TINY, 3);
        // Four stride-8 cells whose offsets all put the center at 28,28 with
        // a 24px box, so they land on top of each other.
        let big = 3f32.ln();
        out.put((8, 3, 3), [0.5, 0.5, big, big], 1.0, 0, 0.90)
            .put((8, 4, 3), [-0.5, 0.5, big, big], 1.0, 0, 0.85)
            .put((8, 3, 4), [0.5, -0.5, big, big], 1.0, 0, 0.80)
            // a car on the same object: a different class is never suppressed
            // by a person, and it has to be its own anchor because one anchor
            // only ever contributes its argmax class
            .put((8, 4, 4), [-0.5, -0.5, big, big], 1.0, 2, 0.70)
            // a person over in the corner: IoU 0.19, under the NMS threshold
            .put((32, 0, 0), [0.5, 0.5, 0.0, 0.0], 1.0, 0, 0.60);
        let mut seen: Vec<(String, f64)> = out
            .decode(&open())
            .into_iter()
            .map(|d| (d.label, d.score))
            .collect();
        seen.sort_by(|a, b| b.1.total_cmp(&a.1));
        assert_eq!(
            seen,
            vec![
                ("person".to_string(), 0.9),
                ("car".to_string(), 0.7),
                ("person".to_string(), 0.6)
            ]
        );
    }

    #[test]
    fn grid_prefilters_at_the_lowest_configured_floor() {
        let floors = floors(r#"{"default":0.5,"car":0.02}"#);
        let mut out = GridOutput::new(TINY, 3);
        // car at 0.03: over its own floor, under the default
        out.put((8, 1, 1), [0.0, 0.0, 0.0, 0.0], 0.1, 2, 0.3)
            // person at the same 0.03: under the 0.5 default
            .put((8, 6, 6), [0.0, 0.0, 0.0, 0.0], 0.1, 0, 0.3);
        let dets = out.decode(&floors);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.03);
    }

    #[test]
    fn a_flood_of_grid_anchors_still_fits_the_contract() {
        // Every stride-8 cell fires a tiny, non-overlapping box, so NMS keeps
        // all 64 and only the MAX_DETS cap can hold the line.
        let mut out = GridOutput::new(TINY, 3);
        for gy in 0..8 {
            for gx in 0..8 {
                let score = 0.6 + (gy * 8 + gx) as f32 / 1000.0;
                out.put((8, gx, gy), [0.0, 0.0, -3.0, -3.0], 1.0, gx % 3, score);
            }
        }
        let dets = out.decode(&open());
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn grid_non_finite_anchors_never_reach_the_output() {
        let mut out = GridOutput::new(TINY, 3);
        out.put((8, 0, 0), [f32::NAN, 0.0, 0.0, 0.0], 1.0, 0, 0.9)
            .put((8, 2, 0), [0.0, f32::INFINITY, 0.0, 0.0], 1.0, 0, 0.9)
            // exp() of a huge logit is inf, which the corner check catches
            .put((8, 4, 0), [0.0, 0.0, 1e30, 0.0], 1.0, 0, 0.9)
            // a NaN objectness makes the product NaN
            .put((8, 6, 0), [0.0, 0.0, 0.0, 0.0], f32::NAN, 0, 0.9)
            .put((16, 1, 1), [0.0, 0.0, 0.0, 0.0], 1.0, 2, 0.9);
        // a NaN class score wins total_cmp's argmax, so it needs its own guard
        let base = out.base_of(8, 7, 7);
        out.values[base + 4] = 1.0;
        out.values[base + 5] = f32::NAN;

        let dets = out.decode(&open());
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        let json = serde_json::to_string(&dets).unwrap();
        assert!(!json.contains("null"), "{json}");
    }

    // ---- detr-queries layout ------------------------------------------------

    /// A DETR head: `[1, Q, 4]` normalized `cx, cy, w, h` beside `[1, Q, nc]`
    /// raw logits over the same queries.
    struct DetrOutput {
        queries: usize,
        classes: usize,
        boxes: Vec<f32>,
        logits: Vec<f32>,
    }

    impl DetrOutput {
        fn new(queries: usize, classes: usize) -> Self {
            Self {
                queries,
                classes,
                boxes: vec![0.0; queries * 4],
                // sigmoid(-20) is 2e-9. A logit of 0 would sigmoid to 0.5 and
                // clear the default floor, so an untouched query has to start
                // well below it rather than at zero.
                logits: vec![-20.0; queries * classes],
            }
        }

        fn put(&mut self, query: usize, cxcywh: [f32; 4], class: usize, logit: f32) -> &mut Self {
            self.boxes[query * 4..query * 4 + 4].copy_from_slice(&cxcywh);
            self.logits[query * self.classes + class] = logit;
            self
        }

        fn spec(&self) -> OutputSpec {
            OutputSpec {
                layout: Layout::DetrQueries { nc: self.classes },
                ..RFDETR.output
            }
        }

        fn decode(&self, floors: &ScoreFloors, size: InputSize) -> Vec<Det> {
            decode_output(
                self.spec(),
                &raw_detr(
                    &self.boxes,
                    &self.logits,
                    self.queries as i64,
                    self.classes as i64,
                ),
                &labels(),
                floors,
                size,
                &Projection::stretch(size),
            )
            .unwrap()
        }
    }

    #[test]
    fn detr_boxes_are_normalized_centers_not_pixels_or_corners() {
        // cx=0.5 cy=0.5 w=0.25 h=0.5 of a 640 square -> 320,320 center with a
        // 160x320 box -> corners 240,160..400,480 -> the frame's middle.
        //
        // Read as xyxy instead this would be a box from 0.5,0.5 to 0.25,0.5 —
        // inverted, and clamped to nothing.
        let mut out = DetrOutput::new(4, 3);
        out.put(0, [0.5, 0.5, 0.25, 0.5], 2, 4.0);
        assert_eq!(
            out.decode(&open(), SQUARE),
            vec![Det {
                label: "car".into(),
                score: 0.982, // sigmoid(4)
                bbox: [0.375, 0.25, 0.25, 0.5],
            }]
        );
    }

    #[test]
    fn detr_scores_are_the_sigmoid_of_the_logit_not_the_logit() {
        // The distinguishing case: a logit of 0.2 sigmoids to 0.5498, which
        // clears the 0.5 default floor, while the bare logit 0.2 does not.
        // Reading logits as probabilities would drop this detection and report
        // every surviving score wrong besides.
        let mut out = DetrOutput::new(2, 3);
        out.put(0, [0.5, 0.5, 0.1, 0.1], 0, 0.2);
        let dets = out.decode(&open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].score, 0.55);
        assert_eq!(RFDETR.output.score, ScoreComposition::SigmoidClass);

        // ...and a strongly negative logit, which is what an unfired query
        // carries, stays far under any floor rather than landing near 0.5.
        assert!(sigmoid(-20.0) < 1e-8);
        assert_eq!(sigmoid(0.0), 0.5);
    }

    #[test]
    fn detr_takes_the_argmax_class_of_each_query() {
        // Under a uniform floor the best class that clears its floor *is* the
        // argmax — sigmoid is monotonic, so no runner-up can clear a bar the
        // argmax misses. The asymmetric case is the next test.
        let mut out = DetrOutput::new(3, 3);
        out.put(0, [0.5, 0.5, 0.2, 0.2], 2, 3.0);
        // a weaker person logit on the same query must not win
        out.logits[0] = 1.0;
        let dets = out.decode(&open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
    }

    #[test]
    fn detr_keeps_the_best_class_that_clears_its_own_floor_not_the_argmax() {
        // Cairn's documented floor pattern is an allowlist: `default: 1.0`
        // admits nothing, and each wanted label names its own bar. Under that
        // shape the argmax class is routinely the *wrong* one to score by —
        // this is the reviewer's case, a query the model reads as car 0.85 /
        // truck 0.60 with floors car 0.9, truck 0.4. Argmax picks car, car
        // fails its own 0.9, and the whole detection — box included — vanishes,
        // even though truck is over its bar and is what RF-DETR's own flattened
        // top-k postprocess would emit.
        let names = Labels(vec!["person".into(), "car".into(), "truck".into()]);
        let asymmetric = floors(r#"{"default":1.0,"person":0.6,"car":0.9,"truck":0.4}"#);
        let logit = |p: f64| (p / (1.0 - p)).ln() as f32;

        let mut out = DetrOutput::new(2, 3);
        out.put(0, [0.5, 0.5, 0.2, 0.2], 1, logit(0.85)).put(
            0,
            [0.5, 0.5, 0.2, 0.2],
            2,
            logit(0.60),
        );

        let decode = |floors: &ScoreFloors, names: &Labels| {
            decode_output(
                out.spec(),
                &raw_detr(&out.boxes, &out.logits, 2, 3),
                names,
                floors,
                SQUARE,
                &Projection::stretch(SQUARE),
            )
            .unwrap()
        };

        let dets = decode(&asymmetric, &names);
        assert_eq!(dets.len(), 1, "the detection must survive: {dets:?}");
        assert_eq!(dets[0].label, "truck");
        assert_eq!(dets[0].score, 0.6);
        // the box is the query's box, unchanged by which label it left under
        assert_eq!(dets[0].bbox, [0.4, 0.4, 0.2, 0.2]);

        // Behaviour under a uniform floor is untouched: car is the argmax and
        // clears 0.5, so it wins and truck is not emitted alongside it.
        let dets = decode(&floors(r#"{"default":0.5}"#), &names);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.85);

        // And a label the allowlist does not name stays out: with `default`
        // at 1.0 and neither class listed, nothing clears anything.
        let unlisted = Labels(vec!["kite".into(), "spoon".into(), "vase".into()]);
        assert!(decode(&asymmetric, &unlisted).is_empty());
    }

    #[test]
    fn detr_is_never_run_through_nms() {
        // Three queries on the same box and class. A grid head would need NMS
        // and this must not get it: DETR's bipartite matching is what stops
        // duplicates, and suppressing here would silently merge the distinct
        // boxes two queries place on neighbouring objects.
        assert!(RFDETR.output.nms.is_none());
        let mut out = DetrOutput::new(4, 3);
        for query in 0..3 {
            out.put(query, [0.5, 0.5, 0.4, 0.4], 2, 3.0);
        }
        assert_eq!(out.decode(&open(), SQUARE).len(), 3);
    }

    #[test]
    fn detr_gates_on_the_per_label_floor_and_caps_like_every_other_layout() {
        let floors = floors(r#"{"default":0.5,"person":0.99}"#);
        let mut out = DetrOutput::new(3, 3);
        // sigmoid(3) = 0.953: over the default, under person's 0.99
        out.put(0, [0.2, 0.2, 0.1, 0.1], 0, 3.0)
            .put(1, [0.7, 0.7, 0.1, 0.1], 2, 3.0);
        let dets = out.decode(&floors, SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");

        // and the MAX_DETS cap holds with the score order intact
        let mut flood = DetrOutput::new(MAX_DETS + 20, 3);
        for query in 0..(MAX_DETS + 20) {
            flood.put(query, [0.5, 0.5, 0.2, 0.2], 2, 1.0 + query as f32 / 100.0);
        }
        let dets = flood.decode(&open(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn detr_non_finite_queries_never_reach_the_output() {
        let mut out = DetrOutput::new(5, 3);
        out.put(0, [f32::NAN, 0.5, 0.1, 0.1], 0, 4.0)
            .put(1, [0.5, f32::INFINITY, 0.1, 0.1], 0, 4.0)
            .put(2, [0.5, 0.5, f32::INFINITY, 0.1], 0, 4.0)
            .put(3, [0.5, 0.5, 0.2, 0.2], 2, 4.0);
        // a NaN logit wins total_cmp's argmax, so it needs its own guard
        out.put(4, [0.5, 0.5, 0.1, 0.1], 1, f32::NAN);

        let dets = out.decode(&open(), SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        let json = serde_json::to_string(&dets).unwrap();
        assert!(!json.contains("null"), "{json}");
    }

    #[test]
    fn detr_boxes_go_through_the_projection_like_everything_else() {
        // Normalized boxes are scaled into model pixels precisely so the
        // letterbox un-projection applies to them too. A DETR fed a padded
        // 16:9 frame is otherwise off by the padding.
        let mut out = DetrOutput::new(2, 3);
        // the box covering the top 234 of 416 rows: the whole content area
        out.put(0, [0.5, 234.0 / 416.0 / 2.0, 1.0, 234.0 / 416.0], 2, 4.0);
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, WIDE);
        let dets = decode_output(
            out.spec(),
            &raw_detr(&out.boxes, &out.logits, 2, 3),
            &labels(),
            &open(),
            YOLOX_416,
            &projection,
        )
        .unwrap();
        assert_eq!(dets[0].bbox, [0.0, 0.0, 1.0, 1.0]);
        // read with the stretch rule the same box loses the bottom 44%
        assert_eq!(
            out.decode(&open(), YOLOX_416)[0].bbox,
            [0.0, 0.0, 1.0, 0.5625]
        );
    }

    // ---- multi-output binding ----------------------------------------------

    #[test]
    fn a_detr_pair_is_bound_by_shape_so_either_export_convention_works() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        // the transformers / onnx-community conversion
        let bound = bind(roles, &declared_detr(300, 91)).unwrap();
        assert_eq!(
            bound.map(|output| output.name.clone()),
            Outputs::BoxesAndLogits {
                boxes: "pred_boxes".into(),
                logits: "logits".into()
            }
        );
        // Roboflow's own export(): different names, and nothing says the
        // boxes come first, so the roles are read off the shapes.
        let roboflow = vec![
            Declared {
                name: "labels".into(),
                dims: Some(vec![1, 300, 91]),
            },
            Declared {
                name: "dets".into(),
                dims: Some(vec![1, 300, 4]),
            },
        ];
        assert_eq!(
            bind(roles, &roboflow).unwrap().map(|o| o.name.clone()),
            Outputs::BoxesAndLogits {
                boxes: "dets".into(),
                logits: "labels".into()
            }
        );
    }

    #[test]
    fn a_detr_export_pinning_no_shape_at_all_is_bound_by_name_instead() {
        // `optimum`'s dynamic_axes leaves the query axis symbolic, so both
        // tensors read as [?, ?, N] and neither declares a shape. Without a
        // fallback such an export cannot be run at all — not even with
        // `--model-profile rfdetr`, whose whole job is to answer for an export
        // that says nothing.
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        let dynamic = |names: [&str; 2]| -> Vec<Declared> {
            names
                .iter()
                .map(|name| Declared {
                    name: (*name).into(),
                    dims: None,
                })
                .collect()
        };
        for names in [
            ["pred_boxes", "logits"],
            ["logits", "pred_boxes"],
            ["dets", "labels"],
            ["labels", "dets"],
        ] {
            let bound = bind(roles, &dynamic(names))
                .unwrap()
                .map(|o| o.name.clone());
            let expected = |role: fn(&str) -> bool| {
                names.iter().copied().find(|n| role(n)).unwrap().to_string()
            };
            assert_eq!(
                bound,
                Outputs::BoxesAndLogits {
                    boxes: expected(|n| n.contains("box") || n.contains("det")),
                    logits: expected(|n| n.contains("logit") || n.contains("label")),
                },
                "{names:?}"
            );
        }

        // ...and the profile that names it then starts, deferring `nc` to the
        // first real output exactly as a one-tensor family does.
        let (profile, outputs, output) = resolve_profile(
            Some(RFDETR),
            &dynamic(["pred_boxes", "logits"]),
            InputSize::square(384),
            Path::new("rfdetr_dynamic.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "rfdetr");
        assert_eq!(
            outputs,
            Outputs::BoxesAndLogits {
                boxes: "pred_boxes".into(),
                logits: "logits".into()
            }
        );
        assert!(output.is_none(), "nc waits for the first real output");
    }

    #[test]
    fn names_that_settle_nothing_are_an_error_rather_than_an_output_order() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        let unnamed = |names: [&str; 2]| -> Vec<Declared> {
            names
                .iter()
                .map(|name| Declared {
                    name: (*name).into(),
                    dims: None,
                })
                .collect()
        };
        // nothing in either name claims a role, and position is not a signal
        let err = bind(roles, &unnamed(["output0", "output1"]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("pred_boxes/logits"), "{err}");
        assert!(err.contains("(dynamic)"), "{err}");
        // two claims on one role is an ambiguity, not a first-wins
        assert!(bind(roles, &unnamed(["pred_boxes", "dets"])).is_err());
        // a name claiming both roles claims neither
        assert!(bind(roles, &unnamed(["box_logits", "logits"])).is_err());

        // An export that *does* pin its shapes and misses is a shape mismatch
        // to report; the name fallback must not paper over it.
        let shaped = vec![Declared {
            name: "pred_boxes".into(),
            dims: Some(vec![1, 300, 6]),
        }];
        let err = bind(roles, &shaped).unwrap_err().to_string();
        assert!(err.contains("[1, 300, 6]"), "{err}");
        assert!(!err.contains("pred_boxes/logits"), "{err}");
    }

    #[test]
    fn a_pair_that_cannot_be_told_apart_is_an_error_naming_the_outputs() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        // a single-output model has no pair at all
        let err = bind(roles, &declared(&[1, 300, 91]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("[1, Q, 4]"), "{err}");
        assert!(err.contains("\"output\""), "{err}");

        // a genuinely 4-class DETR: both tensors end in 4 and nothing says
        // which is the box regression
        let four = vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 300, 4]),
            },
        ];
        assert!(bind(roles, &four).is_err());

        // a pair whose query axes disagree is not a pair
        let mismatched = vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 100, 91]),
            },
        ];
        assert!(bind(roles, &mismatched).is_err());

        // and a single-output layout is unaffected by any of it: it takes the
        // first output and leaves an export's extras alone
        assert_eq!(
            bind(Layout::EndToEnd.roles(), &declared_detr(300, 91)).unwrap(),
            Outputs::One(Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4])
            })
        );
    }

    #[test]
    fn a_two_tensor_model_sniffs_as_rfdetr_and_a_one_tensor_model_never_does() {
        // what rfdetr_nano.onnx declares, at its own 384
        let size = InputSize::square(384);
        let sniffed = sniff(&declared_detr(300, 91), size);
        assert_eq!(sniffed.len(), 1, "{sniffed:?}");
        assert_eq!(sniffed[0].name, "rfdetr");
        assert_eq!(sniffed[0].output.layout, Layout::DetrQueries { nc: 91 });
        assert_eq!(sniffed[0].input.encoding, TensorEncoding::ImageNetRgb);

        // The roles are what keep the families apart: no single-tensor head
        // can match a layout that reads two, and `pred_boxes` on its own fits
        // none of the one-tensor layouts either.
        for dims in [
            vec![1, 300, 6],
            vec![1, 84, 8400],
            vec![1, 3549, 85],
            vec![1, 300, 4],
        ] {
            assert!(
                sniff(&declared(&dims), size)
                    .iter()
                    .all(|p| p.name != "rfdetr"),
                "{dims:?} sniffed as rfdetr"
            );
        }
        assert_eq!(
            fit_layout(Layout::DetrQueries { nc: 91 }, &detr_shapes(300, 91), size).unwrap(),
            Layout::DetrQueries { nc: 91 }
        );
    }

    #[test]
    fn a_detr_whose_logits_come_first_can_collide_with_the_yolox_grid() {
        // The new ambiguity the fifth profile introduces, and the reason
        // binding a role is not the same as sniffing a profile.
        //
        // A single-tensor layout binds the model's *first* output. At 128x128
        // a yolox grid has 16^2 + 8^2 + 4^2 = 336 anchors, so a 336-query DETR
        // that happens to declare its logits first offers `[1, 336, 85]` — a
        // perfectly good 80-class yolox head — while the pair is a perfectly
        // good rfdetr. Nothing in the shapes says which, and they decode
        // completely differently.
        let size = InputSize::square(128);
        assert_eq!(grid_anchors(size, STRIDES), 336);
        let logits_first = vec![
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 336, 85]),
            },
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 336, 4]),
            },
        ];
        assert_eq!(
            sniff(&logits_first, size)
                .iter()
                .map(|p| p.name)
                .collect::<Vec<_>>(),
            vec!["yolox", "rfdetr"]
        );
        let err = resolve_profile(None, &logits_first, size, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("yolox"), "{err}");
        assert!(err.contains("rfdetr"), "{err}");
        assert!(err.contains("--model-profile"), "{err}");
        // the error has to name the outputs, since the shapes alone no longer
        // identify what was looked at
        assert!(err.contains("\"logits\""), "{err}");

        // ...and naming the profile settles it either way
        let (profile, _names, output) =
            resolve_profile(Some(RFDETR), &logits_first, size, Path::new("m.onnx")).unwrap();
        assert_eq!(profile.name, "rfdetr");
        assert_eq!(output.unwrap().layout, Layout::DetrQueries { nc: 85 });
    }

    #[test]
    fn naming_a_profile_whose_roles_the_model_lacks_fails_at_startup() {
        // rfdetr pointed at a one-tensor yolo export: caught here rather than
        // by an output lookup failing inside the inference thread.
        let err = resolve_profile(
            Some(RFDETR),
            &declared(&[1, 300, 6]),
            InputSize::square(384),
            Path::new("m.onnx"),
        )
        .unwrap_err();
        let text = format!("{err:#}");
        assert!(text.contains("--model-profile rfdetr"), "{text}");
        assert!(text.contains("[1, Q, 4]"), "{text}");

        // and the reverse: a single-tensor profile against a DETR export
        // binds `pred_boxes` and then fails to fit it
        assert!(resolve_profile(
            Some(YOLOV10),
            &declared_detr(300, 91),
            InputSize::square(384),
            Path::new("m.onnx")
        )
        .is_err());
    }

    #[test]
    fn a_dynamic_batch_axis_is_not_a_dynamic_layout() {
        // Every RF-DETR export pins its query and class axes and leaves batch
        // symbolic. Reading that as "nothing to sniff" would make the family
        // permanently unsniffable for a reason that says nothing about how it
        // decodes.
        assert_eq!(
            static_output_dims(&tensor_type(&[-1, 300, 4])),
            Some(vec![1, 300, 4])
        );
        assert_eq!(
            static_output_dims(&tensor_type(&[-1, 84, 8400])),
            Some(vec![1, 84, 8400])
        );
        // a symbolic axis anywhere else still declares nothing
        assert!(static_output_dims(&tensor_type(&[-1, 84, -1])).is_none());
        assert!(static_output_dims(&tensor_type(&[1, -1, 8400])).is_none());
        assert!(static_output_dims(&tensor_type(&[-1, -1, -1])).is_none());
        // and a static batch of 2 is a real batched export, which no layout
        // here indexes
        assert_eq!(
            static_output_dims(&tensor_type(&[2, 84, 8400])),
            Some(vec![2, 84, 8400])
        );
        assert!(sniff(&declared(&[2, 84, 8400]), SQUARE).is_empty());
    }

    // ---- decode plumbing ---------------------------------------------------

    #[test]
    fn a_letterboxed_decode_reports_boxes_against_the_original_frame() {
        // The whole reason a projection is threaded through: the same model
        // output, read against a 16:9 source, has to come back as the frame's
        // own geometry rather than the input rectangle's.
        let source = WIDE;
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, source);
        // a box filling the content area exactly
        let rows = row(0.0, 0.0, 416.0, 234.0, 0.9, 2.0);
        let dets = decode_output(
            YOLOV10.output,
            &raw_one(&rows, &[1, 1, 6]),
            &labels(),
            &open(),
            YOLOX_416,
            &projection,
        )
        .unwrap();
        assert_eq!(dets[0].bbox, [0.0, 0.0, 1.0, 1.0]);
        // and the stretch reading of the same output loses the bottom 41%
        let dets = decode(YOLOV10.output, &rows, &[1, 1, 6], &open(), YOLOX_416);
        assert_eq!(dets[0].bbox, [0.0, 0.0, 1.0, 0.5625]);
    }

    #[test]
    fn the_dispatcher_rejects_dims_the_layout_does_not_fit() {
        let projection = Projection::stretch(SQUARE);
        let reject = |output, values: &[f32], dims: &[i64], size| {
            decode_output(
                output,
                &raw_one(values, dims),
                &labels(),
                &open(),
                size,
                &projection,
            )
            .is_err()
        };
        // metadata promised a raw head; the real output is end-to-end
        assert!(reject(v8_spec(80), &[0.0; 6], &[1, 1, 6], SQUARE));
        assert!(reject(YOLOV10.output, &[0.0; 8], &[1, 84, 8400], SQUARE));
        // a raw head whose values do not cover its own dims
        assert!(reject(v8_spec(1), &[0.0; 10], &[1, 5, 100], SQUARE));
        // a raw head whose declared nc disagrees with the real channel axis
        assert!(reject(
            v8_spec(80),
            &vec![0.0; 84 * 8400],
            &[1, 20, 8400],
            SQUARE
        ));
        // ...but one anchor is a decodable raw head, not a shape error: the
        // "anchors far outnumber channels" rule is for telling layouts apart,
        // not for decoding one already settled
        assert!(!reject(v8_spec(3), &[0.0; 7], &[1, 7, 1], SQUARE));

        let yolox = |nc| OutputSpec {
            layout: Layout::GridObjectness {
                nc,
                strides: STRIDES,
            },
            ..YOLOX.output
        };
        // a grid head read at an input size whose grid it does not match:
        // 3549 anchors are 416's, not 640's
        assert!(reject(
            yolox(80),
            &vec![0.0; 3549 * 85],
            &[1, 3549, 85],
            SQUARE
        ));
        // the right anchor count, the wrong row width
        assert!(reject(
            yolox(80),
            &vec![0.0; 3549 * 84],
            &[1, 3549, 84],
            YOLOX_416
        ));
        // dims that fit, values that do not cover them
        assert!(reject(yolox(80), &[0.0; 10], &[1, 3549, 85], YOLOX_416));
        // ...and the shape that does fit is accepted
        assert!(!reject(
            yolox(80),
            &vec![0.0; 3549 * 85],
            &[1, 3549, 85],
            YOLOX_416
        ));
    }

    #[test]
    fn a_label_count_the_model_contradicts_is_fatal() {
        // labels() has 3 names, so an 80-class head is the coco.names-against-
        // rfdetr case: every detection would come out under another class's
        // name, which nothing downstream can detect.
        for layout in [
            Layout::RawClasses { nc: 80 },
            Layout::GridObjectness {
                nc: 80,
                strides: STRIDES,
            },
            Layout::DetrQueries { nc: 91 },
        ] {
            let err = check_label_count(layout, &labels(), false)
                .unwrap_err()
                .to_string();
            // both counts, and the way out
            assert!(err.contains("3 names"), "{err}");
            assert!(
                err.contains(&format!("{} classes", layout.classes().unwrap())),
                "{err}"
            );
            assert!(
                err.contains("coco.names") && err.contains("coco91.names"),
                "{err}"
            );
            assert!(err.contains("--allow-label-mismatch"), "{err}");
            // ...which is honoured
            assert!(check_label_count(layout, &labels(), true).is_ok());
        }
    }

    #[test]
    fn a_label_count_the_model_cannot_contradict_is_fine() {
        // agreeing is not a mismatch
        assert!(check_label_count(Layout::RawClasses { nc: 3 }, &labels(), false).is_ok());
        // no --labels at all is supported: ids render as numbers
        assert!(check_label_count(
            Layout::RawClasses { nc: 80 },
            &Labels::load(None).unwrap(),
            false
        )
        .is_ok());
        // and an end-to-end head declares no class count to check against
        assert!(check_label_count(Layout::EndToEnd, &labels(), false).is_ok());
        assert_eq!(Layout::EndToEnd.classes(), None);
        assert_eq!(Layout::RawClasses { nc: 7 }.classes(), Some(7));
        assert_eq!(labels().count(), 3);
        assert_eq!(Labels::load(None).unwrap().count(), 0);
    }

    /// A labels file, written to a unique path under the test tempdir.
    fn labels_file(name: &str, text: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("cairn-detect-{name}.names"));
        std::fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn a_blank_line_is_an_unnamed_slot_not_a_line_to_skip() {
        // The natural way to write COCO-91's retired ids. Dropping the blanks
        // would shift `car` from 3 to 2 and every later class with it —
        // permanently, silently, and in a file the count check then passes.
        let path = labels_file("gaps", "unlabeled\nperson\n\ncar\n\n\nbus\n");
        let loaded = Labels::load(Some(&path)).unwrap();
        assert_eq!(loaded.count(), 7);
        assert_eq!(loaded.label_for(1), "person");
        assert_eq!(loaded.label_for(3), "car");
        assert_eq!(loaded.label_for(6), "bus");
        // an unnamed slot renders like a missing one, never as an empty label
        assert_eq!(loaded.label_for(2), "2");
        assert_eq!(loaded.label_for(4), "4");
        assert_eq!(loaded.label_for(99), "99");
        // only the trailing newline is dropped, so the count still describes
        // the id space and `check_label_count` can compare it
        assert!(check_label_count(Layout::DetrQueries { nc: 7 }, &loaded, false).is_ok());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_labels_file_is_bounded() {
        // `--labels /dev/zero` is the shape of this: read whole, it never ends
        let path = labels_file("huge", &"x\n".repeat(MAX_LABELS + 1));
        let err = Labels::load(Some(&path)).unwrap_err().to_string();
        assert!(err.contains(&MAX_LABELS.to_string()), "{err}");
        std::fs::remove_file(&path).ok();

        let path = labels_file(
            "wide",
            &format!("{}\n", "x".repeat(MAX_LABELS_BYTES as usize)),
        );
        let err = Labels::load(Some(&path)).unwrap_err().to_string();
        assert!(err.contains(&MAX_LABELS_BYTES.to_string()), "{err}");
        std::fs::remove_file(&path).ok();
    }

    // ---- input size resolution ---------------------------------------------

    fn nchw(dims: [i64; 4]) -> ValueType {
        ValueType::Tensor {
            ty: ort::value::TensorElementType::Float32,
            shape: ort::value::Shape::new(dims),
            dimension_symbols: ort::value::SymbolicDimensions::new([
                String::default(),
                String::default(),
                String::default(),
                String::default(),
            ]),
        }
    }

    #[test]
    fn reads_hw_from_a_static_nchw_input() {
        assert_eq!(
            declared_input_size(&nchw([1, 3, 352, 640])),
            Some(InputSize { w: 640, h: 352 })
        );
    }

    #[test]
    fn a_dynamic_or_odd_rank_input_declares_nothing() {
        // onnxruntime reports a symbolic axis as -1
        assert_eq!(declared_input_size(&nchw([1, 3, -1, -1])), None);
        assert_eq!(declared_input_size(&nchw([-1, 3, 640, -1])), None);
        // a zero axis declares nothing either, so it can never reach the
        // scaler as a 0-wide frame
        assert_eq!(declared_input_size(&nchw([1, 3, 0, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 3, 640, 0])), None);
        assert_eq!(
            declared_input_size(&ValueType::Tensor {
                ty: ort::value::TensorElementType::Float32,
                shape: ort::value::Shape::new([3, 640, 640]),
                dimension_symbols: ort::value::SymbolicDimensions::new([
                    String::default(),
                    String::default(),
                    String::default()
                ]),
            }),
            None
        );
    }

    #[test]
    fn a_channels_last_input_declares_nothing() {
        // [1, H, W, 3] is rank 4 like NCHW, so only the channel axis tells
        // them apart: read positionally it would give w=3 and build a
        // 3-pixel-wide scaler.
        assert_eq!(declared_input_size(&nchw([1, 640, 640, 3])), None);
        assert_eq!(declared_input_size(&nchw([1, 352, 640, 3])), None);
        // a dynamic or non-3 channel axis is equally unreadable
        assert_eq!(declared_input_size(&nchw([1, -1, 640, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 1, 640, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 4, 640, 640])), None);
    }

    #[test]
    fn the_model_supplies_the_size_when_the_flag_does_not() {
        let model = Path::new("m.onnx");
        let declared = Some(InputSize { w: 320, h: 320 });
        assert_eq!(
            resolve_input_size(declared, None, None, model).unwrap(),
            (InputSize::square(320), InputSizeSource::Model)
        );
        // ...and it outranks a profile's family default, which is only a
        // fallback for an export that declares nothing
        assert_eq!(
            resolve_input_size(declared, None, Some(YOLOX), model).unwrap(),
            (InputSize::square(320), InputSizeSource::Model)
        );
    }

    #[test]
    fn the_flag_supplies_the_size_a_dynamic_model_cannot() {
        let model = Path::new("m.onnx");
        assert_eq!(
            resolve_input_size(None, Some(SQUARE), None, model).unwrap(),
            (SQUARE, InputSizeSource::Flag)
        );
        // the flag outranks a profile default too
        assert_eq!(
            resolve_input_size(None, Some(SQUARE), Some(YOLOX), model).unwrap(),
            (SQUARE, InputSizeSource::Flag)
        );
        // a profile default is the last resort...
        assert_eq!(
            resolve_input_size(None, None, Some(YOLOX), model).unwrap(),
            (YOLOX_416, InputSizeSource::Profile)
        );
        // ...and without any of the three there is nothing to build a scaler
        // from
        let err = resolve_input_size(None, None, None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("--input-size"), "{err}");
    }

    #[test]
    fn a_multi_resolution_profile_refuses_to_supply_a_size_it_cannot_know() {
        let model = Path::new("rfdetr_small.onnx");
        // Nano's 384 sits in the profile, but every RF-DETR export leaves its
        // spatial axes dynamic and declares nothing that says which variant it
        // is, so a `small` fed 384 runs to completion and detects nothing.
        // Refusing is the only honest answer; the error carries the set.
        let err = resolve_input_size(None, None, Some(RFDETR), model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("--input-size"), "{err}");
        assert!(err.contains("rfdetr"), "{err}");
        assert!(err.contains(&model.display().to_string()), "{err}");
        for size in ["384", "512", "560", "576", "704"] {
            assert!(err.contains(size), "variant {size} missing from {err}");
        }

        // The flag it asks for is all it needs.
        assert_eq!(
            resolve_input_size(None, Some(InputSize::square(512)), Some(RFDETR), model).unwrap(),
            (InputSize::square(512), InputSizeSource::Flag)
        );
        // A model that pins its own size answers for itself, profile or not.
        assert_eq!(
            resolve_input_size(Some(InputSize::square(512)), None, Some(RFDETR), model).unwrap(),
            (InputSize::square(512), InputSizeSource::Model)
        );
        // A family whose exports pin their geometry still gets its default.
        assert_eq!(
            resolve_input_size(None, None, Some(YOLOX), model).unwrap(),
            (YOLOX_416, InputSizeSource::Profile)
        );
    }

    #[test]
    fn an_absurd_size_is_rejected_whichever_provenance_it_came_from() {
        let model = Path::new("m.onnx");
        let absurd = InputSize::square(64_000_000);
        // a typo'd flag...
        let err = resolve_input_size(None, Some(absurd), None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("64000000x64000000"), "{err}");
        assert!(err.contains("8192"), "{err}");
        assert!(err.contains("--input-size"), "{err}");

        // ...and a model declaring the same nonsense, which no flag touches
        let err = resolve_input_size(Some(absurd), None, None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("64000000x64000000"), "{err}");
        assert!(err.contains("8192"), "{err}");
        assert!(err.contains("from model"), "{err}");

        // one oversized axis is enough
        assert!(resolve_input_size(
            None,
            Some(InputSize {
                w: MAX_INPUT_DIM + 1,
                h: 640
            }),
            None,
            model
        )
        .is_err());
        assert!(resolve_input_size(
            Some(InputSize {
                w: 640,
                h: MAX_INPUT_DIM + 1
            }),
            None,
            None,
            model
        )
        .is_err());
    }

    #[test]
    fn the_limit_itself_is_allowed() {
        let model = Path::new("m.onnx");
        // The widest shape both limits admit: 8192 on one axis is what the
        // i32 casts are bounded for, and 512 on the other keeps the area
        // inside what the allocations are bounded for.
        let at_limit = InputSize {
            w: MAX_INPUT_DIM,
            h: MAX_INPUT_PIXELS / MAX_INPUT_DIM,
        };
        assert_eq!(at_limit.w * at_limit.h, MAX_INPUT_PIXELS);
        assert_eq!(
            resolve_input_size(None, Some(at_limit), None, model).unwrap(),
            (at_limit, InputSizeSource::Flag)
        );
        assert_eq!(
            resolve_input_size(Some(at_limit), None, None, model).unwrap(),
            (at_limit, InputSizeSource::Model)
        );
        // the ceilings are what they protect: the cast stays inside its type
        // and the tensor inside a working set an NVR host can hold
        assert!(i32::try_from(MAX_INPUT_DIM).is_ok());
        assert_eq!(at_limit.tensor_len(), 3 * MAX_INPUT_PIXELS);
        assert!(at_limit.tensor_len() * 4 <= 64 * 1024 * 1024);
        // the square at the same area is admitted too
        assert!(resolve_input_size(Some(InputSize::square(2048)), None, None, model).is_ok());
    }

    #[test]
    fn a_size_inside_the_per_axis_limit_can_still_be_too_large_to_allocate() {
        // The case the per-axis bound alone lets through: a hostile or corrupt
        // ONNX declaring [1, 3, 8192, 8192] passes every dimension check and
        // then asks for an 805 MB tensor plus a 201 MB RGB frame on the first
        // frame, per decode thread, plus one parked in every multiplexed
        // member's slot. Four cameras is over 4 GB of RSS decided by a file.
        let model = Path::new("hostile.onnx");
        let square = InputSize::square(MAX_INPUT_DIM);
        assert!(square.w <= MAX_INPUT_DIM && square.h <= MAX_INPUT_DIM);
        for (declared, requested, source) in [
            (Some(square), None, "from model"),
            (None, Some(square), "--input-size"),
        ] {
            let err = resolve_input_size(declared, requested, None, model)
                .unwrap_err()
                .to_string();
            assert!(err.contains("8192x8192"), "{err}");
            assert!(err.contains(&MAX_INPUT_PIXELS.to_string()), "{err}");
            assert!(err.contains(source), "{err}");
            // the number that makes the case, in MB
            assert!(err.contains("768 MB"), "{err}");
        }
        // one pixel over is over, on either axis
        for over in [
            InputSize {
                w: 2048,
                h: 2048 + 1,
            },
            InputSize {
                w: 2048 + 1,
                h: 2048,
            },
        ] {
            assert!(resolve_input_size(None, Some(over), None, model).is_err());
        }
    }

    #[test]
    fn a_grid_head_refuses_an_input_its_strides_do_not_divide() {
        let grid = Layout::GridObjectness {
            nc: 80,
            strides: STRIDES,
        };
        // 350 is not a multiple of 32: `grid_anchors` and the decode walk both
        // floor-divide and agree with each other, and a real head at that size
        // lays its cells out differently. The total-count check only catches
        // that when the totals differ; when they coincide every box lands in
        // the wrong cell, which is wrong coordinates with nothing on stderr.
        let err = check_grid_divides_input(grid, InputSize { w: 640, h: 350 })
            .unwrap_err()
            .to_string();
        assert!(err.contains("640x350"), "{err}");
        assert!(err.contains("32"), "{err}");

        // the sizes that matter still pass
        for size in [YOLOX_416, SQUARE, TINY, InputSize { w: 640, h: 384 }] {
            assert!(check_grid_divides_input(grid, size).is_ok(), "{size}");
        }
        // and no other layout has a grid to divide
        for layout in [Layout::EndToEnd, Layout::RawClasses { nc: 80 }] {
            assert!(check_grid_divides_input(layout, InputSize { w: 640, h: 350 }).is_ok());
        }
    }

    #[test]
    fn a_flag_contradicting_the_model_fails_at_startup() {
        let err = resolve_input_size(
            Some(InputSize::square(640)),
            Some(InputSize::square(320)),
            None,
            Path::new("m.onnx"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("640x640") && err.contains("320x320"), "{err}");
        // agreeing is not a contradiction
        assert!(resolve_input_size(Some(SQUARE), Some(SQUARE), None, Path::new("m.onnx")).is_ok());
    }

    // ---- encodings ----------------------------------------------------------

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
