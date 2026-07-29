//! Class names and per-class score floors — the two operator-supplied inputs
//! that decide what a detection is *called* and whether it is emitted at all.
//!
//! Both are indexed by class id, which is why a count mismatch is a startup
//! failure rather than a degraded output: nothing downstream can tell a
//! mislabelled detection from a correct one.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{bail, Context, Result};

use super::profile::Layout;

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
pub(super) fn check_label_count(
    layout: Layout,
    labels: &Labels,
    allow_mismatch: bool,
) -> Result<()> {
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
pub struct Labels(pub(super) Vec<String>);

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
}
