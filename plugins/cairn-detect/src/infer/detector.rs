//! The open model, and the per-frame path from a packed tensor to detections.

use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::emit::Det;
use crate::note;

use super::backend::onnxruntime::{OrtBackend, QnnBackend};
use super::backend::{Backend, BackendKind, InputTensor, QnnOptions, SessionOptions};
use super::geometry::{InputSize, Projection};
use super::heads::{decode_output, Raw};
use super::labels::{check_label_count, Labels, ScoreFloors};
use super::profile::InputSpec;
use super::profile::{InputSizeSource, ModelProfile, OutputSpec, Outputs};
use super::resolve::{
    check_grid_divides_input, fit_output, resolve_input_size, resolve_profile, Declared,
};

pub struct Detector {
    /// The runtime holding the open model. Boxed rather than an enum over the
    /// backends: `rknn` has no type to be a variant of yet, and a variant
    /// nothing constructs is dead code under `-D warnings`.
    backend: Box<dyn Backend>,
    /// The model's own name for each tensor this profile's layout reads,
    /// settled at startup so a decode never looks one up by index.
    outputs: Outputs<String>,
    profile: ModelProfile,
    input_size: InputSize,
    input_size_source: InputSizeSource,
    /// `None` until the first output settles `nc`, which only happens for an
    /// export that leaves its output shape dynamic.
    output: Option<OutputSpec>,
    /// `--allow-label-mismatch`, carried because a deferred layout only
    /// settles `nc` on the first real output — see [`check_label_count`].
    allow_label_mismatch: bool,
    latency: LatencyWindow,
}

/// Rolling window over raw inference latency, reported to stderr once per
/// [`LatencyWindow::REPORT_EVERY`] runs.
///
/// This is the plugin's only latency surface, and it exists because of D-P5:
/// on QNN hardware, both known failure modes (whole-session CPU fallback,
/// degraded DSP memory) produce clean logs and correct detections — the only
/// observable difference is the per-run latency, so the plugin has to say
/// what its runs actually cost. On the CPU backend the same line is the
/// number the QNN delta is measured against.
struct LatencyWindow {
    window: Vec<Duration>,
    total_runs: u64,
}

impl LatencyWindow {
    /// Small enough to report within seconds at bench rates, large enough
    /// that p95 is the 95th of a real distribution rather than of noise.
    const REPORT_EVERY: usize = 100;

    fn new() -> Self {
        Self {
            window: Vec::with_capacity(Self::REPORT_EVERY),
            total_runs: 0,
        }
    }

    /// Records one run; on the report boundary, prints and resets the window.
    fn record(&mut self, elapsed: Duration, kind: BackendKind) {
        self.total_runs += 1;
        self.window.push(elapsed);
        if self.window.len() < Self::REPORT_EVERY {
            return;
        }
        self.window.sort_unstable();
        let (p50, p95) = (self.percentile(50), self.percentile(95));
        note!(
            "infer latency: backend={kind} n={} p50={:.2}ms p95={:.2}ms (total {})",
            self.window.len(),
            p50.as_secs_f64() * 1000.0,
            p95.as_secs_f64() * 1000.0,
            self.total_runs,
        );
        self.window.clear();
    }

    /// Nearest-rank percentile of the *sorted* window; only `record` calls
    /// this, after sorting and before clearing.
    fn percentile(&self, pct: usize) -> Duration {
        let rank = (self.window.len() * pct).div_ceil(100);
        self.window[rank.saturating_sub(1)]
    }
}

impl Detector {
    /// `backend` is `--backend`, `requested` is `--input-size`, `profile` is
    /// `--model-profile`, `qnn` is the `--qnn-*` flags (read only when
    /// `backend` is `qnn`); absent, the profile is sniffed from the model's
    /// own I/O. `labels` is read to reject a class-count mismatch, which would
    /// mislabel every detection.
    ///
    /// Everything after the backend opens is backend-agnostic: the size and
    /// profile resolution below read a [`ModelIo`](super::backend::ModelIo),
    /// which is the model's declared names and shapes with no SDK type in it.
    pub fn open(
        model: &Path,
        backend: BackendKind,
        requested: Option<InputSize>,
        profile: Option<ModelProfile>,
        labels: &Labels,
        allow_label_mismatch: bool,
        qnn: QnnOptions,
    ) -> Result<Self> {
        let options = SessionOptions {
            qnn,
            ..SessionOptions::default()
        };
        let backend: Box<dyn Backend> = match backend {
            BackendKind::Ort => Box::new(OrtBackend::open(model, &options)?),
            BackendKind::Qnn => Box::new(QnnBackend::open(model, &options)?),
            // The host refuses this at config load unless the profile and the
            // group both acknowledge it as experimental; this is the same
            // refusal one process later, for the argv that got here anyway.
            // Spelled out rather than a wildcard so that implementing it — or
            // adding a fourth kind — is a compile error here, not a runtime
            // refusal of a backend that exists.
            kind @ BackendKind::Rknn => bail!(
                "backend {kind} is not yet implemented — only ort and qnn execute today. \
                 Its expected artifact is {} (see --backend).",
                kind.capabilities().artifact
            ),
        };
        let io = backend.io();
        let (input_size, input_size_source) =
            resolve_input_size(io.declared_input_size, requested, profile, model)?;
        let declared: &[Declared] = &io.outputs;
        if declared.is_empty() {
            bail!("model {} has no outputs", model.display());
        }
        let (profile, outputs, output) = resolve_profile(profile, declared, input_size, model)?;
        check_grid_divides_input(profile.output.layout, input_size)?;
        if let Some(output) = output {
            check_label_count(output.layout, labels, allow_label_mismatch)?;
        }
        Ok(Self {
            backend,
            outputs,
            profile,
            input_size,
            input_size_source,
            output,
            allow_label_mismatch,
            latency: LatencyWindow::new(),
        })
    }

    pub fn input_name(&self) -> &str {
        &self.backend.io().input_name
    }

    /// Startup description of the runtime that opened this model and what it
    /// accepts — rendered here, like [`Detector::layout_summary`], so
    /// `Capabilities` stays inside `infer` and main.rs prints rather than
    /// interprets it.
    pub fn backend_summary(&self) -> String {
        format!(
            "{} ({})",
            self.backend.kind(),
            self.backend.kind().capabilities()
        )
    }

    pub fn profile(&self) -> ModelProfile {
        self.profile
    }

    /// Everything a decoder needs to build a tensor this model accepts,
    /// with the size the *model* resolved to rather than the profile default.
    pub fn input_spec(&self) -> InputSpec {
        InputSpec {
            size: self.input_size,
            ..self.profile.input
        }
    }

    pub fn input_size_source(&self) -> InputSizeSource {
        self.input_size_source
    }

    /// Startup description of the output layout, deferred when the export
    /// leaves its output shape dynamic.
    pub fn layout_summary(&self) -> String {
        match self.output {
            Some(output) => format!("{} (from model)", output.layout),
            None => format!("{} (nc from first output)", self.profile.output.layout),
        }
    }

    pub fn detect(
        &mut self,
        tensor: Vec<f32>,
        projection: Projection,
        labels: &Labels,
        floors: &ScoreFloors,
    ) -> Result<Vec<Det>> {
        let input = InputTensor {
            shape: [1i64, 3, self.input_size.h as i64, self.input_size.w as i64],
            values: tensor,
        };
        // Timed around `run` alone — the model pass plus the copy of this
        // frame's values into the session's input, no decode — so the number
        // compares across backends (both pay the same copy). `kind` is read
        // first: the returned tensors keep `backend` mutably borrowed.
        let kind = self.backend.kind();
        let started = Instant::now();
        let tensors = self.backend.run(input)?;
        self.latency.record(started.elapsed(), kind);
        // Extract every role this profile reads, by the name settled at
        // startup, so a two-tensor family never depends on output ordering.
        let raw: Outputs<Raw> = match &self.outputs {
            Outputs::One(name) => Outputs::One(tensors.get(name)?),
            Outputs::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: tensors.get(boxes)?,
                logits: tensors.get(logits)?,
            },
        };
        let shapes = raw.map(|tensor| tensor.dims.clone());
        let output = match self.output {
            Some(output) => output,
            None => {
                let output = fit_output(self.profile.output, &shapes, self.input_size)
                    .with_context(|| format!("--model-profile {}", self.profile))?;
                check_label_count(output.layout, labels, self.allow_label_mismatch)?;
                note!("output layout: {} (from first output)", output.layout);
                self.output = Some(output);
                output
            }
        };
        decode_output(output, &raw, labels, floors, self.input_size, &projection)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The stub refusal is the whole operator-visible behaviour of the
    /// `--backend` seam for a backend that has not landed, and it must fire
    /// before any model access — proven here by a path that does not exist.
    #[test]
    fn stub_backend_is_refused_before_any_model_access() {
        // Not `unwrap_err`: `Detector` has no `Debug`, deliberately.
        let err = match Detector::open(
            Path::new("does/not/exist"),
            BackendKind::Rknn,
            None,
            None,
            &Labels::load(None).unwrap(),
            false,
            QnnOptions::default(),
        ) {
            Ok(_) => panic!("stub backend rknn opened"),
            Err(err) => err,
        };
        let msg = err.to_string();
        assert!(msg.contains("backend rknn is not yet implemented"), "{msg}");
        assert!(msg.contains(".rknn"), "{msg}");
    }

    /// The report/reset boundary, driven through `record` itself rather than
    /// a hand-built window: exactly `REPORT_EVERY` runs empty the window (a
    /// broken reset would grow without bound and report stale runs), and the
    /// lifetime total keeps counting across the reset.
    #[test]
    fn latency_window_reports_and_resets_on_the_boundary() {
        let mut window = LatencyWindow::new();
        for run in 0..(LatencyWindow::REPORT_EVERY * 2 + 3) {
            window.record(Duration::from_millis(run as u64), BackendKind::Ort);
            let filled = (run + 1) % LatencyWindow::REPORT_EVERY;
            assert_eq!(window.window.len(), filled, "after run {run}");
        }
        assert_eq!(
            window.total_runs,
            (LatencyWindow::REPORT_EVERY * 2 + 3) as u64
        );
        assert_eq!(window.window.len(), 3);
    }

    /// Nearest-rank on a known distribution: for 1..=100 ms sorted, p50 is
    /// the 50th value and p95 the 95th — off-by-one here would misreport
    /// every latency line the D-P5 check reads.
    #[test]
    fn latency_percentiles_are_nearest_rank() {
        let mut window = LatencyWindow::new();
        window.window = (1..=100).map(Duration::from_millis).collect();
        assert_eq!(window.percentile(50), Duration::from_millis(50));
        assert_eq!(window.percentile(95), Duration::from_millis(95));
        assert_eq!(window.percentile(100), Duration::from_millis(100));

        // A window one short of the report boundary: ranks still in bounds.
        window.window = (1..=99).map(Duration::from_millis).collect();
        assert_eq!(window.percentile(50), Duration::from_millis(50));
        assert_eq!(window.percentile(100), Duration::from_millis(99));
    }

    /// `qnn` without `--qnn-library` must fail on the missing flag, not on
    /// the model path: the EP comes from a plugin library, and there is
    /// nothing to open a session with until one is named.
    #[test]
    fn qnn_without_library_is_refused_before_any_model_access() {
        let err = match Detector::open(
            Path::new("does/not/exist"),
            BackendKind::Qnn,
            None,
            None,
            &Labels::load(None).unwrap(),
            false,
            QnnOptions::default(),
        ) {
            Ok(_) => panic!("qnn opened without a library"),
            Err(err) => err,
        };
        let msg = err.to_string();
        assert!(msg.contains("--qnn-library"), "{msg}");
    }
}
