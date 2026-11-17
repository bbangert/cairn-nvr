//! The per-VM model, and the registry of streams sharing it.
//!
//! One [`Engine`] per `init/1`, shared by every stream: a session per camera
//! would multiply the one expensive resource on the box by the camera count. The
//! model lock is held for one pass, so two cameras serialize on inference and not
//! on each other's decode, motion measurement or gate state.
//!
//! One lock over detector *and* embedder rather than one each: [`Embedder::open`]
//! takes the detector's backend kind, so both halves of a pass submit to the same
//! execution provider, and splitting them would only interleave two cameras on
//! that one provider.
//!
//! This lock is a leaf — nothing taken under it takes another in this crate — and
//! `push_au`'s order is always stream -> model, so the cycle a deadlock needs
//! does not exist. The registry is never touched under it.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard};

use cairn_detect::cli::Provider;
use cairn_detect::decode::ModelInput;
use cairn_detect::emit::Det;
use cairn_detect::infer::{
    self, Detector, Embedder, InputSpec, IoQuant, Labels, ScoreFloors, SessionOptions, TensorLayout,
};
use cairn_detect::note;

use crate::config::InitConfig;
use crate::error::{chain, NativeError, Result};

/// Everything one model pass needs, under one lock.
struct Model {
    detector: Detector,
    embedder: Option<Embedder>,
    labels: Labels,
}

pub struct Engine {
    model: Mutex<Model>,
    open: Registry,
    /// Resolved once here, and exported to the host (`engine_spec`): every
    /// decoder built for this engine — in the *other* NIF library — has to
    /// produce the geometry, encoding and resize policy this one model asked
    /// for, and terms are the only thing that can cross between the two.
    pub input_spec: InputSpec,
    /// See [`Engine::panic_in_the_next_pass`].
    #[cfg(any(test, feature = "test-hooks"))]
    panic_next: std::sync::atomic::AtomicBool,
}

impl Engine {
    pub fn open(config: InitConfig) -> Result<Self> {
        let labels = Labels::load(config.labels.as_deref())
            .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
        // Deliberately no sidecar load on the core backends: their uint8-IO
        // path is the cairn-detect binary's for now (spike). Refused by name
        // here when the sidecar exists — Detector::open's dtype check would
        // otherwise report it "missing" and send the operator re-exporting a
        // file that is sitting right there; a u8 artifact WITHOUT a sidecar
        // still gets that check's accurate message.
        // metadata, not exists(): a permission error must surface, not read
        // as "no sidecar" — the same NotFound-only-is-absence rule as
        // IoQuant::load_for.
        match std::fs::metadata(IoQuant::sidecar_path(&config.model)) {
            Ok(_) => {
                return Err(NativeError::ModelLoad(format!(
                    "model {} has a qparams sidecar — CairnOrt's core backends (ort, \
                     qnn) run uint8-IO artifacts only in the cairn-detect binary, not \
                     in-VM; configure the float-IO artifact here",
                    config.model.display()
                )))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(NativeError::ModelLoad(format!(
                    "checking for a qparams sidecar next to {}: {e}",
                    config.model.display()
                )))
            }
        }
        let detector = Detector::open(
            &config.model,
            config.backend,
            config.input_size,
            config.model_profile,
            &labels,
            config.allow_label_mismatch,
            config.qnn.clone(),
            None,
        )
        .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
        Self::assemble(&config, detector, labels)
    }

    /// An engine on a board library's backend: what the binary's
    /// `cli::run(&[provider])` opens for `--backend <provider.kind>`.
    ///
    /// The library serves that one kind, so any other `backend` is refused
    /// rather than opened on the core's backends — a host sending one here has
    /// routed it to the wrong library. The sidecar is loaded and checked as
    /// the binary loads it: whether one may sit next to the artifact is the
    /// backend's input contract to decide ([`Detector::with_backend`]).
    pub fn with_provider(config: InitConfig, provider: &Provider) -> Result<Self> {
        if config.backend != provider.kind {
            return Err(NativeError::Config(format!(
                "this library's engine runs {}; backend {} is served by CairnOrt",
                provider.kind, config.backend
            )));
        }
        let model_load = |e: anyhow::Error| NativeError::ModelLoad(chain(&e));
        let labels = Labels::load(config.labels.as_deref()).map_err(model_load)?;
        let options = SessionOptions {
            qnn: config.qnn.clone(),
            io_quant: IoQuant::load_for(&config.model).map_err(model_load)?,
            ..SessionOptions::default()
        };
        let backend = (provider.open)(&config.model, &options).map_err(model_load)?;
        // The `up:` line names the backend's own kind.
        if backend.kind() != provider.kind {
            return Err(NativeError::ModelLoad(format!(
                "the provider for backend {} opened backend {}",
                provider.kind,
                backend.kind()
            )));
        }
        let detector = Detector::with_backend(
            backend,
            &config.model,
            config.input_size,
            config.model_profile,
            &labels,
            config.allow_label_mismatch,
            options.io_quant.as_ref(),
        )
        .map_err(model_load)?;
        Self::assemble(&config, detector, labels)
    }

    /// Everything after the detector is open, for both constructors.
    fn assemble(config: &InitConfig, detector: Detector, labels: Labels) -> Result<Self> {
        let input_spec = detector.input_spec();
        let embedder = match config.embedder_model.as_deref() {
            Some(path) => {
                // Here, not at the first person in `detect`: the crops are cut
                // from the detector's packed tensor, read as f32 NCHW planes,
                // and only the opened artifact says whether it is fed that.
                if input_spec.input_quant.is_some() || input_spec.layout != TensorLayout::Nchw {
                    return Err(NativeError::ModelLoad(format!(
                        "embedder_model cannot run with model {}, which takes {} {:?} input: \
                         the reid crop source is the detector's packed tensor, read as f32 \
                         NCHW planes — drop the embedder",
                        config.model.display(),
                        if input_spec.input_quant.is_some() {
                            "uint8"
                        } else {
                            "f32"
                        },
                        input_spec.layout
                    )));
                }
                let embedder = Embedder::open(path, config.backend)
                    .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
                if !labels.contains("person") {
                    note!(
                        "cairn-native: an embedder is configured but the label set has no \
                         `person` entry; no detection will carry an embedding"
                    );
                }
                Some(embedder)
            }
            None => None,
        };

        // The plugin's `up:` line: a wrong model or profile is visible before any
        // frame arrives rather than inferred later from bad boxes.
        note!(
            "cairn-ort up: model={} backend={} profile={} input size={} encoding={} \
             resize={} embedder={}",
            config.model.display(),
            detector.backend_summary(),
            detector.profile(),
            input_spec.size,
            input_spec.encoding,
            input_spec.resize,
            match &embedder {
                Some(embedder) => embedder.summary(),
                None => "off".to_string(),
            }
        );

        Ok(Self {
            model: Mutex::new(Model {
                detector,
                embedder,
                labels,
            }),
            open: Registry::default(),
            input_spec,
            #[cfg(any(test, feature = "test-hooks"))]
            panic_next: std::sync::atomic::AtomicBool::new(false),
        })
    }

    pub fn register(&self, camera_id: &str) -> Result<()> {
        self.open.claim(camera_id)
    }

    pub fn release(&self, camera_id: &str) {
        self.open.release(camera_id);
    }

    /// One frame's model pass — detection, then Re-ID over the person crops: the
    /// same composition both of the plugin's inference loops run.
    pub fn detect(&self, input: ModelInput, floors: &ScoreFloors) -> Result<Vec<Det>> {
        let mut model = self.model.lock().map_err(|_| NativeError::ModelPoisoned)?;
        #[cfg(any(test, feature = "test-hooks"))]
        if self
            .panic_next
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            panic!("the detector exploded");
        }
        let Model {
            detector,
            embedder,
            labels,
        } = &mut *model;
        let spec = detector.input_spec();

        // A pixel-byte artifact's pack is u8, but an embedder only opens
        // beside a detector fed f32 NCHW (`Engine::assemble`), so the u8 arm is
        // an invariant refusal, not a reachable contract.
        let crop_source = match (embedder.as_ref(), input.tensor.as_f32()) {
            (Some(_), Some(tensor)) => Some(tensor.to_vec()),
            (Some(_), None) => {
                return Err(NativeError::Infer(
                    "embedder cannot crop from a u8-packed tensor".to_string(),
                ))
            }
            (None, _) => None,
        };
        let projection = input.projection;
        let mut dets = detector
            .detect(input.tensor, input.projection, labels, floors)
            .map_err(|e| NativeError::Infer(chain(&e)))?;
        if let (Some(embedder), Some(tensor)) = (embedder.as_mut(), crop_source) {
            infer::embed_persons(embedder, &tensor, &spec, &projection, &mut dets)
                .map_err(|e| NativeError::Infer(chain(&e)))?;
        }
        Ok(dets)
    }

    pub fn model_is_poisoned(&self) -> bool {
        self.model.is_poisoned()
    }

    /// Panic inside the *next* model pass, under both locks the way a real one
    /// does — the interleaving no synthetic poisoning can produce.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn panic_in_the_next_pass(&self) {
        self.panic_next
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Median CPU-side model-pass latency, milliseconds: the number
/// `Cairn.Native.Health`'s D-P5 ratio compares an accelerator's own pass
/// latency against. Opens a second [`Detector`] on `BackendKind::Ort` — never
/// the accelerator's session, so this never contends with a live pass —
/// against the same model this engine was, or would be, configured with.
///
/// A second model load is not free, and once this process has registered a
/// QNN EP it is not provably measured on the CPU — see the note in the body.
#[cfg(feature = "nif")]
pub fn cpu_baseline_ms(config: &InitConfig, passes: usize) -> Result<f64> {
    // Before any model access: a bad pass count is the caller's config, not
    // an inference failure.
    if !infer::BASELINE_PASSES.contains(&passes) {
        return Err(NativeError::Config(format!(
            "cpu_baseline_ms passes must be {}..={}, got {passes}",
            infer::BASELINE_PASSES.start(),
            infer::BASELINE_PASSES.end()
        )));
    }

    let labels =
        Labels::load(config.labels.as_deref()).map_err(|e| NativeError::ModelLoad(chain(&e)))?;

    // NOTE: measured in whatever ORT environment THIS process has — once a
    // QNN EP library is registered here, the venue is no longer provably the
    // CPU. The host measures through the backend's canary binary's
    // `--cpu-baseline` (a fresh subprocess) for exactly that reason; this NIF
    // entry point remains for tooling on nodes that never touch QNN. The two
    // phases keep their own reasons, as Engine::open's callers expect: an
    // unloadable model is model_load, only a failed pass is infer.
    let mut detector = infer::open_baseline_detector(
        &config.model,
        config.input_size,
        config.model_profile,
        &labels,
        config.allow_label_mismatch,
    )
    .map_err(|e| NativeError::ModelLoad(chain(&e)))?;

    let median = infer::measure_cpu_baseline(&mut detector, &labels, passes)
        .map_err(|e| NativeError::Infer(chain(&e)))?;

    note!(
        "cairn-ort cpu baseline: model={} median={median:.2}ms over {passes} pass(es)",
        config.model.display(),
    );

    Ok(median)
}

/// The camera ids with a live stream on this engine: not a lookup table, but the
/// answer to "is this camera already open", which a host holding opaque handles
/// cannot ask itself.
#[derive(Default)]
struct Registry(Mutex<HashSet<String>>);

impl Registry {
    /// Claim a camera id, or refuse because it already has a stream: two streams
    /// for one camera would each hold their own motion background and gate state
    /// while emitting under the same id, so the host would see one camera's frames
    /// gated by two policies that disagree.
    fn claim(&self, camera_id: &str) -> Result<()> {
        if self.ids().insert(camera_id.to_string()) {
            Ok(())
        } else {
            Err(NativeError::OpenStream(format!(
                "camera {camera_id} already has an open stream on this engine"
            )))
        }
    }

    fn release(&self, camera_id: &str) {
        self.ids().remove(camera_id);
    }

    #[cfg(test)]
    fn holds(&self, camera_id: &str) -> bool {
        self.ids().contains(camera_id)
    }

    /// Recovered rather than refused: a poisoned registry still holds only a set
    /// of ids, where the model lock holds state a pass would have to run over
    /// ([`NativeError::ModelPoisoned`]).
    fn ids(&self) -> MutexGuard<'_, HashSet<String>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cairn_detect::infer::{BackendKind, QnnOptions};
    use std::path::PathBuf;

    /// The pass-count bound must fire before any model access — proven here by
    /// a model path that does not exist, the same technique
    /// `a_board_backend_this_build_lacks_is_refused_before_any_model_access` in
    /// `cairn-detect` uses.
    #[cfg(feature = "nif")]
    #[test]
    fn cpu_baseline_ms_refuses_a_bad_pass_count_before_any_model_access() {
        let config = InitConfig {
            model: PathBuf::from("does/not/exist"),
            backend: BackendKind::Ort,
            model_profile: None,
            input_size: None,
            labels: None,
            allow_label_mismatch: false,
            embedder_model: None,
            qnn: QnnOptions::default(),
        };
        for passes in [0, 65, 1_000] {
            let error = cpu_baseline_ms(&config, passes).unwrap_err();
            assert_eq!(error.reason(), "config", "{passes}");
        }
    }

    mod board_backend {
        use super::*;
        use crate::config::RawStreamParams;
        use crate::stream::{Frame, Stream};
        use cairn_detect::infer::{
            Backend, Declared, InputElement, InputSize, InputTensor, ModelIo, Raw, Tensors,
        };
        use std::collections::HashMap;
        use std::path::Path;
        use std::sync::Arc;
        use std::time::Instant;

        const SIZE: InputSize = InputSize { w: 96, h: 64 };

        /// A yolox-shaped 96x64 model that takes pixel bytes NHWC, as an
        /// `.rknn` does, and outputs zeros. `run` refuses any tensor but
        /// [`rgb`]'s pixels with each one's channels reversed — the sniffed
        /// yolox profile is raw BGR — so a pass that returns proves what
        /// reached the backend, byte for byte.
        struct PixelBytes {
            io: ModelIo,
            output: Vec<f32>,
        }

        struct Zeros<'a>(&'a [f32]);

        impl Tensors for Zeros<'_> {
            fn get(&self, _name: &str) -> anyhow::Result<Raw<'_>> {
                Ok(Raw {
                    dims: vec![1, 126, 85],
                    values: self.0,
                })
            }
        }

        impl Backend for PixelBytes {
            fn open(_: &Path, _: &SessionOptions) -> anyhow::Result<Self> {
                Ok(Self {
                    io: ModelIo {
                        input_name: "images".to_string(),
                        declared_input_size: Some(SIZE),
                        declared_input_batch: Some(1),
                        outputs: vec![Declared {
                            name: "output".to_string(),
                            dims: Some(vec![1, 126, 85]),
                        }],
                        input_element: InputElement::U8Pixels,
                        u8_outputs: Vec::new(),
                        input_layout: TensorLayout::Nhwc,
                    },
                    output: vec![0.0; 126 * 85],
                })
            }
            fn kind(&self) -> BackendKind {
                BackendKind::Rknn
            }
            fn io(&self) -> &ModelIo {
                &self.io
            }
            fn run(&mut self, input: InputTensor) -> anyhow::Result<Box<dyn Tensors + '_>> {
                anyhow::ensure!(input.shape == [1, 64, 96, 3], "shape {:?}", input.shape);
                let bgr: Vec<u8> = rgb()
                    .as_chunks::<3>()
                    .0
                    .iter()
                    .flat_map(|&[r, g, b]| [b, g, r])
                    .collect();
                anyhow::ensure!(
                    input.values.as_u8() == Some(&bgr[..]),
                    "not the frame's pixels as BGR bytes"
                );
                Ok(Box::new(Zeros(&self.output)))
            }
        }

        fn provider() -> Provider {
            Provider {
                kind: BackendKind::Rknn,
                open: |model, options| Ok(Box::new(PixelBytes::open(model, options)?)),
            }
        }

        fn config(embedder_model: Option<&str>) -> InitConfig {
            InitConfig {
                model: PathBuf::from("does/not/exist.rknn"),
                backend: BackendKind::Rknn,
                model_profile: None,
                input_size: None,
                labels: None,
                allow_label_mismatch: false,
                embedder_model: embedder_model.map(PathBuf::from),
                qnn: QnnOptions::default(),
            }
        }

        /// Consecutive values mod 251: a pixel's three channels all differ
        /// and no row repeats the one above (a row is 288 bytes), so a
        /// channel swap or a shifted read cannot pass for the right order.
        fn rgb() -> Vec<u8> {
            (0..SIZE.tensor_len()).map(|i| (i % 251) as u8).collect()
        }

        /// The model's own size: the fit is the identity, so no letterbox
        /// pad lands in the tensor.
        fn frame(rgb: &[u8]) -> Frame<'_> {
            Frame {
                rgb,
                content: SIZE,
                orig: SIZE,
                pts: Some(0),
                time_base: (1, 90_000),
                observed_at_ms: 0,
                motion: None,
            }
        }

        #[test]
        fn an_rgb_frame_reaches_a_pixel_byte_backend_as_bgr_bytes() {
            let engine = match Engine::with_provider(config(None), &provider()) {
                Ok(engine) => Arc::new(engine),
                Err(error) => panic!("{error:?}"),
            };
            assert_eq!(engine.input_spec.layout, TensorLayout::Nhwc);
            assert!(engine.input_spec.input_quant.is_some());

            let params = RawStreamParams {
                min_score: HashMap::new(),
                motion_json: None,
                track_floor_json: None,
                stream_epoch: None,
            };
            let mut stream = Stream::open(
                Arc::clone(&engine),
                "front".into(),
                params.resolve().unwrap(),
            )
            .unwrap();
            let rgb = rgb();
            let observed = stream.push_frame(frame(&rgb), Instant::now()).unwrap();
            assert_eq!(observed.len(), 1);
            assert!(observed[0].inferred);
        }

        #[test]
        fn an_embedder_beside_a_pixel_byte_detector_is_refused_at_open() {
            let error = match Engine::with_provider(config(Some("osnet.onnx")), &provider()) {
                Ok(_) => panic!("an embedder opened over a u8-packed detector"),
                Err(error) => error,
            };
            assert_eq!(error.reason(), "model_load");
            assert!(error.message().contains("embedder_model"), "{error:?}");
            assert!(error.message().contains("uint8 Nhwc"), "{error:?}");
        }

        /// The core path still refuses a uint8-IO artifact by its sidecar,
        /// before any model access: the model next to it does not exist.
        #[test]
        fn the_core_backends_still_refuse_a_sidecar_by_name() {
            let dir =
                std::env::temp_dir().join(format!("cairn-ort-sidecar-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let model = dir.join("m.onnx");
            std::fs::write(IoQuant::sidecar_path(&model), "{}").unwrap();
            let opened = Engine::open(InitConfig {
                model,
                backend: BackendKind::Ort,
                ..config(None)
            });
            std::fs::remove_dir_all(&dir).unwrap();
            let error = match opened {
                Ok(_) => panic!("a sidecar artifact opened in-VM"),
                Err(error) => error,
            };
            assert_eq!(error.reason(), "model_load");
            assert!(error.message().contains("qparams sidecar"), "{error:?}");
        }
    }

    #[test]
    fn a_camera_can_hold_one_stream_at_a_time() {
        let registry = Registry::default();

        assert!(registry.claim("front").is_ok());
        assert!(registry.holds("front"));

        let error = registry.claim("front").unwrap_err();
        assert_eq!(error.reason(), "open_stream");
        assert!(error.message().contains("front"), "{}", error.message());

        // …and the neighbour is unaffected: a registry, not a lock
        assert!(registry.claim("drive").is_ok());
    }

    #[test]
    fn a_released_camera_can_be_opened_again() {
        let registry = Registry::default();
        registry.claim("front").unwrap();
        registry.release("front");

        assert!(!registry.holds("front"));
        assert!(registry.claim("front").is_ok());
        // releasing one that was never claimed is not an error: `Stream`'s
        // `Drop` runs whether or not `close_stream` already ran
        registry.release("gate");
        registry.release("front");
        registry.release("front");
        assert!(!registry.holds("front"));
    }

    /// N Elixir processes reach the claim at once and exactly one may win.
    #[test]
    fn one_claim_wins_when_they_arrive_together() {
        let registry = Registry::default();
        let winners: usize = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| scope.spawn(|| usize::from(registry.claim("front").is_ok())))
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .sum()
        });

        assert_eq!(winners, 1);
        assert!(registry.holds("front"));
    }

    #[test]
    fn a_poisoned_registry_keeps_answering() {
        let registry = Registry::default();
        registry.claim("front").unwrap();

        let poisoned = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = registry.0.lock().unwrap();
            panic!("while holding the registry");
        }));
        assert!(poisoned.is_err());

        assert!(registry.holds("front"));
        assert!(registry.claim("drive").is_ok());
    }
}
