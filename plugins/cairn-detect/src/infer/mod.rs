//! Inference and postprocess.
//!
//! Two things vary independently here and are separated on purpose. *Which
//! runtime executes the model* is [`backend`]: one trait, two implementations
//! here (onnxruntime on the CPU EP, and on Qualcomm's HTP via the QNN plugin
//! EP), and any other that a board library implements in its own crate and
//! registers by name. *How a family is fed and read* is everything else in this
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
mod baseline;
mod catalog;
mod detector;
mod embedder;
mod encoding;
mod geometry;
mod heads;
mod labels;
mod profile;
mod qparams;
mod resolve;

/// Cap on detections in one frame's output line.
///
/// `pub(super)` rather than `pub`: `heads` is the only caller, and nothing
/// outside `infer` names it (T1.4).
pub(super) const MAX_DETS: usize = 32;

// What `infer::X` resolves to for the rest of this library and for the crates
// that link it. An item is here because something outside `infer` names it,
// not because it is `pub` inside (T1.4).
pub use backend::{select, BackendKind, QnnOptions, Selected};
// The backend seam, for a board library implementing `Backend` outside this
// crate and registering it as a `Provider`.
pub use backend::{
    Backend, Capabilities, Descriptor, InputElement, InputTensor, ModelIo, Provider,
    SessionOptions, Tensors,
};
pub use baseline::{
    cpu_baseline_ms, measure_cpu_baseline, open_baseline_detector, BASELINE_PASSES,
};
pub use detector::Detector;
pub use embedder::{embed_persons, embedder_backend, quantize_base64, Embedder};
pub use geometry::{Fit, InputSize, Projection};
pub use heads::Raw;
pub use labels::{Labels, ScoreFloors, TrackFloorOverrides};
pub use profile::{InputSpec, ModelProfile};
pub use qparams::IoQuant;
pub use resolve::Declared;

// Once test-only, now load-bearing across the split NIF boundary: a resolved
// spec crosses between the inference library (cairn-ort, the producer via
// `engine_spec`) and the decode library (cairn-native, the consumer) as the
// `wire` spellings of exactly these two types.
pub use {encoding::TensorEncoding, geometry::ResizePolicy};

// The uint8-IO spike's payload types: the packer's output enum and the edge
// qparams it quantizes through — named by decode.rs (`pack`'s return and
// `ModelInput.tensor`'s field type) and by tests that build quantized specs.
pub use encoding::{QuantParams, TensorValues};
// The packer's other axis, reported by a backend and carried on `InputSpec`.
pub use encoding::TensorLayout;
