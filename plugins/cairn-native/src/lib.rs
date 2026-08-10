//! The NIF boundary for the `cairn-detect` stages, split at the frame (D-C2):
//! `decode_au` turns compressed access units into content-rect RGB frame
//! terms, and `push_frame` turns those frames into observation terms. The
//! stages themselves are `cairn-detect`, which the plugin binary also links,
//! so there is one implementation — and the bytes cross the boundary exactly,
//! so the split changes no number.
//!
//! Failures are values, because the catching is narrower than it looks: rustler
//! unwinds a NIF body into an error term, but not a resource destructor
//! (`teardown`), and nothing catches an abort or a C++ exception out of ORT.
//! `error`'s doc is the per-stream/engine-wide partition the host dispatches on.
//!
//! Calls block the caller on a dirty scheduler — ~1 ms for a decode, ~12 ms
//! per inference. The one shared session is the only admission control and
//! there is none here: past what it can pass, surplus becomes `push_frame`
//! latency for the host to refuse.

#[cfg(test)]
mod clip;
mod config;
mod decoder;
mod engine;
mod error;
mod observation;
mod stream;
mod teardown;

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use rustler::{Binary, Env, NifMap, OwnedBinary, Resource, ResourceArc};

use cairn_detect::infer::InputSize;
use cairn_detect::motion::MotionVerdict;
use config::{RawInitConfig, RawStreamParams};
use decoder::{DecodeStream, Decoded, DecodedFrame};
use engine::Engine;
use error::{NativeError, Result};
use observation::FrameObservations;
use stream::{Frame, Stream};

struct EngineRef(Arc<Engine>);

#[rustler::resource_impl]
impl Resource for EngineRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

/// One stream's state, `None` once closed so that `close_stream` frees it now
/// rather than at the next GC.
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

    /// The instant is read after the lock, not before: it dates the detection
    /// gate's windows, and a caller that queued behind another push would
    /// otherwise age them by however long it waited.
    fn push(&self, frame: Frame<'_>) -> Result<Vec<FrameObservations>> {
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

    /// Poison this stream's lock the way a gate or packing panic does: under
    /// this lock, never taking the model's.
    #[cfg(test)]
    fn poison_state(&self) {
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            let _guard = self.state.lock().unwrap();
            panic!("inside this stream's gate");
        }));
        assert!(panicked.is_err());
        assert!(self.state.is_poisoned());
    }
}

/// One camera's decoder, `None` once closed so that `close_decoder` frees it
/// now: a hardware decoder holds GPU surfaces a departed camera should not
/// keep until the next GC.
///
/// No engine here — a decode stream never takes the model lock, so its
/// poisoned lock only ever names its own fault.
struct DecoderRef {
    state: Mutex<Option<DecodeStream>>,
}

#[rustler::resource_impl]
impl Resource for DecoderRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

impl DecoderRef {
    fn new(stream: DecodeStream) -> Self {
        Self {
            state: Mutex::new(Some(stream)),
        }
    }

    fn push(&self, au: &[u8], pts: i64, sample: bool) -> Result<Decoded> {
        let mut state = self.state.lock().map_err(|_| NativeError::Poisoned)?;
        let stream = state.as_mut().ok_or(NativeError::Closed)?;
        stream.push_au(au, pts, sample)
    }

    /// As [`StreamRef::close`]: recovering a poisoned lock here only drops
    /// state, and refusing would keep a dead decoder's driver handles alive
    /// until the BEAM collected the term.
    fn close(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.take().is_some()
    }
}

/// The term shape of one decoded frame — `Cairn.Pipeline.Decoder`'s buffer
/// payload and metadata, minted here so the copy out of the scaler is the
/// only copy.
#[derive(NifMap)]
struct RawDecodedFrame<'a> {
    payload: Binary<'a>,
    width: usize,
    height: usize,
    orig_width: usize,
    orig_height: usize,
    pts: Option<i64>,
    observed_at_ms: i64,
    scale_x: f64,
    scale_y: f64,
    pad_w: usize,
    pad_h: usize,
    motion: Option<RawMotionVerdict>,
}

/// `cairn_detect::motion::MotionVerdict`, term-shaped. The fraction survives
/// the f32 -> f64 -> f32 round trip exactly, so carrying it through terms
/// loses nothing.
#[derive(NifMap)]
struct RawMotionVerdict {
    changed_fraction: f64,
    motion: bool,
    calibrating: bool,
    scene_cut: bool,
}

impl From<MotionVerdict> for RawMotionVerdict {
    fn from(verdict: MotionVerdict) -> Self {
        Self {
            changed_fraction: verdict.changed_fraction as f64,
            motion: verdict.motion,
            calibrating: verdict.calibrating,
            scene_cut: verdict.scene_cut,
        }
    }
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

/// What `push_frame` takes alongside the payload binary: the metadata
/// `decode_au` minted, handed back through `Cairn.Pipeline.Decoder`'s buffer.
#[derive(NifMap)]
struct RawFrameMeta {
    width: usize,
    height: usize,
    orig_width: usize,
    orig_height: usize,
    pts: Option<i64>,
    observed_at_ms: i64,
    motion: Option<RawMotionVerdict>,
}

fn encode_frame<'a>(env: Env<'a>, frame: DecodedFrame) -> Result<RawDecodedFrame<'a>> {
    let mut payload = OwnedBinary::new(frame.rgb.len()).ok_or_else(|| {
        NativeError::Decode(format!(
            "allocating a {}-byte frame binary",
            frame.rgb.len()
        ))
    })?;
    payload.as_mut_slice().copy_from_slice(&frame.rgb);
    Ok(RawDecodedFrame {
        payload: Binary::from_owned(payload, env),
        width: frame.width,
        height: frame.height,
        orig_width: frame.orig_width,
        orig_height: frame.orig_height,
        pts: frame.pts,
        observed_at_ms: frame.observed_at_ms,
        scale_x: frame.scale_x,
        scale_y: frame.scale_y,
        pad_w: frame.pad_w,
        pad_h: frame.pad_h,
        motion: frame.motion.map(RawMotionVerdict::from),
    })
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

/// Open one camera's inference stream on this engine, claiming its camera id.
#[rustler::nif(schedule = "DirtyCpu")]
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

/// Open one camera's decode stream against this engine's resolved input spec.
///
/// No camera-id claim — that guards the inference stream — and no model: the
/// engine is here for its resolved decoder kind, input spec and sample rate,
/// so both halves of the boundary are built for the same model without the
/// host restating it.
///
/// DirtyIo: opening a decoder probes hardware backends in turn — device nodes,
/// drivers, a GPU filter graph — each of which can block on a driver's answer.
#[rustler::nif(schedule = "DirtyIo")]
fn open_decoder(
    engine: ResourceArc<EngineRef>,
    camera_id: String,
    params: RawStreamParams,
) -> Result<ResourceArc<DecoderRef>> {
    guarded("open_decoder", || {
        let stream = DecodeStream::open(&engine.0, camera_id, params.resolve()?)?;
        Ok(ResourceArc::new(DecoderRef::new(stream)))
    })
}

/// Feed one access unit; take its frame when `sample` cleared the caller's
/// rate gate.
///
/// The boolean is whether the decoder *completed* a frame for this access
/// unit — what the caller's rate gate spends its interval on, whatever became
/// of the conversion. Every access unit is decoded regardless of `sample`,
/// because a stateful decoder needs its references.
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_au<'a>(
    env: Env<'a>,
    decoder: ResourceArc<DecoderRef>,
    au: Binary<'_>,
    pts: i64,
    sample: bool,
) -> Result<(bool, Option<RawDecodedFrame<'a>>)> {
    guarded("decode_au", || {
        let decoded = decoder.push(au.as_slice(), pts, sample)?;
        let frame = decoded
            .frame
            .map(|frame| encode_frame(env, frame))
            .transpose()?;
        Ok((decoded.completed, frame))
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

/// Close an inference stream, releasing its camera id.
///
/// `{:ok, false}` for an already-closed stream: the host closing a stream it has
/// also dropped the last reference to is a race it should not have to win.
#[rustler::nif(schedule = "DirtyIo")]
fn close_stream(stream: ResourceArc<StreamRef>) -> Result<bool> {
    guarded("close_stream", || Ok(stream.close()))
}

/// Close a decode stream, freeing its decoder now rather than at the next GC.
#[rustler::nif(schedule = "DirtyIo")]
fn close_decoder(decoder: ResourceArc<DecoderRef>) -> Result<bool> {
    guarded("close_decoder", || Ok(decoder.close()))
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

    #[test]
    fn a_motion_verdict_round_trips_through_the_term_shape_exactly() {
        let verdict = MotionVerdict {
            changed_fraction: 0.007_812_5,
            motion: true,
            calibrating: false,
            scene_cut: false,
        };
        let back = MotionVerdict::from(RawMotionVerdict::from(verdict));
        assert_eq!(back, verdict);

        // …including a fraction with no short binary spelling
        let odd = MotionVerdict {
            changed_fraction: 1.0 / 3.0,
            ..verdict
        };
        assert_eq!(MotionVerdict::from(RawMotionVerdict::from(odd)), odd);
    }
}
