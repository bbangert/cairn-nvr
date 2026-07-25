//! ONNX inference and postprocess.
//!
//! The model is expected to be NMS-free (yolov10 / YOLO26 style): output
//! `[1, N, 6]` rows of `[x1, y1, x2, y2, score, class_id]` in input-pixel
//! space, already sorted by score. That is the whole reason there is no NMS
//! in this file — a raw YOLOv8 export needs one and will emit dozens of
//! near-identical boxes here.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use ort::session::Session;
use ort::value::Tensor;

use crate::emit::Det;

pub const INPUT_SIZE: usize = 640;
pub const MAX_DETS: usize = 32;

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
        Ok(Self {
            default: raw.get("default").copied().unwrap_or(0.5),
            by_label: raw,
        })
    }

    pub fn floor_for(&self, label: &str) -> f64 {
        self.by_label.get(label).copied().unwrap_or(self.default)
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

    /// Unknown class ids fall back to their numeric id, so a mismatched label
    /// file degrades the output instead of hiding detections.
    pub fn label_for(&self, class_id: usize) -> String {
        self.0
            .get(class_id)
            .cloned()
            .unwrap_or_else(|| class_id.to_string())
    }
}

pub struct Detector {
    session: Session,
    input_name: String,
    output_name: String,
}

impl Detector {
    pub fn open(model: &Path) -> Result<Self> {
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
        let input_name = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no inputs", model.display()))?
            .name()
            .to_string();
        let output_name = session
            .outputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no outputs", model.display()))?
            .name()
            .to_string();
        Ok(Self {
            session,
            input_name,
            output_name,
        })
    }

    pub fn input_name(&self) -> &str {
        &self.input_name
    }

    pub fn detect(
        &mut self,
        tensor: Vec<f32>,
        labels: &Labels,
        floors: &ScoreFloors,
    ) -> Result<Vec<Det>> {
        let shape = [1i64, 3, INPUT_SIZE as i64, INPUT_SIZE as i64];
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
        if dims.len() != 3 || dims[0] != 1 || dims[2] != 6 {
            bail!(
                "expected an NMS-free [1, N, 6] output, got {dims:?}; \
                 a YOLOv8-style export needs a different postprocess"
            );
        }
        Ok(postprocess(values, labels, floors))
    }
}

/// `[1, N, 6]` rows of `[x1, y1, x2, y2, score, class_id]` -> contract dets.
pub fn postprocess(rows: &[f32], labels: &Labels, floors: &ScoreFloors) -> Vec<Det> {
    let mut dets: Vec<(f64, Det)> = rows
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
            // Contract: bbox normalized 0..1 — boxes can run past the frame edge.
            let scale = INPUT_SIZE as f64;
            let x0 = (f64::from(row[0]) / scale).clamp(0.0, 1.0);
            let y0 = (f64::from(row[1]) / scale).clamp(0.0, 1.0);
            let x1 = (f64::from(row[2]) / scale).clamp(0.0, 1.0);
            let y1 = (f64::from(row[3]) / scale).clamp(0.0, 1.0);
            Some((
                score,
                Det {
                    label,
                    score: round_to(score, 3),
                    bbox: [
                        round_to(x0, 4),
                        round_to(y0, 4),
                        round_to((x1 - x0).max(0.0), 4),
                        round_to((y1 - y0).max(0.0), 4),
                    ],
                },
            ))
        })
        .collect();

    // yolov10 exports are already score-ordered; sorting keeps the MAX_DETS
    // cut meaningful for exports that are not.
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
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap());
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
    fn gates_on_the_per_class_floor() {
        let floors = ScoreFloors::parse(r#"{"default":0.5,"person":0.9}"#).unwrap();
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 0.0)); // person, under 0.9
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.85, 2.0)); // car, over 0.5
        rows.extend_from_slice(&row(0.0, 0.0, 64.0, 64.0, 0.40, 2.0)); // car, under 0.5
        let dets = postprocess(&rows, &labels(), &floors);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
    }

    #[test]
    fn clamps_boxes_to_the_frame() {
        let rows = row(-320.0, -640.0, 1280.0, 1280.0, 0.9, 2.0);
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap());
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
        let dets = postprocess(&rows, &labels(), &floors);
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
        let dets = postprocess(&rows, &labels(), &ScoreFloors::parse("{}").unwrap());
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets[0].score > dets[MAX_DETS - 1].score);
        assert!(dets.windows(2).all(|w| w[0].score >= w[1].score));
    }
}
