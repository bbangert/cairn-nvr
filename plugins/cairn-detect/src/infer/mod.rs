//! Inference and postprocess.
//!
//! Two things vary independently here and are separated on purpose. *Which
//! runtime executes the model* is [`backend`]: one trait, one implementation
//! (onnxruntime on CPU — what every deployment runs), and two names that parse
//! and refuse. *How a family is fed and read* is everything else in this
//! module, and it is backend-agnostic: sniffing, sizing and decode work from a
//! model's declared names and shapes, never from an SDK's types.
//!
//! Everything that differs between detector families is stated once, as data,
//! in a [`ModelProfile`]: how frames must be *fed* to the model ([`InputSpec`])
//! and how its output must be read ([`profile::OutputSpec`]). Adding a family
//! is adding a profile to [`catalog::PROFILES`]; the code is family-agnostic.
//!
//! A profile is either named on the command line (`--model-profile`) or
//! sniffed from the model's own I/O. Sniffing is deliberately strict: a shape
//! that fits *two* built-in profiles is an error naming both, never a silent
//! pick — the two are decoded completely differently and the wrong one emits
//! plausible garbage rather than failing.
//!
//! None of the input half is declared by an ONNX graph. The channel order, the
//! 0..1-vs-0..255 scaling and the resize policy live in the model's training
//! transform and an export inherits them as unwritten preconditions. Feeding
//! the wrong ones is not a small accuracy loss: YOLOX-Nano fed 0..1 RGB
//! returns no detection at all above 0.3 on a frame where 0..255 BGR finds a
//! car and a potted plant.

mod backend;
mod catalog;
mod detector;
mod embedder;
mod encoding;
mod geometry;
mod heads;
mod labels;
mod profile;
mod resolve;

/// Cap on detections in one frame's output line.
///
/// `pub(super)` rather than `pub`: `heads` is the only caller, and nothing
/// outside `infer` names it (T1.4).
pub(super) const MAX_DETS: usize = 32;

// What `infer::X` resolves to for the rest of this library, for main.rs and for
// `cairn-native`. Deliberately *narrower* than the pre-split surface: fifteen items
// that were `pub` only because everything shared one module are named nowhere
// outside `infer` and are no longer re-exported (T1.4).
pub use backend::{BackendKind, QnnOptions};
pub use detector::Detector;
pub use embedder::{embed_persons, quantize_base64, Embedder};
pub use geometry::{Fit, InputSize, Projection};
pub use labels::{Labels, ScoreFloors, TrackFloorOverrides};
pub use profile::{InputSpec, ModelProfile};

// decode.rs and hwdecode.rs name these two only from their own test modules, and no
// host outside this library names them at all. Gated so the public surface stays
// what non-test callers use; an unconditional re-export would be permanent.
#[cfg(test)]
pub use {encoding::TensorEncoding, geometry::ResizePolicy};
