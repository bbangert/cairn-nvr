//! The four decode heads and the tail every one of them converges on.
//!
//! Uniform free-function signatures per head rather than a trait: the set is
//! closed by design — a new family is a catalog entry — and an enum plus plain
//! functions gives the readability without dynamic dispatch.

use std::num::NonZeroUsize;

use anyhow::{anyhow, bail, Result};

use crate::emit::{Det, ObservationKind};

use super::geometry::{Bbox, InputSize, ModelBox, NormBox, Projection};
use super::labels::{Labels, ScoreFloors};
use super::profile::{grid_anchors, show, Layout, NmsSpec, OutputSpec, Outputs, ScoreComposition};
use super::resolve::validate_layout;
use super::MAX_DETS;

/// One extracted output tensor: the values and the shape they came with.
///
/// The borrow is the backend's — this is what
/// [`Tensors::get`](super::backend::Tensors::get) hands back, borrowed from the
/// run that produced it rather than copied out of it.
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

/// One class's two floors: the score it takes to be emitted at all, and the
/// score it takes to be read as evidence.
///
/// The same number unless `--track-floor-json` lowered `emit` under
/// `min_score`, and the gap between them is the band that flag exists to put
/// on the wire.
#[derive(Clone, Copy)]
pub(super) struct ClassFloor {
    emit: f64,
    min_score: f64,
}

/// Both floors for each of a layout's `nc` classes, resolved once per decode
/// rather than per anchor.
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
fn class_floors(nc: NonZeroUsize, labels: &Labels, floors: &ScoreFloors) -> Vec<ClassFloor> {
    (0..nc.get())
        .map(|class_id| {
            let label = labels.label_for(class_id);
            ClassFloor {
                emit: floors.emit_floor_for(&label),
                min_score: floors.floor_for(&label),
            }
        })
        .collect()
}

/// One proposal in model-space pixels, before NMS and un-projection.
pub(super) struct Candidate {
    score: f64,
    class_id: usize,
    /// Corners in model-input pixels, still to be un-projected.
    corners: ModelBox,
    /// Whether this candidate is at or above its class's `min_score` —
    /// evidence, as against the band `--track-floor-json` opens beneath it.
    ///
    /// Carried from here rather than worked out later because it is the
    /// *first* sort key everywhere candidates and detections are ranked
    /// ([`finish`], [`top_dets`]): the band has to sort behind every
    /// evidence-grade box so that each cut below sheds it first, and the
    /// boundary between the two is per class, which score order alone cannot
    /// express.
    ///
    /// With the flag off it is `true` for every candidate a head with a class
    /// table produces — those gate on the class's own floor, and the emission
    /// gate is then the very same comparison — so the ranking below is score
    /// order exactly as it was. [`end_to_end`] is the exception, cutting on a
    /// common lower bound instead, so a candidate of *its* can be `false` with
    /// the flag off. Those are dropped by the per-label gate in [`finish`]
    /// before anything is ranked, and reaching a ranking at all would take a
    /// profile pairing that layout with NMS. No catalog entry does;
    /// [`candidates_from`] carries a `debug_assert` saying so at runtime, and
    /// because that is compiled out of a release build, the test
    /// `no_profile_pairs_an_end_to_end_layout_with_nms` walks the catalog and
    /// fails when a future profile breaks it.
    evidence: bool,
}

/// Pull every anchor/row the layout offers above its floor into candidates.
///
/// Every layout that knows a candidate's class id at candidate time gates on
/// that class's *own* emission floor here, not on a common lower bound. That is
/// what keeps [`finish`]'s `truncate(max_candidates)` honest: it must only ever
/// see candidates that could survive, or a flood of high-scoring boxes in
/// classes the operator excluded (`default: 1.0` as an allowlist is the
/// documented pattern) crowds out the one class they asked for, silently.
///
/// With `--track-floor-json` set those per-class floors are all the same
/// number — the track floor, which is validated strictly below every one of
/// them — so the classes an allowlist closed are open again in the band
/// `[track_floor, min_score)`, and what they cost is `max_candidates` slots
/// and the wire they take.
///
/// **What they do not cost is a detection.** Every box the flag-off run emits
/// is still emitted with the flag on, at the same score under the same label,
/// which is three separate properties and not one:
///
///   * [`raw_classes`] and [`grid_objectness`] pick their class by an argmax
///     that reads no floor at all, so the winning class of an anchor does not
///     move; the floor only decides whether that winner is kept.
///   * [`detr_queries`] does pick by floor, and so tracks the evidence and
///     band bests apart and prefers evidence — a single pick against the
///     shared emission floor would let a band class take the query and lose
///     the evidence detection outright. See the note there.
///   * [`finish`] and [`top_dets`] then rank evidence ahead of the band, so
///     neither cut, nor either of [`crate::emit::objects_line`]'s, can shed an
///     evidence box while a band one survives.
///
/// The first two are what keep the *candidate* set a superset of the flag-off
/// one; the third is what keeps every cut below spending its room on that
/// superset's evidence half first. See `ScoreFloors::with_track_floor`.
///
/// [`Layout::EndToEnd`] is the exception and cannot join them: its class id is
/// a number in the output row rather than an index into a known `nc`, so there
/// is no floor table to look up. It cuts on the lowest score anything could be
/// emitted at instead — sound because that layout is NMS-free by construction,
/// so nothing truncates its candidates and the real per-label gate in
/// [`finish`] sees them all.
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
        (Layout::EndToEnd, Outputs::One(one)) => {
            // The one place the "NMS-free by construction" reading above stops
            // being a catalog convention and becomes checkable: this head's
            // rows are already final, and its candidates are the only ones
            // whose `evidence` can be `false` under a per-label floor with the
            // track floor *off* (it prefilters on a common lower bound, not on
            // each class's own). Nothing downstream would notice — `finish`'s
            // per-label gate drops them before anything is ranked — unless a
            // profile paired this layout with NMS, which would put them
            // through a sort keyed on that flag. No profile does.
            debug_assert!(
                output.nms.is_none(),
                "an end-to-end head is already final and must not be given NMS"
            );
            Ok(end_to_end(one.values, labels, floors))
        }
        (Layout::RawClasses { nc }, Outputs::One(one)) => {
            let anchors = one.dims[2] as usize;
            require_values(one.values.len(), 4 + nc, anchors, &one.dims)?;
            let nc = classes(output.layout, nc)?;
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
            let nc = classes(output.layout, nc)?;
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
            let nc = classes(output.layout, nc)?;
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

/// A class-reading layout's `nc`, refusing a head that declares none.
///
/// `nc == 0` is the export or the profile being wrong — a dynamic-shape export
/// whose class dimension settled at zero, or an int8 one that collapsed it, loaded
/// past the class-count check by `--allow-label-mismatch`. Nothing can be labelled,
/// so the loops below would discard every anchor and the pass would still
/// *complete*: zero detections for as long as the model runs, which the host's
/// health check reads as a quiet scene. Refused here instead, in the fallible half.
fn classes(layout: Layout, nc: usize) -> Result<NonZeroUsize> {
    NonZeroUsize::new(nc).ok_or_else(|| {
        anyhow!(
            "{layout} declares no classes, so no detection could be labelled and every \
             frame would decode to nothing. Check --model-profile against the model's \
             real output shape; --allow-label-mismatch does not make such an export \
             decodable."
        )
    })
}

/// Does this tensor carry the `rows * row` values the layout is about to index?
///
/// The product is `checked_mul` rather than `*` because both factors come off
/// a *runtime* tensor shape — whatever the backend reported alongside the
/// buffer. onnxruntime's extents are consistent with the buffer it hands back,
/// so on the one backend that executes a wrap is unreachable today; a backend
/// whose SDK reports the two separately has no such guarantee. Either way this
/// is the one place the "trust the dims" pattern is not defended, and a wrapped
/// `need` would pass the length check and let the decode loop walk off the
/// slice.
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
///
/// The one head with no `nc` and so no [`class_floors`] table: it prefilters on
/// [`ScoreFloors::min_emit_floor`], the lowest score anything could be emitted
/// at, and looks the surviving row's own floors up by label. That is one
/// allocation per *surviving row* — a few hundred at this layout's row count,
/// where the table exists to keep a lookup out of an `A x nc` loop of tens of
/// thousands. `finish` pays the same cost again for the same rows, and both are
/// a rounding error against the model pass behind them.
fn end_to_end(rows: &[f32], labels: &Labels, floors: &ScoreFloors) -> Vec<Candidate> {
    let prefilter = floors.min_emit_floor();
    rows.as_chunks::<6>()
        .0
        .iter()
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
            let class_id = row[5].max(0.0).round() as usize;
            Some(Candidate {
                score,
                class_id,
                corners: ModelBox(Bbox {
                    x1: f64::from(row[0]),
                    y1: f64::from(row[1]),
                    x2: f64::from(row[2]),
                    y2: f64::from(row[3]),
                }),
                evidence: score >= floors.floor_for(&labels.label_for(class_id)),
            })
        })
        .collect()
}

/// `[1, 4 + nc, A]` channels-first: channel `c` of anchor `a` is at
/// `c * anchors + a`. Rows 0..4 are `cx, cy, w, h` in input pixels; rows 4..
/// are per-class scores, already sigmoided.
///
/// `floors` is one [`ClassFloor`] per class id, from [`class_floors`]: the
/// argmax names the class, so this head can hold each candidate to its own
/// emission floor rather than to a common lower bound — see
/// [`candidates_from`] — and mark it against its own `min_score`.
fn raw_classes(
    values: &[f32],
    nc: NonZeroUsize,
    anchors: usize,
    size: InputSize,
    score: ScoreComposition,
    floors: &[ClassFloor],
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
        let Some(floor) = floors.get(class_id) else {
            continue;
        };
        if score.is_nan() || score < floor.emit {
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
                evidence: score >= floor.min_score,
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
/// `floors` is one [`ClassFloor`] per class id, from [`class_floors`]: the
/// argmax names the class, so this head can hold each candidate to its own
/// emission floor rather than to a common lower bound — see
/// [`candidates_from`] — and mark it against its own `min_score`.
fn grid_objectness(
    values: &[f32],
    nc: NonZeroUsize,
    strides: &[usize],
    size: InputSize,
    score: ScoreComposition,
    floors: &[ClassFloor],
) -> Vec<Candidate> {
    let row = 5 + nc.get();
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
                let Some(floor) = floors.get(class_id) else {
                    continue;
                };
                if score.is_nan() || score < floor.emit {
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
                        evidence: score >= floor.min_score,
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
/// `min_score`, which is not always the query's argmax — and only if no class
/// clears one, the best that clears its own emission floor.
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
/// **The evidence class wins the query even when a band class outscores it**,
/// which is why the two are tracked apart rather than picked by one `>=`
/// against [`ClassFloor::emit`]. With `--track-floor-json` set that emission
/// floor is the *same number for every class*, so a single best-clearing pick
/// would lose the per-class selectivity this head exists for: the query above
/// would leave as a band `car` at 0.85 and the evidence `truck` at 0.60 —
/// which the flag-off run emits — would be gone with the query's one box. The
/// same shape costs an allowlist the class it admitted. Ranking evidence ahead
/// of the band later cannot repair it, there being no candidate to rank.
///
/// With the flag off, `emit` *is* `min_score` for every class, so nothing can
/// land in the band set and this is the single pick it has always been.
///
/// `floors` is one [`ClassFloor`] per class id, from [`class_floors`]. The
/// per-label gate in [`finish`] re-applies the emission floor after NMS;
/// picking here only decides which label the box leaves under.
fn detr_queries(
    boxes: &[f32],
    logits: &[f32],
    nc: NonZeroUsize,
    queries: usize,
    size: InputSize,
    score: ScoreComposition,
    floors: &[ClassFloor],
) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    for query in 0..queries {
        // The two sets kept apart, and evidence spent first below.
        let mut best_evidence: Option<(usize, f64)> = None;
        let mut best_band: Option<(usize, f64)> = None;
        let mut poisoned = false;
        // `zip` rather than indexing: `floors` carries one entry per class by
        // construction, and pairing them is what says so without a panic path.
        for (class_id, floor) in (0..nc.get()).zip(floors) {
            let logit = f64::from(logits[query * nc.get() + class_id]);
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
            // Strict `>` in both, so a tie inside either set keeps the lowest
            // class id — the order the logits were read in, as before.
            if value >= floor.min_score {
                if best_evidence.is_none_or(|(_, high)| value > high) {
                    best_evidence = Some((class_id, value));
                }
            } else if value >= floor.emit && best_band.is_none_or(|(_, high)| value > high) {
                best_band = Some((class_id, value));
            }
        }
        if poisoned {
            continue;
        }
        // Evidence first whatever it scored: a band class outscoring it is
        // exactly the case a single pick gets wrong (see above). With the flag
        // off `best_band` is always `None` and this is `best_evidence` alone.
        let Some((class_id, score, evidence)) = best_evidence
            .map(|(class_id, value)| (class_id, value, true))
            .or_else(|| best_band.map(|(class_id, value)| (class_id, value, false)))
        else {
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
                evidence,
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
///
/// [`NonZeroUsize`] rather than `usize` so there is no empty range to answer for: a
/// zero class count is refused once, in [`classes`], rather than arriving here as a
/// panic under the shared model lock.
///
/// A fold rather than `max_by` only to be total without an `expect`; `>=` keeps
/// that iterator's rule that a tie takes the *later* class.
fn argmax(n: NonZeroUsize, score: impl Fn(usize) -> f64) -> (usize, f64) {
    (1..n.get()).fold((0, score(0)), |best, c| {
        let value = score(c);
        if value.total_cmp(&best.1).is_ge() {
            (c, value)
        } else {
            best
        }
    })
}

/// Center/extent -> corners, dropping anything non-finite or absurdly large.
///
/// The extent bound is not tidiness. `exp()` in the grid decode stays finite up
/// to `exp(88)`, so a broken or int8-collapsed export can emit a box of `1e38`
/// model pixels that every finite check accepts and [`wire_bbox`]'s clamp then
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

/// Where every layout converges, in this order: candidates the host would
/// refuse are dropped; then, on a head that asks for NMS, an
/// evidence-then-score sort, a `truncate` to `max_candidates`, and [`nms`];
/// then the per-label emission floor, un-projection, and last [`top_dets`]'s
/// own sort by the same key and its [`MAX_DETS`] cap. A head with `nms: None`
/// skips those three middle steps entirely — no sort and no `max_candidates`
/// cut — so [`top_dets`] is the only thing that orders its output.
///
/// **Evidence first, score second, at every cut.** `--track-floor-json` puts
/// boxes below their class's `min_score` on the wire, and the boundary between
/// those and evidence is *per class* — so under per-label floors a band `car`
/// at 0.5 outscores an evidence `person` at 0.45, and ranking by score alone
/// would let the band displace evidence here, at [`top_dets`], and again at
/// [`crate::emit::objects_line`]'s two cuts. Ranking [`Candidate::evidence`]
/// first is what makes the band structurally the tail of every list, so each of
/// those cuts sheds it first with no rule of its own. With the flag off every
/// *detection* this returns is evidence — it has passed the per-label gate
/// below, which is then that same comparison — so both keys collapse to the
/// score sorts they always were.
///
/// Ranking is only the half of it that happens here. A candidate that was
/// never built cannot be ranked, and a head that picks one class per anchor or
/// query decides that before this function sees anything — see
/// [`candidates_from`], which sets out both halves together.
///
/// The `retain` below is where a candidate stops being a detection at all: a
/// box whose clamped extent rounds to zero — see [`wire_bbox`] — is dropped
/// there. Its position ahead of that middle block is what earns both halves of
/// the argument in the body comment: ahead of the `truncate`, so a ghost cannot
/// spend a `max_candidates` slot, and ahead of [`nms`], where a suppression a
/// ghost causes cannot afterwards be undone. [`det_from`] tests the same
/// predicate again on the way out. Nothing that reaches it can fail it, the
/// input and the predicate both being the same; it stays because a conversion
/// that can decline is what its signature promises every caller, not just this
/// one.
pub(super) fn finish(
    mut candidates: Vec<Candidate>,
    spec: Option<NmsSpec>,
    labels: &Labels,
    floors: &ScoreFloors,
    projection: &Projection,
) -> Vec<Det> {
    // Ahead of everything, because [`nms`] works in model space and cannot see
    // that a box lying wholly in the letterbox pad is not a detection: there it
    // has ordinary area, so it can suppress a real box of its own class, and
    // dropping it afterwards at [`det_from`] cannot bring that box back. Also
    // ahead of the cut below, so a ghost cannot spend a `max_candidates` slot.
    //
    // Unconditional, though on a `nms: None` head — yolov10 and rfdetr — it
    // cannot change the output: there is no NMS to protect and no
    // `max_candidates` cut, `retain` preserves relative order, and `det_from`
    // then declines exactly the same candidates. Left that way rather than
    // moved into the `Some` arm below, so that "a candidate the host would
    // refuse never gets past here" holds for every head with no arm to check.
    //
    // The survivors are un-projected a second time in `det_from`. Left that
    // way on purpose: carrying the result through NMS would mean a second box
    // per candidate, and what it saves is a couple of dozen flops against a
    // frame that has just been through a whole model.
    candidates.retain(|candidate| wire_bbox(projection.unproject(candidate.corners)).is_some());
    let kept = match spec {
        Some(spec) => {
            candidates.sort_by(|a, b| {
                b.evidence
                    .cmp(&a.evidence)
                    .then_with(|| b.score.total_cmp(&a.score))
            });
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
            if candidate.score < floors.emit_floor_for(&label) {
                return None;
            }
            let det = det_from(
                projection.unproject(candidate.corners),
                candidate.score,
                candidate.evidence,
                label,
            )?;
            Some((candidate.score, det))
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
/// `candidates` must already be sorted by descending score **within each
/// class**, which is all a class-aware suppression can read: only same-class
/// pairs are ever compared, so the relative order of two classes is not
/// something this function can observe. [`finish`] hands it an
/// evidence-then-score order, and that is the same order per class — a class's
/// band is exactly the part of it below that class's own `min_score`, so every
/// evidence-grade box of a class outscores every band box of it.
///
/// This runs on model-space boxes, where pad pixels count as area like any
/// other, so a box lying wholly in the letterbox pad is indistinguishable here
/// from a real detection. [`finish`] drops those before they reach this
/// function, and it has to: suppression is not recoverable afterwards, so a
/// ghost that got this far would take a real box with it and then be dropped
/// itself.
///
/// Nor does that need a contrived overlap. Take a ghost covering exactly the
/// part of a real box that hangs past the content rectangle: the overlap is the
/// whole of the ghost, so the union is the real box alone and
///
/// ```text
/// IoU = (extent of the real box in the pad) / (extent of the real box)
/// ```
///
/// — the real box's pad fraction, nothing else. `threshold` 0.45 therefore
/// needs only 45% of it in the pad, leaving the majority as content and an
/// ordinary edge-of-frame detection to lose. See
/// `a_pad_only_ghost_is_dropped_before_nms_so_it_cannot_suppress_a_real_box`.
///
/// **Known residual, still unfixed.** That filter closes the *wholly*-pad case
/// and only it. What [`wire_bbox`] declines is a box whose clamped extent
/// rounds to zero, so a ghost holding even one row of content passes and
/// arrives here with its whole model-space extent — pad included — counting
/// towards its area. It is as indistinguishable from a real detection as a
/// pad-only box was, and can still suppress one. Under the projection that test
/// uses (1920x1080 into yolox's 416 input, so content rows 0..234), two
/// same-class candidates spanning x 65..130:
///
/// ```text
/// score 0.9   y 233..500   267 tall, one row of it content
/// score 0.8   y 150..500   350 tall
/// IoU = 267 / 350 = 0.7629                              >= threshold 0.45
///
/// output  [Det { "person", 0.9, [0.1563, 0.9957, 0.1563, 0.0043] }]
/// the 0.8 box alone would have given [0.1563, 0.641, 0.1563, 0.359]
/// ```
///
/// So the 0.8 detection is suppressed and never reported, and what reaches the
/// host in its place is the 0.9 box clamped to that one content row: a sliver
/// 0.43% of the frame's height. This note has been deleted once already, on the
/// reading that the pre-filter above had closed the class. It has not.
///
/// The complete fix is to clamp each [`ModelBox`] to the content rectangle
/// before computing [`iou`]. That keeps the comparison in model space, so it
/// does not disturb the reason NMS is not done on un-projected boxes instead:
/// un-projection divides the two axes by differing source dimensions, which
/// does not preserve IoU and so would change suppression everywhere, pad or no
/// pad. Deliberately not done here — clamping changes the IoU of every pair
/// that overlaps the pad, legitimate edge-of-frame detections included, and
/// that is a behaviour decision rather than a correction.
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

/// Already-un-projected corners -> the contract's normalized `[x, y, w, h]`,
/// or `None` for a box the host would refuse anyway.
///
/// Contract: bbox normalized 0..1 against the *original* frame — which is what
/// the projection knows and the input size does not. Taking a [`NormBox`] is
/// what says so in the type: only [`Projection::unproject`] makes one, so
/// there is no way to reach here holding model pixels.
///
/// **What this declines is "a box the host would refuse", and nothing
/// narrower.** The condition is the arithmetic below and only that: `w` or `h`
/// rounds to 0, which `validate_det` on the host rejects outright since it
/// requires `w > 0 and h > 0`. A box lying wholly in the letterbox pad clamps
/// to a line and so satisfies it — that is the instance worth knowing about,
/// and the reason [`finish`] runs this ahead of [`nms`] — but it is not the
/// only one. A box wholly outside the frame clamps to a line too, pad or no pad:
/// reachable under [`super::geometry::ResizePolicy::Stretch`], where there is no
/// pad to lie in at all. So does an inverted box, per the paragraph below.
/// [`finish`] applies the predicate twice — once directly, before NMS, which is
/// where the drop saves a real box, and once through [`det_from`], so a box that
/// reaches the wire has area by construction.
///
/// The rounded extents are what it reads, not the raw ones: rounding is what
/// the host sees, so a sliver narrower than 0.00005 already reaches it as 0.
/// `.max(0.0)` folds an inverted box (`x2 < x1`, which no head checks for and
/// only a broken export produces) into the same zero, and it is dropped too.
fn wire_bbox(bbox: NormBox) -> Option<[f64; 4]> {
    let normalized = bbox.corners();
    let x0 = normalized.x1.clamp(0.0, 1.0);
    let y0 = normalized.y1.clamp(0.0, 1.0);
    let x1 = normalized.x2.clamp(0.0, 1.0);
    let y1 = normalized.y2.clamp(0.0, 1.0);
    let w = round_to((x1 - x0).max(0.0), 4);
    let h = round_to((y1 - y0).max(0.0), 4);
    if w == 0.0 || h == 0.0 {
        return None;
    }
    Some([round_to(x0, 4), round_to(y0, 4), w, h])
}

/// A scored, labelled detection from an un-projected box, or `None` when
/// [`wire_bbox`] declines the box as one the host would refuse.
///
/// `evidence` is carried through from the candidate rather than re-derived:
/// it is decided where the class's `min_score` is in hand, and it is the first
/// key everything downstream ranks by (see [`finish`]). The box is emitted
/// either way, having already passed the emission floor.
fn det_from(bbox: NormBox, score: f64, evidence: bool, label: String) -> Option<Det> {
    let bbox = wire_bbox(bbox)?;
    Some(Det {
        // `--labels` is arbitrary user text and the host refuses a label it
        // cannot print; shaping it here keeps the detection instead.
        label: crate::emit::shape_label(&label),
        // Same reason as `wire_bbox`'s clamp: the host's `validate_det`
        // requires a 0..1 score and drops the whole detection otherwise, so a
        // corrupt or badly-quantized export emitting 3.7 would lose a real
        // detection rather than report an odd number. Non-finite scores are
        // already rejected upstream, which is what makes `clamp` total here.
        score: round_to(score.clamp(0.0, 1.0), 3),
        bbox,
        // A box the model found in the frame in hand. The other kind is minted
        // in `emit`, from boxes an earlier frame's pass found, and never here.
        observation_kind: ObservationKind::Detected,
        evidence,
        // The embedder attaches features after `detect` returns; nothing in
        // the decode path knows about them.
        embedding: None,
    })
}

/// Evidence-then-score order and the [`MAX_DETS`] cap, where every layout
/// converges.
///
/// The same key [`finish`] ranks candidates by, and for the same reason: what
/// `--track-floor-json` admits has to be the tail of this list, so that this
/// cut — and [`crate::emit::objects_line`]'s two, which inherit this order —
/// spend their room on evidence first whatever shape the per-label floors are.
/// With the flag off every detection is evidence and this is the plain score
/// sort it has always been.
fn top_dets(mut dets: Vec<(f64, Det)>) -> Vec<Det> {
    // yolov10 exports are already score-ordered; sorting keeps the MAX_DETS
    // cut meaningful for exports that are not, and NMS output never is.
    dets.sort_by(|a, b| {
        b.1.evidence
            .cmp(&a.1.evidence)
            .then_with(|| b.0.total_cmp(&a.0))
    });
    dets.truncate(MAX_DETS);
    dets.into_iter().map(|(_, det)| det).collect()
}

fn round_to(value: f64, places: u32) -> f64 {
    let factor = 10f64.powi(places as i32);
    (value * factor).round() / factor
}

#[cfg(test)]
mod tests {
    use super::super::catalog::{PROFILES, RFDETR, YOLOV10, YOLOV8, YOLOX};
    use super::super::geometry::{InputSize, Projection, ResizePolicy};
    use super::super::labels::{check_label_count, Labels, ScoreFloors};
    use super::super::profile::*;
    use super::*;
    use crate::emit::{Det, ObservationKind};

    fn labels() -> Labels {
        Labels(vec!["person".into(), "bicycle".into(), "car".into()])
    }

    fn floors(json: &str) -> ScoreFloors {
        ScoreFloors::parse(json).unwrap()
    }

    fn open() -> ScoreFloors {
        floors("{}")
    }

    /// What the `det_from` tests below hand in for `evidence`. They are about
    /// geometry and labels, not about the flag, and a box above its floor is
    /// the ordinary case — spelled once so a reader is not left wondering
    /// which of the two those tests are exercising.
    const EVIDENCE: bool = true;

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
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
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
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
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
        // Every finite check accepts it and `wire_bbox`'s clamp turns it into
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
        // Every other box here is square, which makes `w * h` and `w * w`
        // indistinguishable — so a copy-pasted area factor that never had its
        // axis letters changed passes all of the above. One wide box and one
        // tall one is what separates them: 40x10 and 10x50 overlap in a 10x10
        // corner, for 100 of 800.
        let wide = model_box(0.0, 0.0, 40.0, 10.0);
        let tall = model_box(20.0, 0.0, 30.0, 50.0);
        assert_eq!(iou(&wide, &tall), 0.125);
        assert_eq!(iou(&wide, &tall), iou(&tall, &wide));
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
        assert_eq!(floors.min_emit_floor(), 0.02);
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

    /// `{"default":0.5}` with a track floor at 0.2 — the band the flag opens
    /// is `[0.2, 0.5)`.
    fn banded() -> ScoreFloors {
        floors(r#"{"default":0.5}"#)
            .with_track_floor(Some(0.2))
            .expect("0.2 is strictly below the 0.5 default")
    }

    #[test]
    fn a_track_floor_emits_the_band_below_min_score_at_its_real_score() {
        // Three anchors, well apart so NMS has nothing to say about them: one
        // over the evidence floor, one inside the band, one under the track
        // floor.
        let anchors = [
            (100.0, 100.0, 40.0, 40.0, 0usize, 0.9),
            (300.0, 300.0, 40.0, 40.0, 0usize, 0.3),
            (500.0, 500.0, 40.0, 40.0, 0usize, 0.05),
        ];
        // Without the flag the band is not on the wire at all — the identity
        // every run Cairn launches today depends on.
        let plain = v8(3, &anchors, &floors(r#"{"default":0.5}"#), SQUARE);
        assert_eq!(plain.len(), 1);
        assert_eq!(plain[0].score, 0.9);
        assert!(plain[0].evidence);

        // With it, the band arrives at the score the model gave it, not at
        // some marked-down or floored one, and the sub-floor box is still a
        // `detected` observation — it is a box this frame's model pass found.
        let banded = v8(3, &anchors, &banded(), SQUARE);
        assert_eq!(banded.len(), 2);
        assert_eq!(banded[0].score, 0.9);
        assert!(banded[0].evidence);
        assert_eq!(banded[1].score, 0.3);
        assert!(!banded[1].evidence);
        assert_eq!(banded[1].observation_kind, ObservationKind::Detected);
        // the 0.3 anchor and not the 0.05 one: 280..320 of 640 on both axes.
        // 0.05 is under the track floor, which the flag does not reach past.
        assert_eq!(banded[1].bbox, [0.4375, 0.4375, 0.0625, 0.0625]);
    }

    #[test]
    fn nms_weighs_a_sub_floor_box_against_the_whole_frame_as_it_always_did() {
        // One pass over the combined set, not a second pass over the band: a
        // sub-floor box is suppressed by a stronger box of its own class the
        // way any weaker box is, and survives a stronger box of another class
        // the way any box of another class does.
        let stacked = [
            (100.0, 100.0, 40.0, 40.0, 0usize, 0.9),
            (100.0, 100.0, 40.0, 40.0, 0usize, 0.3),
        ];
        let dets = v8(3, &stacked, &banded(), SQUARE);
        assert_eq!(dets.len(), 1, "{dets:?}");
        assert_eq!(dets[0].score, 0.9);

        let mixed = [
            (100.0, 100.0, 40.0, 40.0, 0usize, 0.9),
            (100.0, 100.0, 40.0, 40.0, 2usize, 0.3),
        ];
        let dets = v8(3, &mixed, &banded(), SQUARE);
        assert_eq!(dets.len(), 2, "{dets:?}");
        assert_eq!(dets[1].label, "car");
        assert!(!dets[1].evidence);
    }

    #[test]
    fn the_band_only_spends_cap_slots_the_evidence_left() {
        // `top_dets` cuts at MAX_DETS on evidence first and score second, so
        // the band can only ever spend slots the evidence-grade boxes left.
        // Fill the cap with evidence and add a band that would overflow it
        // twice over. (The per-label case, where the band *outscores* the
        // evidence, is the test below — this one would pass on score order
        // alone.)
        let mut anchors: Vec<_> = (0..MAX_DETS)
            .map(|i| (20.0 * i as f32 + 10.0, 20.0, 8.0, 8.0, 0usize, 0.6))
            .collect();
        anchors
            .extend((0..MAX_DETS).map(|i| (20.0 * i as f32 + 10.0, 300.0, 8.0, 8.0, 0usize, 0.4)));
        let dets = v8(3, &anchors, &banded(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.iter().all(|det| det.evidence && det.score == 0.6));

        // Take four of the evidence boxes away and the band fills exactly
        // those four slots, strongest first — nothing else changes.
        anchors.truncate(MAX_DETS - 4);
        anchors
            .extend((0..MAX_DETS).map(|i| (20.0 * i as f32 + 10.0, 300.0, 8.0, 8.0, 0usize, 0.4)));
        let dets = v8(3, &anchors, &banded(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert_eq!(dets.iter().filter(|det| det.evidence).count(), MAX_DETS - 4);
        assert!(dets[MAX_DETS - 4..]
            .iter()
            .all(|det| !det.evidence && det.score == 0.4));
    }

    #[test]
    fn a_band_box_outscoring_an_evidence_box_still_sheds_first() {
        // The case score order alone gets wrong, and the one Cairn's own
        // per-label floors make reachable: `person` at 0.4 and `car` at 0.8,
        // so an evidence person at 0.45 sits *below* a band car at 0.5. Rank
        // by score and every cut keeps the car and drops the person.
        let floors = floors(r#"{"default":0.5,"person":0.4,"car":0.8}"#)
            .with_track_floor(Some(0.2))
            .unwrap();
        // A full cap of evidence people just over their floor, then a band of
        // cars that each outscore all of them.
        let mut anchors: Vec<_> = (0..MAX_DETS)
            .map(|i| (20.0 * i as f32 + 10.0, 20.0, 8.0, 8.0, 0usize, 0.45))
            .collect();
        anchors
            .extend((0..MAX_DETS).map(|i| (20.0 * i as f32 + 10.0, 300.0, 8.0, 8.0, 2usize, 0.5)));

        let dets = v8(3, &anchors, &floors, SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(
            dets.iter().all(|det| det.label == "person" && det.evidence),
            "the higher-scoring band was the thing that went: {:?}",
            dets.iter()
                .map(|det| (det.label.as_str(), det.score))
                .collect::<Vec<_>>()
        );
        // The order handed to `emit`, which is where the same property is
        // pinned for the line writer's own two cuts: under the cap, the band
        // is still the tail even though it outscores the head.
        let mut few: Vec<_> = (0..4)
            .map(|i| (20.0 * i as f32 + 10.0, 20.0, 8.0, 8.0, 0usize, 0.45))
            .collect();
        few.extend((0..4).map(|i| (20.0 * i as f32 + 10.0, 300.0, 8.0, 8.0, 2usize, 0.5)));
        assert_eq!(
            v8(3, &few, &floors, SQUARE)
                .iter()
                .map(|det| (det.label.clone(), det.evidence))
                .collect::<Vec<_>>(),
            [
                ("person".to_string(), true),
                ("person".to_string(), true),
                ("person".to_string(), true),
                ("person".to_string(), true),
                ("car".to_string(), false),
                ("car".to_string(), false),
                ("car".to_string(), false),
                ("car".to_string(), false),
            ],
            "evidence first, and the band behind it at a higher score"
        );
    }

    #[test]
    fn the_evidence_mark_is_the_emission_gates_own_comparison() {
        // `score >= min_score` on the score the model gave, which is the
        // comparison the emission gate makes and every other floor in this
        // crate makes. That identity is what makes "with the flag off every
        // emitted detection is evidence" structural rather than a thing to
        // re-check: the gate has already applied the same `>=` to the same
        // number, `emit` being `min_score` there.
        //
        // `det_from` then rounds to three places, so a candidate inside
        // 0.0005 of its floor is marked against the pre-rounding number while
        // the host reads the rounded one — 0.4996 leaves here as 0.5, which
        // the host calls evidence and this calls band. The window is a
        // thousandth wide and the disagreement is one-sided: the plugin
        // declines to seed a box the host would have accepted, never the
        // reverse. It is also not new — the plugin already drops a 0.4996
        // candidate under a 0.5 floor outright, for the same reason.
        let floors = floors(r#"{"default":0.5}"#)
            .with_track_floor(Some(0.2))
            .unwrap();
        let dets = v8(
            3,
            &[
                (100.0, 100.0, 40.0, 40.0, 0, 0.5),
                (300.0, 300.0, 40.0, 40.0, 0, 0.4996),
            ],
            &floors,
            SQUARE,
        );
        assert_eq!(dets.len(), 2);
        assert_eq!(dets[0].score, 0.5);
        assert!(dets[0].evidence, "exactly at the floor is evidence");
        assert_eq!(dets[1].score, 0.5, "and the wire rounds this one to it");
        assert!(!dets[1].evidence, "but it was under the floor when marked");
    }

    #[test]
    fn an_end_to_end_head_reads_the_track_floor_as_its_prefilter() {
        // The one layout with no class table: it cuts on the lowest score
        // anything could be emitted at, which with a track floor set is the
        // track floor itself. Anything else would drop the band before the
        // per-label gate in `finish` ever saw it.
        let floors = floors(r#"{"default":0.5,"car":0.6}"#)
            .with_track_floor(Some(0.2))
            .unwrap();
        assert_eq!(floors.min_emit_floor(), 0.2);
        let mut rows = row(64.0, 64.0, 128.0, 128.0, 0.9, 0.0).to_vec();
        rows.extend_from_slice(&row(256.0, 256.0, 320.0, 320.0, 0.3, 0.0));
        rows.extend_from_slice(&row(448.0, 448.0, 512.0, 512.0, 0.1, 0.0));
        let dets = e2e(&rows, &floors, SQUARE);
        assert_eq!(dets.len(), 2);
        assert_eq!(dets[0].score, 0.9);
        assert!(dets[0].evidence);
        assert_eq!(dets[1].score, 0.3);
        assert!(!dets[1].evidence);
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
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
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
    fn a_score_tie_at_a_truncation_boundary_keeps_whichever_the_head_emitted_first() {
        // Two truncations decide what gets reported, and each is fed by a
        // stable `sort_by`: `finish`'s cut at `max_candidates` ahead of NMS, and
        // `top_dets`'s cut at `MAX_DETS`. Stability is the whole of the tie
        // rule — equal scores keep the order the head emitted them in, so the
        // survivors of a cut that lands inside a tied group are its
        // earliest-emitted members. `sort_unstable_by` orders a tie by nothing
        // at all, and it is the swap someone reaches for on the grounds that it
        // is typically faster and allocates nothing, so this test is what stands
        // between that and a different set of detections.
        //
        // Both halves below thread the tied group *through* the stronger one on
        // purpose: Rust's `sort_unstable_by` detects an input already in order
        // and returns it unchanged, an all-equal input included, so a tie group
        // appended after the strong group is a shape the swap never disturbs.
        //
        // Both keys are `(evidence, score)` since `--track-floor-json`; these
        // floors set no track floor, so every candidate here is evidence and
        // the key is the score alone. A tie in score is a tie in the key.

        // --- `finish`: the cut at `max_candidates`, before NMS ---------------
        //
        // Twenty persons tied at 0.65, one planted every fifteenth anchor among
        // `max_candidates - 10` cars at 0.99 (290 of them today). In descending
        // score order every car comes first, so `truncate(max_candidates)`
        // admits exactly the first ten persons and discards the other ten — a
        // cut straight through the tie. The cars are one repeated box, so NMS
        // collapses them to a single detection and the ten persons that survived
        // the cut are the rest of the output, which is what makes *which* ten of
        // the twenty visible.
        let mut anchors = Vec::new();
        let mut tied = 0;
        for i in 0..(DEFAULT_NMS.max_candidates - 10) {
            if i % 15 == 0 && tied < 20 {
                // 32x32 persons on a 64-pixel pitch, ten to a row: distinct
                // boxes, and disjoint, so NMS keeps every one that gets in.
                let cx = 32.0 + 64.0 * (tied % 10) as f32;
                let cy = 32.0 + 64.0 * (tied / 10) as f32;
                anchors.push((cx, cy, 32.0, 32.0, 0usize, 0.65));
                tied += 1;
            }
            anchors.push((320.0, 320.0, 64.0, 64.0, 2usize, 0.99));
        }
        assert_eq!(tied, 20, "the cut has to land inside the tie");
        assert_eq!(anchors.len(), DEFAULT_NMS.max_candidates + 10);
        // The persons are centers and extents in model pixels and the stretch
        // divides by 640: person `k` has corner 16 + 64k, hence 0.025 on a 0.1
        // pitch, and extent 32/640 = 0.05. The second row of ten sits at 0.125
        // down the frame and is the half the truncation drops, so no bbox below
        // carries that `y`. The car is 288..352 on both axes.
        assert_eq!(
            v8(3, &anchors, &open(), SQUARE),
            vec![
                det("car", 0.99, [0.45, 0.45, 0.1, 0.1]),
                det("person", 0.65, [0.025, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.125, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.225, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.325, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.425, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.525, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.625, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.725, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.825, 0.025, 0.05, 0.05]),
                det("person", 0.65, [0.925, 0.025, 0.05, 0.05]),
            ]
        );

        // --- `top_dets`: the cut at `MAX_DETS` -------------------------------
        //
        // The raw head above cannot reach this one: `finish` hands `top_dets` a
        // list its own sort already put in descending order, which an unstable
        // sort would leave alone. `Layout::EndToEnd` is the head that runs no
        // NMS and therefore no sort of its own, so `top_dets` receives the rows
        // in tensor order and its sort is the only one there is.
        //
        // 31 identical cars at 0.9 — one short of the cap, and this head keeps
        // overlaps — with 20 persons tied at 0.65 threaded through them. One
        // slot is left for the tie, and the first-emitted person is the one
        // entitled to it.
        let mut rows = Vec::new();
        let mut tied = 0;
        for _ in 0..(MAX_DETS - 1) {
            if tied < 20 {
                let x1 = 16.0 + 64.0 * (tied % 10) as f32;
                let y1 = 16.0 + 64.0 * (tied / 10) as f32;
                rows.extend_from_slice(&row(x1, y1, x1 + 32.0, y1 + 32.0, 0.65, 0.0));
                tied += 1;
            }
            rows.extend_from_slice(&row(288.0, 288.0, 352.0, 352.0, 0.9, 2.0));
        }
        assert_eq!(tied, 20, "the cut has to land inside the tie");
        let dets = e2e(&rows, &open(), SQUARE);
        assert_eq!(dets.len(), MAX_DETS);
        // These rows are corners already, so the same 640 divide applies: the
        // first person is 16..48 and the cars are 288..352.
        assert!(
            dets[..MAX_DETS - 1]
                .iter()
                .all(|d| *d == det("car", 0.9, [0.45, 0.45, 0.1, 0.1])),
            "{dets:?}"
        );
        assert_eq!(
            dets[MAX_DETS - 1],
            det("person", 0.65, [0.025, 0.025, 0.05, 0.05])
        );
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
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
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
                observation_kind: ObservationKind::Detected,
                evidence: true,
                embedding: None,
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
    fn detr_picks_the_evidence_class_over_a_higher_scoring_band_one() {
        // A track floor makes the emission floor *one number for every class*,
        // so a query picked by a single "best that clears its floor" loses the
        // per-class selectivity the test above exists for: the band class wins
        // the query and the evidence detection is never built at all. Nothing
        // downstream can rank a candidate that does not exist.
        let names = Labels(vec!["person".into(), "car".into(), "truck".into()]);
        let logit = |p: f64| (p / (1.0 - p)).ln() as f32;
        let decode = |out: &DetrOutput, floors: &ScoreFloors| {
            decode_output(
                out.spec(),
                &raw_detr(&out.boxes, &out.logits, out.queries as i64, 3),
                &names,
                floors,
                SQUARE,
                &Projection::stretch(SQUARE),
            )
            .unwrap()
        };

        // The same query as above — car 0.85 / truck 0.60, floors car 0.9 and
        // truck 0.4 — now with a track floor under both. The band car
        // outscores the evidence truck by 0.25 and must still lose.
        let mut out = DetrOutput::new(1, 3);
        out.put(0, [0.5, 0.5, 0.2, 0.2], 1, logit(0.85)).put(
            0,
            [0.5, 0.5, 0.2, 0.2],
            2,
            logit(0.60),
        );
        let asymmetric = floors(r#"{"default":1.0,"person":0.6,"car":0.9,"truck":0.4}"#);
        let banded = floors(r#"{"default":1.0,"person":0.6,"car":0.9,"truck":0.4}"#)
            .with_track_floor(Some(0.2))
            .unwrap();
        let dets = decode(&out, &banded);
        assert_eq!(dets.len(), 1, "one box per query, either way: {dets:?}");
        assert_eq!(dets[0].label, "truck");
        assert_eq!(dets[0].score, 0.6);
        assert!(dets[0].evidence);
        // …which is exactly what the flag-off run emits.
        assert_eq!(decode(&out, &asymmetric), dets);

        // The allowlist shape: `default: 1.0` excludes car, `person: 0.6`
        // admits person. A track floor reopens car in the band, and the class
        // the operator asked for must still be the one that leaves.
        let mut out = DetrOutput::new(1, 3);
        out.put(0, [0.5, 0.5, 0.2, 0.2], 0, logit(0.65)).put(
            0,
            [0.5, 0.5, 0.2, 0.2],
            1,
            logit(0.9),
        );
        let allowlist = floors(r#"{"default":1.0,"person":0.6}"#)
            .with_track_floor(Some(0.3))
            .unwrap();
        let dets = decode(&out, &allowlist);
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "person", "the admitted class survives");
        assert!(dets[0].evidence);

        // And the flag still does its job where there is no evidence to
        // prefer: a query whose only class over the track floor is band.
        let mut out = DetrOutput::new(1, 3);
        out.put(0, [0.5, 0.5, 0.2, 0.2], 1, logit(0.3));
        let dets = decode(
            &out,
            &floors(r#"{"default":0.5}"#)
                .with_track_floor(Some(0.2))
                .unwrap(),
        );
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        assert_eq!(dets[0].score, 0.3);
        assert!(!dets[0].evidence);
    }

    #[test]
    fn no_profile_pairs_an_end_to_end_layout_with_nms() {
        // The convention [`candidates_from`]'s end-to-end arm leans on, held
        // as a gate rather than as a reading of the catalog. Those rows are
        // already final, and — the reason it is worth a test of its own —
        // that head is the one whose candidates can carry `evidence: false`
        // with the track floor *off*, having prefiltered on a common lower
        // bound rather than on each class's own floor. `finish`'s per-label
        // gate drops those before anything is ranked; giving the layout NMS
        // would send them through a sort keyed on that flag first. The
        // `debug_assert` there says so at runtime and is compiled out of a
        // release build, so this is what actually holds a future profile to
        // it.
        let mut checked = 0;
        for profile in PROFILES {
            if matches!(profile.output.layout, Layout::EndToEnd) {
                checked += 1;
                assert!(
                    profile.output.nms.is_none(),
                    "profile {} pairs an end-to-end layout with NMS",
                    profile.name
                );
            }
        }
        // A loop over a set none of whose members it applies to asserts
        // nothing while still passing, so what the catalog holds is pinned
        // too: retiring yolov10 without another end-to-end entry has to be a
        // failure here rather than a test that quietly stops checking.
        assert_eq!(checked, 1, "yolov10 is the end-to-end profile");
        assert!(matches!(YOLOV10.output.layout, Layout::EndToEnd));
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
    fn det_from_reports_the_projection_it_was_given_not_the_model_rectangle() {
        // Named for what it can actually observe. An earlier name claimed this
        // test guarded "only an un-projection can produce the box `det_from`
        // accepts" — it cannot: that is a type-system property, and if it broke
        // the crate would still compile and this test would still pass. The
        // privacy of `NormBox`'s field is what guards it (see the note there).
        //
        // What *is* checkable is the consequence, at the seam rather than
        // end-to-end: one model-space box, two projections, two different
        // detections. Deleting `unproject` cannot be tested here, but reading
        // it from the wrong projection can.
        let corners = model_box(0.0, 0.0, 416.0, 234.0);
        let letterboxed = det_from(
            ResizePolicy::Letterbox { pad: 114 }
                .project(YOLOX_416, WIDE)
                .unproject(corners),
            0.9,
            EVIDENCE,
            "car".into(),
        );
        let stretched = det_from(
            Projection::stretch(YOLOX_416).unproject(corners),
            0.9,
            EVIDENCE,
            "car".into(),
        );
        // Both have area, so neither is dropped as a pad-only ghost.
        let letterboxed = letterboxed.expect("a full-content box has area");
        let stretched = stretched.expect("a full-content box has area");
        // the content rectangle of a 16:9 letterbox *is* the whole frame...
        assert_eq!(letterboxed.bbox, [0.0, 0.0, 1.0, 1.0]);
        // ...while the stretch rule reads those same rows as its top 234/416
        assert_eq!(stretched.bbox, [0.0, 0.0, 1.0, 0.5625]);
    }

    #[test]
    fn det_from_shapes_the_label_on_its_way_to_the_wire() {
        // Nothing else in this module reaches `shape_label`: every other test
        // decodes under names that are already clean, so the call is invisible
        // to all of them including the composed-tail ones. `--labels` is
        // arbitrary user text and the host refuses a detection whose label it
        // cannot print, so a dropped call here loses real detections with
        // every other gate green.
        let raw = "ca\u{7}r\n";
        let det = det_from(
            Projection::stretch(SQUARE).unproject(model_box(0.0, 0.0, 64.0, 64.0)),
            0.5,
            EVIDENCE,
            raw.to_string(),
        )
        .expect("a 64x64 box has area");
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

    // ---- the composed tail, one head at a time ------------------------------
    //
    // Every test above states one rule about one step. These eight — four heads
    // under two projections — pin the whole `Vec<Det>` a planted tensor decodes
    // to, which is the one thing a per-feature test structurally cannot do:
    // what `finish` -> `nms` -> `det_from` -> `top_dets` -> `Projection` do
    // *together*. A suppression that silently reorders, a rounding that loses a
    // digit or a projection applied one call late satisfies every rule stated
    // above and reaches the wire as a wrong box.
    //
    // The tensors and the expected detections were recorded and hand-verified
    // against the arithmetic during the characterization phase, then
    // independently reproduced in a separate model. They are moved here, not
    // re-derived; the fixture files and their bless-and-diff harness are what
    // was retired, because a blob states no intent and invites re-recording
    // where a named test invites investigation.
    //
    // These deliberately share `labels()` and `floors()` with the rest of the
    // module. The characterization suite deliberately did not — a golden built
    // from the constructors it guards moves with them and proves nothing — but
    // that reasoning was about catching a *move*, and nothing is moving now.

    /// A non-uniform floor table, which is the configuration that makes the
    /// per-class gates observable: `car` is held to 0.8 while everything else
    /// clears at 0.3.
    fn mixed_floors() -> ScoreFloors {
        floors(r#"{"default": 0.3, "car": 0.8}"#)
    }

    /// The second projection every head below is read under: a 16:9 camera
    /// into a square input, whose vertical scale is *not* the input size.
    /// A decode that skips the un-projection reports every box short and
    /// shifted, and each letterboxed test says so in its own numbers.
    fn letterboxed(input: InputSize) -> Projection {
        ResizePolicy::Letterbox { pad: 114 }.project(input, WIDE)
    }

    /// Decode one planted tensor under a projection the test names.
    fn decode_under(
        output: OutputSpec,
        raw: &Outputs<Raw>,
        size: InputSize,
        projection: &Projection,
    ) -> Vec<Det> {
        decode_output(output, raw, &labels(), &mixed_floors(), size, projection)
            .expect("the planted tensors are well-formed for their layout")
    }

    fn det(label: &str, score: f64, bbox: [f64; 4]) -> Det {
        Det {
            label: label.into(),
            score,
            bbox,
            observation_kind: ObservationKind::Detected,
            evidence: true,
            embedding: None,
        }
    }

    /// Three classes, so an argmax has something to choose between and a class
    /// id past the end exercises the numeric fallback.
    const NC: usize = 3;

    const END_TO_END: OutputSpec = OutputSpec {
        layout: Layout::EndToEnd,
        score: ScoreComposition::Class,
        nms: None,
    };
    const RAW_CLASSES: OutputSpec = OutputSpec {
        layout: Layout::RawClasses { nc: NC },
        score: ScoreComposition::Class,
        nms: Some(DEFAULT_NMS),
    };
    const GRID_OBJECTNESS: OutputSpec = OutputSpec {
        layout: Layout::GridObjectness {
            nc: NC,
            strides: STRIDES,
        },
        score: ScoreComposition::ObjTimesClass,
        nms: Some(DEFAULT_NMS),
    };
    const DETR_QUERIES: OutputSpec = OutputSpec {
        layout: Layout::DetrQueries { nc: NC },
        score: ScoreComposition::SigmoidClass,
        nms: None,
    };

    // ---- head 1: end-to-end `[1, N, 6]` -------------------------------------

    /// Rows of `[x1, y1, x2, y2, score, class_id]` in model pixels.
    ///
    /// This head is NMS-free by construction, so rows 0 and 1 overlapping
    /// heavily is the *interesting* case rather than the suppressed one: both
    /// have to survive, because the model already de-duplicated and a second
    /// pass would merge two objects the export deliberately kept apart.
    fn end_to_end_rows() -> Vec<f32> {
        #[rustfmt::skip]
        let rows = vec![
            // strong person
             32.0,  32.0, 160.0, 160.0, 0.90, 0.0,
            // a second person over the top of it — kept, no NMS on this head
             40.0,  40.0, 168.0, 168.0, 0.85, 0.0,
            // bicycle, over the 0.3 default
            200.0, 200.0, 300.0, 300.0, 0.55, 1.0,
            // car at 0.75, under its own 0.8 floor — dropped in `finish`
            320.0, 320.0, 420.0, 420.0, 0.75, 2.0,
            // under the default floor, dropped by the prefilter
             10.0,  10.0,  20.0,  20.0, 0.20, 0.0,
            // class 7 has no label: renders as the bare id. Under the letterbox
            // this box also lands entirely in the pad.
            500.0, 500.0, 600.0, 600.0, 0.65, 7.0,
        ];
        rows
    }

    fn end_to_end_output(rows: &[f32]) -> Outputs<Raw<'_>> {
        raw_one(rows, &[1, (rows.len() / 6) as i64, 6])
    }

    #[test]
    fn a_stretched_end_to_end_head_keeps_both_overlaps_and_drops_only_what_the_floors_refuse() {
        let rows = end_to_end_rows();
        let dets = decode_under(
            END_TO_END,
            &end_to_end_output(&rows),
            SQUARE,
            &Projection::stretch(SQUARE),
        );
        // The rows are already corners in model pixels and the stretch divides
        // by the input size on both axes, so every number below is that row
        // over 640: the first box is 32..160, hence 32/640 = 0.05 with a width
        // of 128/640 = 0.2.
        assert_eq!(
            dets,
            vec![
                // both overlapping persons survive: this head runs no NMS
                det("person", 0.9, [0.05, 0.05, 0.2, 0.2]),
                det("person", 0.85, [0.0625, 0.0625, 0.2, 0.2]),
                // class 7 has no name, so the id itself is the label
                det("7", 0.65, [0.7813, 0.7813, 0.1563, 0.1563]),
                det("bicycle", 0.55, [0.3125, 0.3125, 0.1563, 0.1563]),
            ]
        );
        // ...and the two rows that are gone: a 0.75 car under car's own 0.8,
        // and a 0.20 person under the 0.3 the prefilter cuts at.
    }

    #[test]
    fn a_letterboxed_end_to_end_head_reports_its_rows_against_the_original_frame() {
        let rows = end_to_end_rows();
        let dets = decode_under(
            END_TO_END,
            &end_to_end_output(&rows),
            SQUARE,
            &letterboxed(SQUARE),
        );
        // The content occupies the top 360 of 640 rows, so every `y` is read
        // against 360 rather than 640 and comes out 1.78x further down the
        // frame than the stretch reading above. `x` is untouched.
        assert_eq!(
            dets,
            vec![
                det("person", 0.9, [0.05, 0.0889, 0.2, 0.3556]),
                det("person", 0.85, [0.0625, 0.1111, 0.2, 0.3556]),
                det("bicycle", 0.55, [0.3125, 0.5556, 0.1563, 0.2778]),
            ]
        );
        // The class-7 row is missing rather than reordered: 500..600 is below
        // the content entirely, so it lies in the pad and is dropped — see
        // `a_box_lying_wholly_in_the_letterbox_pad_is_dropped_not_emitted_flat`.
    }

    // ---- head 2: raw classes `[1, 4 + nc, A]` -------------------------------

    /// One planted anchor of a channels-first head: box in model pixels, one
    /// score per class.
    struct RawAnchor {
        cx: f32,
        cy: f32,
        w: f32,
        h: f32,
        classes: [f32; NC],
    }

    /// Anchors long enough to satisfy the channels-first orientation rule
    /// (`A > (4 + nc) * 4`), short enough to write out.
    const RAW_ANCHORS: usize = 32;

    fn raw_classes_tensor() -> Vec<f32> {
        // A data table: one planted row per line, which is how it is read.
        #[rustfmt::skip]
        let planted = [
            // strong person
            RawAnchor { cx: 100.0, cy: 100.0, w: 60.0, h: 60.0, classes: [0.90, 0.0, 0.0] },
            // 0.68 IoU with the one above, same class — NMS suppresses it
            RawAnchor { cx: 108.0, cy: 104.0, w: 60.0, h: 60.0, classes: [0.70, 0.0, 0.0] },
            // car at 0.75, under its own 0.8 floor — never becomes a candidate
            RawAnchor { cx: 200.0, cy: 200.0, w: 40.0, h: 40.0, classes: [0.0, 0.0, 0.75] },
            // bicycle, elsewhere in the frame. 380..420 in model pixels, so
            // under the letterbox — 360 rows of content — it lands entirely in
            // the pad and is dropped rather than clipped.
            RawAnchor { cx: 400.0, cy: 400.0, w: 80.0, h: 40.0, classes: [0.0, 0.60, 0.0] },
            // under the default floor
            RawAnchor { cx: 300.0, cy: 100.0, w: 20.0, h: 20.0, classes: [0.25, 0.0, 0.0] },
            // a second person far enough away that NMS keeps it
            RawAnchor { cx: 100.0, cy: 300.0, w: 60.0, h: 60.0, classes: [0.55, 0.0, 0.0] },
        ];
        // The rest stay zero, and stay dropped — by `car`'s 0.8 rather than by
        // the 0.3 default, which is the intuitive reading and the wrong one.
        // See `an_anchor_with_nothing_to_choose_between_argmaxes_to_the_last_class`.
        let mut values = vec![0.0f32; (4 + NC) * RAW_ANCHORS];
        for (a, anchor) in planted.iter().enumerate() {
            let at = |channel: usize| channel * RAW_ANCHORS + a;
            values[at(0)] = anchor.cx;
            values[at(1)] = anchor.cy;
            values[at(2)] = anchor.w;
            values[at(3)] = anchor.h;
            for (c, score) in anchor.classes.iter().enumerate() {
                values[at(4 + c)] = *score;
            }
        }
        values
    }

    fn raw_classes_output(values: &[f32]) -> Outputs<Raw<'_>> {
        raw_one(values, &[1, (4 + NC) as i64, RAW_ANCHORS as i64])
    }

    #[test]
    fn a_stretched_raw_classes_head_suppresses_its_overlap_and_holds_each_class_to_its_own_floor() {
        let values = raw_classes_tensor();
        let dets = decode_under(
            RAW_CLASSES,
            &raw_classes_output(&values),
            SQUARE,
            &Projection::stretch(SQUARE),
        );
        // These rows are centers and extents, so a corner is the center less
        // half the extent in model pixels, and the stretch then divides by 640.
        // The first person is centered at (100, 100) with extent 60x60: corner
        // 70/640 = 0.1094, extent 60/640 = 0.0938. The bicycle is centered at
        // (400, 400) with extent 80x40: 360/640 = 0.5625, 380/640 = 0.5938.
        assert_eq!(
            dets,
            vec![
                // the 0.70 person at IoU 0.68 with this one is suppressed
                det("person", 0.9, [0.1094, 0.1094, 0.0938, 0.0938]),
                det("bicycle", 0.6, [0.5625, 0.5938, 0.125, 0.0625]),
                // far enough from the first person that NMS keeps it
                det("person", 0.55, [0.1094, 0.4219, 0.0938, 0.0938]),
            ]
        );
    }

    #[test]
    fn a_letterboxed_raw_classes_head_drops_the_box_that_lands_wholly_in_the_pad() {
        let values = raw_classes_tensor();
        let dets = decode_under(
            RAW_CLASSES,
            &raw_classes_output(&values),
            SQUARE,
            &letterboxed(SQUARE),
        );
        // The bicycle at cy 400 is 380..420 in model pixels, entirely below the
        // 360-row content area, so it un-projects past the bottom of the frame
        // and clamps to a line with no area at all. It is dropped rather than
        // emitted flat — the host refuses `w == 0 || h == 0` outright, and an
        // emitted ghost would burn a `MAX_DETS` slot ahead of the truncate.
        assert_eq!(
            dets,
            vec![
                det("person", 0.9, [0.1094, 0.1944, 0.0938, 0.1667]),
                det("person", 0.55, [0.1094, 0.75, 0.0938, 0.1667]),
            ]
        );
    }

    // ---- head 3: grid objectness `[1, A, 5 + nc]` ---------------------------

    /// One planted cell of a grid head.
    struct GridCell {
        stride: usize,
        gx: usize,
        gy: usize,
        /// Offsets inside the cell, in cell units — what the head actually
        /// emits.
        off: (f32, f32),
        /// Box extent in model pixels; stored as the log extent the head emits.
        extent: (f64, f64),
        objectness: f32,
        classes: [f32; NC],
    }

    /// Where a cell lands in the concatenated grid: every earlier stride's
    /// cells, then row-major within this one. Deliberately re-derived here
    /// rather than borrowed from the decode, so a decode that walks the grid
    /// differently shows up as a failure instead of cancelling out.
    fn grid_index(size: InputSize, stride: usize, gx: usize, gy: usize) -> usize {
        let before: usize = STRIDES
            .iter()
            .take_while(|s| **s != stride)
            .map(|s| (size.w / s) * (size.h / s))
            .sum();
        before + gy * (size.w / stride) + gx
    }

    fn grid_objectness_tensor() -> Vec<f32> {
        // A data table: one planted row per line, which is how it is read.
        #[rustfmt::skip]
        let planted = [
            // person at 0.95 x 0.95 = 0.9025, a 32px box centered in cell (3, 3)
            GridCell { stride: 8, gx: 3, gy: 3, off: (0.5, 0.5), extent: (32.0, 32.0),
                       objectness: 0.95, classes: [0.95, 0.0, 0.0] },
            // 0.60 IoU with it, same class — NMS suppresses it
            GridCell { stride: 8, gx: 4, gy: 3, off: (0.5, 0.5), extent: (32.0, 32.0),
                       objectness: 0.90, classes: [0.90, 0.0, 0.0] },
            // car at 0.9 x 0.9 = 0.81, just over its 0.8 floor
            GridCell { stride: 16, gx: 1, gy: 1, off: (0.5, 0.5), extent: (16.0, 16.0),
                       objectness: 0.90, classes: [0.0, 0.0, 0.90] },
            // car at 0.9 x 0.85 = 0.765, just under it — the objectness product
            // is what decides, not the class score
            GridCell { stride: 16, gx: 2, gy: 2, off: (0.5, 0.5), extent: (16.0, 16.0),
                       objectness: 0.90, classes: [0.0, 0.0, 0.85] },
            // bicycle on the coarsest stride, flush with the top and right edges
            // of the input rectangle — inside it, so nothing here clamps
            GridCell { stride: 32, gx: 1, gy: 0, off: (0.5, 0.5), extent: (32.0, 32.0),
                       objectness: 0.80, classes: [0.0, 0.70, 0.0] },
        ];
        let row = 5 + NC;
        // Re-derived here rather than taken from `profile::grid_anchors`, for
        // the same reason `grid_index` below re-derives the walk: a tensor
        // sized by the production count is sized to agree with whatever that
        // count says, so a count that changed would resize the planted tensor
        // to match itself instead of showing up as a failure.
        let anchors = STRIDES
            .iter()
            .map(|s| (TINY.w / s) * (TINY.h / s))
            .sum::<usize>();
        // Zero elsewhere: objectness 0 times anything is 0, under every floor.
        let mut values = vec![0.0f32; anchors * row];
        for cell in &planted {
            let base = grid_index(TINY, cell.stride, cell.gx, cell.gy) * row;
            let log_extent = |pixels: f64| (pixels / cell.stride as f64).ln() as f32;
            values[base] = cell.off.0;
            values[base + 1] = cell.off.1;
            values[base + 2] = log_extent(cell.extent.0);
            values[base + 3] = log_extent(cell.extent.1);
            values[base + 4] = cell.objectness;
            for (c, score) in cell.classes.iter().enumerate() {
                values[base + 5 + c] = *score;
            }
        }
        values
    }

    fn grid_objectness_output(values: &[f32]) -> Outputs<Raw<'_>> {
        raw_one(
            values,
            &[1, (values.len() / (5 + NC)) as i64, (5 + NC) as i64],
        )
    }

    #[test]
    fn a_stretched_grid_head_scores_objectness_times_class_and_suppresses_the_neighbouring_cell() {
        let values = grid_objectness_tensor();
        let dets = decode_under(
            GRID_OBJECTNESS,
            &grid_objectness_output(&values),
            TINY,
            &Projection::stretch(TINY),
        );
        // A cell's center is `(g + off) * stride` and its extent is the planted
        // pixel figure, so the corner is that center less half the extent; the
        // stretch then divides by the 64-pixel input. The person is cell (3, 3)
        // on stride 8, so center 28 and extent 32: 12/64 = 0.1875, 32/64 = 0.5.
        // The car is cell (1, 1) on stride 16, center 24 extent 16: 16/64 =
        // 0.25 both ways.
        assert_eq!(
            dets,
            vec![
                // 0.95 objectness x 0.95 class; the cell beside it is at IoU
                // 0.60 with the same class and does not survive
                det("person", 0.902, [0.1875, 0.1875, 0.5, 0.5]),
                // 0.9 x 0.9 = 0.81 clears car's 0.8; the 0.9 x 0.85 = 0.765
                // cell does not, and it is the *product* that decides
                det("car", 0.81, [0.25, 0.25, 0.25, 0.25]),
                det("bicycle", 0.56, [0.5, 0.0, 0.5, 0.5]),
            ]
        );
    }

    #[test]
    fn a_letterboxed_grid_head_reads_every_row_against_the_content_area_not_the_input() {
        let values = grid_objectness_tensor();
        let dets = decode_under(
            GRID_OBJECTNESS,
            &grid_objectness_output(&values),
            TINY,
            &letterboxed(TINY),
        );
        // 1920x1080 into a 64x64 input is 64x36 of content, so `y` is read
        // against 36 rows rather than 64 — every box the same width and 1.78x
        // taller, with the same three surviving the same gates.
        assert_eq!(
            dets,
            vec![
                det("person", 0.902, [0.1875, 0.3333, 0.5, 0.6667]),
                det("car", 0.81, [0.25, 0.4444, 0.25, 0.4444]),
                det("bicycle", 0.56, [0.5, 0.0, 0.5, 0.8889]),
            ]
        );
    }

    // ---- head 4: DETR queries `[1, Q, 4]` + `[1, Q, nc]` --------------------

    /// One planted query: a normalized `cx, cy, w, h` box and raw class logits.
    struct Query {
        box_: [f32; 4],
        logits: [f32; NC],
    }

    fn detr_tensors() -> (Vec<f32>, Vec<f32>) {
        // A data table: one planted row per line, which is how it is read.
        #[rustfmt::skip]
        let planted = [
            // person, sigmoid(2.0) = 0.881
            Query { box_: [0.25, 0.25, 0.20, 0.20], logits: [2.0, -4.0, -4.0] },
            // car, sigmoid(2.5) = 0.924, over its 0.8 floor
            Query { box_: [0.50, 0.50, 0.10, 0.10], logits: [-4.0, -4.0, 2.5] },
            // the argmax is car at sigmoid(1.0) = 0.731, under car's 0.8 floor;
            // bicycle at sigmoid(0.5) = 0.622 clears its own. This query leaves
            // as a bicycle, which a plain argmax would have thrown away with
            // its box.
            Query { box_: [0.75, 0.25, 0.10, 0.20], logits: [-4.0, 0.5, 1.0] },
            // nothing clears anything
            Query { box_: [0.10, 0.90, 0.05, 0.05], logits: [-5.0, -5.0, -5.0] },
            // all but on top of query 0 — kept, because bipartite matching
            // already de-duplicated and this head runs no NMS
            Query { box_: [0.26, 0.26, 0.20, 0.20], logits: [2.2, -4.0, -4.0] },
            // sigmoid(-1.0) = 0.269, just under the 0.3 default
            Query { box_: [0.40, 0.40, 0.30, 0.30], logits: [-1.0, -1.0, -1.0] },
        ];
        let boxes = planted.iter().flat_map(|q| q.box_).collect();
        let logits = planted.iter().flat_map(|q| q.logits).collect();
        (boxes, logits)
    }

    #[test]
    fn a_stretched_detr_head_emits_one_box_per_query_that_clears_a_floor_and_runs_no_nms() {
        let (boxes, logits) = detr_tensors();
        let queries = (boxes.len() / 4) as i64;
        let dets = decode_under(
            DETR_QUERIES,
            &raw_detr(&boxes, &logits, queries, NC as i64),
            SQUARE,
            &Projection::stretch(SQUARE),
        );
        // These queries are already normalized centers and extents — against
        // the *input*. The decode scales them to model pixels and the stretch
        // divides by that same 640, so under this projection the two cancel and
        // the expectation is the planted row read as a corner: the car at
        // center 0.50 extent 0.10 is 0.50 - 0.05 = 0.45.
        assert_eq!(
            dets,
            vec![
                det("car", 0.924, [0.45, 0.45, 0.1, 0.1]),
                // two all-but-identical queries, both kept
                det("person", 0.9, [0.16, 0.16, 0.2, 0.2]),
                det("person", 0.881, [0.15, 0.15, 0.2, 0.2]),
                // the query whose argmax was car, leaving under its runner-up
                det("bicycle", 0.622, [0.7, 0.15, 0.1, 0.2]),
            ]
        );
    }

    #[test]
    fn a_letterboxed_detr_head_un_projects_its_normalized_queries_like_every_other_family() {
        let (boxes, logits) = detr_tensors();
        let queries = (boxes.len() / 4) as i64;
        let dets = decode_under(
            DETR_QUERIES,
            &raw_detr(&boxes, &logits, queries, NC as i64),
            SQUARE,
            &letterboxed(SQUARE),
        );
        // The queries are already 0..1 — against the *input*, not the frame.
        // Scaling them into model pixels is what lets the same un-projection
        // apply, so a DETR fed a padded frame is not off by the padding.
        assert_eq!(
            dets,
            vec![
                det("car", 0.924, [0.45, 0.8, 0.1, 0.1778]),
                det("person", 0.9, [0.16, 0.2844, 0.2, 0.3556]),
                det("person", 0.881, [0.15, 0.2667, 0.2, 0.3556]),
                det("bicycle", 0.622, [0.7, 0.2667, 0.1, 0.3556]),
            ]
        );
    }

    // ---- behaviors the composed tests above depend on, stated alone ---------

    #[test]
    fn a_box_lying_wholly_in_the_letterbox_pad_is_dropped_not_emitted_flat() {
        // A box below the content area un-projects to a normalized `y` past
        // 1.0 — rows of frame that never held a pixel. Both corners clamp to
        // 1.0, so `h` is exactly 0 and the host refuses the whole detection:
        // `validate_det` requires `w > 0 and h > 0`. Emitting it anyway is not
        // merely useless — it consumes a `MAX_DETS` slot *ahead of*
        // `top_dets`'s truncate, so a pad-only ghost can displace a real
        // detection that would otherwise have been reported.
        let projection = letterboxed(SQUARE);
        let ghost = model_box(500.0, 500.0, 600.0, 600.0);
        assert!(projection.unproject(ghost).corners().y1 > 1.0);
        assert!(det_from(projection.unproject(ghost), 0.99, EVIDENCE, "person".into()).is_none());

        // The displacement, in the numbers that make it matter: MAX_DETS real
        // boxes plus one pad-only ghost scoring higher than any of them. The
        // ghost must not be what the cap keeps.
        let mut rows = Vec::new();
        rows.extend_from_slice(&row(500.0, 500.0, 600.0, 600.0, 0.99, 0.0));
        for i in 0..MAX_DETS {
            let x = i as f32 * 10.0;
            // inside the top 360 rows, so each of these has real area
            rows.extend_from_slice(&row(x, 0.0, x + 8.0, 36.0, 0.5 + i as f32 / 1000.0, 0.0));
        }
        let dets = decode_under(END_TO_END, &end_to_end_output(&rows), SQUARE, &projection);
        assert_eq!(dets.len(), MAX_DETS);
        assert!(dets.iter().all(|d| d.bbox[2] > 0.0 && d.bbox[3] > 0.0));
        // every real box survived, including the weakest — nothing was pushed
        // off the cut by a detection the host would have thrown away
        assert!(dets.iter().all(|d| d.score < 0.99));
        assert_eq!(dets[MAX_DETS - 1].score, 0.5);
    }

    #[test]
    fn a_pad_only_ghost_is_dropped_before_nms_so_it_cannot_suppress_a_real_box() {
        // NMS runs in model space, where a box lying wholly in the letterbox
        // pad still has ordinary area. Left in, a ghost that outscores a real
        // box of its own class suppresses it there and is then dropped itself
        // by `det_from` — the real box gone, the ghost reported as nothing.
        // `finish`'s pre-filter is what keeps that from happening.
        //
        // The projection is yolox's real one — the only built-in family that
        // letterboxes — read against a 1080p camera: 1920x1080 into a 416 input
        // is 416x234 of content, so model rows 234..416 are padding. The head
        // below is the raw-classes one only because it takes model pixels
        // literally and so states the geometry plainly; the defect is in
        // `finish`, which every head converges on.
        //
        // Both boxes span x 104..208. The ghost is rows 234..306 — wholly pad.
        // The real person is rows 180..306: 54 rows of content and 72 of pad.
        // Their overlap is the ghost exactly, so the union is the real box
        // alone and the IoU is 72/126 = 0.571, over `DEFAULT_NMS`'s 0.45.
        //
        // Reaching the threshold is about *choosing* the ghost, not about
        // finding a lucky frame. Fix the ghost's extent first and then measure
        // the overlap it happens to get, and the number lands under 0.45 — an
        // earlier reading of this got 0.37 that way and concluded the case was
        // unreachable. Let the ghost be exactly the overhang and 0.45 asks only
        // that 45% of the real box lie in the pad, leaving the majority of it as
        // content. Pad placement is not the point either: the same arithmetic
        // holds for a centered letterbox. This one is bottom-right only because
        // `fit` hard-codes a `(0, 0)` offset in both arms.
        let projection = letterboxed(YOLOX_416);
        let ghost = model_box(104.0, 234.0, 208.0, 306.0);
        let real = model_box(104.0, 180.0, 208.0, 306.0);
        assert!(iou(&ghost, &real) >= DEFAULT_NMS.iou);
        // the ghost is pad-only: it is what `det_from` declines to emit
        assert!(det_from(projection.unproject(ghost), 0.9, EVIDENCE, "person".into()).is_none());
        // and the real box is not: it keeps the 54 content rows
        assert!(det_from(projection.unproject(real), 0.7, EVIDENCE, "person".into()).is_some());

        let values = v8_output(
            NC,
            &[
                // the ghost, outscoring the real box so NMS ranks it first
                (156.0, 270.0, 104.0, 72.0, 0, 0.9),
                // the real person at the bottom edge of the frame
                (156.0, 243.0, 104.0, 126.0, 0, 0.7),
            ],
        );
        let dets = decode_under(
            RAW_CLASSES,
            &raw_one(&values, &[1, (4 + NC) as i64, 2]),
            YOLOX_416,
            &projection,
        );
        // x is read against all 416 columns: 104..208 is 0.25 wide from 0.25.
        // y is read against the 234 content rows: 180/234 = 0.7692, and the
        // bottom corner clamps to the frame edge, leaving 0.2308 of height.
        assert_eq!(dets, vec![det("person", 0.7, [0.25, 0.7692, 0.25, 0.2308])]);
    }

    #[test]
    fn an_anchor_with_nothing_to_choose_between_argmaxes_to_the_last_class() {
        // `argmax` is `max_by`, which returns the *last* of several equal
        // maxima. So an anchor whose class scores are all equal — every
        // untouched anchor of a sparse tensor — comes out as the *highest*
        // class id, not class 0. Which floor then drops it is decided by that
        // last class, and reading it the intuitive way gets the wrong one.
        assert_eq!(
            argmax(NonZeroUsize::new(NC).unwrap(), |_| 0.0),
            (NC - 1, 0.0)
        );

        let flat = v8_output(3, &[(320.0, 320.0, 64.0, 64.0, 0, 0.0)]);
        // admitted at a floor every class clears, it leaves as `car` — id 2,
        // the last — and not as `person`
        let dets = decode(
            v8_spec(3),
            &flat,
            &[1, 7, 1],
            &floors(r#"{"default":-1.0}"#),
            SQUARE,
        );
        assert_eq!(dets.len(), 1);
        assert_eq!(dets[0].label, "car");
        // ...so it is car's own floor that drops it, even though the default
        // that person and bicycle answer to would have kept it
        let dets = decode(
            v8_spec(3),
            &flat,
            &[1, 7, 1],
            &floors(r#"{"default":-1.0,"car":0.8}"#),
            SQUARE,
        );
        assert!(dets.is_empty(), "{dets:?}");
    }

    #[test]
    fn a_layout_that_declares_no_classes_is_refused_rather_than_decoded_as_empty() {
        let refuse = |output: OutputSpec, raw: &Outputs<Raw>, size: InputSize| -> String {
            let err = decode_output(
                output,
                raw,
                &labels(),
                &open(),
                size,
                &Projection::stretch(size),
            )
            .expect_err("a head with no classes decoded");
            format!("{err:#}")
        };
        // Each shape is one its layout would otherwise index happily: only the
        // class table is empty.
        let cases = [
            {
                let anchors = 4;
                let values = vec![0f32; 4 * anchors];
                let dims = [1, 4, anchors as i64];
                refuse(v8_spec(0), &raw_one(&values, &dims), SQUARE)
            },
            {
                let grid = GridOutput::new(TINY, 0);
                refuse(grid.spec(), &raw_one(&grid.values, &grid.dims()), TINY)
            },
            {
                let detr = DetrOutput::new(2, 0);
                refuse(
                    detr.spec(),
                    &raw_detr(&detr.boxes, &detr.logits, 2, 0),
                    SQUARE,
                )
            },
        ];
        for message in cases {
            assert!(message.contains("no classes"), "{message}");
            // and names the layout, which says whether the profile or the export is
            // the thing to look at
            assert!(
                ["raw-classes", "grid-objectness", "detr-queries"]
                    .iter()
                    .any(|kind| message.contains(kind)),
                "{message}"
            );
        }
    }
}
