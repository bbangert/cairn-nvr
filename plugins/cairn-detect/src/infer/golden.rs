//! Characterization fixtures: what this module *currently does*, recorded.
//!
//! The 90-odd tests beside this one were written per feature — each states a
//! rule and checks that rule. None of them pins end-to-end decode output
//! against a fixed input, which is exactly what a refactor has to preserve and
//! exactly what a per-feature test cannot prove: a move that quietly reorders
//! two NMS candidates, drops a digit of rounding or applies the projection one
//! call later still satisfies every rule any of them states.
//!
//! The `verify/` harness cannot stand in for this. It samples frames on a
//! wall clock, so two runs of the same binary against the same model disagree
//! about which frames they saw; it proves the pipeline runs, never that a
//! refactor was output-identical.
//!
//! So: a fixed synthetic tensor per head, the resulting `Vec<Det>` serialized
//! to the precision a `Det` carries, and the whole table checked in under
//! `golden/`. A diff there during a "pure move" phase is the phase not being a
//! pure move. (Not to *full* precision — `det_from` rounds score to 3 places
//! and bbox to 4 before a `Det` exists, so those roundings are themselves part
//! of what is pinned.)
//!
//! Regenerate after an *intended* behavior change — and only then, with the
//! diff read line by line:
//!
//! ```text
//! CAIRN_GOLDEN_BLESS=1 cargo test -p cairn-detect golden
//! ```
//!
//! That run **fails on purpose**: it rewrites the fixtures without comparing
//! anything, and a run that compared nothing must never read as a pass. Re-run
//! without the flag to see the suite go green.
//!
//! These fixtures deliberately do not share helpers with the `tests` module
//! below. A golden built out of the same constructors it is meant to guard
//! would move with them.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::catalog::{RFDETR, YOLOV10, YOLOV8, YOLOX};
use super::geometry::{Bbox, InputSize, ModelBox, Projection, ResizePolicy};
use super::heads::{decode_output, Raw};
use super::labels::{Labels, ScoreFloors};
use super::profile::{Layout, ModelProfile, OutputSpec, Outputs, ScoreComposition, DEFAULT_NMS};
use super::resolve::{check_grid_divides_input, resolve_input_size, resolve_profile, Declared};

/// Set to rewrite every fixture from current behavior. See the module docs.
const BLESS: &str = "CAIRN_GOLDEN_BLESS";

// ---- the fixture harness ------------------------------------------------

fn golden_path(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src/infer/golden")
        .join(format!("{name}.json"))
}

/// Compare `actual` against the checked-in fixture, or rewrite it under
/// [`BLESS`].
///
/// Compares the *rendered* JSON rather than parsed values: `serde_json` writes
/// `f64` in its shortest round-tripping form, so two distinct floats never
/// render alike and a text compare is an exact compare. It also means the
/// checked-in file is the diff a reviewer reads.
fn check(name: &str, actual: &Value) {
    // Not an obstacle to planting a NaN — the *detector* for one. A planted
    // non-finite that the decode correctly rejects never reaches here; one that
    // leaks reaches `round_to(f64::NAN)` and fails this, loudly, by name.
    let rendered = format!(
        "{}\n",
        serde_json::to_string_pretty(actual).expect("a non-finite value escaped the decode")
    );
    let path = golden_path(name);
    if blessing() {
        // The fixture directory is checked in. Creating it would mean this is
        // not the path the fixtures actually live at — silently re-recording
        // at a stale location is how a bless run passes while guarding nothing.
        let dir = path.parent().expect("fixture path has a parent");
        assert!(
            dir.is_dir(),
            "fixture directory {} does not exist; {BLESS} re-records fixtures, it does not \
             invent a new home for them",
            dir.display()
        );
        std::fs::write(&path, &rendered).expect("writing the fixture");
        // A blessing run must never be mistaken for a passing one: it compared
        // nothing. Fail the whole suite so the flag cannot be left set in CI.
        panic!(
            "re-recorded {} under {BLESS}. Read the diff, then re-run without the flag.",
            path.display()
        );
    }
    let expected = std::fs::read_to_string(&path).unwrap_or_else(|err| {
        panic!(
            "cannot read fixture {}: {err}\nIf this is a new fixture, record it with \
             {BLESS}=1 cargo test -p cairn-detect golden",
            path.display()
        )
    });
    if rendered != expected {
        panic!("{}", report(&path, &expected, &rendered));
    }
}

/// Is this a re-recording run?
///
/// `is_some()` would make `CAIRN_GOLDEN_BLESS=0` bless, which is the opposite of
/// what anyone typing it means. Unset, empty and `0` all mean "compare".
fn blessing() -> bool {
    match std::env::var(BLESS) {
        Ok(value) => !matches!(value.trim(), "" | "0"),
        Err(_) => false,
    }
}

/// The first divergence, with a little context. A whole-file dump of a
/// thousand-line fixture says nothing a reader can act on.
fn report(path: &Path, expected: &str, actual: &str) -> String {
    let (want, got): (Vec<&str>, Vec<&str>) =
        (expected.lines().collect(), actual.lines().collect());
    let at = want
        .iter()
        .zip(&got)
        .position(|(a, b)| a != b)
        .unwrap_or(want.len().min(got.len()));
    let window = |lines: &[&str]| {
        lines
            .iter()
            .enumerate()
            .skip(at.saturating_sub(3))
            .take(9)
            .map(|(i, line)| format!("  {:>4} {line}", i + 1))
            .collect::<Vec<_>>()
            .join("\n")
    };
    // Names the fixture rather than the subject: this helper serves the
    // projection and resolution fixtures too, and "decode output changed" on a
    // projection diff sends the reader to the wrong file.
    format!(
        "{} no longer matches current behavior\n\nfirst difference at line {}\n\nexpected:\n{}\n\n\
         actual:\n{}\n\nIf this change is intended, re-record with {BLESS}=1 cargo test -p \
         cairn-detect golden — and read the diff.",
        path.display(),
        at + 1,
        window(&want),
        window(&got),
    )
}

// ---- the world the fixtures decode in -----------------------------------

/// Three classes, so an argmax has something to choose between and a class id
/// past the end exercises the numeric fallback.
const NC: usize = 3;

fn labels() -> Labels {
    Labels(vec!["person".into(), "bicycle".into(), "car".into()])
}

/// A non-uniform floor table, which is the configuration that makes the
/// per-class gates observable: `car` is held to 0.8 while everything else
/// clears at 0.3.
fn floors() -> ScoreFloors {
    ScoreFloors::parse(r#"{"default": 0.3, "car": 0.8}"#).expect("a literal floor table")
}

/// The model path every resolution error names. Nothing opens it — the
/// resolvers only quote it back.
const MODEL_PATH: &str = "model.onnx";

const MODEL: InputSize = InputSize::square(640);
/// 8x8 + 4x4 + 2x2 = 84 anchors under the yolox strides: a whole grid small
/// enough to write out by hand.
const GRID: InputSize = InputSize::square(64);
const STRIDES: &[usize] = &[8, 16, 32];
/// A 16:9 camera, which is where a letterbox actually pads.
const SOURCE: InputSize = InputSize { w: 1920, h: 1080 };

/// The two projections every head is decoded under: the identity-ish stretch,
/// and a letterbox whose vertical scale differs from the input size — the case
/// that reports every box short and shifted if the un-projection is skipped.
fn projections(input: InputSize) -> [(&'static str, Projection); 2] {
    [
        ("stretch", Projection::stretch(input)),
        (
            "letterbox_16x9",
            ResizePolicy::Letterbox { pad: 114 }.project(input, SOURCE),
        ),
    ]
}

fn decoded(
    output: OutputSpec,
    raw: &Outputs<Raw>,
    size: InputSize,
    projection: &Projection,
) -> Value {
    let dets = decode_output(output, raw, &labels(), &floors(), size, projection)
        .expect("fixture tensors are well-formed for their layout");
    serde_json::to_value(dets).expect("a Det serializes")
}

/// One head's tensors, decoded under both projections, as one fixture object.
fn over_projections(input: InputSize, output: OutputSpec, raw: &Outputs<Raw>) -> Value {
    let mut cases = serde_json::Map::new();
    for (name, projection) in projections(input) {
        cases.insert(name.to_string(), decoded(output, raw, input, &projection));
    }
    Value::Object(cases)
}

// ---- head 1: end-to-end `[1, N, 6]` -------------------------------------

/// Rows of `[x1, y1, x2, y2, score, class_id]` in model pixels.
///
/// This head is NMS-free by construction, so rows 0 and 1 overlapping heavily
/// is the *interesting* case rather than the suppressed one: both have to
/// survive, because the model already de-duplicated and a second pass would
/// merge two objects the export deliberately kept apart.
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
        // this box also lands entirely in the pad — see KNOWN DEFECT below.
        500.0, 500.0, 600.0, 600.0, 0.65, 7.0,
    ];
    rows
}

// ---- head 2: raw classes `[1, 4 + nc, A]` -------------------------------

/// One planted anchor of a channels-first head: box in model pixels, one score
/// per class.
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
        // bicycle, elsewhere in the frame. Under the letterbox its lower edge
        // falls in the pad — see KNOWN DEFECT below.
        RawAnchor { cx: 400.0, cy: 400.0, w: 80.0, h: 40.0, classes: [0.0, 0.60, 0.0] },
        // under the default floor
        RawAnchor { cx: 300.0, cy: 100.0, w: 20.0, h: 20.0, classes: [0.25, 0.0, 0.0] },
        // a second person far enough away that NMS keeps it
        RawAnchor { cx: 100.0, cy: 300.0, w: 60.0, h: 60.0, classes: [0.55, 0.0, 0.0] },
    ];
    // The rest stay zero. `argmax` is `max_by`, which returns the *last* of
    // several equal maxima, so an all-zero anchor argmaxes to class 2 (`car`)
    // at score 0 and it is car's 0.8 floor that drops it — not class 0 and the
    // 0.3 default, which is the intuitive reading and the wrong one. That is
    // most of the tensor, and the fixture is partly about it staying dropped.
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

// ---- head 3: grid objectness `[1, A, 5 + nc]` ---------------------------

/// One planted cell of a grid head.
struct GridCell {
    stride: usize,
    gx: usize,
    gy: usize,
    /// Offsets inside the cell, in cell units — what the head actually emits.
    off: (f32, f32),
    /// Box extent in model pixels; stored as the log extent the head emits.
    extent: (f64, f64),
    objectness: f32,
    classes: [f32; NC],
}

/// Where a cell lands in the concatenated grid: every earlier stride's cells,
/// then row-major within this one. Deliberately re-derived here rather than
/// borrowed from the decode, so a decode that walks the grid differently shows
/// up as a diff instead of cancelling out.
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
        // car at 0.9 x 0.85 = 0.765, just under it — the objectness product is
        // what decides, not the class score
        GridCell { stride: 16, gx: 2, gy: 2, off: (0.5, 0.5), extent: (16.0, 16.0),
                   objectness: 0.90, classes: [0.0, 0.0, 0.85] },
        // bicycle on the coarsest stride, flush with the top and right edges
        // of the input rectangle — inside it, so nothing here clamps
        GridCell { stride: 32, gx: 1, gy: 0, off: (0.5, 0.5), extent: (32.0, 32.0),
                   objectness: 0.80, classes: [0.0, 0.70, 0.0] },
    ];
    let row = 5 + NC;
    let anchors = STRIDES
        .iter()
        .map(|s| (GRID.w / s) * (GRID.h / s))
        .sum::<usize>();
    // Zero elsewhere: objectness 0 times anything is 0, under every floor.
    let mut values = vec![0.0f32; anchors * row];
    for cell in &planted {
        let base = grid_index(GRID, cell.stride, cell.gx, cell.gy) * row;
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
        // bicycle at sigmoid(0.5) = 0.622 clears its own. This query leaves as
        // a bicycle, which a plain argmax would have thrown away with its box.
        Query { box_: [0.75, 0.25, 0.10, 0.20], logits: [-4.0, 0.5, 1.0] },
        // nothing clears anything
        Query { box_: [0.10, 0.90, 0.05, 0.05], logits: [-5.0, -5.0, -5.0] },
        // all but on top of query 0 — kept, because bipartite matching already
        // de-duplicated and this head runs no NMS
        Query { box_: [0.26, 0.26, 0.20, 0.20], logits: [2.2, -4.0, -4.0] },
        // sigmoid(-1.0) = 0.269, just under the 0.3 default
        Query { box_: [0.40, 0.40, 0.30, 0.30], logits: [-1.0, -1.0, -1.0] },
    ];
    let boxes = planted.iter().flat_map(|q| q.box_).collect();
    let logits = planted.iter().flat_map(|q| q.logits).collect();
    (boxes, logits)
}

// KNOWN DEFECT pinned by these fixtures — a zero-area box escapes the decode.
//
// Two recorded rows carry a bbox of `[.., 1.0, .., 0.0]`: `end_to_end`'s class-7
// row and `raw_classes`' bicycle, both under `letterbox_16x9`. Both are correct
// per the code and both are wrong per the contract.
//
// A box lying entirely in the letterbox pad un-projects to a normalized `y`
// past 1.0 — rows of frame that never held a pixel. `det_from` clamps `y0` and
// `y1` both to 1.0, so `h = (1.0 - 1.0).max(0.0) = 0.0`, and the detection is
// emitted rather than dropped. The host then refuses it: `validate_det` in
// `lib/cairn/plugin_protocol.ex` requires `w > 0 and h > 0`. So the plugin
// spends one of its `MAX_DETS` slots — *before* `top_dets` truncates — on a
// detection it knows will be discarded, and on a busy frame that displaces a
// real one.
//
// Phase 0 characterizes, so this is recorded rather than fixed. It is recorded
// here as a defect so that a later phase does not read it as intended clamp
// behavior and carefully preserve it. The fix belongs wherever the clamp lives:
// drop a candidate whose clamped box has zero width or height.

// ---- T0.1: golden decode output -----------------------------------------

#[test]
fn golden_decode_output() {
    let rows = end_to_end_rows();
    let raw = raw_classes_tensor();
    let grid = grid_objectness_tensor();
    let (boxes, logits) = detr_tensors();

    let queries = (boxes.len() / 4) as i64;
    let fixture = json!({
        "end_to_end": over_projections(
            MODEL,
            OutputSpec {
                layout: Layout::EndToEnd,
                score: ScoreComposition::Class,
                nms: None,
            },
            &one(&rows, &[1, (rows.len() / 6) as i64, 6]),
        ),
        "raw_classes": over_projections(
            MODEL,
            OutputSpec {
                layout: Layout::RawClasses { nc: NC },
                score: ScoreComposition::Class,
                nms: Some(DEFAULT_NMS),
            },
            &one(&raw, &[1, (4 + NC) as i64, RAW_ANCHORS as i64]),
        ),
        "grid_objectness": over_projections(
            GRID,
            OutputSpec {
                layout: Layout::GridObjectness { nc: NC, strides: STRIDES },
                score: ScoreComposition::ObjTimesClass,
                nms: Some(DEFAULT_NMS),
            },
            &one(&grid, &[1, (grid.len() / (5 + NC)) as i64, (5 + NC) as i64]),
        ),
        "detr_queries": over_projections(
            MODEL,
            OutputSpec {
                layout: Layout::DetrQueries { nc: NC },
                score: ScoreComposition::SigmoidClass,
                nms: None,
            },
            &Outputs::BoxesAndLogits {
                boxes: Raw { dims: vec![1, queries, 4], values: &boxes },
                logits: Raw { dims: vec![1, queries, NC as i64], values: &logits },
            },
        ),
    });
    check("decode", &fixture);
}

fn one<'a>(values: &'a [f32], dims: &[i64]) -> Outputs<Raw<'a>> {
    Outputs::One(Raw {
        dims: dims.to_vec(),
        values,
    })
}

// ---- T0.2: golden projections -------------------------------------------

/// Model-space corners every projection is probed with: the whole input
/// rectangle, a box inside it, a box that reaches into the letterbox padding,
/// and one that starts outside the rectangle entirely — which a real
/// letterboxed decode does emit and un-projection is what brings back.
fn probes(input: InputSize) -> Vec<(&'static str, ModelBox)> {
    let (w, h) = (input.w as f64, input.h as f64);
    let corners = |x1, y1, x2, y2| ModelBox(Bbox { x1, y1, x2, y2 });
    vec![
        ("full_input", corners(0.0, 0.0, w, h)),
        (
            "centered_quarter",
            corners(w / 4.0, h / 4.0, 3.0 * w / 4.0, 3.0 * h / 4.0),
        ),
        ("into_the_pad", corners(w / 2.0, h / 2.0, w, h)),
        (
            "outside_top_left",
            corners(-w / 8.0, -h / 8.0, w / 8.0, h / 8.0),
        ),
    ]
}

#[test]
fn golden_projections() {
    let cases: Vec<(&str, ResizePolicy, InputSize, InputSize)> = vec![
        // 16:9, the common camera aspect
        ("stretch_640_16x9", ResizePolicy::Stretch, MODEL, SOURCE),
        (
            "letterbox_640_16x9",
            ResizePolicy::Letterbox { pad: 114 },
            MODEL,
            SOURCE,
        ),
        // 4:3
        (
            "stretch_416_4x3",
            ResizePolicy::Stretch,
            InputSize::square(416),
            InputSize { w: 1024, h: 768 },
        ),
        (
            "letterbox_416_4x3",
            ResizePolicy::Letterbox { pad: 114 },
            InputSize::square(416),
            InputSize { w: 1024, h: 768 },
        ),
        // square: the letterbox degenerates to the stretch
        (
            "stretch_416_square",
            ResizePolicy::Stretch,
            InputSize::square(416),
            InputSize { w: 800, h: 800 },
        ),
        (
            "letterbox_416_square",
            ResizePolicy::Letterbox { pad: 114 },
            InputSize::square(416),
            InputSize { w: 800, h: 800 },
        ),
        // portrait, where the *width* is what gets padded
        (
            "letterbox_640_portrait",
            ResizePolicy::Letterbox { pad: 114 },
            MODEL,
            InputSize { w: 480, h: 640 },
        ),
        // floor(33 * 0.64) = 21, forced down to 20: the even-side rounding
        // path, and the reason `Fit::projection` is derived from the side
        // actually produced rather than from the ratio.
        (
            "letterbox_64_odd_side",
            ResizePolicy::Letterbox { pad: 114 },
            GRID,
            InputSize { w: 100, h: 33 },
        ),
        // a source smaller than the input on both axes, which scales *up*
        (
            "letterbox_640_upscale",
            ResizePolicy::Letterbox { pad: 114 },
            MODEL,
            InputSize { w: 320, h: 180 },
        ),
    ];

    let mut fixture = serde_json::Map::new();
    for (name, policy, input, source) in cases {
        let fit = policy.fit(input, source);
        let projection = policy.project(input, source);
        let unprojected: serde_json::Map<String, Value> = probes(input)
            .into_iter()
            .map(|(probe, corners)| {
                // Rendered as the four corners explicitly rather than by
                // serializing a `NormBox`: the fixture is a checked-in wire
                // format and must not be the reason a production type grows a
                // `Serialize` derive.
                let b = projection.unproject(corners).corners();
                (probe.to_string(), json!([b.x1, b.y1, b.x2, b.y2]))
            })
            .collect();
        fixture.insert(
            name.to_string(),
            json!({
                "input": [input.w, input.h],
                "source": [source.w, source.h],
                "fit": {
                    "inner": [fit.inner.w, fit.inner.h],
                    "offset": [fit.offset.0, fit.offset.1],
                    "pad": fit.pad,
                },
                "unproject": unprojected,
            }),
        );
    }
    check("projection", &Value::Object(fixture));
}

// ---- T0.3: golden resolution --------------------------------------------

fn declared(name: &str, dims: Option<Vec<i64>>) -> Declared {
    Declared {
        name: name.to_string(),
        dims,
    }
}

fn detr_outputs(queries: i64, nc: i64) -> Vec<Declared> {
    vec![
        declared("pred_boxes", Some(vec![1, queries, 4])),
        declared("logits", Some(vec![1, queries, nc])),
    ]
}

/// An error as the fixture records it: one array entry per link of the chain.
///
/// Deliberately not `format!("{err:#}")`. That flattens the chain into one
/// string using a format `anyhow` owns, and the resolver's errors are
/// `thiserror` types, which ignore `{:#}` — every multi-link entry would
/// collapse to its outer message and the diff would read like a reworded string
/// while actually recording *lost context*. An array makes the link count part
/// of what is pinned.
///
/// Takes anything `anyhow` can absorb, because that absorption is exactly what
/// the plugin does at its own boundary: a `ResolveError` becomes an
/// `anyhow::Error` on its way out of `infer`, and its `#[source]` links become
/// chain links.
fn error_chain(err: impl Into<anyhow::Error>) -> Value {
    let err = err.into();
    json!({
        "error": err.chain().map(ToString::to_string).collect::<Vec<_>>(),
    })
}

/// A resolution outcome, as the fixture records it: the profile it settled on
/// and how the whole output half was read, or the error chain the operator
/// would see.
fn resolution(explicit: Option<ModelProfile>, outputs: &[Declared], size: InputSize) -> Value {
    match resolve_profile(explicit, outputs, size, Path::new(MODEL_PATH)) {
        Ok((profile, names, output)) => json!({
            "profile": profile.name,
            "outputs": match &names {
                Outputs::One(one) => json!({ "one": one }),
                Outputs::BoxesAndLogits { boxes, logits } => json!({
                    "boxes": boxes,
                    "logits": logits,
                }),
            },
            // `None` is the deferred case: the export pinned no shape and `nc`
            // waits for the first real output.
            "layout": output.map(|output| output.layout.to_string()),
            // The rest of the `OutputSpec`, which nothing else compares by
            // value. Phase 1 hand-copies the profile table into new modules, so
            // a family silently rewired to the wrong score composition or NMS
            // parameters is exactly the mistake that phase can make.
            "score": output.map(|output| output.score.to_string()),
            "nms": output.and_then(|output| output.nms).map(|nms| json!({
                "iou": nms.iou,
                "max_candidates": nms.max_candidates,
            })),
        }),
        Err(err) => error_chain(err),
    }
}

#[test]
fn golden_profile_resolution() {
    let wide = InputSize { w: 640, h: 384 };
    let cases: Vec<(&str, Option<ModelProfile>, Vec<Declared>, InputSize)> = vec![
        // --- each family resolving cleanly ---
        (
            "yolox_416",
            None,
            vec![declared("output", Some(vec![1, 3549, 85]))],
            InputSize::square(416),
        ),
        (
            "yolox_79_classes",
            None,
            vec![declared("output", Some(vec![1, 3549, 84]))],
            InputSize::square(416),
        ),
        (
            "yolov8_640",
            None,
            vec![declared("output0", Some(vec![1, 84, 8400]))],
            MODEL,
        ),
        (
            "yolov10_640",
            None,
            vec![declared("output0", Some(vec![1, 300, 6]))],
            MODEL,
        ),
        (
            "rfdetr_384",
            None,
            detr_outputs(300, 91),
            InputSize::square(384),
        ),
        // --- the documented ambiguities ---
        // 5040 is both this input's yolox anchor count and a plausible N of
        // end-to-end rows; 6 is both `5 + 1` class and the end-to-end width.
        (
            "ambiguous_yolox_1class_vs_end_to_end",
            None,
            vec![declared("output", Some(vec![1, 5040, 6]))],
            wide,
        ),
        // A 336-query DETR that declares its logits first offers a perfectly
        // good 80-class yolox grid as its first output, at 128x128.
        (
            "ambiguous_detr_logits_first_vs_yolox_grid",
            None,
            vec![
                declared("logits", Some(vec![1, 336, 85])),
                declared("pred_boxes", Some(vec![1, 336, 4])),
            ],
            InputSize::square(128),
        ),
        // --- naming a profile settles both of them ---
        (
            "explicit_yolox_on_the_ambiguous_shape",
            Some(YOLOX),
            vec![declared("output", Some(vec![1, 5040, 6]))],
            wide,
        ),
        (
            "explicit_yolov10_on_the_ambiguous_shape",
            Some(YOLOV10),
            vec![declared("output", Some(vec![1, 5040, 6]))],
            wide,
        ),
        // --- failures ---
        (
            "no_profile_fits",
            None,
            vec![declared("output", Some(vec![1, 10, 7]))],
            MODEL,
        ),
        (
            "nothing_to_sniff_from",
            None,
            vec![declared("output", None)],
            MODEL,
        ),
        (
            "explicit_profile_mismatch",
            Some(RFDETR),
            vec![declared("output", Some(vec![1, 300, 6]))],
            InputSize::square(384),
        ),
        (
            "explicit_profile_wrong_shape",
            Some(YOLOV8),
            vec![declared("output", Some(vec![1, 300, 6]))],
            MODEL,
        ),
        // --- deferral: shapes dynamic but the roles still bind by name ---
        (
            "detr_deferred_by_name",
            Some(RFDETR),
            vec![declared("dets", None), declared("labels", None)],
            InputSize::square(384),
        ),
        (
            "one_tensor_deferred",
            Some(YOLOX),
            vec![declared("output", None)],
            InputSize::square(416),
        ),
    ];

    let mut fixture = serde_json::Map::new();
    for (name, explicit, outputs, size) in cases {
        fixture.insert(name.to_string(), resolution(explicit, &outputs, size));
    }
    check("resolution", &Value::Object(fixture));
}

/// One input-size resolution case: what the model pinned, what `--input-size`
/// asked for, and which profile was in play. A struct rather than a tuple so
/// the three `Option`s cannot be read in the wrong order.
struct SizeCase {
    name: &'static str,
    declared: Option<InputSize>,
    requested: Option<InputSize>,
    profile: Option<ModelProfile>,
}

/// The other half of resolution, which Phase 3's typed errors also cover:
/// where the input size comes from and when a grid head refuses one.
#[test]
fn golden_input_size_resolution() {
    // A data table: one case per line, which is how it is read.
    #[rustfmt::skip]
    let cases = [
        SizeCase { name: "model_pins_it",                 declared: Some(MODEL), requested: None,                                 profile: Some(YOLOV8) },
        SizeCase { name: "flag_supplies_it",              declared: None,        requested: Some(InputSize::square(512)),         profile: Some(RFDETR) },
        SizeCase { name: "profile_default",               declared: None,        requested: None,                                 profile: Some(YOLOX)  },
        SizeCase { name: "flag_contradicts_model",        declared: Some(MODEL), requested: Some(InputSize::square(416)),         profile: Some(YOLOX)  },
        SizeCase { name: "flag_agrees_with_model",        declared: Some(MODEL), requested: Some(MODEL),                          profile: Some(YOLOV8) },
        // A family whose every export leaves its spatial axes dynamic supplies
        // no default at all, so this one has nowhere left to look.
        SizeCase { name: "variant_family_has_no_default", declared: None,        requested: None,                                 profile: Some(RFDETR) },
        SizeCase { name: "no_profile_and_nothing_pinned", declared: None,        requested: None,                                 profile: None         },
        SizeCase { name: "over_the_per_axis_limit",       declared: None,        requested: Some(InputSize { w: 9000, h: 64 }),   profile: None         },
        // Inside the per-axis limit and far outside the area one.
        SizeCase { name: "over_the_pixel_limit",          declared: None,        requested: Some(InputSize { w: 4096, h: 2048 }), profile: None         },
    ];

    let mut sizes = serde_json::Map::new();
    for case in cases {
        let outcome = match resolve_input_size(
            case.declared,
            case.requested,
            case.profile,
            Path::new(MODEL_PATH),
        ) {
            Ok((size, source)) => json!({
                "size": [size.w, size.h],
                "source": source.to_string(),
            }),
            Err(err) => error_chain(err),
        };
        sizes.insert(case.name.to_string(), outcome);
    }

    let grid_layout = Layout::GridObjectness {
        nc: 80,
        strides: STRIDES,
    };
    let divisibility: Vec<(&str, Layout, InputSize)> = vec![
        ("grid_416_square", grid_layout, InputSize::square(416)),
        ("grid_640x384", grid_layout, InputSize { w: 640, h: 384 }),
        (
            "grid_400_not_a_multiple_of_32",
            grid_layout,
            InputSize::square(400),
        ),
        (
            "grid_640x300_height_only",
            grid_layout,
            InputSize { w: 640, h: 300 },
        ),
        // Only a grid head has strides to divide by; the rest never refuse.
        (
            "end_to_end_ignores_strides",
            Layout::EndToEnd,
            InputSize::square(400),
        ),
    ];
    let mut grids = serde_json::Map::new();
    for (name, layout, size) in divisibility {
        let outcome = match check_grid_divides_input(layout, size) {
            Ok(()) => json!({ "ok": true }),
            Err(err) => error_chain(err),
        };
        grids.insert(name.to_string(), outcome);
    }

    check(
        "resolution_input_size",
        &json!({ "sizes": sizes, "grid_divisibility": grids }),
    );
}
