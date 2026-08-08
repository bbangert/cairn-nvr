//! The detection stages, loaded into the BEAM.
//!
//! `cairn-detect`'s decode → motion → gate → infer → Re-ID block, behind four
//! NIFs instead of behind a process and an ndjson pipe. The stages themselves
//! are not here — they are the `cairn-detect` library, which the plugin binary
//! also links, so there is one implementation and nothing to keep in sync.
//!
//! ```text
//! init(config)                        -> {:ok, engine} | {:error, {reason, message}}
//! open_stream(engine, camera, params) -> {:ok, stream} | {:error, ...}
//! push_au(stream, au, pts, time_base) -> {:ok, {observations, ended_tracks}} | {:error, ...}
//! close_stream(stream)                -> {:ok, closed?} | {:error, ...}
//! ```
//!
//! **Compressed access units in, observation terms out** (D-M2). A decoded
//! frame never becomes a term: it lives in the stream's decoder, becomes a
//! tensor, and is consumed by the model. What crosses the boundary is one
//! binary per access unit each way's worth of small terms.
//!
//! **One engine, N streams**, which is `multiplex.rs`'s arrangement without
//! the threads: every camera gets its own `Stream` — decoder, motion
//! background, gate, floors, seeds — and they share the one model session the
//! engine holds. What a stream can fail at is its own (`decode`, `infer`,
//! `poisoned`); what the engine can fail at is every stream's (`model_load`,
//! `model_poisoned`). `error`'s module doc is the partition, and the host
//! dispatches on it.
//!
//! **Every call blocks its calling process, on a dirty scheduler.** There is no
//! message-passing design here: an Elixir process hands over an access unit and
//! waits for the observations. Spike 0.5 measured ~12 ms per inference, which
//! is squarely dirty-scheduler work and nowhere near a normal scheduler's
//! budget.
//!
//! Which makes the shared session the admission control, and there is none
//! here: `--sample-fps` thins each stream against the wall clock, so once
//! cameras × sample_fps exceeds what the one session can pass, the gate stops
//! thinning anything and the surplus becomes `push_au` latency the calling
//! process waits out. The host is where a camera count that does not fit gets
//! refused; nothing below this line will refuse it.
//!
//! **A panic here is the whole node** (D-M3 as amended: no peer, in-VM). So
//! every NIF below is wrapped in [`catch_unwind`] and every failure the stages
//! can produce is a value — see `error`. Rustler catches panics too, but it
//! turns one into an Erlang exception; the host needs the *value*, so that
//! `Cairn.Native.Host` gets to decide whether a stream is closed rather than
//! being told a process died.
//!
//! The NIFs are not the only entry point. The emulator also calls the resource
//! destructors below, on the thread that released the last reference and with
//! nothing between them and the C boundary — see the `teardown` module for
//! what that costs and what runs there instead.

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

/// The model, held by the BEAM. Reference-counted rather than owned by any one
/// stream: the streams outlive each other and the model outlives all of them.
struct EngineRef(Arc<Engine>);

#[rustler::resource_impl]
impl Resource for EngineRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    /// Releasing the last engine handle releases the ORT session, and on QNN
    /// gives back an HTP context — driver work, which the BEAM would run here
    /// on the normal scheduler that collected the term. See [`teardown`].
    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

/// One stream's state.
///
/// `None` once closed, which is what makes `close_stream` free the decoder now
/// rather than whenever the BEAM collects the handle — a hardware decoder holds
/// GPU surfaces, and a camera that has gone away should not keep them until the
/// next GC.
///
/// The mutex is what makes two Elixir processes pushing to the same stream
/// safe: they serialize here, on this camera's decoder, and the second one
/// waits. Streams hold one of these each, so that wait is per camera and a
/// stream nobody else is pushing to never sees it.
///
/// The engine is held beside it, and only so that a poisoned lock can be
/// *named*: `push` nests stream -> model, so a panic inside a model pass
/// poisons both, and the answer this stream owes the host is about the model.
struct StreamRef {
    engine: Arc<Engine>,
    state: Mutex<Option<Stream>>,
}

#[rustler::resource_impl]
impl Resource for StreamRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    /// A handle collected without `close_stream` still frees a decoder — hardware
    /// teardown on the accelerated paths — and the BEAM would run it here on the
    /// normal scheduler that collected the term. See [`teardown`].
    ///
    /// The camera id comes back when that drop lands rather than when the term
    /// is collected. Nothing regresses: the GC is not a moment the host controls
    /// either, and `close_stream` — which is how the host actually gives a
    /// camera back — still releases it inline, on a dirty scheduler.
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

    fn close(&self) -> Result<bool> {
        let mut state = self.state.lock().map_err(|_| self.poisoned_by())?;
        Ok(state.take().is_some())
    }

    /// Which fault a poisoned stream lock is reporting.
    ///
    /// The lock says only that *some* previous call unwound while holding it,
    /// and `push` holds it across the model pass — so the poisoning panic is as
    /// likely to have been the shared session's as this camera's, and the two
    /// call for opposite host actions. The model lock is what tells them apart:
    /// it is poisoned only by a panic inside a pass, and on this path a pass is
    /// only ever entered from [`Self::push`], with the stream lock already held.
    /// So a poisoned stream lock is the less informative of the two, and a
    /// poisoned model outranks it on every stream — including the one that hit
    /// it, which is the case a stream reading only its own lock gets backwards.
    fn poisoned_by(&self) -> NativeError {
        if self.engine.model_is_poisoned() {
            NativeError::ModelPoisoned
        } else {
            NativeError::Poisoned
        }
    }

    /// Poison this stream's lock the way a panic in *its own* state does — a
    /// decoder or gate panic, which runs under this lock and never takes the
    /// model's.
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
/// DirtyIo: the cost here is opening a decoder, which probes hardware backends
/// in turn — device nodes, drivers, a GPU filter graph — and any of them can
/// block for as long as a driver takes to answer. Almost no computation
/// happens until the first access unit arrives.
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
/// `ended_tracks` is always empty and is here because the shape is the host's:
/// this block mints no identity and carries none across frames — `plugin.hello`
/// says `object_tracking: false` for the same reason — so `Cairn.Tracker` ends
/// tracks and nothing here does.
///
/// DirtyCpu, and the reason this whole design is on dirty schedulers at all:
/// decode plus a model pass is milliseconds, which is orders of magnitude past
/// what a normal scheduler may be held for.
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
/// should not have to win.
///
/// DirtyIo for the mirror of `open_stream`'s reason — the work is tearing down
/// a decoder, and for the hardware paths that is driver and device teardown.
#[rustler::nif(schedule = "DirtyIo")]
fn close_stream(stream: ResourceArc<StreamRef>) -> Result<bool> {
    guarded("close_stream", || stream.close())
}

/// Run one NIF body, turning a panic into a term.
///
/// The mandatory half of the D-M3 amendment: in-VM, an unwind that reaches the
/// C boundary aborts, and an abort is every camera on the box. Nothing below
/// this line is allowed to panic in the first place — this is the backstop for
/// the panic nobody predicted, not a licence for the ones that could be
/// returned instead.
///
/// This covers the NIF bodies and nothing else. A resource destructor is called
/// from C too and is *not* routed through here — rustler does not wrap it — so
/// [`teardown`] carries the same prohibition on its own.
///
/// Whatever lock a panicking body was holding stays poisoned, which is
/// deliberate: rather than run the stages over state nobody knows the shape of,
/// the next call refuses. Which refusal it is — [`NativeError::Poisoned`] for
/// this stream's own state, [`NativeError::ModelPoisoned`] for the shared
/// session — is decided by [`StreamRef::poisoned_by`], because a panic in a
/// model pass unwinds through both locks and the stream's own is the less
/// informative of the two.
fn guarded<T>(what: &'static str, body: impl FnOnce() -> Result<T>) -> Result<T> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(payload) => Err(NativeError::Panicked(format!(
            "{what} panicked: {}",
            panic_message(&payload)
        ))),
    }
}

/// What a panic payload says, for the two shapes `panic!` actually produces.
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
