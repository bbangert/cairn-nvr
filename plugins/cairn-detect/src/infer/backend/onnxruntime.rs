//! The onnxruntime backends: CPU ([`OrtBackend`]) and Qualcomm HTP
//! ([`QnnBackend`]) — the second is the first with a different execution
//! provider appended, which is why both live here.
//!
//! This module is where `ort` types are allowed to appear. Everything it hands
//! back — [`ModelIo`], [`Raw`] — is SDK-free, so the rest of `infer` reads a
//! model's shapes and a run's tensors without naming onnxruntime.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use anyhow::{anyhow, bail, Context, Result};
use ort::environment::Environment;
use ort::session::{Session, SessionOutputs};
use ort::value::Tensor;

use super::super::heads::Raw;
use super::super::resolve::{
    declared_input_batch, declared_input_size, static_output_dims, Declared,
};
use super::{Backend, BackendKind, InputTensor, ModelIo, QnnOptions, SessionOptions, Tensors};

pub(in crate::infer) struct OrtBackend {
    session: Session,
    io: ModelIo,
    /// The input tensor, allocated on the first run and refilled in place on
    /// every later one, the way the phase-0 spike's driver reuses its one
    /// input buffer. Saves a ~2MB allocation per frame and keeps the buffer
    /// address stable for any provider that caches per-pointer state. On the
    /// QCS6490 this measured *neutral* on QNN latency — the sparse-cadence
    /// slowdown investigated there was the CPU frequency governor, not the
    /// allocation — so this stays as hygiene, not as a performance claim.
    input: Option<Tensor<f32>>,
}

impl OrtBackend {
    /// Settle [`ModelIo`] from a committed session — shared by both backends
    /// so the two cannot disagree about what a model declares.
    ///
    /// Names and shapes are read once, here, so a model with the wrong shape
    /// fails at startup with a clear message rather than by index inside the
    /// inference thread on the first frame.
    fn from_session(session: Session, model: &Path) -> Result<Self> {
        let input = session
            .inputs()
            .first()
            .ok_or_else(|| anyhow!("model {} has no inputs", model.display()))?;
        let io = ModelIo {
            input_name: input.name().to_string(),
            declared_input_size: declared_input_size(input.dtype()),
            declared_input_batch: declared_input_batch(input.dtype()),
            outputs: session
                .outputs()
                .iter()
                .map(|output| Declared {
                    name: output.name().to_string(),
                    dims: static_output_dims(output.dtype()),
                })
                .collect(),
        };
        Ok(Self {
            session,
            io,
            input: None,
        })
    }
}

impl Backend for OrtBackend {
    /// `options` carries no `ort` group: the CPU execution provider registered
    /// below is the only session setting this backend makes, and it is not a
    /// profile knob. The parameter stays in the signature because it is the
    /// trait's; [`QnnBackend::open`] is the one that reads its group.
    fn open(model: &Path, _options: &SessionOptions) -> Result<Self> {
        // ort's builder errors carry the builder itself for recovery, which
        // makes them neither Send nor Sync; flatten them to a message.
        let session = Session::builder()
            .map_err(|e| anyhow!("creating an onnxruntime session builder: {e}"))?
            .with_execution_providers([ort::ep::CPU::default().build()])
            .map_err(|e| anyhow!("registering the CPU execution provider: {e}"))?
            .commit_from_file(model)
            .with_context(|| format!("loading model {}", model.display()))?;
        Self::from_session(session, model)
    }

    fn kind(&self) -> BackendKind {
        BackendKind::Ort
    }

    fn io(&self) -> &ModelIo {
        &self.io
    }

    fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
        let tensor = match &mut self.input {
            // One model, one shape: every tensor this backend is handed has
            // the geometry settled at open, so the buffer refills in place.
            // Checked anyway, because a mismatched copy_from_slice panics.
            Some(tensor) => {
                let (shape, data) = tensor.extract_tensor_mut();
                if **shape != input.shape {
                    bail!(
                        "input tensor shape changed between runs: {:?} then {:?}",
                        &**shape,
                        input.shape
                    );
                }
                data.copy_from_slice(&input.values);
                tensor
            }
            None => self.input.insert(
                Tensor::from_array((input.shape, input.values))
                    .context("building the input tensor")?,
            ),
        };
        let outputs = self
            .session
            .run(ort::inputs![self.io.input_name.as_str() => tensor.view()])
            .context("running inference")?;
        Ok(Box::new(OrtTensors { outputs }))
    }
}

/// The name the QNN plugin execution provider registers under, fixed by the
/// provider itself: `Environment::devices` reports it per device, and the
/// per-EP option prefix `with_devices` strips is derived from it.
const QNN_EP: &str = "QNNExecutionProvider";

/// The one process-wide QNN plugin registration.
///
/// `RegisterExecutionProviderLibrary` is an environment-level call and refuses
/// a name it already knows, while this process opens up to two sessions that
/// want it (detector and, later, embedder). First open registers and records
/// the path; every later open checks it asked for the same library. A failed
/// registration is also cached — fine here, because a failed `Detector::open`
/// exits the process while the operator is still watching.
static QNN_LIBRARY: OnceLock<std::result::Result<PathBuf, String>> = OnceLock::new();

fn register_qnn_library(library: &Path) -> Result<()> {
    let registered = QNN_LIBRARY.get_or_init(|| {
        Environment::current()
            .and_then(|env| env.register_ep_library(QNN_EP, library))
            .map(|_| library.to_path_buf())
            .map_err(|e| e.to_string())
    });
    match registered {
        Ok(path) if path == library => Ok(()),
        Ok(path) => bail!(
            "QNN EP library already registered from {} — cannot re-register as {}",
            path.display(),
            library.display()
        ),
        Err(e) => bail!("registering the QNN EP library {}: {e}", library.display()),
    }
}

/// Qualcomm HTP, as an onnxruntime session whose execution provider comes from
/// a plugin library rather than from the onnxruntime build.
///
/// The recipe is the phase-0 spike's (`tools/qnn-spike/README.md`): register
/// `--qnn-library` with the environment, find the device the plugin exposes,
/// and append it to the session with `backend_type=htp` plus the profile's
/// knobs. The model must be a full-op-coverage QDQ export — a conv-island
/// int8 or fp32 graph fails HTP validation at open.
///
/// Wraps [`OrtBackend`] because after `commit_from_file` the two are the same
/// thing: a session, run one tensor at a time.
pub(in crate::infer) struct QnnBackend(OrtBackend);

impl Backend for QnnBackend {
    fn open(model: &Path, options: &SessionOptions) -> Result<Self> {
        let qnn = &options.qnn;
        let library = qnn.library.as_deref().ok_or_else(|| {
            anyhow!("--backend qnn needs --qnn-library, the QNN plugin EP library (libonnxruntime_providers_qnn.so)")
        })?;
        register_qnn_library(library)?;

        // The registration succeeding is not the guard: a library that loads
        // but finds no NPU registers cleanly and exposes no device. Requiring
        // the device to exist here is what makes "QNN unavailable" a startup
        // error instead of a session that silently built for the CPU.
        let env = Environment::current()
            .map_err(|e| anyhow!("getting the onnxruntime environment: {e}"))?;
        let devices: Vec<_> = env
            .devices()
            .filter(|device| device.ep().is_ok_and(|name| name == QNN_EP))
            .collect();
        if devices.is_empty() {
            bail!(
                "QNN EP library {} registered but exposed no device — \
                 HTP is unavailable on this host, refusing to fall back to CPU",
                library.display()
            );
        }

        let ep_options = qnn_ep_options(qnn);
        eprintln!(
            "qnn: {} device(s) from {}, options [{}]; note: per-node CPU fallback \
             is still possible after open — only a latency delta vs the cpu \
             backend proves HTP execution (D-P5)",
            devices.len(),
            library.display(),
            ep_options
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(" ")
        );

        let session = Session::builder()
            .map_err(|e| anyhow!("creating an onnxruntime session builder: {e}"))?
            .with_devices(devices, Some(&ep_options))
            .map_err(|e| anyhow!("appending the QNN execution provider: {e}"))?
            .commit_from_file(model)
            .with_context(|| {
                format!(
                    "loading model {} on QNN/HTP (is it a full-op-coverage QDQ export?)",
                    model.display()
                )
            })?;
        Ok(Self(OrtBackend::from_session(session, model)?))
    }

    fn kind(&self) -> BackendKind {
        BackendKind::Qnn
    }

    fn io(&self) -> &ModelIo {
        self.0.io()
    }

    fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
        self.0.run(input)
    }
}

/// [`QnnOptions`] as the `EP.key=value` pairs `with_devices` forwards, keys
/// per the spike's working invocation (`tools/qnn-spike/run_spike.sh`).
///
/// `backend_type=htp` is unconditional: it selects which QNN backend library
/// the provider drives, and HTP is the only one this plugin targets.
fn qnn_ep_options(qnn: &QnnOptions) -> Vec<(String, String)> {
    let mut options = vec![(format!("{QNN_EP}.backend_type"), "htp".to_string())];
    let mut push = |key: &str, value: Option<String>| {
        if let Some(value) = value {
            options.push((format!("{QNN_EP}.{key}"), value));
        }
    };
    push("soc_model", qnn.soc_model.map(|v| v.to_string()));
    push("htp_arch", qnn.htp_arch.map(|v| v.to_string()));
    push("htp_performance_mode", qnn.performance_mode.clone());
    push("vtcm_mb", qnn.vtcm_mb.map(|v| v.to_string()));
    options
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
