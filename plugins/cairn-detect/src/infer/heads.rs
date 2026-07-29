//! The four decode heads and the tail every one of them converges on.
//!
//! Uniform free-function signatures per head rather than a trait: the set is
//! closed by design — a new family is a catalog entry — and an enum plus plain
//! functions gives the readability without dynamic dispatch.

use anyhow::{anyhow, bail, Result};

use crate::emit::Det;

use super::geometry::{Bbox, InputSize, ModelBox, NormBox, Projection};
use super::labels::{Labels, ScoreFloors};
use super::profile::{grid_anchors, show, Layout, NmsSpec, OutputSpec, Outputs, ScoreComposition};
use super::resolve::validate_layout;
use super::MAX_DETS;

/// One extracted output tensor: the values and the shape they came with.
pub(super) struct Raw<'a> {
    pub(super) dims: Vec<i64>,
    pub(super) values: &'a [f32],
}

/// Read one output tensor into contract detections.
///
/// The dims are re-checked against the layout even when it came from metadata:
/// an export whose declared shape and real shape disagree would otherwise
/// index a tensor by the wrong stride and emit plausible garbage.
pub(super) fn decode_output(
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
/// Built per decode rather than cached on [`super::detector::Detector`]
/// because the floors are
/// per *camera*: one multiplexed process serves a group whose members each
/// carry their own `min_score`, so a table cached beside the session would be
/// the wrong one for every member but the first.
fn class_floors(nc: usize, labels: &Labels, floors: &ScoreFloors) -> Vec<f64> {
    (0..nc)
        .map(|class_id| floors.floor_for(&labels.label_for(class_id)))
        .collect()
}

/// One proposal in model-space pixels, before NMS and un-projection.
pub(super) struct Candidate {
    score: f64,
    class_id: usize,
    /// Corners in model-input pixels, still to be un-projected.
    corners: ModelBox,
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
pub(super) fn candidates_from(
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
                corners: ModelBox(Bbox {
                    x1: f64::from(row[0]),
                    y1: f64::from(row[1]),
                    x2: f64::from(row[2]),
                    y2: f64::from(row[3]),
                }),
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
fn centered(cx: f64, cy: f64, w: f64, h: f64, size: InputSize) -> Option<ModelBox> {
    /// How far past the input rectangle an extent may still be a real box.
    /// Generous: a letterboxed decode legitimately puts boxes outside the
    /// content rectangle, and un-projection is what brings them back.
    const MAX_EXTENT: f64 = 4.0;
    let finite = cx.is_finite() && cy.is_finite() && w.is_finite() && h.is_finite();
    let bounded = w <= MAX_EXTENT * size.w as f64 && h <= MAX_EXTENT * size.h as f64;
    (finite && bounded).then(|| {
        ModelBox(Bbox {
            x1: cx - w / 2.0,
            y1: cy - h / 2.0,
            x2: cx + w / 2.0,
            y2: cy + h / 2.0,
        })
    })
}

/// Where every layout converges: NMS if the head needs it, then the per-label
/// floor, un-projection, score order and the [`MAX_DETS`] cap.
pub(super) fn finish(
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
                    det_from(
                        projection.unproject(candidate.corners),
                        candidate.score,
                        label,
                    ),
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

/// Intersection over union of two boxes, both in model-input pixels.
fn iou(a: &ModelBox, b: &ModelBox) -> f64 {
    let (ModelBox(a), ModelBox(b)) = (a, b);
    let overlap_w = (a.x2.min(b.x2) - a.x1.max(b.x1)).max(0.0);
    let overlap_h = (a.y2.min(b.y2) - a.y1.max(b.y1)).max(0.0);
    let overlap = overlap_w * overlap_h;
    let area = |r: &Bbox| (r.x2 - r.x1).max(0.0) * (r.y2 - r.y1).max(0.0);
    let union = area(a) + area(b) - overlap;
    if union <= 0.0 {
        0.0
    } else {
        overlap / union
    }
}

/// Already-un-projected corners -> the contract's normalized `[x, y, w, h]`.
///
/// Contract: bbox normalized 0..1 against the *original* frame — which is what
/// the projection knows and the input size does not. Taking a [`NormBox`] is
/// what says so in the type: only [`Projection::unproject`] makes one, so
/// there is no way to reach here holding model pixels.
fn det_from(bbox: NormBox, score: f64, label: String) -> Det {
    let normalized = bbox.corners();
    let x0 = normalized.x1.clamp(0.0, 1.0);
    let y0 = normalized.y1.clamp(0.0, 1.0);
    let x1 = normalized.x2.clamp(0.0, 1.0);
    let y1 = normalized.y2.clamp(0.0, 1.0);
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
mod tests {
    use super::super::catalog::{RFDETR, YOLOV10, YOLOV8, YOLOX};
    use super::super::geometry::{InputSize, Projection, ResizePolicy};
    use super::super::labels::{check_label_count, Labels, ScoreFloors};
    use super::super::profile::*;
    use super::*;
    use crate::emit::Det;

    fn labels() -> Labels {
        Labels(vec!["person".into(), "bicycle".into(), "car".into()])
    }

    fn floors(json: &str) -> ScoreFloors {
        ScoreFloors::parse(json).unwrap()
    }

    fn open() -> ScoreFloors {
        floors("{}")
    }

    /// A model-space box from corners a test names literally.
    fn model_box(x1: f64, y1: f64, x2: f64, y2: f64) -> ModelBox {
        ModelBox(Bbox { x1, y1, x2, y2 })
    }

    const SQUARE: InputSize = InputSize::square(640);
    /// What `yolox_nano.onnx` from the Megvii 0.1.1rc0 release declares.
    const YOLOX_416: InputSize = InputSize::square(416);
    /// The 16:9 source the letterbox fix exists for: 1920x1080 into the model.
    const WIDE: InputSize = InputSize { w: 1920, h: 1080 };
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
        let a = model_box(0.0, 0.0, 10.0, 10.0);
        assert_eq!(iou(&a, &a), 1.0);
        assert_eq!(iou(&a, &model_box(20.0, 20.0, 30.0, 30.0)), 0.0);
        // half-overlap: 50 shared of 150 union
        let b = model_box(5.0, 0.0, 15.0, 10.0);
        assert!((iou(&a, &b) - 1.0 / 3.0).abs() < 1e-12);
        assert_eq!(iou(&a, &b), iou(&b, &a));
        // a degenerate box shares no area with anything
        assert_eq!(iou(&a, &model_box(1.0, 1.0, 1.0, 1.0)), 0.0);
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

    // ---- decode plumbing ---------------------------------------------------

    #[test]
    fn only_an_un_projection_can_produce_the_box_det_from_accepts() {
        // `det_from` takes a `NormBox` and `Projection::unproject` is its only
        // constructor, so there is no way to reach the wire format still
        // holding model pixels. What that buys is here in numbers: the same
        // model-space corners under two projections are two different
        // detections, and the type is what stops one being mistaken for the
        // other by omitting the call.
        let corners = model_box(0.0, 0.0, 416.0, 234.0);
        let letterboxed = det_from(
            ResizePolicy::Letterbox { pad: 114 }
                .project(YOLOX_416, WIDE)
                .unproject(corners),
            0.9,
            "car".into(),
        );
        let stretched = det_from(
            Projection::stretch(YOLOX_416).unproject(corners),
            0.9,
            "car".into(),
        );
        // the content rectangle of a 16:9 letterbox *is* the whole frame...
        assert_eq!(letterboxed.bbox, [0.0, 0.0, 1.0, 1.0]);
        // ...while the stretch rule reads those same rows as its top 234/416
        assert_eq!(stretched.bbox, [0.0, 0.0, 1.0, 0.5625]);
    }

    #[test]
    fn det_from_shapes_the_label_on_its_way_to_the_wire() {
        // No golden fixture reaches `shape_label` — every one of them decodes
        // under names that are already clean — and `det_from`'s signature is
        // what Phase 2 rewrites. `--labels` is arbitrary user text and the
        // host refuses a detection whose label it cannot print, so a dropped
        // call here loses real detections with every other gate green.
        let raw = "ca\u{7}r\n";
        let det = det_from(
            Projection::stretch(SQUARE).unproject(model_box(0.0, 0.0, 64.0, 64.0)),
            0.5,
            raw.to_string(),
        );
        assert_eq!(det.label, "car");
        assert_eq!(det.label, crate::emit::shape_label(raw));
    }

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
}
