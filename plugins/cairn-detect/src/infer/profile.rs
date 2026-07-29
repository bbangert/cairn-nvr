//! What a detector family *is*, as data: how frames must be fed to it and how
//! its output must be read.
//!
//! Everything here is shape and vocabulary. The concrete families that fill
//! these types in live in [`super::catalog`], and nothing in this module knows
//! they exist — which is what lets a new family be a catalog entry rather than
//! a code change.

use std::fmt;

use super::encoding::TensorEncoding;
use super::geometry::{InputSize, ResizePolicy};

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
    pub(super) fn map<U>(&self, mut f: impl FnMut(&T) -> U) -> Outputs<U> {
        match self {
            Self::One(one) => Outputs::One(f(one)),
            Self::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: f(boxes),
                logits: f(logits),
            },
        }
    }

    /// The same, for a payload that may be missing — `None` if any role's is.
    pub(super) fn try_map<U>(&self, mut f: impl FnMut(&T) -> Option<U>) -> Option<Outputs<U>> {
        Some(match self {
            Self::One(one) => Outputs::One(f(one)?),
            Self::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: f(boxes)?,
                logits: f(logits)?,
            },
        })
    }

    /// Every role's payload, in the order an error message lists them.
    pub(super) fn each(&self) -> Vec<&T> {
        match self {
            Self::One(one) => vec![one],
            Self::BoxesAndLogits { boxes, logits } => vec![boxes, logits],
        }
    }
}

/// How a detect head's output tensor is laid out.
///
/// The counts here (`nc`, and the anchor total the strides imply) are read off
/// the model's real output shape by `resolve::fit_layout`; a built-in profile
/// carries
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
    pub(super) fn expected(self, size: InputSize) -> String {
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
    /// ([`super::heads::candidates_from`]). Truncating before that gate would let
    /// a flood of
    /// high-scoring boxes in excluded classes push out the one class an
    /// allowlist configuration asked for.
    pub max_candidates: usize,
}

/// Ultralytics' own default for a detect head, and YOLOX's demo value too.
pub(super) const DEFAULT_NMS: NmsSpec = NmsSpec {
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
    /// An alias is a *name*, never a second entry in [`super::catalog::PROFILES`]:
    /// several
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
    /// [`super::resolve::resolve_input_size`] must refuse rather than fall back to
    /// it. The
    /// consequence of guessing is not a wrong-but-working run: an RF-DETR
    /// `small` export fed Nano's 384 produces zero detections and zero
    /// warnings, and nothing in the graph says which variant it is — every
    /// variant declares the same 300 queries and 91 logits. So the text here
    /// is what the error offers instead of a guess.
    pub variant_sizes: Option<&'static str>,
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
pub(super) fn grid_anchors(size: InputSize, strides: &[usize]) -> usize {
    strides
        .iter()
        .map(|stride| (size.w / stride) * (size.h / stride))
        .sum()
}

/// The bound shapes, as an error message lists them.
pub(super) fn show(shapes: &Shapes) -> String {
    shapes
        .each()
        .into_iter()
        .map(|dims| format!("{dims:?}"))
        .collect::<Vec<_>>()
        .join(" + ")
}
