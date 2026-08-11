//! The decoder's config, decoded from terms and resolved into what the decode
//! stages take.
//!
//! Two layers on purpose: the `Raw*` structs are the term shape, and resolving
//! them is where every rule lives — plain Rust with no `Env` in it, which is
//! what makes any of it testable.
//!
//! Everything here arrives as plain terms, including the model's resolved
//! input spec: the engine that resolved it lives in another NIF library
//! (`cairn-ort`), and no resource can cross between two. The spec's
//! spellings round-trip through `cairn-detect`'s own `wire` helpers
//! (`cairn-ort`'s `engine_spec` is the producer), so a decoder cannot be
//! built for a subtly different model than the one that resolved them.

use cairn_detect::decode::DecoderKind;
use cairn_detect::infer::{InputSize, InputSpec, ResizePolicy, TensorEncoding};
use cairn_detect::motion::{self, MotionConfig, MotionOverrides};
use clap::ValueEnum;
use rustler::NifMap;

use crate::error::{NativeError, Result};

/// The `--sample-fps` range, restated from `main.rs`'s
/// `value_parser!(u32).range(1..=30)` because clap owns it there and there is
/// no argv here. The value sizes the motion detector's calibration window
/// (`CALIBRATION_SECONDS * sample_fps` frames) — the rate gate itself lives
/// in the pipeline (`Cairn.Pipeline.SampleGate`), reading the same configured
/// value — so a zero that reached the stages would be a division by zero on
/// the frame path.
const SAMPLE_FPS: std::ops::RangeInclusive<u32> = 1..=30;

/// One decoder's config: the term shape. Every key is required — `nil` is how
/// the host spells an absent value, so a missing key is a host bug and fails
/// at the decode rather than taking a default here.
#[derive(Debug, NifMap)]
pub struct RawDecoderParams {
    /// The `--decoder` vocabulary: `auto`, `sw`, `vaapi`, `qsv`, `nvdec`,
    /// `v4l2`, `videotoolbox` — per-SoC backend selection, unchanged.
    pub decoder: String,
    /// The engine's resolved input spec, as `cairn-ort`'s `engine_spec`
    /// spells it.
    pub width: usize,
    pub height: usize,
    pub encoding: String,
    pub resize: String,
    pub resize_pad: u8,
    /// What the camera is sending, from the H.264 parser's stream format —
    /// `nil` when the caller has none, which is not the same as "square zero"
    /// and is why this is an option rather than a `0` sentinel. See
    /// [`DecoderParams::source`].
    pub source_width: Option<usize>,
    pub source_height: Option<usize>,
    /// `--motion-json` verbatim, or `nil` for a gate that is off.
    pub motion_json: Option<String>,
    pub sample_fps: u32,
}

#[derive(Debug)]
pub struct DecoderParams {
    pub kind: DecoderKind,
    pub spec: InputSpec,
    /// The source's own geometry, when the caller knows it.
    ///
    /// Software decode does not need this — it learns geometry from the first
    /// SPS — but a V4L2 M2M decoder configures its OUTPUT format when the codec
    /// context opens, and one opened at 0x0 opens *successfully* and then fails
    /// every frame with `AVERROR_BUG`. Measured on QCS6490, where that read as
    /// hardware decode delivering nothing at all
    /// (`research/board-first-light.md`).
    pub source: Option<InputSize>,
    pub motion: Option<MotionConfig>,
    pub sample_fps: u32,
}

impl RawDecoderParams {
    pub fn resolve(self) -> Result<DecoderParams> {
        if self.width == 0 || self.height == 0 {
            return Err(NativeError::Config(format!(
                "input size {}x{} must be positive",
                self.width, self.height
            )));
        }
        if !SAMPLE_FPS.contains(&self.sample_fps) {
            return Err(NativeError::Config(format!(
                "sample_fps must be {}..={}, got {}",
                SAMPLE_FPS.start(),
                SAMPLE_FPS.end(),
                self.sample_fps
            )));
        }
        let overrides = MotionOverrides::parse(self.motion_json.as_deref().unwrap_or("{}"))
            .map_err(|error| NativeError::Config(crate::error::chain(&error)))?;

        Ok(DecoderParams {
            kind: DecoderKind::from_str(&self.decoder, true)
                .map_err(|message| NativeError::Config(format!("decoder: {message}")))?,
            spec: InputSpec {
                size: InputSize {
                    w: self.width,
                    h: self.height,
                },
                encoding: TensorEncoding::parse_wire(&self.encoding)
                    .map_err(|error| NativeError::Config(crate::error::chain(&error)))?,
                resize: ResizePolicy::from_wire(&self.resize, self.resize_pad)
                    .map_err(|error| NativeError::Config(crate::error::chain(&error)))?,
            },
            source: source_size(self.source_width, self.source_height)?,
            motion: motion::resolve(&overrides, &MotionOverrides::default()),
            sample_fps: self.sample_fps,
        })
    }
}

/// Half a source geometry is not a geometry: a caller that knows one axis and
/// not the other has a bug, and passing the pair on with a zero in it would
/// hand libavcodec exactly the shape this field exists to avoid. The upper
/// bound is `i32::MAX` because the codecpar fields these land on are `i32` —
/// past it, the `as i32` at the write would manufacture the very zero (or a
/// negative) this function refuses.
fn source_size(width: Option<usize>, height: Option<usize>) -> Result<Option<InputSize>> {
    const MAX: usize = i32::MAX as usize;
    match (width, height) {
        (None, None) => Ok(None),
        (Some(w), Some(h)) if w > 0 && h > 0 && w <= MAX && h <= MAX => {
            Ok(Some(InputSize { w, h }))
        }
        (w, h) => Err(NativeError::Config(format!(
            "source size {w:?}x{h:?} must be a positive pair within i32 or absent on both axes"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> RawDecoderParams {
        RawDecoderParams {
            decoder: "sw".into(),
            width: 416,
            height: 416,
            encoding: "raw_bgr".into(),
            resize: "letterbox".into(),
            resize_pad: 114,
            source_width: Some(2560),
            source_height: Some(1920),
            motion_json: None,
            sample_fps: 5,
        }
    }

    #[test]
    fn the_wire_spellings_resolve_into_the_spec_the_engine_exported() {
        let resolved = params().resolve().unwrap();
        assert_eq!(resolved.kind, DecoderKind::Sw);
        assert_eq!(resolved.spec.size, InputSize { w: 416, h: 416 });
        assert_eq!(resolved.spec.encoding, TensorEncoding::RawBgr);
        assert_eq!(resolved.spec.resize, ResizePolicy::Letterbox { pad: 114 });
        assert!(resolved.motion.is_none());
        assert_eq!(resolved.sample_fps, 5);
    }

    #[test]
    fn a_name_no_wire_produced_is_refused_by_field() {
        for (field, raw) in [
            (
                "decoder",
                RawDecoderParams {
                    decoder: "magic".into(),
                    ..params()
                },
            ),
            (
                "encoding",
                RawDecoderParams {
                    encoding: "bgr".into(),
                    ..params()
                },
            ),
            (
                "resize policy",
                RawDecoderParams {
                    resize: "crop".into(),
                    ..params()
                },
            ),
        ] {
            let error = raw.resolve().unwrap_err();
            assert_eq!(error.reason(), "config", "{field}");
        }
    }

    #[test]
    fn the_source_geometry_crosses_when_the_caller_has_it_and_is_absent_when_not() {
        assert_eq!(
            params().resolve().unwrap().source,
            Some(InputSize { w: 2560, h: 1920 })
        );

        let unknown = RawDecoderParams {
            source_width: None,
            source_height: None,
            ..params()
        };
        assert_eq!(unknown.resolve().unwrap().source, None);
    }

    #[test]
    fn a_half_known_or_zero_source_geometry_is_refused_rather_than_passed_on() {
        // Zero is the shape that opens a V4L2 M2M decoder and then fails every
        // frame, so it must not survive resolution under any spelling.
        for (w, h) in [
            (Some(2560), None),
            (None, Some(1920)),
            (Some(0), Some(1920)),
            (Some(2560), Some(0)),
            (Some(0), None),
            (None, Some(0)),
            (Some(usize::MAX), Some(1920)),
        ] {
            let error = RawDecoderParams {
                source_width: w,
                source_height: h,
                ..params()
            }
            .resolve()
            .unwrap_err();
            assert_eq!(error.reason(), "config", "{w:?}x{h:?}");
        }
    }

    #[test]
    fn a_zero_dimension_is_refused_before_anything_is_built_for_it() {
        for (w, h) in [(0, 416), (416, 0), (0, 0)] {
            let error = RawDecoderParams {
                width: w,
                height: h,
                ..params()
            }
            .resolve()
            .unwrap_err();
            assert_eq!(error.reason(), "config", "{w}x{h}");
        }
    }

    #[test]
    fn sample_fps_is_held_to_the_flags_range() {
        for rate in [0, 31, 10_000] {
            let error = RawDecoderParams {
                sample_fps: rate,
                ..params()
            }
            .resolve()
            .unwrap_err();
            assert_eq!(error.reason(), "config", "{rate}");
        }
        for rate in [1, 5, 30] {
            assert_eq!(
                RawDecoderParams {
                    sample_fps: rate,
                    ..params()
                }
                .resolve()
                .unwrap()
                .sample_fps,
                rate
            );
        }
    }

    #[test]
    fn the_operator_owned_motion_knobs_reach_the_stages() {
        let resolved = RawDecoderParams {
            motion_json: Some(r#"{"enabled":true,"threshold":30}"#.into()),
            ..params()
        }
        .resolve()
        .unwrap();
        assert_eq!(resolved.motion.unwrap().threshold, 30);
    }

    #[test]
    fn a_knob_no_run_could_honour_is_refused_as_config() {
        for bad in [r#"{"alpha":0}"#, r#"{"nonsense":1}"#] {
            let error = RawDecoderParams {
                motion_json: Some(bad.into()),
                ..params()
            }
            .resolve()
            .unwrap_err();
            assert_eq!(error.reason(), "config", "{bad}");
        }
    }
}
