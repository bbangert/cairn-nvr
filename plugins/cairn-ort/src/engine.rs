//! The per-VM model, and the registry of streams sharing it.
//!
//! One [`Engine`] per `init/1`, shared by every stream: a session per camera
//! would multiply the one expensive resource on the box by the camera count.
//! The engine holds the model in [`Provider::contexts`] slots — one on the
//! core backends — and a pass holds whichever slot is free for that pass, so
//! cameras wait on each other only when every slot is busy, and never on each
//! other's decode, motion measurement or gate state.
//!
//! One slot holds detector *and* embedder rather than a lock each: an embedder
//! opens only beside a detector on this crate's `ort`
//! ([`infer::embedder_backend`]), so both halves of a pass submit to the same
//! execution provider, and splitting them would only interleave two cameras on
//! that one provider. An embedder beside more than one slot is refused.
//!
//! `push_frame` nests stream -> pool and stream -> slot -> the detector's
//! latency window. The pool lock (the free list) is held only to take or give
//! back a slot index, never while another lock is taken, and a slot is
//! unlocked before its index goes back, so the cycle a deadlock needs does not
//! exist. The registry lock is a leaf: nothing else is taken under it, so
//! dropping a stream (which releases its camera) under the stream lock is safe.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

use cairn_detect::decode::ModelInput;
use cairn_detect::emit::Det;
use cairn_detect::infer::{
    self, BackendKind, Detector, Embedder, InputSpec, IoQuant, Labels, Provider, ScoreFloors,
    Selected, SessionOptions, TensorLayout,
};
use cairn_detect::note;

use crate::config::InitConfig;
use crate::error::{chain, NativeError, Result};

/// What one slot runs a pass on, under that slot's lock.
struct Model {
    detector: Detector,
    embedder: Option<Embedder>,
}

/// Slot 0 is the first open, and where a backend makes siblings
/// ([`infer::Backend::sibling`]) every other slot's was made from it; a
/// runtime may need it alive until they are gone. The drop pops from the back,
/// so no backend has to say whether its runtime does, and slot 0 always
/// goes last — on an open that fails halfway too, which is why the detectors
/// are held in one from the start.
struct Slots<T>(Vec<T>);

impl<T> Drop for Slots<T> {
    fn drop(&mut self) {
        while let Some(slot) = self.0.pop() {
            drop(slot);
        }
    }
}

/// The free slots, and whether a pass has panicked in any of them.
struct Pool {
    free: Vec<usize>,
    /// Set by the panicking pass's [`Lease`] and never cleared: one slot's
    /// backend unwound mid-pass, and the engine is refused as a whole rather
    /// than run on the rest (`ModelPoisoned` tells the host to stop trusting
    /// it).
    poisoned: bool,
    #[cfg(test)]
    waiting: usize,
}

impl Pool {
    /// A caller entering [`Engine::lease`]'s wait, counted under the pool lock
    /// so a test that reads the count knows the caller is inside the wait.
    fn arrive(&mut self) {
        #[cfg(test)]
        {
            self.waiting += 1;
        }
    }

    fn leave(&mut self) {
        #[cfg(test)]
        {
            self.waiting -= 1;
        }
    }
}

pub struct Engine {
    slots: Slots<Mutex<Model>>,
    pool: Mutex<Pool>,
    returned: Condvar,
    labels: Labels,
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
        let backend = core_backend(&config.backend)?;
        let embedder = embedder(&config, &Selected::Core(backend))?;
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
            backend,
            config.input_size,
            config.model_profile,
            &labels,
            config.allow_label_mismatch,
            config.qnn.clone(),
            None,
        )
        .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
        Self::assemble(&config, Slots(vec![detector]), embedder, labels)
    }

    /// An engine on a board library's backend: what the binary's
    /// `cli::run(&[provider])` opens for `--backend <provider.descriptor.name>`.
    ///
    /// The library serves that one backend, so any other `backend` is refused
    /// rather than opened on the core's backends — a host sending one here has
    /// routed it to the wrong library. So is an embedder, as the binary refuses
    /// one beside any provider. The sidecar is loaded and checked as
    /// the binary loads it: whether one may sit next to the artifact is the
    /// backend's input contract to decide ([`Detector::with_backend`]).
    ///
    /// Every one of the provider's slots is opened here, inside the `init`
    /// call, and never later from a pass: a board's runtime library path can
    /// be thread-local to `init` (the Rockchip board's is), so an open from
    /// `push_frame`'s scheduler thread would not find it.
    pub fn with_provider(config: InitConfig, provider: &Provider) -> Result<Self> {
        let runs = provider.descriptor.name;
        if config.backend != runs {
            let wanted = &config.backend;
            return Err(NativeError::Config(match infer::select(wanted, &[]) {
                Ok(_) => format!(
                    "this library's engine runs {runs}; backend {wanted} is served by CairnOrt"
                ),
                Err(_) => format!("backend: this library's engine runs {runs}, not {wanted:?}"),
            }));
        }
        let contexts = provider.contexts;
        if contexts == 0 {
            return Err(NativeError::ModelLoad(format!(
                "the provider for backend {runs} asks for 0 contexts; an engine needs one"
            )));
        }
        // Ahead of the provider's own refusal, so it still holds if a
        // provider's backend ever takes an embedder: one embedder per slot is
        // K more model loads, and one shared would serialise the slots again.
        if contexts > 1 && config.embedder_model.is_some() {
            return Err(NativeError::Config(format!(
                "embedder_model: the embedder does not run beside {contexts} contexts of \
                 backend {runs}"
            )));
        }
        let embedder = embedder(&config, &Selected::Provided(provider))?;
        let model_load = |e: anyhow::Error| NativeError::ModelLoad(chain(&e));
        let labels = Labels::load(config.labels.as_deref()).map_err(model_load)?;
        let options = SessionOptions {
            qnn: config.qnn.clone(),
            io_quant: IoQuant::load_for(&config.model).map_err(model_load)?,
        };
        let detector = |backend: Box<dyn infer::Backend>| {
            // The `up:` line renders the backend's own descriptor.
            let opened = backend.descriptor();
            if !std::ptr::eq(opened, provider.descriptor) {
                return Err(NativeError::ModelLoad(format!(
                    "the provider for backend {runs} opened backend {} under a descriptor \
                     it did not register",
                    opened.name
                )));
            }
            Detector::with_backend(
                backend,
                &config.model,
                config.input_size,
                config.model_profile,
                &labels,
                config.allow_label_mismatch,
                options.io_quant.as_ref(),
            )
            .map_err(model_load)
        };
        let open = || (provider.open)(&config.model, &options).map_err(model_load);
        let mut slots = Slots(vec![detector(open()?)?]);
        while slots.0.len() < contexts {
            let first = &mut slots.0[0];
            let backend = match first.sibling_backend().map_err(model_load)? {
                Some(backend) => backend,
                None => open()?,
            };
            let mut sibling = detector(backend)?;
            let first = &slots.0[0];
            // Streams pack for slot 0's spec (`engine_spec`) and any slot may
            // run their tensor.
            if sibling.input_spec() != first.input_spec() || sibling.profile() != first.profile() {
                return Err(NativeError::ModelLoad(format!(
                    "context {} of backend {runs} resolved model {} differently from the \
                     first: input {:?} against {:?}, profile {} against {}",
                    slots.0.len(),
                    config.model.display(),
                    sibling.input_spec(),
                    first.input_spec(),
                    sibling.profile(),
                    first.profile()
                )));
            }
            sibling.share_latency_with(first);
            slots.0.push(sibling);
        }
        Self::assemble(&config, slots, embedder, labels)
    }

    /// Everything after the detectors are open, for both constructors.
    fn assemble(
        config: &InitConfig,
        mut detectors: Slots<Detector>,
        embedder: Option<(&Path, BackendKind)>,
        labels: Labels,
    ) -> Result<Self> {
        let detector = &detectors.0[0];
        let input_spec = detector.input_spec();
        let mut embedder = match embedder {
            Some((path, kind)) => {
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
                let embedder =
                    Embedder::open(path, kind).map_err(|e| NativeError::ModelLoad(chain(&e)))?;
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
        let contexts = detectors.0.len();
        note!(
            "cairn-ort up: model={} backend={} profile={} input size={} encoding={} \
             resize={} contexts={contexts} embedder={}",
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

        // Infallible from here, so nothing drops a half-moved set of slots.
        // Slot 0 takes the embedder; there is one only beside one slot.
        let slots = Slots(
            std::mem::take(&mut detectors.0)
                .into_iter()
                .map(|detector| {
                    Mutex::new(Model {
                        detector,
                        embedder: embedder.take(),
                    })
                })
                .collect(),
        );
        Ok(Self {
            slots,
            pool: Mutex::new(Pool {
                free: (0..contexts).rev().collect(),
                poisoned: false,
                #[cfg(test)]
                waiting: 0,
            }),
            returned: Condvar::new(),
            labels,
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
    /// same composition both of the plugin's inference loops run — on the first
    /// free slot, after waiting for one if every slot is busy.
    pub fn detect(&self, input: ModelInput, floors: &ScoreFloors) -> Result<Vec<Det>> {
        // Declared before the slot's guard, so the guard drops first and a slot
        // is unlocked before its index is free again.
        let lease = self.lease()?;
        let mut model = self.slots.0[lease.slot]
            .lock()
            .map_err(|_| NativeError::ModelPoisoned)?;
        #[cfg(any(test, feature = "test-hooks"))]
        if self
            .panic_next
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            panic!("the detector exploded");
        }
        let Model { detector, embedder } = &mut *model;
        let labels = &self.labels;
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

    /// Wait for a free slot. A poisoned engine is refused even with slots free,
    /// and a waiter is woken to be refused when a pass panics, so none waits on
    /// a slot that will never come back.
    fn lease(&self) -> Result<Lease<'_>> {
        let mut pool = self.pool();
        pool.arrive();
        let mut pool = self
            .returned
            .wait_while(pool, |pool| pool.free.is_empty() && !pool.poisoned)
            .unwrap_or_else(PoisonError::into_inner);
        pool.leave();
        if pool.poisoned {
            return Err(NativeError::ModelPoisoned);
        }
        let slot = pool.free.pop().expect("woken with a free slot");
        Ok(Lease { engine: self, slot })
    }

    /// Recovered rather than refused: it holds indices and a flag, never
    /// state a pass ran over.
    fn pool(&self) -> MutexGuard<'_, Pool> {
        self.pool.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Callers held waiting for a slot.
    #[cfg(test)]
    fn waiting(&self) -> usize {
        self.pool().waiting
    }

    pub fn model_is_poisoned(&self) -> bool {
        self.pool().poisoned
    }

    /// Panic inside the *next* model pass, under both locks the way a real one
    /// does — the interleaving no synthetic poisoning can produce.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn panic_in_the_next_pass(&self) {
        self.panic_next
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

/// One slot held for one pass.
struct Lease<'a> {
    engine: &'a Engine,
    slot: usize,
}

impl Drop for Lease<'_> {
    /// An unwinding pass poisons the engine instead of returning its slot, and
    /// wakes every waiter to be refused; a pass that returned, even with an
    /// error, gives the slot back to one.
    fn drop(&mut self) {
        let mut pool = self.engine.pool();
        if std::thread::panicking() {
            pool.poisoned = true;
            self.engine.returned.notify_all();
        } else {
            pool.free.push(self.slot);
            self.engine.returned.notify_one();
        }
    }
}

/// `name` as one of the backends `cairn-detect` opens itself, refused as
/// config before any model access.
fn core_backend(name: &str) -> Result<BackendKind> {
    match infer::select(name, &[]) {
        Ok(Selected::Core(kind)) => Ok(kind),
        Ok(Selected::Provided(_)) => unreachable!("`select` was handed no providers"),
        Err(error) => Err(NativeError::Config(format!("backend: {}", chain(&error)))),
    }
}

/// The embedder's model and the backend it opens on beside a detector on
/// `detector`, refused as config before any model access.
fn embedder<'a>(
    config: &'a InitConfig,
    detector: &Selected<'_>,
) -> Result<Option<(&'a Path, BackendKind)>> {
    let Some(path) = config.embedder_model.as_deref() else {
        return Ok(None);
    };
    let kind = infer::embedder_backend(detector)
        .map_err(|error| NativeError::Config(format!("embedder_model: {}", chain(&error))))?;
    Ok(Some((path, kind)))
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

    // The measurement is on `ort` whatever the name; a name this crate
    // cannot open is still the caller's config, as `Engine::open` answers it.
    core_backend(&config.backend)?;

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
    /// of ids, where a model slot holds state a pass would have to run over
    /// ([`NativeError::ModelPoisoned`]).
    fn ids(&self) -> MutexGuard<'_, HashSet<String>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cairn_detect::infer::QnnOptions;
    use std::path::PathBuf;

    /// The pass-count bound must fire before any model access — proven here by
    /// a model path that does not exist, the same technique
    /// `qnn_without_library_is_refused_before_any_model_access` in
    /// `cairn-detect` uses.
    #[cfg(feature = "nif")]
    #[test]
    fn cpu_baseline_ms_refuses_a_bad_pass_count_before_any_model_access() {
        let config = InitConfig {
            model: PathBuf::from("does/not/exist"),
            backend: "ort".into(),
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

    #[cfg(feature = "nif")]
    #[test]
    fn cpu_baseline_ms_refuses_an_unknown_backend_before_any_model_access() {
        let config = InitConfig {
            model: PathBuf::from("does/not/exist"),
            backend: "tensorrt".into(),
            model_profile: None,
            input_size: None,
            labels: None,
            allow_label_mismatch: false,
            embedder_model: None,
            qnn: QnnOptions::default(),
        };
        let error = cpu_baseline_ms(&config, 5).unwrap_err();
        assert_eq!(error.reason(), "config");
        assert!(error.message().contains("tensorrt"), "{}", error.message());
    }

    mod board_backend {
        use super::*;
        use crate::config::RawStreamParams;
        use crate::stream::{Frame, Stream};
        use cairn_detect::infer::{
            Backend, Capabilities, Declared, Descriptor, InputElement, InputSize, InputTensor,
            ModelIo, Raw, Tensors,
        };
        use std::collections::HashMap;
        use std::path::Path;
        use std::sync::Arc;
        use std::time::Instant;

        const SIZE: InputSize = InputSize { w: 96, h: 64 };

        static BOARD: Descriptor = Descriptor {
            name: "board",
            capabilities: Capabilities {
                supports_fused_nms: false,
                supports_dynamic_shapes: false,
                artifact: ".board",
            },
        };

        /// A yolox-shaped 96x64 model that takes pixel bytes NHWC, as a
        /// board runtime's compiled artifact can, and outputs zeros. `run` refuses any tensor but
        /// [`rgb`]'s pixels with each one's channels reversed — the sniffed
        /// yolox profile is raw BGR — so a pass that returns proves what
        /// reached the backend, byte for byte.
        struct PixelBytes {
            io: ModelIo,
            output: Vec<f32>,
        }

        /// 126 anchors at either orientation of 96x64, so a sibling can
        /// declare the other one and still open.
        fn io(size: InputSize) -> ModelIo {
            ModelIo {
                input_name: "images".to_string(),
                declared_input_size: Some(size),
                declared_input_batch: Some(1),
                outputs: vec![Declared {
                    name: "output".to_string(),
                    dims: Some(vec![1, 126, 85]),
                }],
                input_element: InputElement::U8Pixels,
                u8_outputs: Vec::new(),
                input_layout: TensorLayout::Nhwc,
            }
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
                    io: io(SIZE),
                    output: vec![0.0; 126 * 85],
                })
            }
            fn descriptor(&self) -> &'static Descriptor {
                &BOARD
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
            Provider::new(&BOARD, |model, options| {
                Ok(Box::new(PixelBytes::open(model, options)?))
            })
        }

        fn config(embedder_model: Option<&str>) -> InitConfig {
            InitConfig {
                model: PathBuf::from("does/not/exist.board"),
                backend: "board".into(),
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

        /// Refused by the name `backend` resolved to, before the provider
        /// opens anything — `ort` included, when a provider holds that name —
        /// while core `ort` goes on to the model load.
        #[test]
        fn an_embedder_beside_a_provided_backend_is_config_before_any_load() {
            let unopened = |descriptor| {
                Provider::new(descriptor, |_, _| {
                    unreachable!("refused before the provider opens")
                })
            };
            for (backend, provider) in [
                ("board", unopened(&BOARD)),
                ("ort", unopened(BackendKind::Ort.descriptor())),
            ] {
                let config = InitConfig {
                    backend: backend.into(),
                    ..config(Some("osnet.onnx"))
                };
                let error = match Engine::with_provider(config, &provider) {
                    Ok(_) => panic!("an embedder opened beside provided {backend}"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "config", "{backend}");
                assert_eq!(
                    error.message(),
                    format!(
                        "embedder_model: the embedder does not run on a board library's \
                         backend ({backend})"
                    )
                );
            }

            let error = match Engine::open(InitConfig {
                backend: "ort".into(),
                ..config(Some("osnet.onnx"))
            }) {
                Ok(_) => panic!("a model that does not exist opened"),
                Err(error) => error,
            };
            assert_eq!(error.reason(), "model_load", "{error:?}");
        }

        /// On the core path the backend resolves first, so an unknown name is
        /// refused as that and not as the embedder's.
        #[test]
        fn an_embedder_off_core_ort_is_config_naming_the_first_refusal() {
            for (backend, refusal) in [
                (
                    "qnn",
                    "embedder_model: the embedder does not run on qnn yet",
                ),
                (
                    "tensorrt",
                    r#"backend: backend "tensorrt" is not one this build carries (ort, qnn)"#,
                ),
            ] {
                let error = match Engine::open(InitConfig {
                    backend: backend.into(),
                    ..config(Some("osnet.onnx"))
                }) {
                    Ok(_) => panic!("{backend} opened with an embedder"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "config", "{backend}");
                assert!(error.message().starts_with(refusal), "{error:?}");
            }
        }

        /// Identity, not the name: a backend reporting a copy of the
        /// registered descriptor is refused.
        #[test]
        fn a_provider_must_open_under_the_descriptor_it_registered() {
            static BOARD_COPY: Descriptor = Descriptor {
                name: "board",
                capabilities: BOARD.capabilities,
            };
            let provider = Provider::new(&BOARD_COPY, provider().open);
            let error = match Engine::with_provider(config(None), &provider) {
                Ok(_) => panic!("a backend opened under another descriptor"),
                Err(error) => error,
            };
            assert_eq!(error.reason(), "model_load");
            assert!(
                error
                    .message()
                    .contains("under a descriptor it did not register"),
                "{error:?}"
            );
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
                backend: "ort".into(),
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

        /// Each constructor refuses a backend it does not run as config, before
        /// any model access: [`Engine::open`] a board's name or an unknown one,
        /// [`Engine::with_provider`] a core name or an unknown one.
        #[test]
        fn a_backend_the_constructor_does_not_run_is_config_before_any_load() {
            for backend in ["board", "tensorrt"] {
                let error = match Engine::open(InitConfig {
                    backend: backend.into(),
                    ..config(None)
                }) {
                    Ok(_) => panic!("{backend} opened on the core backends"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "config", "{backend}");
                assert!(
                    error.message().starts_with(&format!(
                        r#"backend: backend "{backend}" is not one this build carries (ort, qnn)"#
                    )),
                    "{error:?}"
                );
            }

            for (backend, refusal) in [
                ("ort", "runs board; backend ort is served by CairnOrt"),
                (
                    "tensorrt",
                    r#"backend: this library's engine runs board, not "tensorrt""#,
                ),
            ] {
                let error = match Engine::with_provider(
                    InitConfig {
                        backend: backend.into(),
                        ..config(None)
                    },
                    &provider(),
                ) {
                    Ok(_) => panic!("{backend} opened on the board provider"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "config", "{backend}");
                assert!(error.message().contains(refusal), "{error:?}");
            }
        }

        /// A backend whose `run` holds until the test releases it, so what is
        /// inside the engine at once is observed rather than timed.
        mod slots {
            use super::*;
            use crate::{FrameObservations, StreamRef};
            use std::sync::mpsc::{self, Receiver};
            use std::sync::{Condvar, OnceLock};
            use std::time::Duration;

            /// A failure bound only: nothing here waits this long when the
            /// engine is right.
            const BOUND: Duration = Duration::from_secs(10);

            #[derive(Default)]
            struct State {
                opens: usize,
                siblings: usize,
                /// Indexed by backend id, which is also the slot it fills:
                /// slots are opened in order.
                permits: Vec<usize>,
                inside: usize,
                max_inside: usize,
                entered: usize,
                panic_in: Option<usize>,
                dropped: Vec<usize>,
                /// The sibling (counted from 1) that declares another size
                /// than the first's.
                odd_sibling: Option<(usize, InputSize)>,
                /// The backend whose next pass returns an error.
                fail_in: Option<usize>,
            }

            #[derive(Default)]
            struct Rig {
                state: Mutex<State>,
                changed: Condvar,
            }

            impl Rig {
                fn update<T>(&self, change: impl FnOnce(&mut State) -> T) -> T {
                    let out = change(&mut self.state.lock().unwrap());
                    self.changed.notify_all();
                    out
                }

                fn read<T>(&self, read: impl FnOnce(&State) -> T) -> T {
                    read(&self.state.lock().unwrap())
                }

                fn until(&self, what: &str, done: impl Fn(&State) -> bool) {
                    let (_state, waited) = self
                        .changed
                        .wait_timeout_while(self.state.lock().unwrap(), BOUND, |s| !done(s))
                        .unwrap();
                    assert!(!waited.timed_out(), "never saw {what}");
                }

                fn release(&self, id: usize) {
                    self.update(|s| s.permits[id] += 1);
                }
            }

            /// `Provider::open` is a bare `fn`, so a test's rig is found by
            /// the model path that test opens.
            fn rig_for(model: &Path) -> Arc<Rig> {
                static RIGS: OnceLock<Mutex<HashMap<PathBuf, Arc<Rig>>>> = OnceLock::new();
                let rigs = RIGS.get_or_init(Default::default);
                Arc::clone(rigs.lock().unwrap().entry(model.to_path_buf()).or_default())
            }

            struct Gated {
                rig: Arc<Rig>,
                id: usize,
                io: ModelIo,
                output: Vec<f32>,
            }

            impl Gated {
                fn new(rig: Arc<Rig>, size: InputSize) -> Self {
                    let id = rig.update(|s| {
                        s.permits.push(0);
                        s.permits.len() - 1
                    });
                    Self {
                        rig,
                        id,
                        io: io(size),
                        output: vec![0.0; 126 * 85],
                    }
                }
            }

            impl Drop for Gated {
                fn drop(&mut self) {
                    self.rig.update(|s| s.dropped.push(self.id));
                }
            }

            impl Backend for Gated {
                fn open(model: &Path, _: &SessionOptions) -> anyhow::Result<Self> {
                    let rig = rig_for(model);
                    rig.update(|s| s.opens += 1);
                    Ok(Self::new(rig, SIZE))
                }
                fn descriptor(&self) -> &'static Descriptor {
                    &BOARD
                }
                fn io(&self) -> &ModelIo {
                    &self.io
                }
                fn run(&mut self, _: InputTensor) -> anyhow::Result<Box<dyn Tensors + '_>> {
                    let (rig, id) = (&self.rig, self.id);
                    rig.update(|s| {
                        s.inside += 1;
                        s.entered += 1;
                        s.max_inside = s.max_inside.max(s.inside);
                    });
                    let (mut s, waited) = rig
                        .changed
                        .wait_timeout_while(rig.state.lock().unwrap(), BOUND, |s| {
                            s.permits[id] == 0
                        })
                        .unwrap();
                    s.inside -= 1;
                    anyhow::ensure!(!waited.timed_out(), "backend {id} was never released");
                    s.permits[id] -= 1;
                    let explode = s.panic_in == Some(id);
                    let fail = s.fail_in.take_if(|fail| *fail == id).is_some();
                    drop(s);
                    rig.changed.notify_all();
                    assert!(!explode, "backend {id} exploded mid-pass");
                    anyhow::ensure!(!fail, "backend {id} failed its pass");
                    Ok(Box::new(Zeros(&self.output)))
                }
            }

            /// [`Gated`] on a runtime that can make a sibling from an open
            /// context; `Gated` itself keeps the trait's default.
            struct Dup(Gated);

            impl Backend for Dup {
                fn open(model: &Path, options: &SessionOptions) -> anyhow::Result<Self> {
                    Gated::open(model, options).map(Self)
                }
                fn descriptor(&self) -> &'static Descriptor {
                    self.0.descriptor()
                }
                fn io(&self) -> &ModelIo {
                    self.0.io()
                }
                fn run(&mut self, input: InputTensor) -> anyhow::Result<Box<dyn Tensors + '_>> {
                    self.0.run(input)
                }
                fn sibling(&mut self) -> anyhow::Result<Option<Box<dyn Backend>>> {
                    let rig = Arc::clone(&self.0.rig);
                    let size = rig.update(|s| {
                        s.siblings += 1;
                        match s.odd_sibling {
                            Some((nth, size)) if nth == s.siblings => size,
                            _ => SIZE,
                        }
                    });
                    Ok(Some(Box::new(Self(Gated::new(rig, size)))))
                }
            }

            fn provider(contexts: usize, dup: bool) -> Provider {
                let open: fn(&Path, &SessionOptions) -> anyhow::Result<Box<dyn Backend>> = if dup {
                    |model, options| Ok(Box::new(Dup::open(model, options)?))
                } else {
                    |model, options| Ok(Box::new(Gated::open(model, options)?))
                };
                Provider::new(&BOARD, open).with_contexts(contexts)
            }

            fn model(test: &str) -> PathBuf {
                PathBuf::from(format!("gated/{test}.board"))
            }

            fn open(test: &str, provider: &Provider) -> Result<Engine> {
                Engine::with_provider(
                    InitConfig {
                        model: model(test),
                        ..config(None)
                    },
                    provider,
                )
            }

            fn gated(test: &str, contexts: usize, dup: bool) -> (Arc<Engine>, Arc<Rig>) {
                match open(test, &provider(contexts, dup)) {
                    Ok(engine) => (Arc::new(engine), rig_for(&model(test))),
                    Err(error) => panic!("{error:?}"),
                }
            }

            fn stream(engine: &Arc<Engine>, camera: &str) -> Arc<StreamRef> {
                let params = RawStreamParams {
                    min_score: HashMap::new(),
                    motion_json: None,
                    track_floor_json: None,
                    stream_epoch: None,
                };
                Arc::new(StreamRef::open(engine, camera.into(), params).unwrap())
            }

            type Outcome = Result<Vec<FrameObservations>>;

            /// One push on its own thread, as the NIF runs it.
            fn push(stream: &Arc<StreamRef>) -> Receiver<Outcome> {
                let stream = Arc::clone(stream);
                let (sink, outcome) = mpsc::channel();
                std::thread::spawn(move || {
                    let rgb = rgb();
                    let _ = sink.send(crate::guarded("push_frame", || stream.push(frame(&rgb))));
                });
                outcome
            }

            fn reason(outcome: &Receiver<Outcome>) -> &'static str {
                match outcome
                    .recv_timeout(BOUND)
                    .expect("the push never returned")
                {
                    Ok(observed) => {
                        assert!(observed[0].inferred, "the frame was not inferred");
                        "ok"
                    }
                    Err(error) => error.reason(),
                }
            }

            /// Polled, since the wait is the engine's own; the count is taken
            /// under the pool lock, so `n` means `n` callers inside the wait.
            fn until_waiting(engine: &Engine, n: usize) {
                let deadline = Instant::now() + BOUND;
                while engine.waiting() != n {
                    assert!(Instant::now() < deadline, "never saw {n} caller(s) waiting");
                    std::thread::sleep(Duration::from_millis(1));
                }
            }

            #[test]
            fn two_passes_are_inside_the_backend_at_once_on_two_slots() {
                let (engine, rig) = gated("overlap", 2, false);
                let (front, drive) = (stream(&engine, "front"), stream(&engine, "drive"));
                let (a, b) = (push(&front), push(&drive));
                rig.until("both passes inside run", |s| s.inside == 2);
                rig.release(0);
                rig.release(1);
                assert_eq!((reason(&a), reason(&b)), ("ok", "ok"));
                // no sibling support: the second slot is a second open
                assert_eq!(rig.read(|s| (s.opens, s.siblings)), (2, 0));
            }

            #[test]
            fn one_slot_serialises_two_passes() {
                let (engine, rig) = gated("serial", 1, false);
                let (front, drive) = (stream(&engine, "front"), stream(&engine, "drive"));
                let (a, b) = (push(&front), push(&drive));
                rig.until("one pass inside run", |s| s.inside == 1);
                until_waiting(&engine, 1);
                assert_eq!(rig.read(|s| s.entered), 1, "the waiter reached the backend");
                rig.release(0);
                rig.until("the waiter's pass", |s| s.entered == 2);
                rig.release(0);
                assert_eq!((reason(&a), reason(&b)), ("ok", "ok"));
                assert_eq!(rig.read(|s| s.max_inside), 1);
            }

            #[test]
            fn a_third_caller_waits_and_takes_the_slot_that_comes_back() {
                let (engine, rig) = gated("third", 2, false);
                let streams = ["front", "drive", "gate"].map(|camera| stream(&engine, camera));
                let (a, b) = (push(&streams[0]), push(&streams[1]));
                rig.until("both slots busy", |s| s.inside == 2);
                let c = push(&streams[2]);
                until_waiting(&engine, 1);
                assert_eq!(rig.read(|s| s.entered), 2);
                rig.release(0);
                rig.until("the third pass", |s| s.entered == 3);
                rig.release(0);
                rig.release(1);
                assert_eq!([reason(&a), reason(&b), reason(&c)], ["ok"; 3]);
                assert_eq!(rig.read(|s| s.max_inside), 2);
            }

            /// For a panic in either slot: the waiter is woken and refused,
            /// the slot still running finishes, and from then on every stream
            /// is refused — the one that panicked included.
            #[test]
            fn a_panic_in_any_slot_poisons_the_engine_and_wakes_its_waiters() {
                for target in [0, 1] {
                    let (engine, rig) = gated(&format!("panic-{target}"), 2, false);
                    let streams = ["front", "drive", "gate"].map(|camera| stream(&engine, camera));
                    let (a, b) = (push(&streams[0]), push(&streams[1]));
                    rig.until("both slots busy", |s| s.inside == 2);
                    let c = push(&streams[2]);
                    until_waiting(&engine, 1);

                    rig.update(|s| s.panic_in = Some(target));
                    rig.release(target);
                    assert_eq!(reason(&c), "model_poisoned", "slot {target}");
                    assert!(engine.model_is_poisoned());

                    rig.release(1 - target);
                    let mut first = [reason(&a), reason(&b)];
                    first.sort_unstable();
                    assert_eq!(first, ["ok", "panicked"], "slot {target}");
                    for stream in &streams {
                        assert_eq!(reason(&push(stream)), "model_poisoned", "slot {target}");
                    }
                    assert_eq!(rig.read(|s| s.entered), 2, "a poisoned engine ran a pass");
                }
            }

            /// The host's engine handle and the stream both go while a pass
            /// runs: the pass finishes on a live backend, and the model drops
            /// only once the last stream handle has.
            #[test]
            fn closing_with_a_pass_in_flight_drops_the_model_after_it() {
                let (engine, rig) = gated("close", 1, false);
                let front = stream(&engine, "front");
                let pass = push(&front);
                rig.until("the pass inside run", |s| s.inside == 1);

                let closed = {
                    let front = Arc::clone(&front);
                    let (sink, closed) = mpsc::channel();
                    std::thread::spawn(move || sink.send(front.close()));
                    closed
                };
                drop(engine);
                rig.release(0);
                assert_eq!(reason(&pass), "ok");
                assert!(closed.recv_timeout(BOUND).expect("close never returned"));
                assert_eq!(rig.read(|s| s.dropped.len()), 0, "dropped under a stream");
                assert_eq!(reason(&push(&front)), "closed");

                drop(front);
                rig.until("the model dropped", |s| s.dropped == [0]);
            }

            /// With the hook a board's slots are siblings of the first open;
            /// without it, opens of the file. Either way slot 0 goes last.
            #[test]
            fn siblings_drop_before_the_slot_they_were_made_from() {
                for dup in [false, true] {
                    let test = format!("drop-{dup}");
                    let (engine, rig) = gated(&test, 3, dup);
                    let made = if dup { (1, 2) } else { (3, 0) };
                    assert_eq!(rig.read(|s| (s.opens, s.siblings)), made, "dup {dup}");
                    drop(engine);
                    assert_eq!(rig.read(|s| s.dropped.clone()), [2, 1, 0], "dup {dup}");
                }
            }

            /// Streams pack for the first slot's spec, so a sibling resolving
            /// another is refused. It is the last of three, so the open fails
            /// with two slots held: all three drop, the first last.
            #[test]
            fn a_sibling_that_resolves_another_input_is_refused() {
                let test = "sibling-size";
                rig_for(&model(test)).update(|s| {
                    s.odd_sibling = Some((2, InputSize { w: 64, h: 96 }));
                });
                let error = match open(test, &provider(3, true)) {
                    Ok(_) => panic!("a mismatched sibling opened"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "model_load");
                assert!(
                    error.message().contains("differently from the first"),
                    "{error:?}"
                );
                let rig = rig_for(&model(test));
                assert_eq!(rig.read(|s| s.dropped.clone()), [2, 1, 0]);
            }

            /// An error is not a panic: the slot goes back, and with one slot
            /// a leaked one would hold the next pass forever.
            #[test]
            fn a_pass_that_fails_gives_its_slot_back() {
                let (engine, rig) = gated("failed-pass", 1, false);
                let (front, drive) = (stream(&engine, "front"), stream(&engine, "drive"));
                rig.update(|s| s.fail_in = Some(0));
                rig.release(0);
                assert_eq!(reason(&push(&front)), "infer");
                assert!(!engine.model_is_poisoned());
                rig.release(0);
                assert_eq!(reason(&push(&drive)), "ok");
            }

            #[test]
            fn an_embedder_beside_more_than_one_context_is_refused_before_any_open() {
                let test = "embedder";
                let error = match Engine::with_provider(
                    InitConfig {
                        model: model(test),
                        ..config(Some("osnet.onnx"))
                    },
                    &provider(2, true),
                ) {
                    Ok(_) => panic!("an embedder opened beside two contexts"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "config");
                assert_eq!(
                    error.message(),
                    "embedder_model: the embedder does not run beside 2 contexts of backend board"
                );
                assert_eq!(rig_for(&model(test)).read(|s| s.opens), 0);
            }

            #[test]
            fn zero_contexts_is_refused_before_any_open() {
                let test = "zero";
                let error = match open(test, &provider(0, false)) {
                    Ok(_) => panic!("an engine opened with no slot"),
                    Err(error) => error,
                };
                assert_eq!(error.reason(), "model_load");
                assert!(error.message().contains("0 contexts"), "{error:?}");
                assert_eq!(rig_for(&model(test)).read(|s| s.opens), 0);
            }
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
