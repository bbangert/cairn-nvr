//! The one gate for the one invariant that nothing else in this crate can
//! check: that `infer::geometry`'s `NormBox` keeps its inner `Bbox` private.
//!
//! Everything the coordinate newtypes buy rests on that field. Only
//! `Projection::unproject` can mint a `NormBox`, and `det_from` takes nothing
//! else, so handing `det_from` model-space pixels is an `E0308`. Widening the
//! field to `pub(super)` — the plausible "for consistency with `ModelBox`"
//! edit — restores the ability to report model pixels as frame-relative ones,
//! and no unit test, clippy lint or rustdoc check in this crate would notice,
//! because the guarantee *is* the privacy.
//!
//! A `compile_fail` doctest cannot stand in for this: the crate has no library
//! target, so `cargo test --doc` fails with "no library targets found" and
//! doctests never run at all.
//!
//! `trybuild` compiles the case under `tests/ui` as its own crate and compares
//! the full compiler output against the recorded `.stderr`. Because the case
//! mounts the real `src/infer/geometry.rs` with `#[path]`, there is no copy of
//! the invariant to drift: the file that ships is the file compiled here.
//! Re-record with `TRYBUILD=overwrite cargo test`, but read the diff — a
//! disappeared error means the invariant is gone, not that the expectation is
//! stale.

/// Rejects a `NormBox` forged from a `Bbox` by a sibling module of `geometry`.
#[test]
fn norm_box_cannot_be_forged_outside_geometry() {
    trybuild::TestCases::new().compile_fail("tests/ui/norm_box_cannot_be_forged.rs");
}
