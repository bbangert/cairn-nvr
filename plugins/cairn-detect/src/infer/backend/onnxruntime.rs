//! The onnxruntime backend: the only one that executes.
//!
//! This module is where `ort` types are allowed to appear. Everything it hands
//! back — [`ModelIo`], [`Raw`] — is SDK-free, so the rest of `infer` reads a
//! model's shapes and a run's tensors without naming onnxruntime.

use std::path::Path;

use anyhow::{anyhow, Context, Result};
use ort::session::{Session, SessionOutputs};
use ort::value::Tensor;

use super::super::heads::Raw;
use super::super::resolve::{declared_input_size, static_output_dims, Declared};
use super::{Backend, BackendKind, InputTensor, ModelIo, SessionOptions, Tensors};

pub(in crate::infer) struct OrtBackend {
    session: Session,
    io: ModelIo,
}

impl Backend for OrtBackend {
    /// `options` carries no `ort` group: the CPU execution provider registered
    /// below is the only session setting this backend makes, and it is not a
    /// profile knob. The parameter stays in the signature because it is the
    /// trait's, and because an ort group is where a future `--backend qnn`
    /// would register its execution provider instead.
    fn open(model: &Path, _options: &SessionOptions) -> Result<Self> {
        // ort's builder errors carry the builder itself for recovery, which
        // makes them neither Send nor Sync; flatten them to a message.
        let session = Session::builder()
            .map_err(|e| anyhow!("creating an onnxruntime session builder: {e}"))?
            .with_execution_providers([ort::ep::CPU::default().build()])
            .map_err(|e| anyhow!("registering the CPU execution provider: {e}"))?
            .commit_from_file(model)
            .with_context(|| format!("loading model {}", model.display()))?;
        // Names and shapes are read once, here, so a model with the wrong shape
        // fails at startup with a clear message rather than by index inside the
        // inference thread on the first frame.
        let input = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no inputs", model.display()))?;
        let io = ModelIo {
            input_name: input.name().to_string(),
            declared_input_size: declared_input_size(input.dtype()),
            outputs: session
                .outputs()
                .iter()
                .map(|output| Declared {
                    name: output.name().to_string(),
                    dims: static_output_dims(output.dtype()),
                })
                .collect(),
        };
        Ok(Self { session, io })
    }

    fn kind(&self) -> BackendKind {
        BackendKind::Ort
    }

    fn io(&self) -> &ModelIo {
        &self.io
    }

    fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
        let tensor =
            Tensor::from_array((input.shape, input.values)).context("building the input tensor")?;
        let outputs = self
            .session
            .run(ort::inputs![self.io.input_name.as_str() => tensor])
            .context("running inference")?;
        Ok(Box::new(OrtTensors { outputs }))
    }
}

/// One run's `SessionOutputs`, which borrow the session they came out of —
/// hence the lifetime, and hence [`Backend::run`] returning a handle rather
/// than owned buffers.
struct OrtTensors<'s> {
    outputs: SessionOutputs<'s>,
}

impl Tensors for OrtTensors<'_> {
    fn get(&self, name: &str) -> Result<Raw<'_>> {
        let (shape, values) = self
            .outputs
            .get(name)
            .ok_or_else(|| anyhow!("model produced no output named {name}"))?
            .try_extract_tensor::<f32>()
            .with_context(|| format!("model output {name} is not an f32 tensor"))?;
        Ok(Raw {
            dims: shape.iter().copied().collect(),
            values,
        })
    }
}
