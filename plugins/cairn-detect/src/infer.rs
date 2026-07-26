//! ONNX inference and postprocess.
//!
//! Two detect-head layouts are supported, told apart by the output shape
//! alone (see [`Layout`]):
//!
//!   * end-to-end / NMS-free (yolov10, YOLO26): `[1, N, 6]` rows of
//!     `[x1, y1, x2, y2, score, class_id]` in input-pixel space, already
//!     sorted by score and already de-duplicated by the model.
//!   * raw (a stock Ultralytics yolov8 / yolo11 detect export):
//!     `[1, 4 + nc, A]` channels-first over A anchors, `cx, cy, w, h` in
//!     input pixels and `nc` sigmoided class scores. This one has *not* had
//!     NMS applied, so this file applies it.
//!
//! Both converge on the same [`Det`] emission: normalize by the input size,
//! clamp, sort by score, cap at [`MAX_DETS`].

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
/// FFmpeg frame and scaler geometry, and multiplied out as `3 * w * h` for
/// every tensor allocation. Without a bound, a typo'd `--input-size` or a
/// model declaring nonsense truncates on the cast or asks for a colossal
/// allocation, which panics or OOMs mid-run instead of failing at startup.
/// 8192 is far past any real detector input — Ultralytics tops out around
/// 1280 — and leaves both well inside their types.
const MAX_INPUT_DIM: usize = 8192;

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

/// Where the resolved [`InputSize`] came from, for the startup line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSizeSource {
    Model,
    Flag,
}

impl fmt::Display for InputSizeSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Model => "from model",
            Self::Flag => "from --input-size",
        })
    }
}

/// IoU above which two same-class boxes are the same detection.
///
/// Ultralytics' own default for a detect head, and only the raw layout ever
/// reaches it — an end-to-end export has already done this inside the model.
const NMS_IOU: f64 = 0.45;

/// Candidates carried into NMS, after sorting by score.
///
/// A 640x640 raw head offers 8400 anchors and NMS is O(k^2); the cap bounds
/// that at a few thousand IoU computations. It is applied *after* the score
/// sort, so it can only ever discard the weakest candidates, and 300 of them
/// is an order of magnitude more than [`MAX_DETS`] can emit.
const MAX_CANDIDATES: usize = 300;

/// Which detect-head layout the model's output is in.
///
/// Resolved once — from the session's output metadata at startup when the
/// export pins its shape, otherwise from the first real output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    /// `[1, N, 6]`, already NMS'd by the model.
    Yolov10,
    /// `[1, 4 + nc, A]`, raw: needs argmax, box conversion and NMS.
    Yolov8 { classes: usize },
}

impl fmt::Display for Layout {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Yolov10 => f.write_str("yolov10"),
            Self::Yolov8 { classes } => write!(f, "yolov8 (nc={classes})"),
        }
    }
}

/// Output dims when the export pins all of them, `None` when any is dynamic.
///
/// A dynamic axis anywhere defers the decision to the first real output
/// rather than guessing: the concrete dims are unambiguous and cost one
/// classification on one frame.
fn static_output_dims(dtype: &ValueType) -> Option<Vec<i64>> {
    let ValueType::Tensor { shape, .. } = dtype else {
        return None;
    };
    shape.iter().all(|d| *d > 0).then(|| shape.to_vec())
}

/// Pick the layout from an output shape.
///
/// The two are structurally distinct, which is why there is no override flag:
/// `6` is the *row width* of an end-to-end output, while a raw head's anchor
/// axis is thousands of entries long (8400 at 640x640, and it scales with the
/// input size) against a channel axis of `4 + nc`. Neither can be mistaken
/// for the other at any nc or any input size.
fn classify_layout(dims: &[i64]) -> Result<Layout> {
    if dims.len() == 3 && dims[0] == 1 {
        if dims[2] == 6 {
            return Ok(Layout::Yolov10);
        }
        if dims[1] >= 5 && dims[2] > dims[1] * 4 {
            return Ok(Layout::Yolov8 {
                classes: (dims[1] - 4) as usize,
            });
        }
    }
    bail!(
        "unsupported model output shape {dims:?}; expected [1, N, 6] \
         (end-to-end yolov10 / YOLO26) or [1, 4 + nc, A] (a raw yolov8 / \
         yolo11 detect head)"
    )
}

/// A label file that does not describe the model's classes is a degraded
/// output, not a fault: ids past the end of the file render as bare numbers,
/// and `--labels` is optional to begin with.
fn warn_on_label_mismatch(layout: Layout, labels: &Labels) {
    let Layout::Yolov8 { classes } = layout else {
        return;
    };
    let provided = labels.count();
    if provided != 0 && provided != classes {
        eprintln!(
            "labels: model has {classes} classes but the label file lists {provided}; \
             class ids past the end will be emitted as numbers"
        );
    }
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
    /// The raw layout prefilters anchors on this before it knows their label,
    /// so it has to be the floor no configured label can undercut — anything
    /// higher would silently drop detections a per-label floor admits.
    pub fn min_floor(&self) -> f64 {
        self.by_label.values().copied().fold(self.default, f64::min)
    }
}

pub struct Labels(Vec<String>);

impl Labels {
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let Some(path) = path else {
            return Ok(Self(Vec::new()));
        };
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading labels from {}", path.display()))?;
        Ok(Self(
            text.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect(),
        ))
    }

    /// Names loaded; 0 when `--labels` was not given.
    pub fn count(&self) -> usize {
        self.0.len()
    }

    /// Unknown class ids fall back to their numeric id, so a mismatched label
    /// file degrades the output instead of hiding detections.
    pub fn label_for(&self, class_id: usize) -> String {
        self.0
            .get(class_id)
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
/// leaves the size to `--input-size`.
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
/// a minute.
fn resolve_input_size(
    declared: Option<InputSize>,
    requested: Option<InputSize>,
    model: &Path,
) -> Result<(InputSize, InputSizeSource)> {
    let (size, source) = match (requested, declared) {
        (Some(requested), Some(declared)) if requested != declared => bail!(
            "--input-size {requested} contradicts model {}, whose input is {declared}",
            model.display()
        ),
        (Some(requested), _) => (requested, InputSizeSource::Flag),
        (None, Some(declared)) => (declared, InputSizeSource::Model),
        (None, None) => bail!(
            "model {} does not pin its input width and height; pass --input-size WxH (or N)",
            model.display()
        ),
    };
    // Both provenances funnel through here, so the ceiling covers a model's
    // declared dims as well as a typo'd flag. Zero is already impossible:
    // `dim` rejects it on the flag and `declared_input_size` requires `> 0`.
    if size.w > MAX_INPUT_DIM || size.h > MAX_INPUT_DIM {
        bail!("input size {size} ({source}) exceeds the {MAX_INPUT_DIM} per-dimension limit");
    }
    Ok((size, source))
}

pub struct Detector {
    session: Session,
    input_name: String,
    output_name: String,
    input_size: InputSize,
    input_size_source: InputSizeSource,
    /// `None` until the first output settles it: see [`static_output_dims`].
    layout: Option<Layout>,
}

impl Detector {
    /// `requested` is `--input-size`; absent, the model must declare one.
    /// `labels` is only read to warn about a class-count mismatch.
    pub fn open(model: &Path, requested: Option<InputSize>, labels: &Labels) -> Result<Self> {
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
        let (input_size, input_size_source) =
            resolve_input_size(declared_input_size(input.dtype()), requested, model)?;
        let output = session
            .outputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no outputs", model.display()))?;
        let output_name = output.name().to_string();
        let layout = static_output_dims(output.dtype())
            .map(|dims| classify_layout(&dims))
            .transpose()
            .with_context(|| format!("model {}", model.display()))?;
        if let Some(layout) = layout {
            warn_on_label_mismatch(layout, labels);
        }
        Ok(Self {
            session,
            input_name,
            output_name,
            input_size,
            input_size_source,
            layout,
        })
    }

    pub fn input_name(&self) -> &str {
        &self.input_name
    }

    /// The geometry every decoder in this process must scale to.
    pub fn input_size(&self) -> InputSize {
        self.input_size
    }

    pub fn input_size_source(&self) -> InputSizeSource {
        self.input_size_source
    }

    /// Startup description of the output layout, deferred when the export
    /// leaves its output shape dynamic.
    pub fn layout_summary(&self) -> String {
        match self.layout {
            Some(layout) => format!("{layout} (from model)"),
            None => "pending (from first output)".to_string(),
        }
    }

    pub fn detect(
        &mut self,
        tensor: Vec<f32>,
        labels: &Labels,
        floors: &ScoreFloors,
    ) -> Result<Vec<Det>> {
        let shape = [1i64, 3, self.input_size.h as i64, self.input_size.w as i64];
        let input = Tensor::from_array((shape, tensor)).context("building the input tensor")?;
        let outputs = self
            .session
            .run(ort::inputs![self.input_name.as_str() => input])
            .context("running inference")?;
        let (shape, values) = outputs
            .get(self.output_name.as_str())
            .ok_or_else(|| anyhow!("model produced no output named {}", self.output_name))?
            .try_extract_tensor::<f32>()
            .context("model output is not an f32 tensor")?;
        let dims: Vec<i64> = shape.iter().copied().collect();
        let layout = match self.layout {
            Some(layout) => layout,
            None => {
                let layout = classify_layout(&dims)?;
                warn_on_label_mismatch(layout, labels);
                eprintln!("output layout: {layout} (from first output)");
                self.layout = Some(layout);
                layout
            }
        };
        decode_output(layout, values, &dims, labels, floors, self.input_size)
    }
}

/// Send the output down the branch its layout calls for.
///
/// The dims are re-checked against the layout even when it came from
/// metadata: an export whose declared shape and real shape disagree would
/// otherwise index a tensor by the wrong stride and emit plausible garbage.
fn decode_output(
    layout: Layout,
    values: &[f32],
    dims: &[i64],
    labels: &Labels,
    floors: &ScoreFloors,
    size: InputSize,
) -> Result<Vec<Det>> {
    match layout {
        Layout::Yolov10 => {
            if dims.len() != 3 || dims[0] != 1 || dims[2] != 6 {
                bail!("expected a [1, N, 6] end-to-end output, got {dims:?}");
            }
            Ok(postprocess(values, labels, floors, size))
        }
        Layout::Yolov8 { classes } => {
            if dims.len() != 3 || dims[0] != 1 || dims[1] != (4 + classes) as i64 {
                bail!(
                    "expected a [1, {}, A] raw detect head, got {dims:?}",
                    4 + classes
                );
            }
            let anchors = dims[2] as usize;
            if values.len() < (4 + classes) * anchors {
                bail!(
                    "output {dims:?} declares {} values but carries {}",
                    (4 + classes) * anchors,
                    values.len()
                );
            }
            Ok(postprocess_yolov8(
                values, classes, anchors, labels, floors, size,
            ))
        }
    }
}

/// `[1, N, 6]` rows of `[x1, y1, x2, y2, score, class_id]` -> contract dets.
///
/// `size` is the geometry the rows are in: model coordinates are input pixels,
/// which for a non-square input normalize by a different divisor per axis.
pub fn postprocess(
    rows: &[f32],
    labels: &Labels,
    floors: &ScoreFloors,
    size: InputSize,
) -> Vec<Det> {
    let dets: Vec<(f64, Det)> = rows
        .chunks_exact(6)
        .filter_map(|row| {
            // NaN survives `score < floor` (the comparison is false) and
            // serde_json writes non-finite floats as `null` — one such row
            // would take the whole line, and every valid detection on it,
            // out of the contract.
            if !row.iter().all(|v| v.is_finite()) {
                return None;
            }
            let score = f64::from(row[4]);
            let class_id = row[5].max(0.0).round() as usize;
            let label = labels.label_for(class_id);
            if score < floors.floor_for(&label) {
                return None;
            }
            let corners = [
                f64::from(row[0]),
                f64::from(row[1]),
                f64::from(row[2]),
                f64::from(row[3]),
            ];
            Some((score, det_from(corners, score, label, size)))
        })
        .collect();

    top_dets(dets)
}

/// `[1, 4 + nc, A]` channels-first raw detect head -> contract dets.
///
/// `values` is channel-major: channel `c` of anchor `a` sits at
/// `c * anchors + a`. Rows 0..4 are `cx, cy, w, h` in input pixels; rows 4..
/// are per-class scores, already sigmoided, with no objectness row to fold
/// in. Unlike the end-to-end layout these are raw proposals — several anchors
/// fire on one object, which is what [`nms`] is here for.
pub fn postprocess_yolov8(
    values: &[f32],
    classes: usize,
    anchors: usize,
    labels: &Labels,
    floors: &ScoreFloors,
    size: InputSize,
) -> Vec<Det> {
    // The prefilter runs before an anchor's label is known, so it cuts at the
    // lowest floor any label could carry. Anything higher would drop
    // detections that a per-label floor admits.
    let prefilter = floors.min_floor();
    let mut candidates: Vec<Candidate> = Vec::new();

    for a in 0..anchors {
        let (class_id, score) = (0..classes)
            .map(|c| (c, f64::from(values[(4 + c) * anchors + a])))
            .max_by(|x, y| x.1.total_cmp(&y.1))
            .expect("a raw detect head has at least one class");
        // A NaN score wins `total_cmp`'s argmax, so it is rejected here
        // rather than left to be compared against a floor (where every
        // comparison is false) and serialized as `null`, which would take the
        // whole output line out of the contract.
        if score.is_nan() || score < prefilter {
            continue;
        }
        let cx = f64::from(values[a]);
        let cy = f64::from(values[anchors + a]);
        let w = f64::from(values[2 * anchors + a]);
        let h = f64::from(values[3 * anchors + a]);
        if !(cx.is_finite() && cy.is_finite() && w.is_finite() && h.is_finite()) {
            continue;
        }
        candidates.push(Candidate {
            score,
            class_id,
            corners: [cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0],
        });
    }

    candidates.sort_by(|a, b| b.score.total_cmp(&a.score));
    candidates.truncate(MAX_CANDIDATES);

    let dets = nms(candidates)
        .into_iter()
        .filter_map(|candidate| {
            let label = labels.label_for(candidate.class_id);
            // The per-label floor waits until after NMS because it needs the
            // label. Nothing is lost by waiting: NMS only ever drops a box
            // weaker than one of its own class, which shares its floor.
            (candidate.score >= floors.floor_for(&label)).then(|| {
                (
                    candidate.score,
                    det_from(candidate.corners, candidate.score, label, size),
                )
            })
        })
        .collect();
    top_dets(dets)
}

/// One anchor of a raw detect head, in input pixels, before NMS.
struct Candidate {
    score: f64,
    class_id: usize,
    /// `[x0, y0, x1, y1]`.
    corners: [f64; 4],
}

/// Class-aware greedy NMS.
///
/// Only a stronger box of the *same* class suppresses one, so two classes
/// firing on the same object both survive — merging them would lose the
/// weaker label entirely, and Cairn's per-label floors are what decide
/// whether it matters.
///
/// `candidates` must already be sorted by descending score.
fn nms(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut kept: Vec<Candidate> = Vec::new();
    for candidate in candidates {
        let suppressed = kept.iter().any(|keeper| {
            keeper.class_id == candidate.class_id
                && iou(&keeper.corners, &candidate.corners) >= NMS_IOU
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

/// Input-pixel corners -> the contract's normalized `[x, y, w, h]`.
///
/// Contract: bbox normalized 0..1 — boxes can run past the frame edge, and a
/// non-square input normalizes each axis by its own side.
fn det_from(corners: [f64; 4], score: f64, label: String, size: InputSize) -> Det {
    let (sx, sy) = (size.w as f64, size.h as f64);
    let x0 = (corners[0] / sx).clamp(0.0, 1.0);
    let y0 = (corners[1] / sy).clamp(0.0, 1.0);
    let x1 = (corners[2] / sx).clamp(0.0, 1.0);
    let y1 = (corners[3] / sy).clamp(0.0, 1.0);
    Det {
        label,
        score: round_to(score, 3),
        bbox: [
            round_to(x0, 4),
            round_to(y0, 4),
            round_to((x1 - x0).max(0.0), 4),
            round_to((y1 - y0).max(0.0), 4),
        ],
    }
}

/// Score-order and cap, where both layouts converge.
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
mod tests {
    use super::*;

    fn labels() -> Labels {
        Labels(vec!["person".into(), "bicycle".into(), "car".into()])
    }

    fn row(x1: f32, y1: f32, x2: f32, y2: f32, score: f32, class_id: f32) -> [f32; 6] {
        [x1, y1, x2, y2, score, class_id]
    }

    const SQUARE: InputSize = InputSize::square(640);

    #[test]
    fn floors_default_to_half() {
        let floors = ScoreFloors::parse("{}").unwrap();
        assert_eq!(floors.floor_for("person"), 0.5);
    }

    #[test]
    fn floors_are_per_label_with_a_default() {
        let floors = ScoreFloors::parse(r#"{"default":0.4,"person":0.8}"#).unwrap();
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
    fn normalizes_and_rounds_boxes() {
        let rows = row(64.0, 128.0, 192.0, 320.0, 0.876_54, 0.0);
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap(), SQUARE);
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
        let rows = row(32.0, 32.0, 160.0, 80.0, 0.9, 0.0);
        let dets = postprocess(
            &rows,
            &labels(),
            &ScoreFloors::parse("{}").unwrap(),
            InputSize { w: 320, h: 160 },
        );
        assert_eq!(dets[0].bbox, [0.1, 0.2, 0.4, 0.3]);
    }

    #[test]
    fn gates_on_the_per_class_floor() {
        let floors = ScoreFloors::parse(r#"{"default":0.5,"person":0.9}"#).unwrap();
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 0.0)); // person, under 0.9
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 2.0)); // car, over 0.5
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.40, 2.0)); // car, under 0.5
        let dets = postprocess(&rows, &labels(), &floors, SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
    }

    #[test]
    fn clamps_boxes_to_the_frame() {
        let rows = row(-320.0, -640.0, 1280.0, 1280.0, 0.9, 2.0);
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap(), SQUARE);
        assert_eq!(dets[0].bbox, [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn drops_non_finite_rows() {
        let floors = ScoreFloors::parse("{}").unwrap();
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, f32::NAN, 0.0));
        rows.extend_from_slice(&row(f32::NAN, 0.0, 64.0, 64.0, 0.9, 0.0));
        rows.extend_from_slice(&row(0.0, 0.0, f32::INFINITY, 64.0, 0.9, 0.0));
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.9, 2.0));
        let dets = postprocess(&rows, &labels(), &floors, SQUARE);
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
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets[0].score > dets[MAX_DETS - 1].score);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
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

    fn v8(
        nc: usize,
        anchors: &[(f32, f32, f32, f32, usize, f32)],
        floors: &ScoreFloors,
        size: InputSize,
    ) -> Vec<Det> {
        let values = v8_output(nc, anchors);
        postprocess_yolov8(&values, nc, anchors.len(), &labels(), floors, size)
    }

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
    fn a_row_width_of_six_is_the_end_to_end_layout() {
        assert_eq!(classify_layout(&[1, 300, 6]).unwrap(), Layout::Yolov10);
        // yolov10n's own export
        assert_eq!(
            classify_layout(&[1, 300, 6]).unwrap().to_string(),
            "yolov10"
        );
    }

    #[test]
    fn a_long_anchor_axis_is_the_raw_detect_head() {
        // coco yolov8n at 640x640
        assert_eq!(
            classify_layout(&[1, 84, 8400]).unwrap(),
            Layout::Yolov8 { classes: 80 }
        );
        // a single-class model at a small input still has far more anchors
        // than channels
        assert_eq!(
            classify_layout(&[1, 5, 189]).unwrap(),
            Layout::Yolov8 { classes: 1 }
        );
        assert_eq!(
            classify_layout(&[1, 84, 8400]).unwrap().to_string(),
            "yolov8 (nc=80)"
        );
    }

    #[test]
    fn an_unrecognizable_shape_names_both_layouts() {
        for dims in [
            vec![1, 84, 84],      // no axis long enough to be anchors
            vec![1, 3, 640, 640], // rank 4
            vec![1, 8400, 84],    // transposed raw head: not what ort emits
            vec![1, 25200, 85],   // yolov5, which carries an objectness row
            vec![2, 84, 8400],    // batched
        ] {
            let err = classify_layout(&dims).unwrap_err().to_string();
            assert!(
                err.contains("[1, N, 6]") && err.contains("[1, 4 + nc, A]"),
                "{err}"
            );
        }
    }

    #[test]
    fn a_static_output_shape_settles_the_layout_at_startup() {
        let dims = static_output_dims(&tensor_type(&[1, 84, 8400])).unwrap();
        assert_eq!(
            classify_layout(&dims).unwrap(),
            Layout::Yolov8 { classes: 80 }
        );
    }

    #[test]
    fn a_dynamic_output_shape_defers_to_the_first_output() {
        // nothing to classify at startup...
        assert!(static_output_dims(&tensor_type(&[1, 84, -1])).is_none());
        assert!(static_output_dims(&tensor_type(&[-1, -1, -1])).is_none());
        // ...and the concrete dims of the first output settle it
        assert_eq!(
            classify_layout(&[1, 84, 8400]).unwrap(),
            Layout::Yolov8 { classes: 80 }
        );
    }

    #[test]
    fn decodes_raw_boxes_from_centers() {
        // cx=320 cy=320 w=128 h=192 -> corners 256,224..384,416
        let dets = v8(
            3,
            &[(320.0, 320.0, 128.0, 192.0, 0, 0.9)],
            &ScoreFloors::parse("{}").unwrap(),
            SQUARE,
        );
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
        let dets = postprocess_yolov8(
            &values,
            3,
            1,
            &labels(),
            &ScoreFloors::parse("{}").unwrap(),
            SQUARE,
        );
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.8);
    }

    #[test]
    fn nms_collapses_same_class_overlap_but_keeps_other_classes() {
        let floors = ScoreFloors::parse("{}").unwrap();
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
            &floors,
            SQUARE,
        );
        let mut seen: Vec<(&str, f64)> = dets.iter().map(|d| (d.label.as_str(), d.score)).collect();
        seen.sort_by(|a, b| b.1.total_cmp(&a.1));
        assert_eq!(seen, vec![("person", 0.9), ("car", 0.7), ("person", 0.6)]);
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
        let dets = v8(
            3,
            &[(160.0, 80.0, 64.0, 32.0, 0, 0.9)],
            &ScoreFloors::parse("{}").unwrap(),
            size,
        );
        assert_eq!(dets[0].bbox, [0.4, 0.4, 0.2, 0.2]);
    }

    #[test]
    fn the_prefilter_never_cuts_above_a_configured_floor() {
        // the lowest configured floor is what the prefilter may cut at
        let floors = ScoreFloors::parse(r#"{"default":0.5,"car":0.02}"#).unwrap();
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
    fn a_flood_of_raw_anchors_still_fits_the_contract() {
        // Distinct, non-overlapping boxes so NMS keeps every one of them:
        // the MAX_DETS cap, not NMS, is what has to hold the line.
        let anchors: Vec<_> = (0..(MAX_CANDIDATES + 500))
            .map(|i| {
                let x = (i % 600) as f32;
                let y = (i / 600) as f32;
                (x, y, 0.5, 0.5, i % 3, 0.6 + (i % 100) as f32 / 1000.0)
            })
            .collect();
        let dets = v8(3, &anchors, &ScoreFloors::parse("{}").unwrap(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }

    #[test]
    fn raw_non_finite_anchors_never_reach_the_output() {
        let floors = ScoreFloors::parse("{}").unwrap();
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
        let dets = postprocess_yolov8(&values, 3, 3, &labels(), &floors, SQUARE);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        let json = serde_json::to_string(&dets).unwrap();
        assert!(!json.contains("null"), "{json}");
    }

    #[test]
    fn the_dispatcher_rejects_dims_the_layout_does_not_fit() {
        let floors = ScoreFloors::parse("{}").unwrap();
        // metadata promised a raw head; the real output is end-to-end
        assert!(decode_output(
            Layout::Yolov8 { classes: 80 },
            &[0.0; 6],
            &[1, 1, 6],
            &labels(),
            &floors,
            SQUARE,
        )
        .is_err());
        assert!(decode_output(
            Layout::Yolov10,
            &[0.0; 8],
            &[1, 84, 8400],
            &labels(),
            &floors,
            SQUARE,
        )
        .is_err());
        // a raw head whose values do not cover its own dims
        assert!(decode_output(
            Layout::Yolov8 { classes: 1 },
            &[0.0; 10],
            &[1, 5, 100],
            &labels(),
            &floors,
            SQUARE,
        )
        .is_err());
    }

    #[test]
    fn label_count_mismatch_is_a_warning_not_a_failure() {
        // labels() has 3 names; the call must return either way
        warn_on_label_mismatch(Layout::Yolov8 { classes: 80 }, &labels());
        warn_on_label_mismatch(Layout::Yolov8 { classes: 3 }, &labels());
        warn_on_label_mismatch(Layout::Yolov10, &labels());
        assert_eq!(labels().count(), 3);
        assert_eq!(Labels::load(None).unwrap().count(), 0);
    }

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
            resolve_input_size(declared, None, model).unwrap(),
            (InputSize::square(320), InputSizeSource::Model)
        );
    }

    #[test]
    fn the_flag_supplies_the_size_a_dynamic_model_cannot() {
        let model = Path::new("m.onnx");
        assert_eq!(
            resolve_input_size(None, Some(SQUARE), model).unwrap(),
            (SQUARE, InputSizeSource::Flag)
        );
        // ...and without it there is nothing to build a scaler from
        let err = resolve_input_size(None, None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("--input-size"), "{err}");
    }

    #[test]
    fn an_absurd_size_is_rejected_whichever_provenance_it_came_from() {
        let model = Path::new("m.onnx");
        let absurd = InputSize::square(64_000_000);
        // a typo'd flag...
        let err = resolve_input_size(None, Some(absurd), model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("64000000x64000000"), "{err}");
        assert!(err.contains("8192"), "{err}");
        assert!(err.contains("--input-size"), "{err}");

        // ...and a model declaring the same nonsense, which no flag touches
        let err = resolve_input_size(Some(absurd), None, model)
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
            model
        )
        .is_err());
        assert!(resolve_input_size(
            Some(InputSize {
                w: 640,
                h: MAX_INPUT_DIM + 1
            }),
            None,
            model
        )
        .is_err());
    }

    #[test]
    fn the_limit_itself_is_allowed() {
        let model = Path::new("m.onnx");
        let at_limit = InputSize::square(MAX_INPUT_DIM);
        assert_eq!(
            resolve_input_size(None, Some(at_limit), model).unwrap(),
            (at_limit, InputSizeSource::Flag)
        );
        assert_eq!(
            resolve_input_size(Some(at_limit), None, model).unwrap(),
            (at_limit, InputSizeSource::Model)
        );
        // the ceiling is what it protects: both stay inside their types
        assert!(i32::try_from(MAX_INPUT_DIM).is_ok());
        assert!(at_limit.tensor_len() < usize::MAX);
    }

    #[test]
    fn a_flag_contradicting_the_model_fails_at_startup() {
        let err = resolve_input_size(
            Some(InputSize::square(640)),
            Some(InputSize::square(320)),
            Path::new("m.onnx"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("640x640") && err.contains("320x320"), "{err}");
        // agreeing is not a contradiction
        assert!(resolve_input_size(Some(SQUARE), Some(SQUARE), Path::new("m.onnx")).is_ok());
    }
}
