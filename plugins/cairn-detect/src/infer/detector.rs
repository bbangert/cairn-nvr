//! The ONNX session, and the per-frame path from a packed tensor to detections.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use ort::session::Session;
use ort::value::Tensor;

use crate::emit::Det;

use super::geometry::{InputSize, Projection};
use super::heads::{candidates_from, finish};
use super::labels::{check_label_count, Labels, ScoreFloors};
use super::profile::InputSpec;
use super::profile::{InputSizeSource, ModelProfile, OutputSpec, Outputs};
use super::resolve::{
    check_grid_divides_input, declared_input_size, fit_output, resolve_input_size, resolve_profile,
    static_output_dims, validate_layout, Declared,
};

pub struct Detector {
    session: Session,
    input_name: String,
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
    /// `requested` is `--input-size`, `profile` is `--model-profile`; absent,
    /// the profile is sniffed from the model's own I/O. `labels` is read to
    /// reject a class-count mismatch, which would mislabel every detection.
    pub fn open(
        model: &Path,
        requested: Option<InputSize>,
        profile: Option<ModelProfile>,
        labels: &Labels,
        allow_label_mismatch: bool,
    ) -> Result<Self> {
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
        let (input_size, input_size_source) = resolve_input_size(
            declared_input_size(input.dtype()),
            requested,
            profile,
            model,
        )?;
        let declared: Vec<Declared> = session
            .outputs()
            .iter()
            .map(|output| Declared {
                name: output.name().to_string(),
                dims: static_output_dims(output.dtype()),
            })
            .collect();
        if declared.is_empty() {
            bail!("model {} has no outputs", model.display());
        }
        let (profile, outputs, output) = resolve_profile(profile, &declared, input_size, model)?;
        check_grid_divides_input(profile.output.layout, input_size)?;
        if let Some(output) = output {
            check_label_count(output.layout, labels, allow_label_mismatch)?;
        }
        Ok(Self {
            session,
            input_name,
            outputs,
            profile,
            input_size,
            input_size_source,
            output,
            allow_label_mismatch,
        })
    }

    pub fn input_name(&self) -> &str {
        &self.input_name
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
        let shape = [1i64, 3, self.input_size.h as i64, self.input_size.w as i64];
        let input = Tensor::from_array((shape, tensor)).context("building the input tensor")?;
        let outputs = self
            .session
            .run(ort::inputs![self.input_name.as_str() => input])
            .context("running inference")?;
        // Extract every role this profile reads, by the name settled at
        // startup, so a two-tensor family never depends on output ordering.
        let extract = |name: &String| -> Result<Raw> {
            let (shape, values) = outputs
                .get(name.as_str())
                .ok_or_else(|| anyhow!("model produced no output named {name}"))?
                .try_extract_tensor::<f32>()
                .with_context(|| format!("model output {name} is not an f32 tensor"))?;
            Ok(Raw {
                dims: shape.iter().copied().collect(),
                values,
            })
        };
        let raw = match &self.outputs {
            Outputs::One(name) => Outputs::One(extract(name)?),
            Outputs::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: extract(boxes)?,
                logits: extract(logits)?,
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
