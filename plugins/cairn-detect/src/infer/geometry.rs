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

/// Model-space box -> normalized original-frame box.
///
/// Every decode path takes one of these rather than an [`InputSize`], because
/// under a letterbox the model's coordinate space is *not* the frame's: part
/// of it is padding that never held any pixels. Dividing by the input size
/// there — the stretch rule — reports every box short and shifted. Making the
/// un-projection a value the decoder is handed is what makes forgetting it
/// impossible.
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
    /// `[x0, y0, x1, y1]` in model pixels -> the same box normalized 0..1
    /// against the original frame. Not clamped: [`det_from`] does that.
    pub fn unproject(&self, corners: [f64; 4]) -> [f64; 4] {
        let x = |v: f64| (v - self.offset.0) / self.scale.0 / self.source.0;
        let y = |v: f64| (v - self.offset.1) / self.scale.1 / self.source.1;
        [x(corners[0]), y(corners[1]), x(corners[2]), y(corners[3])]
    }

    /// The stretch projection for an input size, for callers with no frame in
    /// hand. Sound because under `Stretch` the source cancels out entirely.
    #[cfg(test)]
    pub fn stretch(input: InputSize) -> Self {
        ResizePolicy::Stretch.project(input, input)
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

    #[test]
    fn stretch_fills_the_whole_input_and_ignores_the_source() {
        for source in [WIDE, InputSize { w: 2560, h: 1920 }, YOLOX_416] {
            let fit = ResizePolicy::Stretch.fit(YOLOX_416, source);
            assert_eq!(fit.inner, YOLOX_416);
            assert_eq!(fit.offset, (0, 0));
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
                let whole = [0.0, 0.0, fit.inner.w as f64, fit.inner.h as f64];
                let back = projection.unproject(whole);
                assert_eq!(back[0], 0.0, "{policy} {source}");
                assert_eq!(back[1], 0.0, "{policy} {source}");
                assert!((back[2] - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
                assert!((back[3] - 1.0).abs() < 1e-9, "{policy} {source}: {back:?}");
            }
        }
    }

    #[test]
    fn stretch_un_projection_is_a_divide_by_the_input_size() {
        // The pre-existing rule, unchanged: independent of the source frame.
        let projection = ResizePolicy::Stretch.project(SQUARE, WIDE);
        assert_eq!(
            projection.unproject([64.0, 128.0, 192.0, 320.0]),
            [0.1, 0.2, 0.3, 0.5]
        );
        // ...and the same box under the same input from a different source
        let other = ResizePolicy::Stretch.project(SQUARE, InputSize::square(720));
        assert_eq!(
            other.unproject([64.0, 128.0, 192.0, 320.0]),
            projection.unproject([64.0, 128.0, 192.0, 320.0])
        );
    }

    #[test]
    fn letterbox_un_projection_ignores_the_padding() {
        // 1920x1080 -> 416x234 content with 182 rows of pad below it. A box
        // filling the content's lower half is the frame's lower half.
        let projection = ResizePolicy::Letterbox { pad: 114 }.project(YOLOX_416, WIDE);
        let back = projection.unproject([0.0, 117.0, 416.0, 234.0]);
        assert!((back[0] - 0.0).abs() < 1e-9, "{back:?}");
        assert!((back[1] - 0.5).abs() < 1e-9, "{back:?}");
        assert!((back[2] - 1.0).abs() < 1e-9, "{back:?}");
        assert!((back[3] - 1.0).abs() < 1e-9, "{back:?}");
        // A box down in the padding un-projects past the bottom of the frame,
        // which `det_from` clamps away rather than reporting as content.
        assert!(projection.unproject([0.0, 300.0, 10.0, 320.0])[1] > 1.0);
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
        let box_ = [104.0, 58.0, 312.0, 176.0];
        let good = letterbox.unproject(box_);
        let bad = stretch.unproject(box_);
        assert!((good[0] - bad[0]).abs() < 1e-9, "x is unaffected");
        // The letterboxed picture only occupies the top 234 of 416 rows, so
        // reading it with the stretch rule squashes every box's height by
        // exactly the aspect ratio, 1080/1920.
        let good_h = good[3] - good[1];
        let bad_h = bad[3] - bad[1];
        assert!(
            (bad_h / good_h - 1080.0 / 1920.0).abs() < 0.001,
            "{bad_h} vs {good_h}"
        );
        // and every box is pulled toward the top of the frame as well
        assert!(bad[1] < good[1], "{bad:?} vs {good:?}");
    }
}
