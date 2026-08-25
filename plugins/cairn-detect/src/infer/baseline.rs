//! The CPU baseline pass, measured where nothing else has ever run.
//!
//! `Cairn.Native.Health`'s D-P5 ratio judges an accelerator against what one
//! model pass costs on the CPU — a number that is only evidence if it was
//! actually measured on the CPU. Inside the engine's own process that cannot
//! be guaranteed twice: the QNN plugin EP registers with the process-wide ORT
//! environment at first engine init, and a "CPU" session created after that
//! registration has been observed executing on the HTP (60.8 ms for a model
//! whose true CPU pass exceeds 40 s). This function is therefore meant to run
//! in a subprocess that has never touched QNN — `cairn-detect
//! --cpu-baseline`, driven by `Cairn.Native.Canary` — where the venue is
//! structural, holds on every reload, and a timeout is a kill rather than an
//! orphaned native call.

use std::collections::HashMap;
use std::path::Path;
use std::time::Instant;

use anyhow::{bail, Context, Result};

use super::backend::{BackendKind, QnnOptions};
use super::detector::Detector;
use super::encoding::TensorValues;
use super::geometry::{Fit, InputSize};
use super::labels::{Labels, ScoreFloors};
use super::profile::ModelProfile;

/// The `passes` range [`cpu_baseline_ms`] accepts.
pub const BASELINE_PASSES: std::ops::RangeInclusive<usize> = 1..=64;

/// Median CPU model-pass latency, milliseconds: one untimed warmup (an ORT
/// session's first run pays for lazy allocations a steady-state pass does
/// not), then `passes` timed passes on a deterministic synthetic input.
///
/// Two phases on purpose, so a caller that distinguishes "the model would
/// not open" from "a pass failed" (the cairn-ort NIF's `model_load` vs
/// `infer` reasons) can map each half to its own class.
pub fn cpu_baseline_ms(
    model: &Path,
    input_size: Option<InputSize>,
    model_profile: Option<ModelProfile>,
    labels: &Labels,
    allow_label_mismatch: bool,
    passes: usize,
) -> Result<f64> {
    // Before the open: a bad pass count must not pay for a large model load
    // (or report as a load/timeout error). measure_cpu_baseline keeps its own
    // check as defense for its public entry point.
    if !BASELINE_PASSES.contains(&passes) {
        bail!(
            "cpu baseline passes must be {}..={}, got {passes}",
            BASELINE_PASSES.start(),
            BASELINE_PASSES.end()
        );
    }

    let mut detector = open_baseline_detector(
        model,
        input_size,
        model_profile,
        labels,
        allow_label_mismatch,
    )?;
    measure_cpu_baseline(&mut detector, labels, passes)
}

/// The open phase alone: a failure here is the model or the session, never
/// a pass. Loads the model's own qparams sidecar the way the serving open
/// does: a uint8-IO artifact's CPU baseline runs the same u8 contract, so
/// the D-P5 ratio compares the artifact against itself, not against a
/// float-IO sibling.
pub fn open_baseline_detector(
    model: &Path,
    input_size: Option<InputSize>,
    model_profile: Option<ModelProfile>,
    labels: &Labels,
    allow_label_mismatch: bool,
) -> Result<Detector> {
    let io_quant = super::qparams::IoQuant::load_for(model)?;
    Detector::open(
        model,
        BackendKind::Ort,
        input_size,
        model_profile,
        labels,
        allow_label_mismatch,
        QnnOptions::default(),
        io_quant,
    )
    .context("opening the CPU baseline detector")
}

/// The measurement phase alone, on an already-open detector.
pub fn measure_cpu_baseline(
    detector: &mut Detector,
    labels: &Labels,
    passes: usize,
) -> Result<f64> {
    if !BASELINE_PASSES.contains(&passes) {
        bail!(
            "cpu baseline passes must be {}..={}, got {passes}",
            BASELINE_PASSES.start(),
            BASELINE_PASSES.end()
        );
    }

    let spec = detector.input_spec();
    let size = spec.size;
    // Deterministic and not all zeros: a constant-zero tensor is exactly what
    // the letterbox pad is, and it is not this model's typical input. The
    // dtype follows the detector's resolved contract — u8 codes for a
    // uint8-IO artifact, the same cycling pattern either way.
    let tensor = match spec.input_quant {
        None => TensorValues::F32(
            (0..size.tensor_len())
                .map(|i| (i % 255) as f32 / 255.0)
                .collect(),
        ),
        Some(_) => TensorValues::U8((0..size.tensor_len()).map(|i| (i % 255) as u8).collect()),
    };
    // The identity fit: this measures the model pass alone, so the source and
    // the input rectangle are the same and nothing is scaled or offset.
    let projection = Fit {
        inner: size,
        offset: (0, 0),
        pad: 0,
    }
    .projection(size);
    let floors = ScoreFloors::from_map(HashMap::new());

    detector
        .detect(tensor.clone(), projection, labels, &floors)
        .context("the warmup pass")?;

    let mut samples = Vec::with_capacity(passes);
    for _ in 0..passes {
        let started = Instant::now();
        detector
            .detect(tensor.clone(), projection, labels, &floors)
            .context("a timed pass")?;
        samples.push(started.elapsed());
    }
    samples.sort_unstable();
    Ok(samples[samples.len() / 2].as_secs_f64() * 1000.0)
}
