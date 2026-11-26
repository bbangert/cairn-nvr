//! The open model, and the per-frame path from a packed tensor to detections.

use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::emit::Det;
use crate::note;

use super::backend::onnxruntime::{OrtBackend, QnnBackend};
use super::backend::{
    Backend, BackendKind, InputElement, InputTensor, ModelIo, QnnOptions, SessionOptions,
};
use super::encoding::TensorValues;
use super::geometry::{InputSize, Projection};
use super::heads::{decode_output, Raw};
use super::labels::{check_label_count, Labels, ScoreFloors};
use super::profile::InputSpec;
use super::profile::{InputSizeSource, ModelProfile, OutputSpec, Outputs};
use super::qparams::IoQuant;
use super::resolve::{
    check_grid_divides_input, fit_output, resolve_input_size, resolve_profile, Declared,
};

pub struct Detector {
    /// The runtime holding the open model. Boxed rather than an enum over the
    /// backends: a board library's backend is a type this crate never sees.
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
    /// Shared by every detector `cairn-ort`'s engine holds on one model
    /// ([`Detector::share_latency_with`]): the line is the engine's per-run
    /// cost, and one window per slot would print K lines each over a share of
    /// the runs. Its lock is a leaf: nothing is taken under it.
    latency: Arc<Mutex<LatencyWindow>>,
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
    fn record(&mut self, elapsed: Duration, backend: &str) {
        self.total_runs += 1;
        self.window.push(elapsed);
        if self.window.len() < Self::REPORT_EVERY {
            return;
        }
        self.window.sort_unstable();
        let (p50, p95) = (self.percentile(50), self.percentile(95));
        note!(
            "infer latency: backend={backend} n={} p50={:.2}ms p95={:.2}ms (total {})",
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
    /// mislabel every detection. `io_quant` is the model's qparams sidecar
    /// when the caller loaded one ([`IoQuant::load_for`]) — required by a
    /// uint8-IO artifact, refused next to a float one, checked against the
    /// session's sniffed dtypes either way.
    ///
    /// Opens only the backends this crate carries; the rest is
    /// [`Detector::with_backend`].
    #[allow(clippy::too_many_arguments)]
    pub fn open(
        model: &Path,
        backend: BackendKind,
        requested: Option<InputSize>,
        profile: Option<ModelProfile>,
        labels: &Labels,
        allow_label_mismatch: bool,
        qnn: QnnOptions,
        io_quant: Option<IoQuant>,
    ) -> Result<Self> {
        let options = SessionOptions { qnn, io_quant };
        let backend: Box<dyn Backend> = match backend {
            BackendKind::Ort => Box::new(OrtBackend::open(model, &options)?),
            BackendKind::Qnn => Box::new(QnnBackend::open(model, &options)?),
        };
        Self::with_backend(
            backend,
            model,
            requested,
            profile,
            labels,
            allow_label_mismatch,
            options.io_quant.as_ref(),
        )
    }

    /// Everything after the backend opens, for a backend opened anywhere —
    /// this crate's, through [`Detector::open`], or a board library's. It is
    /// backend-agnostic: the size and profile resolution below read a
    /// [`ModelIo`], which is the model's declared names and shapes with no SDK
    /// type in it.
    ///
    /// `model` names the artifact, and its sidecar's path, in errors; it is
    /// never opened here. `io_quant` must be the sidecar the backend was
    /// opened with — the one its [`SessionOptions::io_quant`] carried —
    /// since the backend dequantizes by it and, for an
    /// [`InputElement::U8Codes`] input, the packer quantizes by it.
    pub fn with_backend(
        backend: Box<dyn Backend>,
        model: &Path,
        requested: Option<InputSize>,
        profile: Option<ModelProfile>,
        labels: &Labels,
        allow_label_mismatch: bool,
        io_quant: Option<&IoQuant>,
    ) -> Result<Self> {
        let io = backend.io();
        check_io_quant(io, io_quant, model)?;
        let (input_size, input_size_source) =
            resolve_input_size(io.declared_input_size, requested, profile, model)?;
        let declared: &[Declared] = &io.outputs;
        if declared.is_empty() {
            bail!("model {} has no outputs", model.display());
        }
        let (mut profile, outputs, output) = resolve_profile(profile, declared, input_size, model)?;
        // The input qparams and the backend's layout ride the resolved spec
        // so the packer — on either side of `input_spec()` — packs for the
        // artifact that opened, never for a profile default. Pixel bytes are
        // the quantized packer under the encoding's identity qparams, so
        // `InputSpec` and the NIF wire carry no third element kind.
        profile.input.input_quant = match io.input_element {
            InputElement::F32 | InputElement::U8Codes => {
                io_quant.and_then(|quant| quant.input.as_ref().map(|(_, qp)| *qp))
            }
            InputElement::U8Pixels => {
                Some(profile.input.encoding.pixel_quant().with_context(|| {
                    format!(
                        "model {} takes pixel bytes, which profile {} ({}) cannot be fed as",
                        model.display(),
                        profile.name,
                        profile.input.encoding
                    )
                })?)
            }
        };
        profile.input.layout = io.input_layout;
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
            latency: Arc::new(Mutex::new(LatencyWindow::new())),
        })
    }

    /// Report this detector's runs in `first`'s latency window, not its own.
    pub fn share_latency_with(&mut self, first: &Detector) {
        self.latency = Arc::clone(&first.latency);
    }

    /// [`Backend::sibling`] of the backend this detector runs on.
    pub fn sibling_backend(&mut self) -> Result<Option<Box<dyn Backend>>> {
        self.backend.sibling()
    }

    pub fn input_name(&self) -> &str {
        &self.backend.io().input_name
    }

    /// Startup description of the runtime that opened this model and what it
    /// accepts — rendered here, like [`Detector::layout_summary`], so
    /// `cli.rs` prints rather than interprets it.
    pub fn backend_summary(&self) -> String {
        let descriptor = self.backend.descriptor();
        format!("{} ({})", descriptor.name, descriptor.capabilities)
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
            None => format!("{} (counts from first output)", self.profile.output.layout),
        }
    }

    pub fn detect(
        &mut self,
        tensor: TensorValues,
        projection: Projection,
        labels: &Labels,
        floors: &ScoreFloors,
    ) -> Result<Vec<Det>> {
        // The packer chooses the dtype from this detector's own resolved
        // spec, so a mismatch here is a caller that packed for a different
        // model — refused before the session turns it into a bind error.
        match (&tensor, self.profile.input.input_quant) {
            (TensorValues::U8(_), None) => {
                bail!("u8 input codes packed for a float-input model")
            }
            (TensorValues::F32(_), Some(_)) => {
                bail!("f32 input packed for a uint8-input model")
            }
            _ => {}
        }
        let spec = self.input_spec();
        let input = InputTensor::new(spec.size, spec.layout, tensor);
        // Timed around `run` alone — the model pass plus the copy of this
        // frame's values into the session's input (plus, for a uint8-IO
        // artifact, the output dequant the graph's stripped DequantizeLinear
        // used to do), no decode — so the number compares across backends
        // and across the float/u8 contracts. `name` is read first: the
        // returned tensors keep `backend` mutably borrowed.
        let name = self.backend.descriptor().name;
        let started = Instant::now();
        let tensors = self.backend.run(input)?;
        let elapsed = started.elapsed();
        self.latency
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .record(elapsed, name);
        // Extract every role this profile reads, by the name settled at
        // startup, so a multi-tensor family never depends on output ordering.
        let raw: Outputs<Raw> = match &self.outputs {
            Outputs::One(name) => Outputs::One(tensors.get(name)?),
            Outputs::BoxesAndLogits { boxes, logits } => Outputs::BoxesAndLogits {
                boxes: tensors.get(boxes)?,
                logits: tensors.get(logits)?,
            },
            Outputs::Split { boxes, scores } => {
                let levels = |names: &[String; 3]| -> Result<[Raw; 3]> {
                    Ok([
                        tensors.get(&names[0])?,
                        tensors.get(&names[1])?,
                        tensors.get(&names[2])?,
                    ])
                };
                Outputs::Split {
                    boxes: levels(boxes)?,
                    scores: levels(scores)?,
                }
            }
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

/// A uint8-IO artifact and its sidecar must describe each other exactly,
/// judged against the session's *sniffed* dtypes rather than either one's
/// claim. Refused at open: a u8-code input with no qparams (nothing
/// downstream could quantize it), input qparams next to a float or a
/// pixel-byte input (a sidecar for some other artifact — quantizing anyway
/// would corrupt every value), an input-name mismatch (same failure, caught
/// by name), and an output set the sidecar does not cover exactly.
fn check_io_quant(io: &ModelIo, quant: Option<&IoQuant>, model: &Path) -> Result<()> {
    let input_quant = quant.and_then(|quant| quant.input.as_ref());
    match (io.input_element, input_quant) {
        (InputElement::U8Codes, None) => bail!(
            "model {} declares a uint8 input but its qparams sidecar ({}) {} — \
             re-export with u8_io_surgery.py, which writes both",
            model.display(),
            IoQuant::sidecar_path(model).display(),
            if quant.is_some() {
                "carries no input entry"
            } else {
                "is missing"
            }
        ),
        (InputElement::F32, Some(_)) => bail!(
            "qparams sidecar declares input quantization but model {} takes float input — \
             wrong sidecar, or wrong artifact",
            model.display()
        ),
        (InputElement::U8Pixels, Some(_)) => bail!(
            "qparams sidecar declares input quantization but model {} takes pixel bytes \
             (its runtime quantizes them) — wrong sidecar, or wrong artifact",
            model.display()
        ),
        (InputElement::U8Codes, Some((name, _))) if *name != io.input_name => bail!(
            "qparams sidecar quantizes input {name:?} but model {} calls its input {:?}",
            model.display(),
            io.input_name
        ),
        _ => {}
    }
    let mut declared: Vec<&str> = io.u8_outputs.iter().map(String::as_str).collect();
    let mut sidecar: Vec<&str> = quant
        .map(|quant| quant.outputs.keys().map(String::as_str).collect())
        .unwrap_or_default();
    declared.sort_unstable();
    sidecar.sort_unstable();
    if declared != sidecar {
        bail!(
            "model {} declares uint8 outputs [{}] but the qparams sidecar covers [{}]",
            model.display(),
            declared.join(", "),
            sidecar.join(", ")
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::backend::{Capabilities, Descriptor, Tensors};
    use super::super::encoding::TensorLayout;
    use super::*;

    /// The refusal matrix the u8-input open-time safety rests on,
    /// driven directly: it is a pure function over sniffed IO and the
    /// sidecar, so every arm is pinned without a model file.
    #[test]
    fn check_io_quant_covers_the_refusal_matrix() {
        use super::super::encoding::QuantParams;

        let model = Path::new("m.onnx");
        let qp = QuantParams::new(1.0, 0).unwrap();
        let io = |input_element: InputElement, u8_outputs: &[&str]| ModelIo {
            input_name: "images".to_string(),
            declared_input_size: None,
            declared_input_batch: None,
            outputs: Vec::new(),
            input_element,
            u8_outputs: u8_outputs.iter().map(|s| s.to_string()).collect(),
            input_layout: TensorLayout::Nchw,
        };
        let quant = |input: Option<&str>, outputs: &[&str]| IoQuant {
            input: input.map(|name| (name.to_string(), qp)),
            outputs: outputs.iter().map(|s| (s.to_string(), qp)).collect(),
        };

        // Float model, no sidecar: the ordinary case.
        assert!(check_io_quant(&io(InputElement::F32, &[]), None, model).is_ok());
        // The full u8io shape, sidecar agreeing on name and output set.
        let full = quant(Some("images"), &["output"]);
        assert!(
            check_io_quant(&io(InputElement::U8Codes, &["output"]), Some(&full), model).is_ok()
        );
        // Output-only conversion: float input plus a u8-output sidecar.
        let out_only = quant(None, &["output"]);
        assert!(
            check_io_quant(&io(InputElement::F32, &["output"]), Some(&out_only), model).is_ok()
        );

        // u8 input with no sidecar at all — the orphan-artifact case.
        let err = check_io_quant(&io(InputElement::U8Codes, &[]), None, model).unwrap_err();
        assert!(err.to_string().contains("is missing"), "{err}");
        // Sidecar quantizing the input of a float artifact — wrong sidecar.
        let err = check_io_quant(
            &io(InputElement::F32, &[]),
            Some(&quant(Some("images"), &[])),
            model,
        )
        .unwrap_err();
        assert!(err.to_string().contains("takes float input"), "{err}");
        // Input-name mismatch — a sidecar for some other model.
        let err = check_io_quant(
            &io(InputElement::U8Codes, &["output"]),
            Some(&quant(Some("input"), &["output"])),
            model,
        )
        .unwrap_err();
        assert!(err.to_string().contains("calls its input"), "{err}");
        // Output-set mismatch, both directions through one sorted compare.
        let err = check_io_quant(
            &io(InputElement::U8Codes, &["output"]),
            Some(&quant(Some("images"), &[])),
            model,
        )
        .unwrap_err();
        assert!(err.to_string().contains("uint8 outputs"), "{err}");
        let err = check_io_quant(&io(InputElement::F32, &[]), Some(&out_only), model).unwrap_err();
        assert!(err.to_string().contains("uint8 outputs"), "{err}");

        // Pixel bytes: no sidecar is the normal case, an input entry is a
        // sidecar for another artifact, and outputs are still held to it.
        let pixels = |u8_outputs| io(InputElement::U8Pixels, u8_outputs);
        assert!(check_io_quant(&pixels(&[]), None, model).is_ok());
        let err =
            check_io_quant(&pixels(&[]), Some(&quant(Some("images"), &[])), model).unwrap_err();
        assert!(err.to_string().contains("takes pixel bytes"), "{err}");
        assert!(check_io_quant(&pixels(&["output"]), Some(&out_only), model).is_ok());
        let err = check_io_quant(&pixels(&[]), Some(&out_only), model).unwrap_err();
        assert!(err.to_string().contains("uint8 outputs"), "{err}");
    }

    type Seen = std::sync::Arc<std::sync::Mutex<Vec<([i64; 4], TensorLayout)>>>;

    /// A backend opened outside this crate, over a 96x64 yolox-shaped model.
    /// Every run's input shape is recorded in `seen`, and every output is
    /// zeros — no detections, only the plumbing.
    struct FakeBackend {
        io: ModelIo,
        output: Vec<f32>,
        seen: Seen,
    }

    struct FakeTensors<'a>(&'a [f32]);

    impl Tensors for FakeTensors<'_> {
        fn get(&self, _name: &str) -> Result<Raw<'_>> {
            Ok(Raw {
                dims: vec![1, 126, 85],
                values: self.0,
            })
        }
    }

    impl Backend for FakeBackend {
        fn open(_: &Path, _: &SessionOptions) -> Result<Self> {
            unreachable!("built directly")
        }
        fn descriptor(&self) -> &'static Descriptor {
            static FAKE: Descriptor = Descriptor {
                name: "fake",
                capabilities: Capabilities {
                    supports_fused_nms: false,
                    supports_dynamic_shapes: false,
                    artifact: ".fake",
                },
            };
            &FAKE
        }
        fn io(&self) -> &ModelIo {
            &self.io
        }
        fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
            self.seen.lock().unwrap().push((input.shape, input.layout));
            Ok(Box::new(FakeTensors(&self.output)))
        }
    }

    /// The layout is the backend's to decide: whatever `io()` reports is what
    /// the resolved spec carries and what shape the run is handed. The input is
    /// not square, so a swapped height and width cannot pass.
    #[test]
    fn with_backend_takes_the_input_layout_from_the_backend() {
        use super::super::geometry::ResizePolicy;

        for (layout, shape) in [
            (TensorLayout::Nhwc, [1, 64, 96, 3]),
            (TensorLayout::Nchw, [1, 3, 64, 96]),
        ] {
            let seen = Seen::default();
            let backend = FakeBackend {
                io: ModelIo {
                    input_name: "images".to_string(),
                    declared_input_size: Some(InputSize { w: 96, h: 64 }),
                    declared_input_batch: Some(1),
                    outputs: vec![Declared {
                        name: "output".to_string(),
                        dims: Some(vec![1, 126, 85]),
                    }],
                    input_element: InputElement::F32,
                    u8_outputs: Vec::new(),
                    input_layout: layout,
                },
                output: vec![0.0; 126 * 85],
                seen: std::sync::Arc::clone(&seen),
            };
            let labels = Labels::load(None).unwrap();
            let mut detector = match Detector::with_backend(
                Box::new(backend),
                Path::new("m.fake"),
                None,
                None,
                &labels,
                false,
                None,
            ) {
                Ok(detector) => detector,
                Err(err) => panic!("{err:#}"),
            };
            let spec = detector.input_spec();
            assert_eq!(spec.layout, layout);
            assert_eq!(detector.profile().name, "yolox");

            let projection = ResizePolicy::Stretch.project(spec.size, spec.size);
            let floors = ScoreFloors::parse("{}").unwrap();
            let tensor = TensorValues::F32(vec![0.0; spec.size.tensor_len()]);
            let dets = detector
                .detect(tensor, projection, &labels, &floors)
                .unwrap();
            assert!(dets.is_empty());
            assert_eq!(*seen.lock().unwrap(), [(shape, layout)]);
        }
    }

    /// Two detectors on one window report as one engine: their runs add up
    /// to one total and the window resets at their combined boundary.
    #[test]
    fn detectors_sharing_a_window_report_their_runs_together() {
        use super::super::geometry::ResizePolicy;

        let labels = Labels::load(None).unwrap();
        let open = || {
            let backend = FakeBackend {
                io: ModelIo {
                    input_name: "images".to_string(),
                    declared_input_size: Some(InputSize { w: 96, h: 64 }),
                    declared_input_batch: Some(1),
                    outputs: vec![Declared {
                        name: "output".to_string(),
                        dims: Some(vec![1, 126, 85]),
                    }],
                    input_element: InputElement::F32,
                    u8_outputs: Vec::new(),
                    input_layout: TensorLayout::Nchw,
                },
                output: vec![0.0; 126 * 85],
                seen: Seen::default(),
            };
            let opened = Detector::with_backend(
                Box::new(backend),
                Path::new("m.fake"),
                None,
                None,
                &labels,
                false,
                None,
            );
            match opened {
                Ok(detector) => detector,
                Err(err) => panic!("{err:#}"),
            }
        };
        let (mut first, mut second) = (open(), open());
        second.share_latency_with(&first);

        let spec = first.input_spec();
        let projection = ResizePolicy::Stretch.project(spec.size, spec.size);
        let floors = ScoreFloors::parse("{}").unwrap();
        let run = |detector: &mut Detector, times: usize| {
            for _ in 0..times {
                let tensor = TensorValues::F32(vec![0.0; spec.size.tensor_len()]);
                detector
                    .detect(tensor, projection, &labels, &floors)
                    .unwrap();
            }
        };
        let seen = |detector: &Detector| {
            let window = detector.latency.lock().unwrap();
            (window.window.len(), window.total_runs)
        };

        run(&mut first, 60);
        run(&mut second, 39);
        assert_eq!(seen(&first), (99, 99));
        run(&mut second, 1);
        assert_eq!(seen(&first), (0, 100));
        assert_eq!(seen(&second), (0, 100));
    }

    /// A pixel-byte backend's spec carries the encoding's identity qparams,
    /// with no sidecar; an encoding that has none is refused at open, naming
    /// the profile.
    #[test]
    fn a_pixel_byte_backend_resolves_to_the_identity_qparams() {
        let open = |size: usize, outputs: Vec<Declared>| {
            let backend = FakeBackend {
                io: ModelIo {
                    input_name: "images".to_string(),
                    declared_input_size: Some(InputSize::square(size)),
                    declared_input_batch: Some(1),
                    outputs,
                    input_element: InputElement::U8Pixels,
                    u8_outputs: Vec::new(),
                    input_layout: TensorLayout::Nhwc,
                },
                output: Vec::new(),
                seen: Seen::default(),
            };
            Detector::with_backend(
                Box::new(backend),
                Path::new("m.fake"),
                None,
                None,
                &Labels::load(None).unwrap(),
                true,
                None,
            )
        };
        let declared = |name: &str, dims: Vec<i64>| Declared {
            name: name.to_string(),
            dims: Some(dims),
        };

        let detector = match open(64, vec![declared("output", vec![1, 84, 85])]) {
            Ok(detector) => detector,
            Err(err) => panic!("{err:#}"),
        };
        let spec = detector.input_spec();
        assert_eq!(detector.profile().name, "yolox");
        assert_eq!(spec.input_quant, spec.encoding.pixel_quant());
        assert!(spec.input_quant.is_some());

        let detr = vec![
            declared("dets", vec![1, 300, 4]),
            declared("labels", vec![1, 300, 91]),
        ];
        let err = match open(384, detr) {
            Ok(_) => panic!("an imagenet-normalized profile opened over pixel bytes"),
            Err(err) => format!("{err:#}"),
        };
        assert!(
            err.contains("m.fake") && err.contains("takes pixel bytes") && err.contains("rfdetr"),
            "{err}"
        );
    }

    /// The report/reset boundary, driven through `record` itself rather than
    /// a hand-built window: exactly `REPORT_EVERY` runs empty the window (a
    /// broken reset would grow without bound and report stale runs), and the
    /// lifetime total keeps counting across the reset.
    #[test]
    fn latency_window_reports_and_resets_on_the_boundary() {
        let mut window = LatencyWindow::new();
        for run in 0..(LatencyWindow::REPORT_EVERY * 2 + 3) {
            window.record(Duration::from_millis(run as u64), "ort");
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
            None,
        ) {
            Ok(_) => panic!("qnn opened without a library"),
            Err(err) => err,
        };
        let msg = err.to_string();
        assert!(msg.contains("--qnn-library"), "{msg}");
    }
}
