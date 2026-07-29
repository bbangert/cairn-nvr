//! `NormBox`'s inner `Bbox` must stay private to `src/infer/geometry.rs`.
//!
//! That privacy is the whole reason a missed un-projection cannot compile:
//! `Projection::unproject` is the only thing able to mint a `NormBox`, and
//! `det_from` accepts nothing else. Widen the field to `pub(super)` for
//! symmetry with `ModelBox` and this case starts compiling, which is the
//! regression it exists to catch.
//!
//! The attempt itself is in `support/infer.rs`. Not because it has to be —
//! `pub(super)` in a top-level module resolves to the crate root, so these
//! items are nameable from here and the forge yields the identical `E0423`.
//! The nesting is for *fidelity*: `det_from` really does live in a sibling
//! module of `geometry` inside `infer`, and the case should fail the way the
//! shipping code would. See `support/infer.rs` for the mounting constraint that
//! actually forces the extra file.
// Nothing in the tree below is ever called — it exists to be type-checked, and
// `geometry.rs` brings a module's worth of items in with it.
#![allow(dead_code)]

#[path = "support/infer.rs"]
mod infer;

fn main() {}
