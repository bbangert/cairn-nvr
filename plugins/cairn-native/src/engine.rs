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

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, Once};
use std::time::Instant;

use cairn_detect::decode::{DecoderKind, ModelInput};
use cairn_detect::emit::Det;
use cairn_detect::infer::{
    self, BackendKind, Detector, Embedder, Fit, InputSpec, Labels, QnnOptions, ScoreFloors,
};
use cairn_detect::note;
use rsmpeg::ffi;

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
    pub decoder: DecoderKind,
    pub sample_fps: u32,
    /// Resolved once here: every decoder this engine's streams open has to
    /// produce the geometry, encoding and resize policy this one model asked for.
    pub input_spec: InputSpec,
    /// See [`Engine::panic_in_the_next_pass`].
    #[cfg(test)]
    panic_next: std::sync::atomic::AtomicBool,
    /// See [`Engine::panic_in_the_next_open`].
    #[cfg(test)]
    panic_next_open: std::sync::atomic::AtomicBool,
}

impl Engine {
    pub fn open(config: InitConfig) -> Result<Self> {
        quiet_libav();
        let labels = Labels::load(config.labels.as_deref())
            .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
        let detector = Detector::open(
            &config.model,
            config.backend,
            config.input_size,
            config.model_profile,
            &labels,
            config.allow_label_mismatch,
            config.qnn,
        )
        .map_err(|e| NativeError::ModelLoad(chain(&e)))?;
        let embedder = match config.embedder_model.as_deref() {
            Some(path) => {
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

        let input_spec = detector.input_spec();
        // The plugin's `up:` line: a wrong model or profile is visible before any
        // frame arrives rather than inferred later from bad boxes.
        note!(
            "cairn-native up: model={} backend={} profile={} input size={} encoding={} \
             resize={} decoder={} sample_fps={} embedder={}",
            config.model.display(),
            detector.backend_summary(),
            detector.profile(),
            input_spec.size,
            input_spec.encoding,
            input_spec.resize,
            config.decoder,
            config.sample_fps,
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
            decoder: config.decoder,
            sample_fps: config.sample_fps,
            input_spec,
            #[cfg(test)]
            panic_next: std::sync::atomic::AtomicBool::new(false),
            #[cfg(test)]
            panic_next_open: std::sync::atomic::AtomicBool::new(false),
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
        #[cfg(test)]
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

        let crop_source = embedder.as_ref().map(|_| input.tensor.clone());
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
    #[cfg(test)]
    pub fn panic_in_the_next_pass(&self) {
        self.panic_next
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Panic inside the *next* decoder open, where a driver actually can: after
    /// the camera id is claimed and before any stream exists to hand it back.
    #[cfg(test)]
    pub fn panic_in_the_next_open(&self) {
        self.panic_next_open
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Called from the decoder open itself, because what is under test is where
    /// the unwind starts.
    #[cfg(test)]
    pub fn panic_if_armed_for_open(&self) {
        if self
            .panic_next_open
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            panic!("the decoder exploded while opening");
        }
    }
}

/// The `passes` range `cpu_baseline_ms` accepts.
const BASELINE_PASSES: std::ops::RangeInclusive<usize> = 1..=64;

/// Median CPU-side model-pass latency, milliseconds: the number
/// `Cairn.Native.Health`'s D-P5 ratio compares an accelerator's own pass
/// latency against. Opens a second [`Detector`] on `BackendKind::Ort` — never
/// the accelerator's session, so this never contends with a live pass —
/// against the same model this engine was, or would be, configured with.
///
/// Called once, at engine init, only when the configured backend is an
/// accelerator: a second model load is not free.
pub fn cpu_baseline_ms(config: &InitConfig, passes: usize) -> Result<f64> {
    if !BASELINE_PASSES.contains(&passes) {
        return Err(NativeError::Config(format!(
            "cpu_baseline_ms passes must be {}..={}, got {passes}",
            BASELINE_PASSES.start(),
            BASELINE_PASSES.end()
        )));
    }

    let labels =
        Labels::load(config.labels.as_deref()).map_err(|e| NativeError::ModelLoad(chain(&e)))?;
    let mut detector = Detector::open(
        &config.model,
        BackendKind::Ort,
        config.input_size,
        config.model_profile,
        &labels,
        config.allow_label_mismatch,
        QnnOptions::default(),
    )
    .map_err(|e| NativeError::ModelLoad(chain(&e)))?;

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

    // Untimed: an ORT session's first run pays extra for lazy allocations a
    // steady-state pass does not, and the ratio has to compare steady state.
    detector
        .detect(tensor.clone(), projection, &labels, &floors)
        .map_err(|e| NativeError::Infer(chain(&e)))?;

    let mut samples = Vec::with_capacity(passes);
    for _ in 0..passes {
        let started = Instant::now();
        detector
            .detect(tensor.clone(), projection, &labels, &floors)
            .map_err(|e| NativeError::Infer(chain(&e)))?;
        samples.push(started.elapsed());
    }
    samples.sort_unstable();
    let median = samples[samples.len() / 2].as_secs_f64() * 1000.0;

    note!(
        "cairn-native cpu baseline: backend={} model={} median={median:.2}ms over {passes} pass(es)",
        detector.backend_summary(),
        config.model.display(),
    );

    Ok(median)
}

/// Stop libav writing the BEAM's stderr for us.
///
/// A camera joining mid-GOP or any flaky RTSP source emits two `AV_LOG_ERROR`
/// lines *per malformed access unit* (`No start code is found.` / `Error
/// splitting the input into NAL units.`), at frame rate, per camera — and in-VM
/// that is the node's log. Nothing is lost: those are the tolerated errors
/// `Stream::note` already counts and rate-limits. `AV_LOG_FATAL` and
/// `AV_LOG_PANIC` still print.
///
/// A level rather than an `av_log_set_callback`: routing the text through
/// [`note!`] means reformatting a `va_list`, whose bindgen type differs between
/// x86_64 and the aarch64 board.
///
/// Once per VM, not per engine: the setting is a libav global, and `init/1` can
/// be called again behind the host's canary.
fn quiet_libav() {
    static ONCE: Once = Once::new();
    // SAFETY: `av_log_set_level` stores an int in a libav global. Serialized by
    // `Once` against itself; libav reads it unsynchronized either way, and an
    // int is what every one of its own callers writes there too.
    ONCE.call_once(|| unsafe {
        ffi::av_log_set_level(ffi::AV_LOG_FATAL as i32);
    });
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
    use std::path::PathBuf;

    /// The pass-count bound must fire before any model access — proven here by
    /// a model path that does not exist, the same technique
    /// `stub_backend_is_refused_before_any_model_access` in `cairn-detect` uses.
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
            decoder: DecoderKind::Sw,
            sample_fps: 5,
            qnn: QnnOptions::default(),
        };
        for passes in [0, 65, 1_000] {
            let error = cpu_baseline_ms(&config, passes).unwrap_err();
            assert_eq!(error.reason(), "config", "{passes}");
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
