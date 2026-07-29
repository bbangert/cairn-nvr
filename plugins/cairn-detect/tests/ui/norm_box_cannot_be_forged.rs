//! `NormBox`'s inner `Bbox` must stay private to `src/infer/geometry.rs`.
//!
//! That privacy is the whole reason a missed un-projection cannot compile:
//! `Projection::unproject` is the only thing able to mint a `NormBox`, and
//! `det_from` accepts nothing else. Widen the field to `pub(super)` for
//! symmetry with `ModelBox` and this case starts compiling, which is the
//! regression it exists to catch.
//!
//! The attempt itself is in `support/infer.rs`, because it has to be made from
//! a sibling module *inside* `infer`: from this crate root, `geometry`'s
//! `pub(super)` items are not nameable at all and the error would be the wrong
//! one.
// Nothing in the tree below is ever called — it exists to be type-checked, and
// `geometry.rs` brings a module's worth of items in with it.
#![allow(dead_code)]

#[path = "support/infer.rs"]
mod infer;

fn main() {}
