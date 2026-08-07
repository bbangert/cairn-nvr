//! Class names and score floors — the operator-supplied inputs that decide
//! what a detection is *called* and whether it is emitted at all.
//!
//! Names and per-class floors are both indexed by class id, which is why a
//! count mismatch is a startup failure rather than a degraded output: nothing
//! downstream can tell a mislabelled detection from a correct one.
//!
//! The third input, `--track-floor-json`, is a floor *under* the per-class
//! ones: with it set a detection between the two is still emitted, at its real
//! score, for the host's low-confidence association stage to match against.
//! Absent — the default — it changes nothing anywhere.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{bail, Context, Result};
use serde::Deserialize;

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

/// Track-floor knob as the operator writes it, with its one key optional.
///
/// The same shape parses `--track-floor-json` (the whole process's default)
/// and a `--cameras-json` member's `track_floor` key (that one camera's
/// override), which is the [`crate::motion::MotionOverrides`] pattern and for
/// the same reason: this is the operator's own flag, written into the
/// configured command rather than appended by Cairn, so it has to be
/// expressible in both modes.
///
/// `deny_unknown_fields` for the motion gate's reason too — a mistyped knob
/// that parses is a setting that silently did nothing.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrackFloorOverrides {
    /// Score below the per-class `min_score` down to which detections are
    /// still emitted. Absent is the feature off.
    pub floor: Option<f64>,
}

impl TrackFloorOverrides {
    /// Decode the `--track-floor-json` argument.
    pub fn parse(json: &str) -> Result<Self> {
        let parsed: Self = serde_json::from_str(json)
            .context("--track-floor-json is not a JSON object of track-floor knobs")?;
        parsed.validate()?;
        Ok(parsed)
    }

    /// Reject a floor no run could honour, at the point the operator can still
    /// read the message. The check that needs a camera's own `min_score` map
    /// is [`ScoreFloors::with_track_floor`]; this one is the range.
    pub fn validate(&self) -> Result<()> {
        match self.floor {
            Some(floor) => check_track_floor(floor),
            None => Ok(()),
        }
    }

    /// The floor one camera emits under: the process-wide
    /// `--track-floor-json`, then that camera's own `track_floor` key, which
    /// replaces it outright rather than merging into it — there is one knob,
    /// so "override only what you name" and "override" are the same thing.
    ///
    /// `None` is the feature off, which is the default and is what makes a run
    /// with no `--track-floor-json` byte-identical to the build before the flag
    /// existed: nothing below a per-class `min_score` reaches the wire.
    pub fn resolve(global: &Self, per_camera: &Self) -> Option<f64> {
        per_camera.floor.or(global.floor)
    }
}

/// Is this a score a track floor could be?
///
/// Written as a positive test rather than as `floor <= 0.0`: NaN fails every
/// comparison, and it has to land on the refusing side.
fn check_track_floor(floor: f64) -> Result<()> {
    if !(floor > 0.0 && floor < 1.0) {
        bail!(
            "track floor must be in (0, 1), got {floor}: at or below 0 every box the model \
             proposes is emitted, which is noise the host's low-confidence stage has no use for \
             below about 0.05, and no score is ever above 1"
        );
    }
    Ok(())
}

/// Per-class score floor from `--min-score-json`, plus the optional
/// `--track-floor-json` floor underneath them. Cairn enforces the per-class
/// floors again downstream; gating here just keeps the ndjson small.
#[derive(Debug, Clone)]
pub struct ScoreFloors {
    default: f64,
    by_label: HashMap<String, f64>,
    /// The resolved track floor, or `None` with the feature off. Strictly
    /// below every floor in `by_label` and below `default`, which
    /// [`ScoreFloors::with_track_floor`] is where it is checked.
    track_floor: Option<f64>,
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
            track_floor: None,
        }
    }

    /// Attach this camera's resolved track floor, refusing one it cannot sit
    /// under.
    ///
    /// A track floor is only meaningful as a floor *below* the evidence
    /// floors: what it buys is the band `[track_floor, min_score)`, and a floor
    /// at or above the lowest configured `min_score` either makes that band
    /// empty for some class or — worse — reads as an attempt to raise a floor,
    /// which this flag cannot do. So it is refused rather than clamped, naming
    /// the floor it collided with.
    ///
    /// The range check is repeated here rather than left to
    /// [`TrackFloorOverrides::validate`], which has already run over both argv
    /// forms: this is the only place a floor is attached to a camera's floors,
    /// and what a hole here costs is silent noise emission for the life of the
    /// process.
    pub fn with_track_floor(mut self, floor: Option<f64>) -> Result<Self> {
        let Some(floor) = floor else {
            return Ok(self);
        };
        check_track_floor(floor)?;
        let lowest = self.lowest_min_score();
        if floor >= lowest {
            bail!(
                "track floor {floor} must be strictly below every min_score it pairs with; the \
                 lowest on this camera is {lowest}. The flag emits the band \
                 [track_floor, min_score), so a floor at or above one closes that band instead of \
                 opening it"
            );
        }
        self.track_floor = Some(floor);
        Ok(self)
    }

    /// The `min_score` this label is held to — the evidence floor, as the
    /// operator wrote it. Unaffected by the track floor: what that lowers is
    /// what reaches the wire, not what the host will read as evidence.
    pub fn floor_for(&self, label: &str) -> f64 {
        self.by_label.get(label).copied().unwrap_or(self.default)
    }

    /// The score below which a detection of `label` is not emitted at all:
    /// this camera's track floor when it has one, and the label's own
    /// `min_score` otherwise.
    ///
    /// The two are the same number for every label with the flag off, which is
    /// what makes the default byte-identical to the build before it.
    pub fn emit_floor_for(&self, label: &str) -> f64 {
        self.track_floor.unwrap_or_else(|| self.floor_for(label))
    }

    /// The lowest score anything could be emitted at.
    ///
    /// Only [`Layout::EndToEnd`] needs it: its class id is a number in the
    /// output row rather than an index into a known `nc`, so there is no
    /// per-class floor table to look one up in. It has to be the floor no
    /// configured label can undercut — anything higher would silently drop
    /// detections a per-label floor admits — which with a track floor set is
    /// the track floor itself, it being strictly below all of them.
    pub fn min_emit_floor(&self) -> f64 {
        self.track_floor.unwrap_or_else(|| self.lowest_min_score())
    }

    /// The lowest `min_score` configured on this camera, `default` included.
    fn lowest_min_score(&self) -> f64 {
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

    /// Whether any class resolves to this label name.
    pub fn contains(&self, name: &str) -> bool {
        self.0.iter().any(|label| label == name)
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

    /// The resolved floor of a `--track-floor-json` that parses.
    fn track_floor(json: &str) -> Option<f64> {
        TrackFloorOverrides::resolve(
            &TrackFloorOverrides::parse(json).unwrap(),
            &TrackFloorOverrides::default(),
        )
    }

    #[test]
    fn a_track_floor_is_absent_unless_the_operator_writes_one() {
        // The whole default: no flag, no key, nothing to resolve. What that
        // buys is the byte-identity below.
        assert_eq!(track_floor("{}"), None);
        assert_eq!(TrackFloorOverrides::default().floor, None);
        assert_eq!(track_floor(r#"{"floor":null}"#), None);
        assert_eq!(track_floor(r#"{"floor":0.1}"#), Some(0.1));
    }

    #[test]
    fn with_no_track_floor_every_emission_floor_is_the_labels_own() {
        let floors = floors(r#"{"default":0.4,"person":0.8}"#)
            .with_track_floor(None)
            .unwrap();
        assert_eq!(floors.emit_floor_for("person"), 0.8);
        assert_eq!(floors.emit_floor_for("car"), 0.4);
        assert_eq!(floors.min_emit_floor(), 0.4);
    }

    #[test]
    fn a_track_floor_is_the_emission_floor_for_every_label() {
        let floors = floors(r#"{"default":0.4,"person":0.8}"#)
            .with_track_floor(Some(0.1))
            .unwrap();
        // what reaches the wire drops to the one floor...
        assert_eq!(floors.emit_floor_for("person"), 0.1);
        assert_eq!(floors.emit_floor_for("car"), 0.1);
        assert_eq!(floors.min_emit_floor(), 0.1);
        // ...and what counts as evidence does not move at all
        assert_eq!(floors.floor_for("person"), 0.8);
        assert_eq!(floors.floor_for("car"), 0.4);
    }

    #[test]
    fn a_track_floor_at_or_above_a_min_score_is_refused() {
        let floors = || floors(r#"{"default":0.4,"person":0.8}"#);
        // the band it would open is empty for `car` at exactly the floor, and
        // inverted above it
        let err = floors()
            .with_track_floor(Some(0.4))
            .unwrap_err()
            .to_string();
        assert!(err.contains("0.4"), "{err}");
        assert!(floors().with_track_floor(Some(0.5)).is_err());
        // the lowest floor is what it has to clear, not the default and not
        // the label the operator was thinking of
        assert!(floors().with_track_floor(Some(0.399)).is_ok());
        // a bare `--min-score-json '{}'` is the 0.5 default alone
        assert!(open().with_track_floor(Some(0.5)).is_err());
        assert!(open().with_track_floor(Some(0.499)).is_ok());
    }

    #[test]
    fn a_track_floor_outside_a_score_is_refused_at_both_ends() {
        // 0 is the one the plan names: emitting every box the model proposes
        // is a cost with nothing on the host side to match it against.
        for floor in [0.0, -0.1, 1.0, 2.0, f64::NAN, f64::INFINITY] {
            assert!(
                open().with_track_floor(Some(floor)).is_err(),
                "track floor {floor} was accepted"
            );
            assert!(
                TrackFloorOverrides { floor: Some(floor) }
                    .validate()
                    .is_err(),
                "track floor {floor} validated"
            );
        }
        // and the same check runs at parse time, where the operator is still
        // reading messages about their argv
        assert!(TrackFloorOverrides::parse(r#"{"floor":0}"#).is_err());
        assert!(TrackFloorOverrides::parse(r#"{"floor":-1}"#).is_err());
        assert!(TrackFloorOverrides::parse(r#"{"floor":1}"#).is_err());
    }

    #[test]
    fn a_mistyped_track_floor_knob_is_a_startup_failure_not_a_silent_default() {
        assert!(TrackFloorOverrides::parse("not json").is_err());
        assert!(TrackFloorOverrides::parse("[]").is_err());
        assert!(TrackFloorOverrides::parse("0.1").is_err());
        // the knob is `floor`; anything else parses to "no track floor at all"
        // unless it is refused
        assert!(TrackFloorOverrides::parse(r#"{"flor":0.1}"#).is_err());
        assert!(TrackFloorOverrides::parse(r#"{"track_floor":0.1}"#).is_err());
        assert!(TrackFloorOverrides::parse(r#"{"floor":"low"}"#).is_err());
    }

    #[test]
    fn a_cameras_own_track_floor_replaces_the_process_wide_one() {
        let global = TrackFloorOverrides::parse(r#"{"floor":0.1}"#).unwrap();
        let camera = TrackFloorOverrides::parse(r#"{"floor":0.25}"#).unwrap();
        let none = TrackFloorOverrides::default();
        assert_eq!(TrackFloorOverrides::resolve(&global, &camera), Some(0.25));
        assert_eq!(TrackFloorOverrides::resolve(&global, &none), Some(0.1));
        assert_eq!(TrackFloorOverrides::resolve(&none, &camera), Some(0.25));
        assert_eq!(TrackFloorOverrides::resolve(&none, &none), None);
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
