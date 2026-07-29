//! ONNX inference and postprocess.
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

mod catalog;
mod detector;
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

// What `crate::infer::X` still resolves to for main.rs, decode.rs, hwdecode.rs
// and multiplex.rs. Deliberately *narrower* than the pre-split surface: fifteen
// items that were `pub` only because everything shared one module — PROFILES,
// the four family constants, Layout, Outputs, Declared and the rest — are named
// nowhere outside `infer` and are no longer re-exported (T1.4).
pub use detector::Detector;
pub use geometry::{Fit, InputSize, Projection};
pub use labels::{Labels, ScoreFloors};
pub use profile::{InputSpec, ModelProfile};

// decode.rs and hwdecode.rs name these two only from their own test modules,
// and a binary crate has no consumer outside itself — so an unconditional
// re-export reads as dead to rustc and `-D warnings` makes that fatal. Gated
// rather than blanket-`#[allow(unused_imports)]`, which would also hide a
// re-export that really had gone dead.
#[cfg(test)]
pub use {encoding::TensorEncoding, geometry::ResizePolicy};
