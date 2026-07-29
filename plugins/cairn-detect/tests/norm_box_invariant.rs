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

/// The recorded expectation, so the assertion below can read it without
/// resolving a path at runtime.
const EXPECTED: &str = include_str!("ui/norm_box_cannot_be_forged.stderr");

/// Rejects a `NormBox` forged from a `Bbox` by a sibling module of `geometry`.
#[test]
fn norm_box_cannot_be_forged_outside_geometry() {
    trybuild::TestCases::new().compile_fail("tests/ui/norm_box_cannot_be_forged.rs");
}

/// The expectation still has to be *about* the private field.
///
/// `trybuild` already refuses to re-record a case that unexpectedly compiled,
/// so a widened field cannot be blessed away. What it does not guard is a
/// *replaced* error: add a `use super::…` to `geometry.rs` that the shim does
/// not satisfy and the case still fails to compile, just with `E0432` instead.
/// One blind `TRYBUILD=overwrite` then pins that, and the gate keeps passing
/// forever while checking nothing about privacy.
///
/// Asserting on the recorded text is what makes that loud. It is deliberately
/// coarse — the error code and the phrase rustc uses for this class — so a
/// wording change does not break it, but a different *error* does.
#[test]
fn the_recorded_expectation_is_still_about_a_private_field() {
    assert!(
        EXPECTED.contains("E0423"),
        "the recorded stderr no longer carries E0423; if `geometry.rs` now fails \
         to compile in the ui case for some other reason, fix that rather than \
         re-recording — otherwise this gate stops checking the invariant:\n{EXPECTED}"
    );
    assert!(
        EXPECTED.contains("private field"),
        "the recorded stderr no longer names a private field:\n{EXPECTED}"
    );
}
