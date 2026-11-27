//! The detector families this plugin ships, and the names the command line
//! accepts for them.
//!
//! Each entry is a decode contract; its `families` list the model families
//! the contract applies to. A family is a *name*, never a second [`PROFILES`]
//! entry: several Ultralytics generations export byte-identical tensor
//! layouts, and listing each as its own profile would make every ordinary
//! detect head sniff as several candidates and hard-error on an ambiguity that
//! does not exist.
//!
//! The one exception is [`YOLOV8_SPLIT`] and [`YOLOV9_SPLIT`]: their tensors
//! are identical but their preprocessing is not, which no shape reveals. That
//! ambiguity is real, so an unnamed split-DFL model fails to resolve with both
//! names listed rather than running under a guess.

use anyhow::{anyhow, Result};

use super::encoding::{TensorEncoding, TensorLayout};
use super::geometry::{InputSize, ResizePolicy};
use super::profile::{InputSpec, Layout, ModelProfile, OutputSpec, ScoreComposition, DEFAULT_NMS};

/// Megvii YOLOX (nano / tiny / s). Apache-2.0, the documented default.
pub const YOLOX: ModelProfile = ModelProfile {
    name: "yolox",
    families: &[],
    input: InputSpec {
        size: InputSize::square(416),
        encoding: TensorEncoding::RawBgr,
        resize: ResizePolicy::Letterbox { pad: 114 },
        input_quant: None,
        layout: TensorLayout::Nchw,
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

/// Ultralytics end-to-end / NMS-free head (yolov10).
///
/// `yolo26` used to sit in this contract's families on the claim that YOLO26 is
/// end-to-end like yolov10 — disproven by the first real export run against
/// this decode (yolo26m QDQ on-device, 2026-08-19): the only whole-head YOLO26
/// exports this stack can run are `end2end=False` (the NMS-free tail segfaults
/// quantized QNN — tools/qdq-export/README.md), and their raw `[1, 4+nc, A]`
/// head is the yolov8 contract, whose families list now carries it. A true end-to-end
/// export, should one ever work, names `yolov10` explicitly.
pub const YOLOV10: ModelProfile = ModelProfile {
    name: "yolov10",
    families: &[],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
        input_quant: None,
        layout: TensorLayout::Nchw,
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
/// yolov8, yolov9, yolo11, yolov11 — and yolo26 in the only whole-head form
/// this stack runs (`end2end=False`; see the yolov10 doc) — are all this one
/// profile: every
/// generation's detect head exports the same `[1, 4 + nc, A]` channels-first
/// tensor with no objectness, fed 0..1 RGB stretched to a square, and needs
/// the same NMS afterwards. They differ in weights and backbone, which is not
/// something a decode can see. Verified against a yolov8n export; the others
/// are the same tensor contract by construction, and any export that is not is
/// rejected by `fit_output` rather than decoded wrong.
pub const YOLOV8: ModelProfile = ModelProfile {
    name: "yolov8",
    families: &["yolov9", "yolo11", "yolov11", "yolo26"],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
        input_quant: None,
        layout: TensorLayout::Nchw,
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
/// makes [`super::resolve::resolve_input_size`] refuse to guess and ask for
/// `--input-size`.
pub const RFDETR: ModelProfile = ModelProfile {
    name: "rfdetr",
    families: &[],
    input: InputSpec {
        size: InputSize::square(384),
        encoding: TensorEncoding::ImageNetRgb,
        resize: ResizePolicy::Stretch,
        input_quant: None,
        layout: TensorLayout::Nchw,
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

/// Ultralytics yolov8 and yolo11 exported with the head cut before the box
/// decode, so the DFL runs on the host.
///
/// Same preprocessing and NMS as [`YOLOV8`]; only the tensors differ — three
/// strides of box logits and class scores instead of one decoded tensor. The
/// two generations share this contract. Its own profile rather than a family of
/// `yolov8`, whose output it does not share.
pub const YOLOV8_SPLIT: ModelProfile = ModelProfile {
    name: "yolov8split",
    families: &[],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
        input_quant: None,
        layout: TensorLayout::Nchw,
    },
    output: OutputSpec {
        layout: Layout::SplitDfl {
            nc: 80,
            reg_max: 16,
        },
        score: ScoreComposition::Class,
        nms: Some(DEFAULT_NMS),
    },
    variant_sizes: None,
};

/// YOLOv9 from the MIT rewrite (MultimediaTechLab/YOLO), its head cut the
/// same way.
///
/// The tensors are [`YOLOV8_SPLIT`]'s byte for byte; the resize is not. The
/// model was trained letterboxed, and stretching it costs 1.7–1.8 AP on COCO
/// val2017 (v9-t 38.21 → 36.50, v9-s 46.56 → 44.80). `Letterbox`'s top-left
/// placement measured within 0.2 AP of centred. Not the `yolov9` family name,
/// which is Ultralytics' whole-head export under [`YOLOV8`].
pub const YOLOV9_SPLIT: ModelProfile = ModelProfile {
    name: "yolov9split",
    families: &[],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Letterbox { pad: 114 },
        input_quant: None,
        layout: TensorLayout::Nchw,
    },
    output: YOLOV8_SPLIT.output,
    variant_sizes: None,
};

/// yolo26's one2one head exported with the same cut: `reg_max` is 1, so the
/// box tensors carry l, t, r, b distances directly and there is no DFL.
pub const YOLO26_SPLIT: ModelProfile = ModelProfile {
    name: "yolo26split",
    families: &[],
    input: InputSpec {
        size: InputSize::square(640),
        encoding: TensorEncoding::UnitRgb,
        resize: ResizePolicy::Stretch,
        input_quant: None,
        layout: TensorLayout::Nchw,
    },
    output: OutputSpec {
        layout: Layout::SplitLtrb { nc: 80 },
        score: ScoreComposition::Class,
        nms: Some(DEFAULT_NMS),
    },
    variant_sizes: None,
};

/// Every profile `--model-profile` accepts and sniffing considers, in the
/// order an ambiguity error lists them.
pub const PROFILES: &[ModelProfile] = &[
    YOLOX,
    YOLOV10,
    YOLOV8,
    RFDETR,
    YOLOV8_SPLIT,
    YOLOV9_SPLIT,
    YOLO26_SPLIT,
];

impl ModelProfile {
    /// `--model-profile` value parser, so a typo's error names the real set.
    ///
    /// Hyphens are spelling, not identity — `rf-detr` is the same family as
    /// `rfdetr`, so normalization handles it rather than a `families` entry,
    /// which is reserved for genuinely different families sharing a contract.
    pub fn parse(name: &str) -> Result<Self> {
        let wanted = name.trim().to_ascii_lowercase().replace('-', "");
        PROFILES
            .iter()
            .find(|profile| profile.name == wanted || profile.families.contains(&wanted.as_str()))
            .copied()
            .ok_or_else(|| {
                anyhow!(
                    "unknown model profile {name:?}; expected one of {}",
                    names()
                )
            })
    }
}

/// Every accepted `--model-profile` value, families shown against the
/// contract they resolve to so the error says what `yolo11` will actually do.
pub(super) fn names() -> String {
    PROFILES
        .iter()
        .map(|profile| match profile.families {
            [] => profile.name.to_string(),
            families => format!("{} (or {})", profile.name, families.join(", ")),
        })
        .collect::<Vec<_>>()
        .join(", ")
}
