//! The detector families this plugin ships, and the names the command line
//! accepts for them.
//!
//! An alias is a *name*, never a second [`PROFILES`] entry: several Ultralytics
//! generations export byte-identical tensor layouts, and listing each as its
//! own profile would make every ordinary detect head sniff as three candidates
//! and hard-error on an ambiguity that does not exist.

use anyhow::{anyhow, Result};

use super::encoding::TensorEncoding;
use super::geometry::{InputSize, ResizePolicy};
use super::profile::{InputSpec, Layout, ModelProfile, OutputSpec, ScoreComposition, DEFAULT_NMS};

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
/// makes [`super::resolve::resolve_input_size`] refuse to guess and ask for
/// `--input-size`.
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
pub(super) fn names() -> String {
    PROFILES
        .iter()
        .map(|profile| match profile.aliases {
            [] => profile.name.to_string(),
            aliases => format!("{} (or {})", profile.name, aliases.join(", ")),
        })
        .collect::<Vec<_>>()
        .join(", ")
}
