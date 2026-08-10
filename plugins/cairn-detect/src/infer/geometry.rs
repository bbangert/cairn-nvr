//! Input geometry: the sizes a model accepts, how a frame is made to fit one,
//! and how a box in model space comes back to the original frame.
//!
//! Kept together with [`crate::infer::encoding`] in spirit but separate in
//! file: this half is about *where* pixels land, that half about *what value*
//! each byte becomes.

use std::fmt;

use anyhow::{bail, Context, Result};

/// Ceiling on either input dimension, enforced wherever a size is resolved.
///
/// Nothing downstream re-checks it: the resolved size is cast to `i32` for
/// FFmpeg frame and scaler geometry. Without a bound, a typo'd `--input-size`
/// or a model declaring nonsense truncates on the cast instead of failing at
/// startup. 8192 is far past any real detector input — Ultralytics tops out
/// around 1280 — and leaves the cast well inside its type.
///
/// This bounds each axis and *not* the allocation: see [`MAX_INPUT_PIXELS`],
/// which is the one that bounds memory.
pub(super) const MAX_INPUT_DIM: usize = 8192;

/// Ceiling on the input *area*, enforced alongside [`MAX_INPUT_DIM`].
///
/// A per-axis bound says nothing about how much memory a size asks for, and
/// the size can come straight off the model: `declared_input_size` reads
/// `shape[2]`/`shape[3]` of an untrusted ONNX. At `8192x8192` — inside the
/// per-axis limit — the first frame allocates a 768 MiB `pack_chw` tensor and
/// a 192 MiB RGB24 AVFrame, per decode thread, plus one tensor parked in each
/// multiplexed member's slot. Four cameras is over 4 GB of steady-state RSS on
/// the NVR host, all of it decided by a file the operator downloaded.
///
/// So the model-declared path gets the rule `decode::MAX_PIXELS` already
/// applies to camera frames: bound the area. 4 Mpx is `2048x2048`, an order of
/// magnitude past RF-DETR-Large's 704 and Ultralytics' 1280.
pub(super) const MAX_INPUT_PIXELS: usize = 4 * 1024 * 1024;

/// The model's input geometry, resolved once at startup.
///
/// Every scaler, GPU filter graph and tensor in the process is built for
/// exactly this, so it is settled before any of them exist — a mismatch is a
/// runtime failure on the first frame, not something the pipeline recovers
/// from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputSize {
    pub w: usize,
    pub h: usize,
}

impl InputSize {
    pub const fn square(size: usize) -> Self {
        Self { w: size, h: size }
    }

    /// `--input-size` value: `N` for a square N×N, or `WxH`.
    ///
    /// Written as a `clap` value parser, so its errors are the ones the user
    /// sees on a bad flag.
    pub fn parse(spec: &str) -> Result<Self> {
        let spec = spec.trim();
        match spec.split_once(['x', 'X']) {
            Some((w, h)) => Ok(Self {
                w: dim(w)?,
                h: dim(h)?,
            }),
            None => Ok(Self::square(dim(spec)?)),
        }
    }

    /// Elements in the CHW f32 tensor a frame of this size packs into.
    pub fn tensor_len(self) -> usize {
        3 * self.w * self.h
    }
}

/// `usize::from_str` already rejects a sign and any non-digit; only zero needs
/// its own check, and it needs one because a 0-wide scaler fails much later.
fn dim(text: &str) -> Result<usize> {
    let value: usize = text
        .trim()
        .parse()
        .with_context(|| format!("input size {text:?} is not a number"))?;
    if value == 0 {
        bail!("input size must be positive, got {text:?}");
    }
    Ok(value)
}

impl fmt::Display for InputSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.w, self.h)
    }
}

/// How a source frame is made to fit the model's input rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResizePolicy {
    /// Scale each axis independently to fill the input exactly. Cheap and
    /// correct only for a model trained the same way.
    Stretch,
    /// Scale by the smaller of the two ratios and fill the remainder with
    /// `pad`, preserving aspect. The content goes at the top-left corner and
    /// the padding lands bottom-right, which is what YOLOX's own `preproc`
    /// does (`padded_img[: int(h*r), : int(w*r)] = resized`).
    Letterbox { pad: u8 },
}

impl fmt::Display for ResizePolicy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Stretch => f.write_str("stretch"),
            Self::Letterbox { pad } => write!(f, "letterbox (pad {pad})"),
        }
    }
}

impl ResizePolicy {
    /// The stable wire spelling as `(policy, pad)`, round-tripped by
    /// [`Self::from_wire`]: how a resolved spec crosses a boundary that
    /// carries terms rather than types. `pad` is `0` under `Stretch`, which
    /// has none to carry.
    pub fn wire(self) -> (&'static str, u8) {
        match self {
            Self::Stretch => ("stretch", 0),
            Self::Letterbox { pad } => ("letterbox", pad),
        }
    }

    /// The inverse of [`Self::wire`], refusing anything else by name.
    pub fn from_wire(policy: &str, pad: u8) -> Result<Self> {
        match policy {
            "stretch" => Ok(Self::Stretch),
            "letterbox" => Ok(Self::Letterbox { pad }),
            other => bail!("unknown resize policy {other:?}"),
        }
    }

    /// Where a `source`-sized frame lands inside an `input`-sized tensor.
    pub fn fit(self, input: InputSize, source: InputSize) -> Fit {
        match self {
            Self::Stretch => Fit {
                inner: input,
                offset: (0, 0),
                pad: 0,
            },
            Self::Letterbox { pad } => {
                let ratio = f64::min(
                    input.w as f64 / source.w as f64,
                    input.h as f64 / source.h as f64,
                );
                Fit {
                    inner: InputSize {
                        w: scaled_dim(source.w, ratio, input.w),
                        h: scaled_dim(source.h, ratio, input.h),
                    },
                    offset: (0, 0),
                    pad,
                }
            }
        }
    }

    /// The un-projection a `source`-sized frame implies under this policy.
    ///
    /// The pipeline itself goes through [`Fit`], which it needs anyway to
    /// build the scaler; this is the same thing for a caller that only wants
    /// the coordinate mapping.
    #[cfg(test)]
    pub fn project(self, input: InputSize, source: InputSize) -> Projection {
        self.fit(input, source).projection(source)
    }
}

/// A letterboxed side length: `floor(side * ratio)`, forced even and clamped
/// into `1..=limit`.
///
/// Even because the hardware path scales into NV12, whose chroma planes are
/// half resolution on both axes — an odd side there is either rejected by the
/// GPU scaler or silently rounded, and a silent round would shift every box by
/// the rounding it did not tell us about. Losing up to one pixel of content to
/// the pad is the cheaper side of that trade, and it costs nothing in accuracy
/// because [`Fit::projection`] is derived from the side we actually produced,
/// not from `ratio`.
fn scaled_dim(side: usize, ratio: f64, limit: usize) -> usize {
    let scaled = (side as f64 * ratio).floor().max(0.0) as usize;
    let even = (scaled.min(limit) / 2) * 2;
    even.max(2).min(limit).max(1)
}

/// Where the scaled frame sits inside the input rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fit {
    /// Size the source is scaled to. Equal to the input under `Stretch`.
    pub inner: InputSize,
    /// Top-left corner of that content within the input rectangle.
    pub offset: (usize, usize),
    /// Fill for everything outside `inner`.
    pub pad: u8,
}

impl Fit {
    /// The inverse of this fit: model-space pixels back to the source frame.
    pub fn projection(self, source: InputSize) -> Projection {
        Projection {
            scale: (
                self.inner.w as f64 / source.w as f64,
                self.inner.h as f64 / source.h as f64,
            ),
            offset: (self.offset.0 as f64, self.offset.1 as f64),
            source: (source.w as f64, source.h as f64),
        }
    }
}

/// A box as its two corners: `x1, y1` top-left, `x2, y2` bottom-right.
///
/// Named fields rather than `[f64; 4]` so a transposed index is a
/// compile error rather than a box that decodes to the wrong rectangle. It
/// carries no coordinate space of its own — [`ModelBox`] and [`NormBox`] are
/// what say which space a given box is in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Bbox {
    pub(super) x1: f64,
    pub(super) y1: f64,
    pub(super) x2: f64,
    pub(super) y2: f64,
}

/// Corners in model-input pixels: the space every decode head works in.
///
/// Freely constructible inside `infer`, because producing one is what the
/// heads do. Consuming one is the restricted direction — see [`NormBox`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct ModelBox(pub(super) Bbox);

/// Corners normalized 0..1 against the *original* frame: the contract's space.
///
/// The inner field is private to this module on purpose, so
/// [`Projection::unproject`] is the **only** way to obtain one. That is what
/// makes a missed un-projection a compile error rather than a box reported
/// against the model's input rectangle — which under a letterbox is not the
/// frame at all, part of it being padding that never held a pixel.
///
/// **Do not widen that field to match [`ModelBox`]'s.** The asymmetry between
/// the two is the whole mechanism, not an oversight: a `ModelBox` is something
/// the heads make freely, a `NormBox` is something only the projection can
/// mint. Writing `NormBox(pub(super) Bbox)` for consistency would restore the
/// ability to hand `det_from` model pixels, and because the guarantee is the
/// privacy itself, no unit test or lint can see it go.
///
/// One thing can: `tests/norm_box_invariant.rs` drives a `trybuild` case that
/// compiles this very file and forges a `NormBox` from a sibling module,
/// requiring the compiler to refuse. Widen the field and that case compiles,
/// which fails the test. A `compile_fail` doctest could not have done it:
/// `geometry` is private inside `infer`, so a doctest — which compiles against
/// the library's *public* surface — cannot name `NormBox` to forge one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct NormBox(Bbox);

impl NormBox {
    /// The corners, for the one consumer that turns them into a `Det`.
    pub(super) fn corners(self) -> Bbox {
        self.0
    }
}

/// Model-space box -> normalized original-frame box.
///
/// Every decode path takes one of these rather than an [`InputSize`], because
/// under a letterbox the model's coordinate space is *not* the frame's: part
/// of it is padding that never held any pixels. Dividing by the input size
/// there — the stretch rule — reports every box short and shifted.
///
/// Handing the decoder this value is *not* what makes forgetting it impossible
/// — that is a common misreading, and this comment used to make it. A
/// parameter can be accepted and ignored. What actually forbids it is
/// [`NormBox`]: only [`Projection::unproject`] can produce one, and only a
/// `NormBox` reaches the wire.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Projection {
    /// Model pixels per source pixel, per axis.
    scale: (f64, f64),
    /// Top-left of the content in model space.
    offset: (f64, f64),
    /// Original frame size, which the result is normalized by.
    source: (f64, f64),
}

impl Projection {
    /// Model pixels -> the same box normalized 0..1 against the original
    /// frame. Not clamped: `wire_bbox`, on the way to the wire, does that.
    ///
    /// The sole constructor of a [`NormBox`], which is what makes skipping
    /// this call fail to compile rather than silently report model-space
    /// numbers as frame-relative ones.
    pub(super) fn unproject(&self, corners: ModelBox) -> NormBox {
        let x = |v: f64| (v - self.offset.0) / self.scale.0 / self.source.0;
        let y = |v: f64| (v - self.offset.1) / self.scale.1 / self.source.1;
        let ModelBox(corners) = corners;
        NormBox(Bbox {
            x1: x(corners.x1),
            y1: y(corners.y1),
            x2: x(corners.x2),
            y2: y(corners.y2),
        })
    }

    /// The stretch projection for an input size, for callers with no frame in
    /// hand. Sound because under `Stretch` the source cancels out entirely.
    #[cfg(test)]
    pub fn stretch(input: InputSize) -> Self {
        ResizePolicy::Stretch.project(input, input)
    }

    /// A wire-shaped normalized frame box forward into model-canvas pixels —
    /// the direction `unproject` inverts, as corner coordinates. Not clamped;
    /// callers cropping from the canvas intersect with `content_rect` (the
    /// canvas past the content is letterbox padding that never held pixels).
    pub(super) fn project_norm(&self, bbox: [f64; 4]) -> (f64, f64, f64, f64) {
        let x = |v: f64| v * self.source.0 * self.scale.0 + self.offset.0;
        let y = |v: f64| v * self.source.1 * self.scale.1 + self.offset.1;
        (
            x(bbox[0]),
            y(bbox[1]),
            x(bbox[0] + bbox[2]),
            y(bbox[1] + bbox[3]),
        )
    }

    /// Where real pixels live on the model canvas, as corner coordinates:
    /// the content rectangle this projection carried in from the fit.
    pub(super) fn content_rect(&self) -> (f64, f64, f64, f64) {
        (
            self.offset.0,
            self.offset.1,
            self.offset.0 + self.scale.0 * self.source.0,
            self.offset.1 + self.scale.1 * self.source.1,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SQUARE: InputSize = InputSize::square(640);
    /// What `yolox_nano.onnx` from the Megvii 0.1.1rc0 release declares.
    const YOLOX_416: InputSize = InputSize::square(416);

    #[test]
    fn a_bare_number_is_a_square() {
        assert_eq!(InputSize::parse("640").unwrap(), SQUARE);
        assert_eq!(InputSize::parse(" 320 ").unwrap(), InputSize::square(320));
        assert_eq!(SQUARE.to_string(), "640x640");
        assert_eq!(SQUARE.tensor_len(), 3 * 640 * 640);
    }

    #[test]
    fn wxh_keeps_the_axes_in_order() {
        assert_eq!(
            InputSize::parse("640x352").unwrap(),
            InputSize { w: 640, h: 352 }
        );
        // uppercase because `--input-size 640X352` is a plausible typo, not
        // a different format
        assert_eq!(
            InputSize::parse("640X352").unwrap(),
            InputSize { w: 640, h: 352 }
        );
        assert_eq!(InputSize::parse("640x352").unwrap().to_string(), "640x352");
    }

    #[test]
    fn rejects_zero_and_garbage_sizes() {
        for spec in ["0", "0x640", "640x0", "", "x", "640x", "x640", "-640"] {
            assert!(InputSize::parse(spec).is_err(), "{spec:?} parsed");
        }
        assert!(InputSize::parse("640.0").is_err());
        assert!(InputSize::parse("640x352x1").is_err());
    }

    // ---- resize policy and projection -------------------------------------

    /// The 16:9 source the fix exists for: 1920x1080 into a 416x416 model.
    const WIDE: InputSize = InputSize { w: 1920, h: 1080 };

    /// A model-space box from corners a test names literally.
    fn model_box(x1: f64, y1: f64, x2: f64, y2: f64) -> ModelBox {
        ModelBox(Bbox { x1, y1, x2, y2 })
    }

    #[test]
    fn stretch_fills_the_whole_input_and_ignores_the_source() {
        for source in [WIDE, InputSize { w: 2560, h: 1920 }, YOLOX_416] {
            let fit = ResizePolicy::Stretch.fit(YOLOX_416, source);
            assert_eq!(fit.inner, YOLOX_416);
            assert_eq!(fit.offset, (0, 0));
            // nothing is padded, so there is no fill to choose
            assert_eq!(fit.pad, 0);
        }
    }

    #[test]
    fn letterbox_scales_by_the_smaller_ratio_and_pads_bottom_right() {
        // min(416/1920, 416/1080) = 0.21667 -> 416 x 234, 182 rows of pad
        // under it. Content at the origin is what YOLOX's own preproc does:
        // `padded_img[: int(h*r), : int(w*r)] = resized`.
        let fit = ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, WIDE);
        assert_eq!(fit.inner, InputSize { w: 416, h: 234 });
        assert_eq!(fit.offset, (0, 0));
        assert_eq!(fit.pad, 114);
        // the aspect the model sees is the camera's, to within the even-side
        // rounding: 416/234 = 1.778 against 1920/1080 = 1.778
        let seen = fit.inner.w as f64 / fit.inner.h as f64;
        let real = WIDE.w as f64 / WIDE.h as f64;
        assert!((seen - real).abs() < 0.01, "{seen} vs {real}");
    }

    #[test]
    fn letterbox_sides_are_even_and_never_exceed_the_input() {
        // A source whose exact fit is odd still lands on an even side, because
        // the hardware path scales into NV12 and a silently rounded side would
        // shift every box.
        let odd = ResizePolicy::Letterbox { pad: 114 }.fit(InputSize::square(101), WIDE);
        assert_eq!(odd.inner.w % 2, 0);
        assert_eq!(odd.inner.h % 2, 0);
        assert!(odd.inner.w <= 101 && odd.inner.h <= 101);
        // a square source fills the square input exactly
        let square = ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, InputSize::square(1080));
        assert_eq!(square.inner, YOLOX_416);
        // an absurdly thin source still leaves a usable side
        let sliver =
            ResizePolicy::Letterbox { pad: 114 }.fit(YOLOX_416, InputSize { w: 4000, h: 2 });
        assert!(sliver.inner.h >= 1 && sliver.inner.w <= 416);
    }

    #[test]
    fn a_full_frame_box_round_trips_under_both_policies() {
        // The property that makes a projection right: whatever the model sees
        // of the whole frame must come back as the whole frame.
        for source in [WIDE, InputSize { w: 2560, h: 1920 }, SQUARE] {
            for policy in [ResizePolicy::Stretch, ResizePolicy::Letterbox { pad: 114 }] {
                let fit = policy.fit(YOLOX_416, source);
                let projection = fit.projection(source);
                let whole = model_box(0.0, 0.0, fit.inner.w as f64, fit.inner.h as f64);
                let back = projection.unproject(whole).corners();
                assert_eq!(back.x1, 0.0, "{policy} {source}");
                assert_eq!(back.y1, 0.0, "{policy} {source}");
                assert!((back.x2 - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
                assert!((back.y2 - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
            }
        }
    }

    #[test]
    fn stretch_un_projection_is_a_divide_by_the_input_size() {
        // The pre-existing rule, unchanged: independent of the source frame.
        let projection = ResizePolicy::Stretch.project(SQUARE, WIDE);
        let probe = model_box(64.0, 128.0, 192.0, 320.0);
        assert_eq!(
            projection.unproject(probe).corners(),
            Bbox {
                x1: 0.1,
                y1: 0.2,
                x2: 0.3,
                y2: 0.5
            }
        );
        // ...and the same box under the same input from a different source
        let other = ResizePolicy::Stretch.project(SQUARE, InputSize::square(720));
        assert_eq!(other.unproject(probe), projection.unproject(probe));
    }

    #[test]
    fn letterbox_un_projection_ignores_the_padding() {
        // 1920x1080 -> 416x234 content with 182 rows of pad below it. A box
        // filling the content's lower half is the frame's lower half.
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, WIDE);
        let back = projection
            .unproject(model_box(0.0, 117.0, 416.0, 234.0))
            .corners();
        assert!((back.x1 - 0.0).abs() < 1e-9, "{back:?}");
        assert!((back.y1 - 0.5).abs() < 1e-9, "{back:?}");
        assert!((back.x2 - 1.0).abs() < 1e-9, "{back:?}");
        assert!((back.y2 - 1.0).abs() < 1e-9, "{back:?}");
        // A box down in the padding un-projects past the bottom of the frame,
        // which `wire_bbox` clamps away rather than reporting as content.
        assert!(
            projection
                .unproject(model_box(0.0, 300.0, 10.0, 320.0))
                .corners()
                .y1
                > 1.0
        );
    }

    #[test]
    fn a_centered_letterbox_reads_its_content_rectangle_back_as_the_whole_frame() {
        // `ResizePolicy::fit` hard-codes `offset: (0, 0)` in both of its arms, so
        // no production path can hand `unproject` a non-zero one and its two
        // `v - self.offset.N` terms subtract a constant nothing everywhere the
        // pipeline runs. The field is not unused — `decode::pack_chw` reads it to
        // place the scaled content inside the input rectangle — and it is what a
        // *centered* letterbox would set. `Fit`'s fields are public, so this
        // builds that `Fit` directly and gives both terms a caller that notices
        // if either goes.
        //
        // 1920x1080 into 416x416. `inner` is what
        // `letterbox_scales_by_the_smaller_ratio_and_pads_bottom_right` already
        // pins for this pair: the ratio is min(416/1920, 416/1080) = 13/60 and
        // floor(1080 * 13/60) = 234, already even. Centering splits the
        // remaining 416 - 234 = 182 rows evenly, so the content starts at row
        // (416 - 234) / 2 = 91 and runs to 91 + 234 = 325.
        //
        // `Fit::projection` takes the scale from `inner` rather than from the
        // ratio, so it is (416/1920, 234/1080): those 234 model rows are exactly
        // the frame's 1080, and columns 0..416 exactly its 1920.
        let projection = Fit {
            inner: InputSize { w: 416, h: 234 },
            offset: (0, 91),
            pad: 114,
        }
        .projection(WIDE);
        assert_eq!(
            projection
                .unproject(model_box(0.0, 91.0, 416.0, 325.0))
                .corners(),
            Bbox {
                x1: 0.0,
                y1: 0.0,
                x2: 1.0,
                y2: 1.0
            }
        );
        // Rows 0..91 are the pad *above* the content, so they read back above
        // the top of the frame, which `wire_bbox`'s clamp then cuts away. That
        // sign is the difference the offset makes: with the padding all
        // bottom-right, no model row inside the input rectangle un-projects to a
        // negative `y` at all.
        let above = projection
            .unproject(model_box(0.0, 0.0, 416.0, 45.0))
            .corners();
        assert!(above.y2 < 0.0, "{above:?}");

        // The mirror case, so the `x` term is pinned as well: a portrait source
        // centers horizontally. 480x640 into 640x640 has ratio min(640/480,
        // 640/640) = 1.0, so `inner` is the source size — the same `inner`
        // `a_portrait_source_pads_the_width_and_reads_that_pad_past_the_right_edge`
        // pins — and the spare 640 - 480 = 160 columns split into 80 each side,
        // putting the content at 80..560.
        let portrait = InputSize { w: 480, h: 640 };
        let projection = Fit {
            inner: portrait,
            offset: (80, 0),
            pad: 114,
        }
        .projection(portrait);
        assert_eq!(
            projection
                .unproject(model_box(80.0, 0.0, 560.0, 640.0))
                .corners(),
            Bbox {
                x1: 0.0,
                y1: 0.0,
                x2: 1.0,
                y2: 1.0
            }
        );
        // ...and the pad to its left reads back past the frame's left edge.
        let left = projection
            .unproject(model_box(0.0, 0.0, 40.0, 640.0))
            .corners();
        assert!(left.x2 < 0.0, "{left:?}");
    }

    #[test]
    fn stretch_and_letterbox_disagree_on_a_16_by_9_frame() {
        // The bug this fix exists for, stated as a number: a box that is
        // square in the camera's frame is decoded from a model that saw it
        // squashed to 9/16 of its height under stretch, so reading it back
        // with the stretch rule stretches it again.
        let source = WIDE;
        let letterbox = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, source);
        let stretch = ResizePolicy::Stretch.project(YOLOX_416, source);
        // the same model-space box read both ways
        let box_ = model_box(104.0, 58.0, 312.0, 176.0);
        let good = letterbox.unproject(box_).corners();
        let bad = stretch.unproject(box_).corners();
        assert!((good.x1 - bad.x1).abs() < 1e-9, "x is unaffected");
        // The letterboxed picture only occupies the top 234 of 416 rows, so
        // reading it with the stretch rule squashes every box's height by
        // exactly the aspect ratio, 1080/1920.
        let good_h = good.y2 - good.y1;
        let bad_h = bad.y2 - bad.y1;
        assert!(
            (bad_h / good_h - 1080.0 / 1920.0).abs() < 0.001,
            "{bad_h} vs {good_h}"
        );
        // and every box is pulled toward the top of the frame as well
        assert!(bad.y1 < good.y1, "{bad:?} vs {good:?}");
    }

    #[test]
    fn an_odd_scaled_side_is_forced_even_and_the_projection_follows_the_side_produced() {
        // 100x33 into a 64x64 input: the ratio is min(64/100, 64/33) = 0.64,
        // and the exact height is floor(33 * 0.64) = 21 — odd. The hardware
        // path scales into NV12, whose chroma planes are half resolution on
        // both axes, so an odd side there is either refused by the GPU scaler
        // or silently rounded — and a silent round shifts every box by a
        // rounding nobody was told about. 21 becomes 20.
        let input = InputSize::square(64);
        let source = InputSize { w: 100, h: 33 };
        let letterbox = ResizePolicy::Letterbox { pad: 114 };
        assert_eq!(
            letterbox.fit(input, source).inner,
            InputSize { w: 64, h: 20 }
        );

        // Losing that row of content costs nothing in accuracy because the
        // projection is derived from the side actually produced rather than
        // from the ratio: 20 rows of content are exactly the whole frame.
        let projection = letterbox.project(input, source);
        let content = projection
            .unproject(model_box(0.0, 0.0, 64.0, 20.0))
            .corners();
        assert!((content.x2 - 1.0).abs() < 1e-9, "{content:?}");
        assert!((content.y2 - 1.0).abs() < 1e-9, "{content:?}");
        // Derived from the ratio instead, the same rows would have read back as
        // 20 / 21.12 of the frame — every box short by 5% with nothing to say so.
        assert!((20.0f64 / (33.0 * 0.64) - 0.947).abs() < 0.001);

        // The rest of the input rectangle is pad, and reads past the bottom:
        // 64 model rows are 3.2 frames tall at this scale.
        let whole = projection
            .unproject(model_box(0.0, 0.0, 64.0, 64.0))
            .corners();
        assert!((whole.y2 - 3.2).abs() < 1e-9, "{whole:?}");
        // ...and a corner outside the rectangle keeps its sign on both axes,
        // which is what `wire_bbox`'s clamp then cuts away.
        let outside = projection
            .unproject(model_box(-8.0, -8.0, 8.0, 8.0))
            .corners();
        assert!((outside.x1 + 0.125).abs() < 1e-9, "{outside:?}");
        assert!((outside.y1 + 0.4).abs() < 1e-9, "{outside:?}");
    }

    #[test]
    fn a_portrait_source_pads_the_width_and_reads_that_pad_past_the_right_edge() {
        // Every other letterbox here pads below. A source taller than it is
        // wide pads to the *right* instead, and it is `x` that leaves the
        // frame — the mirror case, and the one an implementation that assumed
        // landscape gets wrong.
        let source = InputSize { w: 480, h: 640 };
        let letterbox = ResizePolicy::Letterbox { pad: 114 };
        assert_eq!(
            letterbox.fit(SQUARE, source).inner,
            InputSize { w: 480, h: 640 }
        );
        let projection = letterbox.project(SQUARE, source);
        let content = projection
            .unproject(model_box(0.0, 0.0, 480.0, 640.0))
            .corners();
        assert!((content.x2 - 1.0).abs() < 1e-9, "{content:?}");
        assert!((content.y2 - 1.0).abs() < 1e-9, "{content:?}");
        // the full input rectangle runs 640/480 frames wide and exactly one tall
        let whole = projection
            .unproject(model_box(0.0, 0.0, 640.0, 640.0))
            .corners();
        assert!((whole.x2 - 640.0 / 480.0).abs() < 1e-9, "{whole:?}");
        assert!((whole.y2 - 1.0).abs() < 1e-9, "{whole:?}");
    }

    #[test]
    fn a_source_smaller_than_the_input_is_scaled_up_rather_than_left_at_its_own_size() {
        // Nothing about the letterbox assumes the frame is the larger of the
        // two: 320x180 into 640 is a ratio of 2.0, filling the width and
        // padding 280 rows below.
        let source = InputSize { w: 320, h: 180 };
        let letterbox = ResizePolicy::Letterbox { pad: 114 };
        assert_eq!(
            letterbox.fit(SQUARE, source).inner,
            InputSize { w: 640, h: 360 }
        );
        let back = letterbox
            .project(SQUARE, source)
            .unproject(model_box(0.0, 0.0, 640.0, 360.0))
            .corners();
        assert!((back.x2 - 1.0).abs() < 1e-9, "{back:?}");
        assert!((back.y2 - 1.0).abs() < 1e-9, "{back:?}");
    }

    /// Every policy must round-trip: the wire pair is how a resolved spec
    /// crosses between NIF libraries, pad value included — a letterbox that
    /// comes back with a different pad letterboxes a different picture.
    #[test]
    fn every_resize_policy_round_trips_through_its_wire_pair() {
        for policy in [
            ResizePolicy::Stretch,
            ResizePolicy::Letterbox { pad: 114 },
            ResizePolicy::Letterbox { pad: 0 },
        ] {
            let (name, pad) = policy.wire();
            assert_eq!(ResizePolicy::from_wire(name, pad).unwrap(), policy);
        }
        assert!(ResizePolicy::from_wire("crop", 0).is_err());
    }
}
