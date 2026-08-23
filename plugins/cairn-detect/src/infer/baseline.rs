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
use super::geometry::{Fit, InputSize};
use super::labels::{Labels, ScoreFloors};
use super::profile::ModelProfile;

/// The `passes` range [`cpu_baseline_ms`] accepts.
pub const BASELINE_PASSES: std::ops::RangeInclusive<usize> = 1..=64;

/// Median CPU model-pass latency, milliseconds: one untimed warmup (an ORT
/// session's first run pays for lazy allocations a steady-state pass does
/// not), then `passes` timed passes on a deterministic synthetic input.
pub fn cpu_baseline_ms(
    model: &Path,
    input_size: Option<InputSize>,
    model_profile: Option<ModelProfile>,
    labels: &Labels,
    allow_label_mismatch: bool,
    passes: usize,
) -> Result<f64> {
    if !BASELINE_PASSES.contains(&passes) {
        bail!(
            "cpu baseline passes must be {}..={}, got {passes}",
            BASELINE_PASSES.start(),
            BASELINE_PASSES.end()
        );
    }

    let mut detector = Detector::open(
        model,
        BackendKind::Ort,
        input_size,
        model_profile,
        labels,
        allow_label_mismatch,
        QnnOptions::default(),
    )
    .context("opening the CPU baseline detector")?;

    let size = detector.input_spec().size;
    // Deterministic and not all zeros: a constant-zero tensor is exactly what
    // the letterbox pad is, and it is not this model's typical input.
    let tensor: Vec<f32> = (0..size.tensor_len())
        .map(|i| (i % 255) as f32 / 255.0)
        .collect();
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
