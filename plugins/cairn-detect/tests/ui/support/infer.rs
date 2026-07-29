//! Stand-in for `crate::infer`, mounting the real `src/infer/geometry.rs` one
//! module deep so that its `pub(super)` items get exactly the visibility they
//! have in the crate: reachable from a sibling of `geometry`, which is where
//! `heads.rs` sits and where `det_from` is called.
//!
//! The module below *is* the production source, not a copy of it: `#[path]`
//! resolves against this file's own directory, and the target is the shipping
//! `geometry.rs`. Rename or move that file and this case fails with a
//! "couldn't read" error rather than quietly testing nothing.

#[path = "../../../src/infer/geometry.rs"]
mod geometry;

/// Stands where `infer::heads` stands: a sibling of `geometry` inside `infer`.
mod heads {
    use super::geometry::{Bbox, ModelBox, NormBox};

    /// The permitted direction, and the control for the case below.
    ///
    /// `ModelBox`'s field is `pub(super)`, so a sibling mints one freely. This
    /// has to keep compiling: were it to stop, the expected error would be
    /// about reaching `geometry` at all rather than about `NormBox`'s field,
    /// and the case would no longer be testing the invariant.
    fn model_pixels() -> ModelBox {
        ModelBox(Bbox {
            x1: 0.0,
            y1: 0.0,
            x2: 8.0,
            y2: 8.0,
        })
    }

    /// The forbidden direction: a `NormBox` minted without un-projecting.
    ///
    /// `E0423`, and its diagnostic quotes the guarded declaration itself, so
    /// the recorded `norm_box_cannot_be_forged.stderr` one directory up
    /// carries a copy of the exact line this gate protects.
    fn forged_norm_box(b: Bbox) -> NormBox {
        NormBox(b)
    }
}
