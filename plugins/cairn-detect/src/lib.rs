//! The detection stages, as a library.
//!
//! Everything between a compressed access unit and a detection lives here:
//! decode and the sample gate ([`decode`], [`hwdecode`]), the motion
//! measurement and its policy ([`motion`], [`gate`]), inference and
//! postprocess ([`infer`]), and the protocol writer ([`emit`]).
//!
//! Two hosts consume it and neither owns it: the `cairn-detect` binary
//! (`main.rs` — RTP in, ndjson out) and `cairn-native`, the Rustler NIF the
//! Membrane pipeline loads in-VM. That is the whole reason this is a library —
//! the stages have exactly one implementation, so the two hosts cannot drift
//! into disagreeing about what a frame means.
//!
//! What is *not* here is either host's transport or lifecycle: sockets and
//! argv belong to the binary, and resource handles and the BEAM boundary to
//! the NIF.

// `process::exit` runs atexit handlers and C++ static destructors, and off the
// main thread that is a live hazard here: the control thread can fire while the
// main thread is inside onnxruntime's session constructor, and C++ teardown over
// a half-built session is the SIGSEGV that made `control::spawn_reader` use
// `libc::_exit` instead — the reasoning is at that call site. Two later windows
// have the same shape: `rtp::open_stream` retries for about a minute, and the
// VAAPI/CUDA device creation after it. So the call is denied across this
// library rather than left to one comment that nobody is obliged to read.
//
// Every thread this crate starts is inside this deny — `multiplex::run`,
// `control::spawn_reader`, `log`'s writer — so this is the deny that matters.
// `main.rs` repeats it for its own crate, where clippy exempts `fn main` itself.
//
// It is a `restriction`-group lint, hence allow-by-default, so `-D warnings`
// does not enable it and this line is what turns it on.
#![deny(clippy::exit)]
// Every doc build of this crate passes `--document-private-items` (CLAUDE.md's
// gate), so a public item linking to a private one resolves in the only build
// anyone runs. The twenty links this lint flags — `Publisher::emit`,
// `CameraState::last_dets`, `LIGHTNING_FRACTION` and the rest — are where the
// reasoning behind the public item actually is; rewriting them as plain code
// spans to satisfy a lint about a documentation build we never do would delete
// the navigation the gate exists to protect. `broken_intra_doc_links`, the one
// that catches a reference that stopped resolving, is a different lint and
// stays on.
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
