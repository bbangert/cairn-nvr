//! ONNX inference and postprocess.
//!
//! Everything that differs between detector families is stated once, as data,
//! in a [`ModelProfile`]: how frames must be *fed* to the model ([`InputSpec`])
//! and how its output must be read ([`OutputSpec`]). Adding a family is adding
//! a profile to [`PROFILES`]; the code below is family-agnostic.
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

#[cfg(test)]
mod golden;

/// Cap on detections in one frame's output line.
pub const MAX_DETS: usize = 32;

// The public surface is unchanged: `crate::infer::X` keeps resolving for
// main.rs, decode.rs, hwdecode.rs and multiplex.rs exactly as it did when this
// was one file.
pub use detector::Detector;
pub use geometry::{Fit, InputSize, Projection};
pub use labels::{Labels, ScoreFloors};
pub use profile::{InputSpec, ModelProfile};

// `decode.rs` names these two only from its own tests, and a binary crate has
// no consumer outside itself — so an unconditional re-export reads as dead to
// rustc. Gated rather than blanket-`#[allow(unused_imports)]`, which would also
// hide a re-export that really had gone dead.
#[cfg(test)]
pub use {encoding::TensorEncoding, geometry::ResizePolicy};
