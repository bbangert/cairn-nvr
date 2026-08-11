//! The inference half of the split NIF boundary (D-C2): sampled content-rect
//! RGB frames in as terms, observation terms out. The model session — `ort`
//! CPU or the QNN/HTP plugin EP, our own in-tree pin (D-C1) — the detection
//! gate, heads/NMS and Re-ID all live behind this library; the decode half is
//! `cairn-native`, and the two share no resource: what an engine resolves
//! (its input spec) crosses to the decode side as plain terms
//! (`engine_spec`).
//!
//! Failures are values, because the catching is narrower than it looks: rustler
//! unwinds a NIF body into an error term, but not a resource destructor
//! (`teardown`), and nothing catches an abort or a C++ exception out of ORT.
//! `error`'s doc is the per-stream/engine-wide partition the host dispatches on.
//! One class of failure stays an exception: an argument the `NifMap` decoders
//! refuse (a negative integer where `usize` is promised, a wrong-shaped map)
//! raises `ArgumentError` in the caller *before* any body runs — a caller bug,
//! not a stage fault, and so deliberately outside the error-term contract.
//!
//! Calls block the caller on a dirty scheduler, ~12 ms per inference. The one
//! shared session is the only admission control and there is none here: past
//! what it can pass, surplus becomes `push_frame` latency for the host to
//! refuse.

mod config;
mod engine;
mod error;
mod observation;
mod stream;
mod teardown;

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use rustler::{Binary, Env, NifMap, Resource, ResourceArc};

use cairn_detect::infer::InputSize;
use cairn_detect::motion::MotionVerdict;

pub use config::{RawInitConfig, RawQnnOptions, RawStreamParams};
pub use engine::Engine;
pub use error::{NativeError, Result};
pub use observation::FrameObservations;
pub use stream::{Frame, Stream};

pub struct EngineRef(pub Arc<Engine>);

#[rustler::resource_impl]
impl Resource for EngineRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

/// One stream's state, `None` once closed so that `close_stream` frees it now
/// rather than at the next GC.
pub struct StreamRef {
    /// Held only so a poisoned lock can be named — see [`Self::poisoned_by`].
    engine: Arc<Engine>,
    state: Mutex<Option<Stream>>,
}

#[rustler::resource_impl]
impl Resource for StreamRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

impl StreamRef {
    pub fn new(engine: Arc<Engine>, stream: Stream) -> Self {
        Self {
            engine,
            state: Mutex::new(Some(stream)),
        }
    }

    /// The instant is read after the lock, not before: it dates the detection
    /// gate's windows, and a caller that queued behind another push would
    /// otherwise age them by however long it waited.
    pub fn push(&self, frame: Frame<'_>) -> Result<Vec<FrameObservations>> {
        let mut state = self.state.lock().map_err(|_| self.poisoned_by())?;
        let stream = state.as_mut().ok_or(NativeError::Closed)?;
        stream.push_frame(frame, Instant::now())
    }

    /// Use versus drop: [`Self::push`] refuses a poisoned lock because it would
    /// have to run the stages over half-updated state; this recovers it because
    /// all it does is drop that state. Refusing here would hold the camera id in
    /// the registry until the BEAM collected the handle, so the reopen
    /// `poisoned` asks `Cairn.Native.Host` for would be refused as a duplicate
    /// and the camera would stay dark.
    pub fn close(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.take().is_some()
    }

    /// Which fault a poisoned stream lock is reporting: see
    /// [`NativeError::ModelPoisoned`] for why the model lock outranks it.
    fn poisoned_by(&self) -> NativeError {
        if self.engine.model_is_poisoned() {
            NativeError::ModelPoisoned
        } else {
            NativeError::Poisoned
        }
    }

    /// Poison this stream's lock the way a gate or packing panic does: under
    /// this lock, never taking the model's.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn poison_state(&self) {
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            let _guard = self.state.lock().unwrap();
            panic!("inside this stream's gate");
        }));
        assert!(panicked.is_err());
        assert!(self.state.is_poisoned());
    }

    /// Whether a push panicked and poisoned the state — the harness's own
    /// assertion surface, since the field is private.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn state_is_poisoned(&self) -> bool {
        self.state.is_poisoned()
    }
}

/// `cairn_detect::motion::MotionVerdict`, term-shaped. The fraction survives
/// the f32 -> f64 -> f32 round trip exactly, so carrying it through terms
/// loses nothing.
#[derive(NifMap)]
pub struct RawMotionVerdict {
    changed_fraction: f64,
    motion: bool,
    calibrating: bool,
    scene_cut: bool,
}

impl From<RawMotionVerdict> for MotionVerdict {
    fn from(raw: RawMotionVerdict) -> Self {
        Self {
            changed_fraction: raw.changed_fraction as f32,
            motion: raw.motion,
            calibrating: raw.calibrating,
            scene_cut: raw.scene_cut,
        }
    }
}

/// What `push_frame` takes alongside the payload binary: the metadata the
/// decode half minted, handed back through `Cairn.Pipeline.Decoder`'s buffer.
#[derive(NifMap)]
pub struct RawFrameMeta {
    width: usize,
    height: usize,
    orig_width: usize,
    orig_height: usize,
    pts: Option<i64>,
    observed_at_ms: i64,
    motion: Option<RawMotionVerdict>,
}

/// The engine's resolved input spec as plain terms — what the decode half is
/// built from, since no resource can cross between two NIF libraries. The
/// spellings round-trip through `cairn-detect`'s own `wire` helpers, so the
/// decoder cannot be built for a subtly different model than the one that
/// resolved them.
#[derive(NifMap)]
pub struct RawInputSpec {
    width: usize,
    height: usize,
    encoding: String,
    resize: String,
    resize_pad: u8,
}

/// Load the backend and model, once per VM.
///
/// DirtyCpu rather than DirtyIo: reading the artifact is the small half and
/// building the session is the rest — on QNN a multi-second HTP graph compile.
#[rustler::nif(schedule = "DirtyCpu")]
fn init(config: RawInitConfig) -> Result<ResourceArc<EngineRef>> {
    guarded("init", || {
        let engine = Engine::open(config.resolve()?)?;
        Ok(ResourceArc::new(EngineRef(Arc::new(engine))))
    })
}

/// The engine's resolved input spec, for the host to hand to the decode
/// library's `open_decoder` — one source of truth for what both halves are
/// built for, restated as terms because that is all that can cross.
#[rustler::nif]
fn engine_spec(engine: ResourceArc<EngineRef>) -> RawInputSpec {
    let spec = engine.0.input_spec;
    let (resize, resize_pad) = spec.resize.wire();
    RawInputSpec {
        width: spec.size.w,
        height: spec.size.h,
        encoding: spec.encoding.wire_name().to_string(),
        resize: resize.to_string(),
        resize_pad,
    }
}

/// Open one stream on this engine, claiming its stream id: one stream per
/// camera, because two would each hold their own gate state while emitting
/// under one id.
#[rustler::nif(schedule = "DirtyCpu")]
fn open_stream(
    engine: ResourceArc<EngineRef>,
    stream_id: String,
    params: RawStreamParams,
) -> Result<ResourceArc<StreamRef>> {
    guarded("open_stream", || {
        let stream = Stream::open(Arc::clone(&engine.0), stream_id, params.resolve()?)?;
        Ok(ResourceArc::new(StreamRef::new(
            Arc::clone(&engine.0),
            stream,
        )))
    })
}

/// Take one decoded frame through the detection gate and the model.
///
/// `ended_tracks` is always empty, and is here only because the shape is the
/// host's: nothing below mints an identity (`plugin.hello` says
/// `object_tracking: false`), so `Cairn.Tracker` ends tracks.
#[rustler::nif(schedule = "DirtyCpu")]
fn push_frame(
    stream: ResourceArc<StreamRef>,
    payload: Binary<'_>,
    meta: RawFrameMeta,
    time_base: (i32, i32),
) -> Result<(Vec<FrameObservations>, Vec<String>)> {
    guarded("push_frame", || {
        let frame = Frame {
            rgb: payload.as_slice(),
            content: InputSize {
                w: meta.width,
                h: meta.height,
            },
            orig: InputSize {
                w: meta.orig_width,
                h: meta.orig_height,
            },
            pts: meta.pts,
            time_base,
            observed_at_ms: meta.observed_at_ms,
            motion: meta.motion.map(MotionVerdict::from),
        };
        let frames = stream.push(frame)?;
        Ok((frames, Vec::new()))
    })
}

/// The CPU-side model-pass baseline `Cairn.Native.Health` compares an
/// accelerator's own latency against. A second, CPU-side model load — not
/// the accelerator's session — so it costs one; the host calls it once, at
/// engine init.
#[rustler::nif(schedule = "DirtyCpu")]
fn cpu_baseline_ms(config: RawInitConfig, passes: usize) -> Result<f64> {
    guarded("cpu_baseline_ms", || {
        engine::cpu_baseline_ms(&config.resolve()?, passes)
    })
}

/// Close a stream, releasing its stream id.
///
/// `{:ok, false}` for an already-closed stream: the host closing a stream it has
/// also dropped the last reference to is a race it should not have to win.
#[rustler::nif(schedule = "DirtyIo")]
fn close_stream(stream: ResourceArc<StreamRef>) -> Result<bool> {
    guarded("close_stream", || Ok(stream.close()))
}

/// Run one NIF body, turning a panic into a term rather than into rustler's
/// Erlang exception: `Cairn.Native.Host` decides whether a stream is closed, and
/// cannot if it is told a process died instead. Destructors are not covered —
/// see the `teardown` module.
pub fn guarded<T>(what: &'static str, body: impl FnOnce() -> Result<T>) -> Result<T> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(payload) => Err(NativeError::Panicked(format!(
            "{what} panicked: {}",
            panic_message(&payload)
        ))),
    }
}

fn panic_message(payload: &Box<dyn Any + Send>) -> &str {
    if let Some(message) = payload.downcast_ref::<&'static str>() {
        message
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message
    } else {
        "unknown payload"
    }
}

/// Wait (bounded) for every native drop deferred so far to finish.
///
/// For the exit path only: callers halting the VM run this first, because a
/// halt racing the teardown thread mid-drop is the observed exit-time abort
/// and fastrpc hang on QCS6490. `true` means drained; `false` means the
/// timeout passed with drops still running, and the caller halts into the
/// race knowingly.
#[rustler::nif(schedule = "DirtyIo")]
fn drain_teardown(timeout_ms: u64) -> bool {
    teardown::drain(std::time::Duration::from_millis(timeout_ms))
}

rustler::init!("Elixir.CairnOrt");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panicking_body_becomes_an_error_and_not_an_unwind() {
        let caught = guarded("test", || -> Result<()> { panic!("the model exploded") });
        let error = caught.unwrap_err();
        assert_eq!(error.reason(), "panicked");
        assert!(error.message().contains("the model exploded"), "{error:?}");
        assert!(error.message().contains("test"), "{error:?}");
    }

    #[test]
    fn a_payload_that_is_not_a_string_still_returns() {
        let caught = guarded("test", || -> Result<()> {
            std::panic::panic_any(42u8);
        });
        assert_eq!(caught.unwrap_err().reason(), "panicked");
    }

    #[test]
    fn a_body_that_returns_normally_is_untouched() {
        assert_eq!(guarded("test", || Ok(7)).unwrap(), 7);
        assert_eq!(
            guarded("test", || -> Result<()> { Err(NativeError::Closed) })
                .unwrap_err()
                .reason(),
            "closed"
        );
    }

    #[test]
    fn a_motion_verdict_survives_the_term_shape_exactly() {
        let raw = RawMotionVerdict {
            changed_fraction: 1.0 / 3.0,
            motion: true,
            calibrating: false,
            scene_cut: false,
        };
        let verdict = MotionVerdict::from(raw);
        assert_eq!(verdict.changed_fraction, (1.0f64 / 3.0) as f32);
        assert!(verdict.motion);
    }
}
