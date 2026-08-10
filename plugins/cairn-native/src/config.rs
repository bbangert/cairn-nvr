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
    /// `--motion-json` verbatim, or `nil` for a gate that is off.
    pub motion_json: Option<String>,
    pub sample_fps: u32,
}

#[derive(Debug)]
pub struct DecoderParams {
    pub kind: DecoderKind,
    pub spec: InputSpec,
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
            motion: motion::resolve(&overrides, &MotionOverrides::default()),
            sample_fps: self.sample_fps,
        })
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
