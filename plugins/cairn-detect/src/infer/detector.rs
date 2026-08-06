//! The open model, and the per-frame path from a packed tensor to detections.

use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::emit::Det;

use super::backend::onnxruntime::OrtBackend;
use super::backend::{Backend, BackendKind, InputTensor, SessionOptions};
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
    /// backends: `rknn` and `qnn` have no type to be a variant of yet, and a
    /// variant nothing constructs is dead code under `-D warnings`.
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
}

impl Detector {
    /// `backend` is `--backend`, `requested` is `--input-size`, `profile` is
    /// `--model-profile`; absent, the profile is sniffed from the model's own
    /// I/O. `labels` is read to reject a class-count mismatch, which would
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
    ) -> Result<Self> {
        let options = SessionOptions::default();
        let backend: Box<dyn Backend> = match backend {
            BackendKind::Ort => Box::new(OrtBackend::open(model, &options)?),
            // The host refuses this at config load unless the profile and the
            // group both acknowledge it as experimental; this is the same
            // refusal one process later, for the argv that got here anyway.
            // Spelled out rather than a wildcard so that implementing one of
            // these — or adding a fourth kind — is a compile error here, not a
            // runtime refusal of a backend that exists.
            kind @ (BackendKind::Rknn | BackendKind::Qnn) => bail!(
                "backend {kind} is not yet implemented — only ort executes today. \
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
        let tensors = self.backend.run(input)?;
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
                eprintln!("output layout: {} (from first output)", output.layout);
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
    /// `--backend` seam, and it must fire before any model access — proven
    /// here by a path that does not exist.
    #[test]
    fn stub_backends_are_refused_before_any_model_access() {
        for (kind, artifact) in [(BackendKind::Rknn, ".rknn"), (BackendKind::Qnn, ".onnx")] {
            // Not `unwrap_err`: `Detector` has no `Debug`, deliberately.
            let err = match Detector::open(
                Path::new("does/not/exist"),
                kind,
                None,
                None,
                &Labels::load(None).unwrap(),
                false,
            ) {
                Ok(_) => panic!("stub backend {kind} opened"),
                Err(err) => err,
            };
            let msg = err.to_string();
            assert!(
                msg.contains(&format!("backend {kind} is not yet implemented")),
                "{msg}"
            );
            assert!(msg.contains(artifact), "{msg}");
        }
    }
}
