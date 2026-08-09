//! The NIF boundary for the `cairn-detect` stages: compressed access units in,
//! observation terms out (D-M2) — a decoded frame never becomes a term. The
//! stages themselves are `cairn-detect`, which the plugin binary also links, so
//! there is one implementation.
//!
//! Failures are values, because the catching is narrower than it looks: rustler
//! unwinds a NIF body into an error term, but not a resource destructor
//! (`teardown`), and nothing catches an abort or a C++ exception out of ORT.
//! `error`'s doc is the per-stream/engine-wide partition the host dispatches on.
//!
//! Calls block the caller on a dirty scheduler, ~12 ms per inference. The one
//! shared session is the only admission control and there is none here: past
//! what it can pass, surplus becomes `push_au` latency for the host to refuse.

#[cfg(test)]
mod clip;
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

use rustler::{Binary, Env, Resource, ResourceArc};

use config::{RawInitConfig, RawStreamParams};
use engine::Engine;
use error::{NativeError, Result};
use observation::FrameObservations;
use stream::Stream;

struct EngineRef(Arc<Engine>);

#[rustler::resource_impl]
impl Resource for EngineRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

/// One stream's state, `None` once closed so that `close_stream` frees the
/// decoder now: a hardware decoder holds GPU surfaces a departed camera should
/// not keep until the next GC.
struct StreamRef {
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
    fn new(engine: Arc<Engine>, stream: Stream) -> Self {
        Self {
            engine,
            state: Mutex::new(Some(stream)),
        }
    }

    /// The instant is read after the lock, not before: it paces the rate gate
    /// and dates the motion gate's windows, and a caller that queued behind
    /// another push would otherwise age both by however long it waited.
    fn push(&self, au: &[u8], pts: i64, time_base: (i32, i32)) -> Result<Vec<FrameObservations>> {
        let mut state = self.state.lock().map_err(|_| self.poisoned_by())?;
        let stream = state.as_mut().ok_or(NativeError::Closed)?;
        stream.push_au(au, pts, time_base, Instant::now())
    }

    /// Use versus drop: [`Self::push`] refuses a poisoned lock because it would
    /// have to run the stages over half-updated state; this recovers it because
    /// all it does is drop that state. Refusing here would hold the camera id in
    /// the registry until the BEAM collected the handle, so the reopen
    /// `poisoned` asks `Cairn.Native.Host` for would be refused as a duplicate
    /// and the camera would stay dark.
    fn close(&self) -> bool {
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

    /// Poison this stream's lock the way a decoder or gate panic does: under
    /// this lock, never taking the model's.
    #[cfg(test)]
    fn poison_state(&self) {
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            let _guard = self.state.lock().unwrap();
            panic!("inside this stream's decoder");
        }));
        assert!(panicked.is_err());
        assert!(self.state.is_poisoned());
    }
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

/// Open one camera's stream on this engine.
///
/// DirtyIo: opening a decoder probes hardware backends in turn — device nodes,
/// drivers, a GPU filter graph — each of which can block on a driver's answer.
#[rustler::nif(schedule = "DirtyIo")]
fn open_stream(
    engine: ResourceArc<EngineRef>,
    camera_id: String,
    params: RawStreamParams,
) -> Result<ResourceArc<StreamRef>> {
    guarded("open_stream", || {
        let stream = Stream::open(Arc::clone(&engine.0), camera_id, params.resolve()?)?;
        Ok(ResourceArc::new(StreamRef::new(
            Arc::clone(&engine.0),
            stream,
        )))
    })
}

/// Feed one access unit and take what it completed.
///
/// `ended_tracks` is always empty, and is here only because the shape is the
/// host's: nothing below mints an identity (`plugin.hello` says
/// `object_tracking: false`), so `Cairn.Tracker` ends tracks.
#[rustler::nif(schedule = "DirtyCpu")]
fn push_au(
    stream: ResourceArc<StreamRef>,
    au: Binary<'_>,
    pts: i64,
    time_base: (i32, i32),
) -> Result<(Vec<FrameObservations>, Vec<String>)> {
    guarded("push_au", || {
        let frames = stream.push(au.as_slice(), pts, time_base)?;
        Ok((frames, Vec::new()))
    })
}

/// Close a stream, freeing its decoder and releasing its camera id.
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
/// see [`teardown`].
fn guarded<T>(what: &'static str, body: impl FnOnce() -> Result<T>) -> Result<T> {
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

rustler::init!("Elixir.Cairn.Native");

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
}
