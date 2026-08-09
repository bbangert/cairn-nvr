//! The detection stages, loaded into the BEAM.
//!
//! The stages are not here: they are the `cairn-detect` library, which the
//! plugin binary also links, so there is one implementation and nothing to keep
//! in sync.
//!
//! **Compressed access units in, observation terms out** (D-M2). A decoded
//! frame never becomes a term: it lives in the stream's decoder, becomes a
//! tensor, and is consumed by the model.
//!
//! **A panic here is the whole node** (D-M3 as amended: no peer, in-VM), so
//! every failure the stages can produce is a value — see `error`, whose module
//! doc is also the per-stream/engine-wide partition the host dispatches on.
//!
//! **Every call blocks its calling process, on a dirty scheduler**: spike 0.5
//! measured ~12 ms per inference. Which makes the one shared session the
//! admission control, and there is none here — `--sample-fps` thins against the
//! wall clock, so past what the session can pass the surplus becomes `push_au`
//! latency the calling process waits out. A camera count that does not fit has
//! to be refused by the host; nothing below this line will refuse it.

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

/// One stream's state.
///
/// `None` once closed, which is what makes `close_stream` free the decoder now
/// rather than whenever the BEAM collects the handle — a hardware decoder holds
/// GPU surfaces a departed camera should not keep until the next GC.
struct StreamRef {
    /// Held only so that a poisoned lock can be *named*: `push` nests stream ->
    /// model, so a panic inside a model pass poisons both, and the answer this
    /// stream owes the host is about the model.
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

    /// The instant is read after the lock, not before: it is what the sample
    /// rate is measured against, so a caller that queued behind another push on
    /// this stream must not thin against the time it started waiting.
    fn push(&self, au: &[u8], pts: i64, time_base: (i32, i32)) -> Result<Vec<FrameObservations>> {
        let mut state = self.state.lock().map_err(|_| self.poisoned_by())?;
        let stream = state.as_mut().ok_or(NativeError::Closed)?;
        stream.push_au(au, pts, time_base, Instant::now())
    }

    /// Use versus drop: [`Self::push`] refuses a poisoned lock because it would
    /// have to *run* the stages over half-updated state; this recovers it
    /// because all it does is drop that state. Refusing here would hold the
    /// camera id in the engine's registry until the BEAM collected the handle,
    /// so the reopen that `poisoned` tells `Cairn.Native.Host` to perform would
    /// be refused as a duplicate and the camera would stay dark.
    fn close(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.take().is_some()
    }

    /// Which fault a poisoned stream lock is reporting.
    ///
    /// `push` holds this lock across the model pass, so the poisoning panic is
    /// as likely to have been the shared session's as this camera's — and the
    /// two call for opposite host actions. The model lock tells them apart: it
    /// is poisoned only by a panic inside a pass. So the stream's own lock is
    /// the less informative of the two, and a poisoned model outranks it on
    /// every stream *including the one that hit it* — the case a stream reading
    /// only its own lock gets backwards.
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
/// DirtyCpu rather than DirtyIo: reading the artifact is the small half, and
/// building the session is the rest — on QNN a multi-second HTP graph compile,
/// which is compute and not waiting.
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
/// drivers, a GPU filter graph — any of which can block for as long as a driver
/// takes to answer, and almost nothing here computes.
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
/// host's: this block mints no identity and carries none across frames
/// (`plugin.hello` says `object_tracking: false`), so `Cairn.Tracker` ends
/// tracks and nothing here does.
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
/// `{:ok, false}` for a stream that was already closed: idempotent, because the
/// host closing a stream it has also dropped the last reference to is a race it
/// should not have to win. DirtyIo for the mirror of `open_stream`'s reason.
#[rustler::nif(schedule = "DirtyIo")]
fn close_stream(stream: ResourceArc<StreamRef>) -> Result<bool> {
    guarded("close_stream", || Ok(stream.close()))
}

/// Run one NIF body, turning a panic into a term.
///
/// Rustler catches a panicking NIF body too, but raises an Erlang exception;
/// the host needs the *value*, so that `Cairn.Native.Host` decides whether a
/// stream is closed rather than being told a process died. Nothing below this
/// line is allowed to panic in the first place — this is the backstop for the
/// panic nobody predicted, not a licence for the ones that could be returned.
///
/// This covers the NIF bodies and nothing else. A resource destructor is called
/// from C too and is *not* routed through here — rustler does not wrap it — so
/// [`teardown`] carries the same prohibition and its own guard.
///
/// Whatever lock a panicking body held stays poisoned, deliberately: the next
/// call that would *use* it refuses, with [`StreamRef::poisoned_by`] deciding
/// which refusal. Tearing that state down is the exception — see
/// [`StreamRef::close`].
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
