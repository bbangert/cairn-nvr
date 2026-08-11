//! The decode half of the split NIF boundary (D-C2): compressed access units
//! in, content-rect RGB frame terms out. Decode, resize and the motion
//! measurement live behind this library; the inference half is `cairn-ort`,
//! and the two share no resource — the input spec a decoder is built for
//! arrives as plain terms (`cairn-ort`'s `engine_spec` is the producer).
//!
//! Failures are values, because the catching is narrower than it looks: rustler
//! unwinds a NIF body into an error term, but not a resource destructor
//! (`teardown`), and nothing catches an abort out of a driver. One class of
//! failure stays an exception: an argument the `NifMap` decoders refuse (a
//! negative integer where `usize` is promised, a wrong-shaped map) raises
//! `ArgumentError` in the caller *before* any body runs — a caller bug, not a
//! stage fault, and so deliberately outside the error-term contract.
//!
//! Calls block the caller on a dirty scheduler — ~1 ms for a decode, ~27 ms
//! for a sampled frame's conversion on the boards.

#[cfg(test)]
mod clip;
mod config;
mod decoder;
mod error;
mod teardown;

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

use rustler::{Binary, Env, NifMap, OwnedBinary, Resource, ResourceArc};

use cairn_detect::motion::MotionVerdict;
use config::RawDecoderParams;
use decoder::{DecodeStream, Decoded, DecodedFrame};
use error::{NativeError, Result};

/// One camera's decoder, `None` once closed so that `close_decoder` frees it
/// now: a hardware decoder holds GPU surfaces a departed camera should not
/// keep until the next GC.
///
/// No engine anywhere near this — a decode stream never takes a model lock,
/// so its poisoned lock only ever names its own fault.
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

    /// Recovering a poisoned lock here only drops state, and refusing would
    /// keep a dead decoder's driver handles alive until the BEAM collected
    /// the term.
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

/// `None` when the binary could not be allocated: the frame is lost, the call
/// is not. Returning an error instead would drop the `completed` bit — the
/// caller's rate gate would under-spend its interval — and would spell a
/// VM-wide memory event in the tolerated per-stream `decode` class, telling
/// the host one camera's bitstream is at fault.
fn encode_frame<'a>(env: Env<'a>, frame: DecodedFrame) -> Option<RawDecodedFrame<'a>> {
    let Some(mut payload) = OwnedBinary::new(frame.rgb.len()) else {
        cairn_detect::note!(
            "decode_au: allocating a {}-byte frame binary failed; the frame is dropped",
            frame.rgb.len()
        );
        return None;
    };
    payload.as_mut_slice().copy_from_slice(&frame.rgb);
    Some(RawDecodedFrame {
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

/// Open one camera's decoder for the input spec an engine resolved —
/// `params` carries that spec as terms, exactly as `cairn-ort`'s
/// `engine_spec` spells it.
///
/// DirtyIo: opening a decoder probes hardware backends in turn — device nodes,
/// drivers, a GPU filter graph — each of which can block on a driver's answer.
#[rustler::nif(schedule = "DirtyIo")]
fn open_decoder(camera_id: String, params: RawDecoderParams) -> Result<ResourceArc<DecoderRef>> {
    guarded("open_decoder", || {
        let stream = DecodeStream::open(camera_id, params.resolve()?)?;
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
        let frame = decoded.frame.and_then(|frame| encode_frame(env, frame));
        Ok((decoded.completed, frame))
    })
}

/// Close a decode stream, freeing its decoder now rather than at the next GC.
#[rustler::nif(schedule = "DirtyIo")]
fn close_decoder(decoder: ResourceArc<DecoderRef>) -> Result<bool> {
    guarded("close_decoder", || Ok(decoder.close()))
}

/// Run one NIF body, turning a panic into a term rather than into rustler's
/// Erlang exception: the host decides whether a stream is closed, and cannot
/// if it is told a process died instead. Destructors are not covered — see
/// [`teardown`].
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

rustler::init!("Elixir.Cairn.Native");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panicking_body_becomes_an_error_and_not_an_unwind() {
        let caught = guarded("test", || -> Result<()> { panic!("the decoder exploded") });
        let error = caught.unwrap_err();
        assert_eq!(error.reason(), "panicked");
        assert!(
            error.message().contains("the decoder exploded"),
            "{error:?}"
        );
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
