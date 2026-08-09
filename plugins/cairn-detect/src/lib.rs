//! The detection stages, as a library: everything between a compressed access
//! unit and a detection.
//!
//! Two hosts consume it and neither owns it — the `cairn-detect` binary (RTP in,
//! ndjson out) and `cairn-native`, the Rustler NIF the Membrane pipeline loads
//! in-VM — so the stages have one implementation and the two cannot drift into
//! disagreeing about what a frame means. Neither host's transport or lifecycle is
//! here.

// `process::exit` runs atexit handlers and C++ static destructors, and off the main
// thread that is a live hazard here: the control thread can fire while the main
// thread is inside onnxruntime's session constructor, and C++ teardown over a
// half-built session is the SIGSEGV that made `control::spawn_reader` use
// `libc::_exit` instead. `rtp::open_stream`'s minute of retries and the VAAPI/CUDA
// device creation after it are two more windows of the same shape.
//
// It is a `restriction`-group lint, hence allow-by-default, so `-D warnings` does
// not enable it and this line is what turns it on.
#![deny(clippy::exit)]
// Every doc build of this crate passes `--document-private-items` (CLAUDE.md's
// gate), so a public item linking to a private one resolves in the only build
// anyone runs, and the links this lint flags are where the reasoning behind the
// public item actually is. `broken_intra_doc_links`, which catches a reference that
// stopped resolving, is a different lint and stays on.
#![allow(rustdoc::private_intra_doc_links)]

pub mod control;
pub mod decode;
pub mod emit;
pub mod gate;
mod glibc_compat;
pub mod hwdecode;
pub mod infer;
pub mod log;
pub mod motion;
pub mod multiplex;
pub mod rtp;
