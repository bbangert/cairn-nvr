//! The per-VM model, and the registry of streams sharing it.
//!
//! One [`Engine`] per `init/1`, shared by every stream: a model session per
//! camera would multiply the one expensive resource on the box by the camera
//! count. A `push_au` holds the model lock for one model pass and releases it,
//! so two cameras serialize on inference and on nothing else — not on each
//! other's decode, motion measurement or gate state.
//!
//! **One lock over detector *and* embedder, held for the whole pass**, rather
//! than one each: [`Embedder::open`] takes the detector's backend kind, so both
//! halves of a pass submit to the same execution provider, and splitting them
//! would only interleave two cameras on that one provider. Serializing is not
//! starving — four saturated streams over the clip harness (yolox-nano/ort, no
//! embedder) finished within 6% of each other's frame counts over ~7,200 passes.
//!
//! **This lock is a leaf**: nothing acquired while it is held acquires any lock
//! in this crate. `push_au` takes its own stream's lock and then this one, so the
//! order is always stream -> model and the cycle a deadlock needs does not exist.
//! The registry is touched only by open and drop, never under this lock. The
//! stage code called under it logs, and [`cairn_detect::note!`] queues the line
//! for a worker thread rather than writing it here — a stalled log reader must
//! not stall detection on every camera. What it may not do is *panic*: an unwind
//! under this lock poisons a session nothing recovers, which is why
//! `cairn_detect::log` drops a line it cannot queue and a write it cannot make.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard, Once};

use cairn_detect::decode::{DecoderKind, ModelInput};
use cairn_detect::emit::Det;
use cairn_detect::infer::{self, Detector, Embedder, InputSpec, Labels, ScoreFloors};
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
    /// Armed by [`Engine::panic_in_the_next_pass`] — a panic unwinding through
    /// the stream lock *and* the model lock, which is the only shape the frame
    /// path produces and the one thing a test cannot stage from outside.
    #[cfg(test)]
    panic_next: std::sync::atomic::AtomicBool,
    /// Armed by [`Engine::panic_in_the_next_open`] — a panic between the registry
    /// claim and the [`crate::stream::Stream`] that owns it.
    #[cfg(test)]
    panic_next_open: std::sync::atomic::AtomicBool,
}

impl Engine {
    /// Load the backend and model. Every failure is a value — see
    /// [`NativeError::ModelLoad`].
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

    /// One frame's model pass — detection, then Re-ID over the person crops, the
    /// same composition both of the plugin's inference loops run. The tensor is
    /// cloned only when an embedder is configured, because `detect` consumes it.
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

    /// Whether a previous pass panicked inside this session. Read by
    /// [`crate::StreamRef::poisoned_by`], which cannot tell the two poisonings
    /// apart from the stream lock alone.
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

/// Stop libav writing the BEAM's stderr for us.
///
/// Out of process libav's chatter was a child's stderr; in-VM it is the node's
/// log, and a camera joining mid-GOP or any flaky RTSP source emits two
/// `AV_LOG_ERROR` lines *per malformed access unit* (`No start code is found.` /
/// `Error splitting the input into NAL units.`) at frame rate, per camera.
/// Nothing is lost by cutting them: those are the tolerated errors `Stream::note`
/// already counts and rate-limits per camera. `AV_LOG_FATAL` and `AV_LOG_PANIC`
/// still print.
///
/// A level rather than an `av_log_set_callback`: routing the text through
/// [`note!`] means reformatting a `va_list`, whose bindgen type differs between
/// x86_64 and the aarch64 board — an FFI portability risk taken for messages
/// this suppresses anyway. libav's own writer is C stdio and cannot panic.
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

/// The camera ids with a live stream on this engine.
///
/// Not a lookup table — streams are reached through their own resource handles —
/// but the answer to "is this camera already open", which a host holding opaque
/// handles cannot ask itself.
#[derive(Default)]
struct Registry(Mutex<HashSet<String>>);

impl Registry {
    /// Claim a camera id, or refuse because it already has a stream: two streams
    /// for one camera would hold their own motion background and gate state each
    /// while emitting under the same id, so the host would see one camera's
    /// frames gated by two policies that disagree.
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
    /// of ids, and refusing every later `open_stream` because an unrelated stage
    /// panicked would be the worse failure. The *model* lock is the opposite case
    /// — see [`NativeError::ModelPoisoned`].
    fn ids(&self) -> MutexGuard<'_, HashSet<String>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// `open_stream` runs on a dirty IO scheduler, so N Elixir processes reach
    /// the claim at once and exactly one may win.
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
