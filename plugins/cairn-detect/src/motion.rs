//! Frame-to-frame change measurement, on a grayscale thumbnail of the sampled
//! frame.
//!
//! **This is the first place in the crate where one frame's picture outlives
//! it.** Every stage above is a function of the frame in hand — a tensor, a
//! projection, a detection list — and the state that does survive a frame
//! elsewhere (`emit::CameraState`'s sequence counter and diagnostic tallies)
//! is bookkeeping that never looked at a pixel. A [`MotionDetector`] remembers
//! a rolling average of the frames it has already seen, so it belongs to
//! exactly one camera: it lives on that camera's decode thread, which is per
//! camera in both modes by construction (one decode thread per process in
//! single mode, one `stream-<id>` thread per member in group mode).
//!
//! The algorithm is Frigate's, adapted: downscale to a small grayscale
//! thumbnail, keep a rolling-average background, take the absolute difference,
//! threshold it per pixel, and report the fraction of the thumbnail that
//! changed. No contours: the changed *area fraction* is the whole verdict
//! here, because the gate only ever asks "is anything happening", never "where".
//!
//! Pure — no clocks and no I/O. Elapsed time is counted in frames, which is
//! what keeps the calibration independent of how long the process spent
//! opening a stream and the tests independent of wall-clock timing.

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use crate::decode::SAMPLE_FPS;
use crate::infer::InputSize;

/// Widest a thumbnail gets, in pixels.
///
/// Frigate compares motion on a frame around 100 px wide; staying in that
/// order of magnitude is what lets its published threshold values mean
/// anything here. At this width a 16:9 content rectangle compares
/// 96x54 = 5 184 pixels per sample and a square one 96x96 = 9 216, so the
/// whole measurement is a rounding error next to the model pass it exists to
/// skip.
const MAX_THUMB_W: usize = 96;

/// Changed fraction above which the frame is treated as a scene cut rather
/// than as motion: an IR-cut filter flipping, a light switch, a camera
/// re-exposing. Every pixel moving at once is not an object.
const LIGHTNING_FRACTION: f32 = 0.8;

/// Rolling-average weight while the background is still being learned, and
/// the number of frames it is used for.
///
/// Counted in frames rather than seconds because this module has no clock; at
/// [`SAMPLE_FPS`] the two constants are 5 seconds of settling. No verdict
/// during that window reports motion — the background starts as one frame,
/// and until it has absorbed a few more, "differs from the background" mostly
/// means "differs from whatever was in front of the camera at startup".
const CALIBRATION_ALPHA: f32 = 0.2;
const CALIBRATION_FRAMES: u32 = 5 * SAMPLE_FPS;

/// Per-pixel 0..255 difference that counts as changed.
const DEFAULT_THRESHOLD: u8 = 25;
/// Changed fraction that counts as motion. Deliberately low: a gate that
/// decides "motion" runs the model, which is what happens today anyway, so
/// erring small costs nothing but CPU while erring large loses detections.
const DEFAULT_MIN_AREA_FRACTION: f32 = 0.005;
/// Rolling-average weight in steady state — about a 50-frame time constant,
/// or 10 seconds at [`SAMPLE_FPS`].
const DEFAULT_ALPHA: f32 = 0.02;
const DEFAULT_LINGER_MS: u64 = 12_000;
const DEFAULT_EPOCH_BYPASS_MS: u64 = 15_000;
const DEFAULT_REVERIFY_MS: u64 = 10_000;

/// Motion-gate knobs as the operator writes them, with every key optional.
///
/// The same shape parses `--motion-json` (the whole process's defaults) and a
/// `--cameras-json` member's `motion` key (that one camera's overrides), which
/// is what makes "override one knob, keep the rest" expressible at all.
///
/// `deny_unknown_fields` because the failure mode of a mistyped knob is a gate
/// that silently runs on defaults — the operator sees a plugin that started
/// fine and a setting that did nothing.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MotionOverrides {
    pub enabled: Option<bool>,
    pub threshold: Option<u8>,
    pub min_area_fraction: Option<f32>,
    pub alpha: Option<f32>,
    pub linger_ms: Option<u64>,
    pub epoch_bypass_ms: Option<u64>,
    pub reverify_ms: Option<u64>,
}

impl MotionOverrides {
    /// Decode the `--motion-json` argument.
    pub fn parse(json: &str) -> Result<Self> {
        let parsed: Self = serde_json::from_str(json)
            .context("--motion-json is not a JSON object of motion-gate knobs")?;
        parsed.validate()?;
        Ok(parsed)
    }

    /// Reject a knob no run could honour, at the point the operator can still
    /// read the message.
    ///
    /// Two of these are rules from `observe` rather than range checks: a
    /// threshold of 255 counts no pixel as changed, because 255 is the largest
    /// difference there is and the comparison is strict, and a floor at or
    /// above [`LIGHTNING_FRACTION`] is swallowed by the scene-cut rule before
    /// it is ever reached. Both messages name the rule, because the symptom
    /// they produce — a gate that starts clean, logs nothing, and answers the
    /// same thing for every frame it will ever see — is not diagnosable from
    /// outside this file.
    pub fn validate(&self) -> Result<()> {
        if let Some(threshold) = self.threshold {
            if threshold == 0 {
                bail!("motion threshold must be 1..=254; 0 counts every pixel as changed");
            }
            if threshold == u8::MAX {
                bail!(
                    "motion threshold must be 1..=254; the per-pixel compare is strict and 255 \
                     is the largest difference there is, so 255 counts no pixel as changed"
                );
            }
        }
        if let Some(fraction) = self.min_area_fraction {
            if !(fraction > 0.0 && fraction <= 1.0) {
                bail!("motion min_area_fraction must be in (0, 1], got {fraction}");
            }
            if fraction >= LIGHTNING_FRACTION {
                bail!(
                    "motion min_area_fraction must be below {LIGHTNING_FRACTION}, got {fraction}: \
                     a frame that changes more than {LIGHTNING_FRACTION} of the thumbnail is \
                     treated as a scene cut and reports no motion, so a floor at or above it is \
                     reachable at best by a frame that changes exactly {LIGHTNING_FRACTION} of it"
                );
            }
        }
        if let Some(alpha) = self.alpha {
            if !(alpha > 0.0 && alpha <= 1.0) {
                bail!("motion alpha must be in (0, 1], got {alpha}");
            }
        }
        Ok(())
    }
}

/// The resolved knobs one camera's detector runs under.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MotionConfig {
    /// Whether the gate runs at all. Off unless the operator says otherwise:
    /// see [`resolve`], which is where this stops being a field and becomes
    /// the presence or absence of a detector.
    pub enabled: bool,
    /// Per-pixel 0..255 difference that counts as changed.
    pub threshold: u8,
    /// Changed fraction at or above which a calibrated detector reports motion.
    pub min_area_fraction: f32,
    /// Rolling-average weight: `bg = (1 - alpha) * bg + alpha * frame`.
    pub alpha: f32,
    // The three knobs below belong to the gate policy and are read in
    // [`crate::gate`], not here: this side measures a frame, and a duration is
    // no use to it. `validate` bounds nothing about them, deliberately — every
    // u64 is a policy a run can honour, including `0` (that rule never fires)
    // and a duration longer than the process will live (it never stops
    // firing), so an out-of-range value is not a thing an operator can write.
    // What they cost when set wrongly is inference the gate did or did not
    // skip, which the run's own output shows.
    /// How long past the last motion to keep inferring anyway.
    pub linger_ms: u64,
    /// How long after a stream epoch change to infer regardless of motion.
    pub epoch_bypass_ms: u64,
    /// How often to infer anyway while gated, to re-verify what is parked.
    pub reverify_ms: u64,
}

impl Default for MotionConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            threshold: DEFAULT_THRESHOLD,
            min_area_fraction: DEFAULT_MIN_AREA_FRACTION,
            alpha: DEFAULT_ALPHA,
            linger_ms: DEFAULT_LINGER_MS,
            epoch_bypass_ms: DEFAULT_EPOCH_BYPASS_MS,
            reverify_ms: DEFAULT_REVERIFY_MS,
        }
    }
}

impl MotionConfig {
    fn apply(&mut self, overrides: &MotionOverrides) {
        let MotionOverrides {
            enabled,
            threshold,
            min_area_fraction,
            alpha,
            linger_ms,
            epoch_bypass_ms,
            reverify_ms,
        } = *overrides;
        // Destructured rather than field-by-field off `overrides` so that a
        // knob added to `MotionOverrides` and forgotten here is a compile
        // error instead of a setting that parses and is then discarded.
        if let Some(enabled) = enabled {
            self.enabled = enabled;
        }
        if let Some(threshold) = threshold {
            self.threshold = threshold;
        }
        if let Some(fraction) = min_area_fraction {
            self.min_area_fraction = fraction;
        }
        if let Some(alpha) = alpha {
            self.alpha = alpha;
        }
        if let Some(ms) = linger_ms {
            self.linger_ms = ms;
        }
        if let Some(ms) = epoch_bypass_ms {
            self.epoch_bypass_ms = ms;
        }
        if let Some(ms) = reverify_ms {
            self.reverify_ms = ms;
        }
    }
}

/// The config one camera measures under: defaults, then the process-wide
/// `--motion-json`, then that camera's own `motion` key — each layer
/// overriding only the knobs it names.
///
/// `None` when the resolved gate is disabled, which is the default. That is
/// the difference between "off" and "on with a threshold of zero": no
/// detector is built, no thumbnail is taken, and `Sample::motion` stays
/// `None` all the way to the inference thread.
pub fn resolve(global: &MotionOverrides, per_camera: &MotionOverrides) -> Option<MotionConfig> {
    let mut config = MotionConfig::default();
    config.apply(global);
    config.apply(per_camera);
    config.enabled.then_some(config)
}

/// What one frame's comparison against the background says.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MotionVerdict {
    /// Fraction of the thumbnail whose difference from the background exceeded
    /// the threshold, in 0..=1. Reported even when `motion` is false, because
    /// it is the number an operator tunes `min_area_fraction` against — which
    /// is why [`crate::gate::Telemetry`] carries its per-window peak out to the
    /// host, where an operator can read it.
    pub changed_fraction: f32,
    /// Whether that fraction reaches `min_area_fraction` on a calibrated
    /// detector. Always false while calibrating and on a scene cut.
    pub motion: bool,
    /// Whether this verdict came from a detector that has not finished
    /// calibrating, and so cannot say a scene is still — see
    /// [`CALIBRATION_FRAMES`]. `motion` is false throughout that window
    /// whatever is in front of the camera, which is a statement about the
    /// background rather than about the picture, and the two are worth telling
    /// apart by anything deciding whether to skip work.
    pub calibrating: bool,
    /// Whether `changed_fraction` cleared [`LIGHTNING_FRACTION`], so this
    /// frame was read as a scene cut and rebaselined the background. `motion`
    /// is false on one of these for a reason of its own — what changed is the
    /// whole picture, which is not a thing moving in the scene — and that
    /// false is the second one that says nothing about the picture: the
    /// background it was measured against described a scene that no longer
    /// exists, and the frames after it are measured against a background one
    /// frame old. [`crate::gate`] reads this the same way it reads
    /// `calibrating`.
    pub scene_cut: bool,
}

impl MotionVerdict {
    /// The verdict for a frame there is nothing to compare against: the first
    /// one, or the first after the geometry changed. Calibrating by
    /// construction — that frame *is* the background — and not a cut, there
    /// being no comparison behind it to have cleared the threshold.
    fn still() -> Self {
        Self {
            changed_fraction: 0.0,
            motion: false,
            calibrating: true,
            scene_cut: false,
        }
    }
}

/// A downscaled grayscale copy of one frame's content rectangle.
///
/// Small on purpose. Downscaling is the noise filter — sensor grain, an
/// individual leaf and JPEG-ish blocking all average away, while anything
/// large enough to be worth inferring on survives — and it is also what makes
/// the comparison cost nothing.
pub struct GrayThumb {
    w: usize,
    h: usize,
    /// Luma, row-major, `w * h` long.
    pixels: Vec<u8>,
}

impl GrayThumb {
    /// Box-filter downsample of packed RGB24 rows to the thumbnail size.
    ///
    /// `plane` must cover `stride * content.h` bytes with `content.w` pixels
    /// of picture in each row — the same precondition `decode::pack_chw`
    /// carries, and for the same reason: this reads the scaler's own output
    /// frame, whose geometry is the one it was built for.
    ///
    /// Every source pixel lands in exactly one box, so a thumbnail pixel is
    /// the mean of the block under it — not a point sample, which would alias
    /// a moving edge into and out of existence between frames and report the
    /// aliasing as motion.
    pub fn from_rgb24(plane: &[u8], stride: usize, content: InputSize) -> Self {
        let (w, h) = thumb_size(content);
        let mut pixels = Vec::with_capacity(w * h);
        for ty in 0..h {
            let y0 = ty * content.h / h;
            let y1 = ((ty + 1) * content.h / h).max(y0 + 1);
            for tx in 0..w {
                let x0 = tx * content.w / w;
                let x1 = ((tx + 1) * content.w / w).max(x0 + 1);
                let mut sum: u32 = 0;
                for y in y0..y1 {
                    let row = &plane[y * stride..y * stride + content.w * 3];
                    for x in x0..x1 {
                        let px = &row[x * 3..x * 3 + 3];
                        sum += luma_256(px[0], px[1], px[2]);
                    }
                }
                let count = ((y1 - y0) * (x1 - x0)) as u32;
                // The weights sum to 256, so this is already 0..=255.
                pixels.push((sum / (count * 256)) as u8);
            }
        }
        Self { w, h, pixels }
    }

    fn size(&self) -> (usize, usize) {
        (self.w, self.h)
    }
}

/// BT.601 luma, scaled by 256 so the weights are integers.
///
/// `(77, 150, 29)` is `(0.299, 0.587, 0.114) * 256` rounded, and the three sum
/// to exactly 256 — which is what keeps a white pixel white after the shift
/// instead of one count short of it.
fn luma_256(r: u8, g: u8, b: u8) -> u32 {
    77 * u32::from(r) + 150 * u32::from(g) + 29 * u32::from(b)
}

/// Thumbnail geometry for a content rectangle: the same aspect ratio, at most
/// [`MAX_THUMB_W`] wide.
///
/// The ratio is the content rectangle's, which is the camera's only under a
/// letterbox — where `Fit::inner` is the picture inside the padding. Under
/// `ResizePolicy::Stretch` (yolov8, yolov10, rfdetr: everything in the catalog
/// but yolox) `Fit::inner` *is* the model input, so the content rectangle is
/// square and so is the thumbnail — 96x96 on rfdetr at 384, whatever shape the
/// camera is.
///
/// Deriving the shape from the content rectangle rather than hardcoding 96x54
/// is free and keeps the thumbnail a scaled copy of exactly what the model is
/// shown. It is not what makes `min_area_fraction` one number for every
/// camera: an area fraction survives an anisotropic scale, so a squashed
/// thumbnail would report the same fraction anyway.
pub fn thumb_size(content: InputSize) -> (usize, usize) {
    let source_w = content.w.max(1);
    let w = source_w.min(MAX_THUMB_W);
    let h = (content.h * w / source_w).max(1);
    (w, h)
}

/// One camera's rolling-average background and the verdicts it produces.
pub struct MotionDetector {
    config: MotionConfig,
    /// The background at the thumbnail's geometry, on the thumbnail's 0..255
    /// scale. `f32` and not `u8`: at alpha 0.02 an integer average never
    /// moves at all — `0.02 * d` truncates to zero for every difference under
    /// 50 — so the background would freeze on its first frame and every later
    /// verdict would be measured against a scene from minutes ago.
    background: Vec<f32>,
    size: (usize, usize),
    /// Thumbnails observed since calibration last restarted, counting the one
    /// that restarted it: the first frame, or the first at a new geometry.
    /// Those two are the only events that restart it — a lightning rebaseline
    /// replaces the background, keeps this count, and advances it like any
    /// other frame.
    frames: u32,
}

impl MotionDetector {
    pub fn new(config: MotionConfig) -> Self {
        Self {
            config,
            background: Vec::new(),
            size: (0, 0),
            frames: 0,
        }
    }

    /// Compare one thumbnail against the background, then fold it in.
    ///
    /// The three ways this reports no motion are not the same thing: a frame
    /// measured against a background still being learned (the calibration
    /// window, which the first frame and a geometry change restart), a scene
    /// cut, and a genuinely still scene. Only the last is a statement about
    /// the picture, and the verdict names the other two: `calibrating` and
    /// `scene_cut` are each set on their own frame, and [`crate::gate`]
    /// refuses to skip work on a verdict carrying either.
    pub fn observe(&mut self, thumb: &GrayThumb) -> MotionVerdict {
        if self.size != thumb.size() {
            self.take_background(thumb);
            self.frames = 1;
            return MotionVerdict::still();
        }

        // Read before the frame is folded in, so the flag describes the
        // background this frame was compared against rather than the one the
        // comparison produced.
        let calibrating = self.frames < CALIBRATION_FRAMES;
        let threshold = f32::from(self.config.threshold);
        let changed = self
            .background
            .iter()
            .zip(&thumb.pixels)
            .filter(|(bg, px)| (f32::from(**px) - **bg).abs() > threshold)
            .count();
        let changed_fraction = changed as f32 / self.background.len() as f32;

        if changed_fraction > LIGHTNING_FRACTION {
            // A scene cut, not motion — and the background is now describing a
            // scene that no longer exists, so it is replaced outright rather
            // than averaged toward the new one over the next 50 frames (during
            // which every frame would read as motion).
            //
            // `frames` deliberately survives and advances. It survives because
            // a calibrated detector stays calibrated: restarting the
            // calibration here would report `calibrating` for 5 seconds every
            // time a light came on, and what the camera is looking at then
            // tends to be worth measuring. It advances because a detector that
            // has just rebaselined onto the scene in front of it has, if
            // anything, more to go on than a calibrating one — and because a
            // camera that cuts on most samples (an IR-cut filter hunting,
            // auto-exposure oscillating) has to finish calibrating at some
            // point, rather than sitting at "no motion" for as long as it
            // flickers.
            //
            // Neither of those is what keeps the gate open on this frame:
            // `scene_cut` is, and it is set whether or not the detector was
            // calibrating.
            self.take_background(thumb);
            self.frames = self.frames.saturating_add(1);
            return MotionVerdict {
                changed_fraction,
                motion: false,
                calibrating,
                scene_cut: true,
            };
        }

        let alpha = if calibrating {
            CALIBRATION_ALPHA
        } else {
            self.config.alpha
        };
        for (bg, px) in self.background.iter_mut().zip(&thumb.pixels) {
            *bg += alpha * (f32::from(*px) - *bg);
        }
        self.frames = self.frames.saturating_add(1);

        MotionVerdict {
            changed_fraction,
            motion: !calibrating && changed_fraction >= self.config.min_area_fraction,
            calibrating,
            scene_cut: false,
        }
    }

    fn take_background(&mut self, thumb: &GrayThumb) {
        self.background.clear();
        self.background
            .extend(thumb.pixels.iter().map(|px| f32::from(*px)));
        self.size = thumb.size();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIDE: InputSize = InputSize { w: 1920, h: 1080 };

    /// A detector on the defaults, with the gate switched on.
    fn detector() -> MotionDetector {
        MotionDetector::new(MotionConfig {
            enabled: true,
            ..MotionConfig::default()
        })
    }

    /// A thumbnail built directly, bypassing the RGB24 downsample.
    fn thumb(w: usize, h: usize, fill: u8) -> GrayThumb {
        GrayThumb {
            w,
            h,
            pixels: vec![fill; w * h],
        }
    }

    /// `fill`, with a `bw x bh` block of `value` at the top-left corner.
    fn block(w: usize, h: usize, fill: u8, bw: usize, bh: usize, value: u8) -> GrayThumb {
        let mut thumb = thumb(w, h, fill);
        for y in 0..bh {
            for x in 0..bw {
                thumb.pixels[y * w + x] = value;
            }
        }
        thumb
    }

    /// Observe one still frame `count` times, which is `count` observations
    /// toward the calibration window.
    fn observe_still(detector: &mut MotionDetector, still: &GrayThumb, count: u32) {
        for _ in 0..count {
            detector.observe(still);
        }
    }

    /// Run a detector to the end of its calibration window on one still frame,
    /// so the next observation is the first that can report motion.
    fn calibrate(detector: &mut MotionDetector, still: &GrayThumb) {
        observe_still(detector, still, CALIBRATION_FRAMES);
    }

    /// A packed RGB24 buffer of `size`, `stride` bytes per row, filled by
    /// `pixel(x, y) -> (r, g, b)`.
    fn rgb24(
        size: InputSize,
        stride: usize,
        pixel: impl Fn(usize, usize) -> (u8, u8, u8),
    ) -> Vec<u8> {
        let mut plane = vec![0u8; stride * size.h];
        for y in 0..size.h {
            for x in 0..size.w {
                let (r, g, b) = pixel(x, y);
                let at = y * stride + x * 3;
                plane[at] = r;
                plane[at + 1] = g;
                plane[at + 2] = b;
            }
        }
        plane
    }

    // ---- the detector ------------------------------------------------------

    #[test]
    fn nothing_reports_motion_while_the_background_is_still_being_learned() {
        // The background starts as one frame, so "differs from the background"
        // means "differs from whatever the camera happened to be looking at"
        // until it has absorbed a few more.
        let mut warming = detector();
        let still = thumb(96, 54, 100);
        let moved = block(96, 54, 100, 48, 27, 200);

        // The first frame becomes the background; every frame in the window
        // after it differs from that background by a quarter of the picture
        // and still reports no motion.
        warming.observe(&still);
        for frame in 1..CALIBRATION_FRAMES {
            assert!(!warming.observe(&moved).motion, "frame {frame}");
        }

        // ...and it is the window that says so, not the picture: a detector
        // past it has an opinion about the very same frame.
        let mut calibrated = detector();
        calibrate(&mut calibrated, &still);
        assert!(calibrated.observe(&moved).motion);
    }

    #[test]
    fn the_calibration_window_is_exactly_the_documented_number_of_observations() {
        // The window the README publishes as "the first 25 samples", pinned
        // against the constant from both sides: widening the compare in
        // `observe` from `<` to `<=` fails the second half, narrowing it to a
        // count one lower fails the first.
        let still = thumb(96, 54, 100);
        let moved = block(96, 54, 100, 48, 27, 200);

        let mut last_inside = detector();
        observe_still(&mut last_inside, &still, CALIBRATION_FRAMES - 1);
        let verdict = last_inside.observe(&moved);
        assert!(
            !verdict.motion,
            "observation {CALIBRATION_FRAMES} is still inside the window"
        );
        // The window is what the flag reports, and the gate is what reads it:
        // a verdict from inside it says nothing about the picture, so it is
        // never one the gate may skip on.
        assert!(verdict.calibrating);

        let mut first_outside = detector();
        observe_still(&mut first_outside, &still, CALIBRATION_FRAMES);
        let verdict = first_outside.observe(&moved);
        assert!(
            verdict.motion,
            "observation {} is the first outside it",
            CALIBRATION_FRAMES + 1
        );
        assert!(!verdict.calibrating);
    }

    #[test]
    fn every_observation_of_the_calibration_window_is_flagged_as_one() {
        // The flag the whole reopen guarantee rests on (`crate::gate`: a
        // camera whose detector is not calibrated is never gated), asserted on
        // every verdict the window produces rather than only at its edge —
        // including the first frame, which is the background rather than a
        // comparison against one.
        let mut warming = detector();
        let still = thumb(96, 54, 100);

        assert!(warming.observe(&still).calibrating, "the first frame");
        for frame in 1..CALIBRATION_FRAMES {
            assert!(warming.observe(&still).calibrating, "frame {frame}");
        }
        assert!(
            !warming.observe(&still).calibrating,
            "the first one past it"
        );
    }

    #[test]
    fn a_scene_that_cuts_on_every_sample_still_finishes_calibrating() {
        // An IR-cut filter hunting at dusk, or auto-exposure oscillating under
        // a security light: every sample after the first is a scene cut. The
        // counter has to keep moving through those, or the camera reports no
        // motion for as long as it flickers and cannot recover on its own.
        let mut flickering = detector();
        let dark = thumb(96, 54, 40);
        let bright = thumb(96, 54, 200);
        for observation in 0..CALIBRATION_FRAMES {
            let flip = if observation % 2 == 0 { &bright } else { &dark };
            let verdict = flickering.observe(flip);
            assert!(!verdict.motion, "{observation}");
            // The first frame *is* the background; every one after it is a cut
            // and is flagged as one, so a camera in this state is one the gate
            // infers on every sample of.
            assert_eq!(verdict.scene_cut, observation > 0, "{observation}");
        }

        // Calibrated, on the scene the last cut left behind.
        let settled = if CALIBRATION_FRAMES.is_multiple_of(2) {
            &dark
        } else {
            &bright
        };
        assert!(
            flickering
                .observe(&block(96, 54, settled.pixels[0], 48, 27, 120))
                .motion
        );
    }

    #[test]
    fn a_static_scene_reports_no_motion_after_calibration() {
        let mut detector = detector();
        let still = thumb(96, 54, 120);
        calibrate(&mut detector, &still);

        for _ in 0..50 {
            let verdict = detector.observe(&still);
            assert_eq!(verdict.changed_fraction, 0.0);
            assert!(!verdict.motion);
        }
    }

    #[test]
    fn a_moving_block_reports_motion_covering_its_own_area() {
        // A quarter of the frame changes; the fraction reported is that
        // quarter, which is what makes `min_area_fraction` mean something an
        // operator can reason about.
        let mut detector = detector();
        let still = thumb(96, 54, 100);
        calibrate(&mut detector, &still);

        let verdict = detector.observe(&block(96, 54, 100, 48, 27, 200));
        assert!(verdict.motion);
        assert!(
            (verdict.changed_fraction - 0.25).abs() < 1e-6,
            "{}",
            verdict.changed_fraction
        );
    }

    #[test]
    fn a_change_under_the_area_floor_is_not_motion_but_is_still_measured() {
        let mut detector = MotionDetector::new(MotionConfig {
            enabled: true,
            min_area_fraction: 0.1,
            ..MotionConfig::default()
        });
        let still = thumb(100, 10, 100);
        calibrate(&mut detector, &still);

        // 50 of 1000 pixels: half the floor.
        let verdict = detector.observe(&block(100, 10, 100, 50, 1, 200));
        assert!(!verdict.motion);
        assert!((verdict.changed_fraction - 0.05).abs() < 1e-6);
    }

    #[test]
    fn a_change_exactly_at_the_area_floor_counts_as_motion() {
        // The compare is `>=`, so the floor is the first fraction that counts.
        let mut detector = MotionDetector::new(MotionConfig {
            enabled: true,
            min_area_fraction: 0.1,
            ..MotionConfig::default()
        });
        let still = thumb(100, 10, 100);
        calibrate(&mut detector, &still);

        // 100 of 1000 pixels: the floor exactly.
        let verdict = detector.observe(&block(100, 10, 100, 100, 1, 200));
        assert_eq!(verdict.changed_fraction, 0.1);
        assert!(verdict.motion);
    }

    #[test]
    fn a_frame_changing_exactly_the_scene_cut_fraction_is_motion() {
        // The scene-cut compare is strict, so 80 % is the largest change that
        // is still an object rather than a cut — the one fraction where the
        // README's "more than 80 %" and the code could have drifted apart.
        let mut detector = detector();
        let still = thumb(10, 10, 100);
        calibrate(&mut detector, &still);

        // 80 of 100 pixels.
        let verdict = detector.observe(&block(10, 10, 100, 10, 8, 200));
        assert_eq!(verdict.changed_fraction, LIGHTNING_FRACTION);
        assert!(verdict.motion);

        // ...and it went through the rolling average, not the rebaseline: a
        // cut would have taken the new scene outright and read 0.0 next.
        let held = detector.observe(&block(10, 10, 100, 10, 8, 200));
        assert_eq!(held.changed_fraction, LIGHTNING_FRACTION);
    }

    #[test]
    fn sensor_noise_under_the_threshold_is_not_motion() {
        // A real static scene is not a constant picture: sensor noise moves
        // every pixel between samples. While that swing stays under the
        // threshold none of it counts as changed, which is what "a static scene
        // reports no motion" means on a camera rather than on a fixture — the
        // constant-picture version of this test cannot fail if thresholding
        // broke.
        let noisy = |phase: usize| {
            let mut thumb = thumb(96, 54, 100);
            for (at, px) in thumb.pixels.iter_mut().enumerate() {
                *px = if (at + phase).is_multiple_of(2) {
                    110
                } else {
                    90
                };
            }
            thumb
        };

        let mut detector = detector();
        calibrate(&mut detector, &noisy(0));

        // Every pixel swings the full 20 levels, under the threshold of 25.
        let verdict = detector.observe(&noisy(1));
        assert_eq!(verdict.changed_fraction, 0.0);
        assert!(!verdict.motion);
    }

    #[test]
    fn a_whole_frame_illumination_change_rebaselines_instead_of_reporting_motion() {
        let mut detector = detector();
        let dark = thumb(96, 54, 40);
        calibrate(&mut detector, &dark);

        let bright = thumb(96, 54, 200);
        let flash = detector.observe(&bright);
        assert_eq!(flash.changed_fraction, 1.0);
        assert!(!flash.motion, "a scene cut is not motion");
        // …and says so as its own field, which is what keeps the gate from
        // reading this frame's `motion: false` as a still scene. The detector
        // was past its window, so the flag it does *not* set matters as much.
        assert!(flash.scene_cut);
        assert!(!flash.calibrating);

        // The background is the new scene outright, so the very next frame is
        // judged against it — not averaged toward it over the next 50 frames,
        // every one of which would have read as motion.
        let settled = detector.observe(&bright);
        assert_eq!(settled.changed_fraction, 0.0);
        assert!(!settled.motion);
        // This one is the ordinary still verdict, cut and window both behind
        // it: the frames after a cut are the gate's to skip on.
        assert!(!settled.scene_cut);
        assert!(!settled.calibrating);
        // ...and the detector is still calibrated: it did not go blind.
        assert!(detector.observe(&block(96, 54, 200, 48, 27, 40)).motion);
    }

    #[test]
    fn a_scene_cut_inside_the_calibration_window_carries_both_flags() {
        // The two "this says nothing about the picture" bits are independent:
        // a detector still learning its background can cut, and the verdict
        // has to name both, since the window ending is not what stops the cut
        // from being read as a still scene.
        let mut warming = detector();
        let dark = thumb(96, 54, 40);
        warming.observe(&dark);

        let flash = warming.observe(&thumb(96, 54, 200));
        assert_eq!(flash.changed_fraction, 1.0);
        assert!(flash.scene_cut);
        assert!(flash.calibrating);
        assert!(!flash.motion);
    }

    #[test]
    fn a_geometry_change_starts_over_rather_than_comparing_mismatched_frames() {
        let mut detector = detector();
        calibrate(&mut detector, &thumb(96, 54, 100));

        let verdict = detector.observe(&thumb(96, 72, 200));
        assert_eq!(verdict, MotionVerdict::still());
        // Spelled out because the compare above is against the same
        // constructor and so pins nothing about the fields: calibration starts
        // over at the new geometry, and there was no comparison behind this
        // frame for a cut to have come out of.
        assert!(verdict.calibrating);
        assert!(!verdict.scene_cut);
        // and it re-calibrates at the new geometry
        assert!(!detector.observe(&block(96, 72, 200, 96, 36, 40)).motion);
    }

    #[test]
    fn raising_the_threshold_lowers_the_changed_fraction_monotonically() {
        // Four bands, each a different distance from the background.
        let still = thumb(4, 4, 100);
        let mut banded = thumb(4, 4, 100);
        for (row, delta) in [10u8, 20, 40, 80].into_iter().enumerate() {
            for x in 0..4 {
                banded.pixels[row * 4 + x] = 100 + delta;
            }
        }

        let fraction_at = |threshold: u8| {
            let mut detector = MotionDetector::new(MotionConfig {
                enabled: true,
                threshold,
                ..MotionConfig::default()
            });
            calibrate(&mut detector, &still);
            detector.observe(&banded).changed_fraction
        };

        let fractions: Vec<f32> = [5u8, 15, 30, 60, 100]
            .into_iter()
            .map(fraction_at)
            .collect();
        assert_eq!(fractions, vec![1.0, 0.75, 0.5, 0.25, 0.0]);
        for pair in fractions.windows(2) {
            assert!(pair[1] <= pair[0], "{fractions:?}");
        }
    }

    #[test]
    fn a_faster_alpha_absorbs_a_held_change_sooner() {
        // Something moves into frame and stops there. The background is
        // supposed to learn it, and how fast is exactly what alpha says — this
        // is the knob that decides when a parked car stops being motion.
        let still = thumb(20, 20, 100);
        let held = block(20, 20, 100, 20, 10, 160);

        let frames_to_settle = |alpha: f32| {
            let mut detector = MotionDetector::new(MotionConfig {
                enabled: true,
                alpha,
                ..MotionConfig::default()
            });
            calibrate(&mut detector, &still);
            (1..=500)
                .find(|_| !detector.observe(&held).motion)
                .expect("the background absorbs a held change at any alpha")
        };

        let slow = frames_to_settle(0.02);
        let medium = frames_to_settle(0.1);
        let fast = frames_to_settle(0.5);
        assert!(fast < medium, "{fast} vs {medium}");
        assert!(medium < slow, "{medium} vs {slow}");
    }

    // ---- the thumbnail -----------------------------------------------------

    #[test]
    fn the_thumbnail_keeps_the_content_aspect_under_a_width_cap() {
        assert_eq!(thumb_size(InputSize { w: 416, h: 234 }), (96, 54));
        assert_eq!(thumb_size(WIDE), (96, 54));
        // the stretch profiles hand this a square content rect — it is the
        // model input itself — so the thumbnail is square whatever the camera
        // is shaped like
        assert_eq!(thumb_size(InputSize::square(384)), (96, 96));
        assert_eq!(thumb_size(InputSize::square(640)), (96, 96));
        // 4:3 stays 4:3 rather than being squashed into the 16:9 shape
        assert_eq!(thumb_size(InputSize { w: 640, h: 480 }), (96, 72));
        // portrait: the cap is on the width, so the height is the long side
        assert_eq!(thumb_size(InputSize { w: 480, h: 640 }), (96, 128));
        // already smaller than the cap: kept as it is, never scaled up
        assert_eq!(thumb_size(InputSize { w: 64, h: 32 }), (64, 32));
        // a sliver still has a usable row
        assert_eq!(thumb_size(InputSize { w: 4000, h: 2 }).1, 1);
    }

    #[test]
    fn a_downsample_averages_each_block_rather_than_sampling_a_point() {
        // A 1-pixel checkerboard: every point sample is 0 or 255 and every
        // box mean is 127. Point sampling here would make a frame that
        // shifted by one pixel look like a total scene change.
        let size = InputSize { w: 192, h: 108 };
        let stride = size.w * 3 + 16;
        let checker = rgb24(size, stride, |x, y| {
            let on = ((x + y) % 2 == 0) as u8 * 255;
            (on, on, on)
        });

        let thumb = GrayThumb::from_rgb24(&checker, stride, size);
        assert_eq!(thumb.size(), (96, 54));
        assert_eq!(thumb.pixels.len(), 96 * 54);
        assert!(
            thumb.pixels.iter().all(|px| *px == 127),
            "{:?}",
            &thumb.pixels[..8]
        );
    }

    #[test]
    fn a_downsample_places_constant_blocks_where_they_belong() {
        // Left half white, right half black: the boundary has to land in the
        // middle of the thumbnail, not be smeared across it.
        let size = InputSize { w: 192, h: 108 };
        let stride = size.w * 3;
        let split = rgb24(size, stride, |x, _| {
            if x < size.w / 2 {
                (255, 255, 255)
            } else {
                (0, 0, 0)
            }
        });

        let thumb = GrayThumb::from_rgb24(&split, stride, size);
        for y in 0..54 {
            for x in 0..48 {
                assert_eq!(thumb.pixels[y * 96 + x], 255, "({x}, {y})");
            }
            for x in 48..96 {
                assert_eq!(thumb.pixels[y * 96 + x], 0, "({x}, {y})");
            }
        }
    }

    #[test]
    fn luma_weights_a_grey_ramp_the_way_bt601_does() {
        // Grey in, the same grey out — the property the weights summing to 256
        // buys, and the one an off-by-one weight breaks at the white end.
        for level in [0u8, 1, 77, 128, 254, 255] {
            let size = InputSize { w: 8, h: 4 };
            let stride = size.w * 3;
            let plane = rgb24(size, stride, |_, _| (level, level, level));
            let thumb = GrayThumb::from_rgb24(&plane, stride, size);
            assert!(thumb.pixels.iter().all(|px| *px == level), "grey {level}");
        }
        // ...and the channels are not interchangeable: green dominates, and a
        // saturated primary lands on its own weight scaled by 255/256 —
        // floor(77 * 255 / 256), floor(150 * 255 / 256), floor(29 * 255 / 256).
        let size = InputSize { w: 4, h: 4 };
        let stride = size.w * 3;
        let red = GrayThumb::from_rgb24(&rgb24(size, stride, |_, _| (255, 0, 0)), stride, size);
        let green = GrayThumb::from_rgb24(&rgb24(size, stride, |_, _| (0, 255, 0)), stride, size);
        let blue = GrayThumb::from_rgb24(&rgb24(size, stride, |_, _| (0, 0, 255)), stride, size);
        assert_eq!(
            (red.pixels[0], green.pixels[0], blue.pixels[0]),
            (76, 149, 28)
        );
    }

    #[test]
    fn a_content_rectangle_smaller_than_the_cap_is_copied_pixel_for_pixel() {
        let size = InputSize { w: 8, h: 4 };
        let stride = size.w * 3 + 3;
        let ramp = rgb24(size, stride, |x, y| {
            let v = (y * 8 + x) as u8 * 8;
            (v, v, v)
        });

        let thumb = GrayThumb::from_rgb24(&ramp, stride, size);
        assert_eq!(thumb.size(), (8, 4));
        for y in 0..4 {
            for x in 0..8 {
                assert_eq!(thumb.pixels[y * 8 + x], (y * 8 + x) as u8 * 8, "({x}, {y})");
            }
        }
    }

    #[test]
    fn the_thumbnail_reaches_the_detector_as_motion() {
        // The two halves together: a real RGB24 plane through the downsample
        // and into a verdict, which is the path `decode::RgbScaler` takes.
        let size = InputSize { w: 192, h: 108 };
        let stride = size.w * 3;
        let still = GrayThumb::from_rgb24(&rgb24(size, stride, |_, _| (30, 30, 30)), stride, size);
        let moved = GrayThumb::from_rgb24(
            &rgb24(size, stride, |_, y| {
                if y < size.h / 2 {
                    (220, 220, 220)
                } else {
                    (30, 30, 30)
                }
            }),
            stride,
            size,
        );

        let mut detector = detector();
        calibrate(&mut detector, &still);
        let verdict = detector.observe(&moved);
        assert!(verdict.motion);
        assert!(
            (verdict.changed_fraction - 0.5).abs() < 0.02,
            "{}",
            verdict.changed_fraction
        );
    }

    // ---- config ------------------------------------------------------------

    #[test]
    fn the_gate_is_off_unless_it_is_switched_on() {
        assert!(resolve(&MotionOverrides::default(), &MotionOverrides::default()).is_none());
        // every other knob set, still off
        let tuned = MotionOverrides::parse(r#"{"threshold":40,"alpha":0.1}"#).unwrap();
        assert!(resolve(&tuned, &MotionOverrides::default()).is_none());
        assert!(!MotionConfig::default().enabled);
    }

    #[test]
    fn an_enabled_gate_resolves_to_the_documented_defaults() {
        let config = resolve(
            &MotionOverrides::parse(r#"{"enabled":true}"#).unwrap(),
            &MotionOverrides::default(),
        )
        .unwrap();
        assert_eq!(
            config,
            MotionConfig {
                enabled: true,
                ..MotionConfig::default()
            }
        );
        assert_eq!(config.threshold, 25);
        assert_eq!(config.alpha, 0.02);
        assert_eq!(config.linger_ms, 12_000);
        assert_eq!(config.epoch_bypass_ms, 15_000);
        assert_eq!(config.reverify_ms, 10_000);
    }

    #[test]
    fn a_camera_overrides_only_the_knobs_it_names() {
        let global =
            MotionOverrides::parse(r#"{"enabled":true,"threshold":40,"alpha":0.1}"#).unwrap();
        let camera = MotionOverrides::parse(r#"{"threshold":15,"linger_ms":30000}"#).unwrap();

        let resolved = resolve(&global, &camera).unwrap();
        assert_eq!(resolved.threshold, 15, "the camera's own value wins");
        assert_eq!(resolved.alpha, 0.1, "the global value survives");
        assert_eq!(resolved.linger_ms, 30_000);
        assert_eq!(
            resolved.min_area_fraction, DEFAULT_MIN_AREA_FRACTION,
            "a knob neither names keeps the default"
        );
        // the other camera in the same group is unaffected
        assert_eq!(
            resolve(&global, &MotionOverrides::default())
                .unwrap()
                .threshold,
            40
        );
    }

    #[test]
    fn a_camera_can_switch_the_gate_on_or_off_by_itself() {
        let off = MotionOverrides::default();
        let on = MotionOverrides::parse(r#"{"enabled":true}"#).unwrap();
        assert!(resolve(&off, &on).is_some());
        assert!(resolve(
            &on,
            &MotionOverrides::parse(r#"{"enabled":false}"#).unwrap()
        )
        .is_none());
    }

    #[test]
    fn every_knob_parses_from_json() {
        let all = r#"{"enabled":true,"threshold":30,"min_area_fraction":0.02,"alpha":0.05,
                      "linger_ms":9000,"epoch_bypass_ms":20000,"reverify_ms":4000}"#;
        let config = resolve(
            &MotionOverrides::parse(all).unwrap(),
            &MotionOverrides::default(),
        )
        .unwrap();
        assert_eq!(
            config,
            MotionConfig {
                enabled: true,
                threshold: 30,
                min_area_fraction: 0.02,
                alpha: 0.05,
                linger_ms: 9_000,
                epoch_bypass_ms: 20_000,
                reverify_ms: 4_000,
            }
        );
    }

    #[test]
    fn out_of_range_knobs_are_refused_at_parse_time() {
        for json in [
            r#"{"threshold":0}"#,
            // 255 is the largest difference two pixels can have and the
            // compare is strict, so it counts nothing as changed
            r#"{"threshold":255}"#,
            r#"{"min_area_fraction":0}"#,
            r#"{"min_area_fraction":1.5}"#,
            r#"{"min_area_fraction":-0.1}"#,
            // at or above the scene-cut fraction the floor is unreachable:
            // anything bigger is classified as a cut and reports no motion
            r#"{"min_area_fraction":0.8}"#,
            r#"{"min_area_fraction":1}"#,
            r#"{"alpha":0}"#,
            r#"{"alpha":1.5}"#,
            // the switch does not exempt the knobs under it — an experiment
            // parked behind `enabled: false` fails startup rather than waiting
            // there to be switched on
            r#"{"enabled":false,"alpha":0}"#,
        ] {
            assert!(MotionOverrides::parse(json).is_err(), "{json} parsed");
        }
        // the edges that do something are legal: alpha 1 is "the background is
        // the last frame", threshold 254 is "only a near-total swing counts",
        // and a floor just under the scene-cut fraction is the least sensitive
        // gate that can still fire
        assert!(
            MotionOverrides::parse(r#"{"alpha":1,"min_area_fraction":0.79,"threshold":254}"#)
                .is_ok()
        );
    }

    #[test]
    fn an_explicitly_null_knob_reads_as_unset_rather_than_as_an_error() {
        // serde maps JSON `null` onto the same `None` an absent key produces,
        // and `deny_unknown_fields` does not reach it, so a template layer that
        // emits nulls for the knobs it has no value for runs on the defaults.
        // Pinned because both readings are defensible and the current one is
        // not written down anywhere else.
        let parsed = MotionOverrides::parse(r#"{"enabled":true,"threshold":null}"#).unwrap();
        assert!(parsed.threshold.is_none());
        assert_eq!(
            resolve(&parsed, &MotionOverrides::default())
                .unwrap()
                .threshold,
            DEFAULT_THRESHOLD
        );
    }

    #[test]
    fn malformed_and_mistyped_knobs_are_refused() {
        assert!(MotionOverrides::parse("not json").is_err());
        assert!(MotionOverrides::parse("[]").is_err());
        assert!(MotionOverrides::parse(r#"{"enabled":"yes"}"#).is_err());
        assert!(MotionOverrides::parse(r#"{"threshold":300}"#).is_err());
        // a mistyped knob is refused rather than silently running on defaults
        assert!(MotionOverrides::parse(r#"{"enable":true}"#).is_err());
        assert!(MotionOverrides::parse(r#"{"min_area":0.1}"#).is_err());
        // ...and an empty object is the documented "all defaults"
        assert!(MotionOverrides::parse("{}").is_ok());
    }
}
