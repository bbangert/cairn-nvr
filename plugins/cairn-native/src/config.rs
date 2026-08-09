//! The host's config, decoded from terms and resolved into what the stages take.
//!
//! Two layers on purpose: the `Raw*` structs are the term shape, and resolving
//! them is where every rule lives — plain Rust with no `Env` in it, which is what
//! makes any of it testable.
//!
//! The host sends the same vocabulary the operator's flags use (D-P6), parsed by
//! the same code that parses argv, so a profile cannot mean one thing to the plugin
//! and another to the NIF.

use std::collections::HashMap;
use std::path::PathBuf;

use cairn_detect::decode::DecoderKind;
use cairn_detect::infer::{
    BackendKind, InputSize, ModelProfile, QnnOptions, ScoreFloors, TrackFloorOverrides,
};
use cairn_detect::motion::{self, MotionConfig, MotionOverrides};
use clap::ValueEnum;
use rustler::NifMap;

use crate::error::{NativeError, Result};

/// The `--sample-fps` range, restated from `main.rs`'s
/// `value_parser!(u32).range(1..=30)` because clap owns it there and there is no
/// argv here. On this path the value only sizes the motion detector's calibration
/// window (`CALIBRATION_SECONDS * sample_fps` frames), so a zero that reached the
/// stages would leave the gate with no calibration at all.
const SAMPLE_FPS: std::ops::RangeInclusive<u32> = 1..=30;

/// Per-VM model config: the term shape. Every key is required — `nil` is how the
/// host spells an absent value, so a missing key is a host bug and fails at the
/// decode rather than taking a default here.
#[derive(Debug, NifMap)]
pub struct RawInitConfig {
    pub model: String,
    pub backend: String,
    pub model_profile: Option<String>,
    pub input_size: Option<String>,
    pub labels: Option<String>,
    pub allow_label_mismatch: bool,
    pub embedder_model: Option<String>,
    pub decoder: String,
    pub sample_fps: u32,
    pub qnn: RawQnnOptions,
}

#[derive(Debug, NifMap)]
pub struct RawQnnOptions {
    pub library: Option<String>,
    pub soc_model: Option<u32>,
    pub htp_arch: Option<u32>,
    pub performance_mode: Option<String>,
    pub vtcm_mb: Option<u32>,
}

#[derive(Debug)]
pub struct InitConfig {
    pub model: PathBuf,
    pub backend: BackendKind,
    pub model_profile: Option<ModelProfile>,
    pub input_size: Option<InputSize>,
    pub labels: Option<PathBuf>,
    pub allow_label_mismatch: bool,
    pub embedder_model: Option<PathBuf>,
    pub decoder: DecoderKind,
    pub sample_fps: u32,
    pub qnn: QnnOptions,
}

impl RawInitConfig {
    pub fn resolve(self) -> Result<InitConfig> {
        let backend = enum_value::<BackendKind>("backend", &self.backend)?;
        let embedder_model = self.embedder_model.map(PathBuf::from);
        // The embedder's own open refuses qnn too, but only after the detector's
        // multi-second HTP graph compile. `main.rs`'s `run` refuses it up front as
        // well, so the two hosts answer the same profile the same way.
        if embedder_model.is_some() && backend == BackendKind::Qnn {
            return Err(NativeError::Config(
                "the embedder does not run on qnn yet (no QDQ embedder artifact) \
                 — drop embedder_model or use the ort backend"
                    .to_string(),
            ));
        }
        if !SAMPLE_FPS.contains(&self.sample_fps) {
            return Err(NativeError::Config(format!(
                "sample_fps must be {}..={}, got {}",
                SAMPLE_FPS.start(),
                SAMPLE_FPS.end(),
                self.sample_fps
            )));
        }

        Ok(InitConfig {
            model: PathBuf::from(self.model),
            backend,
            model_profile: self
                .model_profile
                .as_deref()
                .map(ModelProfile::parse)
                .transpose()
                .map_err(|message| NativeError::Config(format!("model_profile: {message}")))?,
            input_size: self
                .input_size
                .as_deref()
                .map(InputSize::parse)
                .transpose()
                .map_err(|message| NativeError::Config(format!("input_size: {message}")))?,
            labels: self.labels.map(PathBuf::from),
            allow_label_mismatch: self.allow_label_mismatch,
            embedder_model,
            decoder: enum_value::<DecoderKind>("decoder", &self.decoder)?,
            sample_fps: self.sample_fps,
            qnn: QnnOptions {
                library: self.qnn.library.map(PathBuf::from),
                soc_model: self.qnn.soc_model,
                htp_arch: self.qnn.htp_arch,
                performance_mode: self.qnn.performance_mode,
                vtcm_mb: self.qnn.vtcm_mb,
            },
        })
    }
}

/// One stream's scene config: the term shape. Everything here is per camera and
/// operator-owned (D-P6), never model config ([`RawInitConfig`]).
#[derive(Debug, NifMap)]
pub struct RawStreamParams {
    /// The `--min-score-json` shape already decoded: label -> minimum score, with
    /// an optional `"default"` key.
    pub min_score: HashMap<String, f64>,
    /// `--motion-json` verbatim, or `nil` for a gate that is off.
    pub motion_json: Option<String>,
    /// `--track-floor-json` verbatim, or `nil` for the feature off.
    pub track_floor_json: Option<String>,
    /// The stream epoch, or `nil` before the host has announced one. Fixed for the
    /// life of the stream — see `Stream`'s `epoch` field.
    pub stream_epoch: Option<String>,
}

#[derive(Debug)]
pub struct StreamParams {
    pub floors: ScoreFloors,
    pub motion: Option<MotionConfig>,
    pub epoch: Option<String>,
}

impl RawStreamParams {
    pub fn resolve(self) -> Result<StreamParams> {
        let track_floor =
            TrackFloorOverrides::parse(self.track_floor_json.as_deref().unwrap_or("{}"))
                .map_err(|error| NativeError::Config(crate::error::chain(&error)))?;
        // One camera per stream, so there is nothing to override the knobs with:
        // the shape `run_single` resolves, where the "global" and "per camera"
        // halves are the one set the caller sent.
        let floors = ScoreFloors::from_map(self.min_score)
            .with_track_floor(TrackFloorOverrides::resolve(
                &track_floor,
                &TrackFloorOverrides::default(),
            ))
            .map_err(|error| NativeError::Config(crate::error::chain(&error)))?;
        let overrides = MotionOverrides::parse(self.motion_json.as_deref().unwrap_or("{}"))
            .map_err(|error| NativeError::Config(crate::error::chain(&error)))?;

        Ok(StreamParams {
            floors,
            motion: motion::resolve(&overrides, &MotionOverrides::default()),
            epoch: self.stream_epoch,
        })
    }
}

fn enum_value<T: ValueEnum>(field: &str, value: &str) -> Result<T> {
    T::from_str(value, true).map_err(|message| NativeError::Config(format!("{field}: {message}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn init() -> RawInitConfig {
        RawInitConfig {
            model: "m.onnx".into(),
            backend: "ort".into(),
            model_profile: None,
            input_size: None,
            labels: None,
            allow_label_mismatch: false,
            embedder_model: None,
            decoder: "sw".into(),
            sample_fps: 5,
            qnn: RawQnnOptions {
                library: None,
                soc_model: None,
                htp_arch: None,
                performance_mode: None,
                vtcm_mb: None,
            },
        }
    }

    fn params() -> RawStreamParams {
        RawStreamParams {
            min_score: HashMap::new(),
            motion_json: None,
            track_floor_json: None,
            stream_epoch: None,
        }
    }

    #[test]
    fn the_plugins_own_flag_vocabulary_is_what_parses() {
        let resolved = RawInitConfig {
            backend: "ort".into(),
            decoder: "vaapi".into(),
            input_size: Some("640x352".into()),
            model_profile: Some("yolox".into()),
            ..init()
        }
        .resolve()
        .unwrap();
        assert_eq!(resolved.backend, BackendKind::Ort);
        assert_eq!(resolved.decoder, DecoderKind::Vaapi);
        assert_eq!(resolved.input_size, Some(InputSize { w: 640, h: 352 }));
        assert!(resolved.model_profile.is_some());
    }

    #[test]
    fn a_name_no_flag_would_accept_is_refused_by_field() {
        for (field, config) in [
            (
                "backend",
                RawInitConfig {
                    backend: "tensorrt".into(),
                    ..init()
                },
            ),
            (
                "decoder",
                RawInitConfig {
                    decoder: "magic".into(),
                    ..init()
                },
            ),
            (
                "input_size",
                RawInitConfig {
                    input_size: Some("huge".into()),
                    ..init()
                },
            ),
            (
                "model_profile",
                RawInitConfig {
                    model_profile: Some("yolox9000".into()),
                    ..init()
                },
            ),
        ] {
            let error = config.resolve().unwrap_err();
            assert_eq!(error.reason(), "config", "{field}");
            assert!(error.message().contains(field), "{}", error.message());
        }
    }

    #[test]
    fn sample_fps_is_held_to_the_flags_range() {
        for rate in [0, 31, 10_000] {
            assert_eq!(
                RawInitConfig {
                    sample_fps: rate,
                    ..init()
                }
                .resolve()
                .unwrap_err()
                .reason(),
                "config",
                "{rate}"
            );
        }
        for rate in [1, 5, 30] {
            assert_eq!(
                RawInitConfig {
                    sample_fps: rate,
                    ..init()
                }
                .resolve()
                .unwrap()
                .sample_fps,
                rate
            );
        }
    }

    #[test]
    fn an_embedder_on_qnn_is_refused_before_the_model_load() {
        let error = RawInitConfig {
            backend: "qnn".into(),
            embedder_model: Some("osnet.onnx".into()),
            ..init()
        }
        .resolve()
        .unwrap_err();
        assert_eq!(error.reason(), "config");
        assert!(error.message().contains("qnn"), "{}", error.message());
    }

    #[test]
    fn stream_params_default_to_the_gate_off_and_no_band() {
        let resolved = params().resolve().unwrap();
        assert!(resolved.motion.is_none());
        assert!(resolved.epoch.is_none());
        // no track floor, so the emission cutoff is the label's own min_score
        assert_eq!(resolved.floors.emit_floor_for("person"), 0.5);
    }

    #[test]
    fn the_operator_owned_knobs_reach_the_stages() {
        let resolved = RawStreamParams {
            min_score: HashMap::from([("default".into(), 0.5), ("person".into(), 0.8)]),
            motion_json: Some(r#"{"enabled":true,"threshold":30}"#.into()),
            track_floor_json: Some(r#"{"floor":0.2}"#.into()),
            stream_epoch: Some("01K1B2C3D4E5F6G7H8J9K0M1N2".into()),
        }
        .resolve()
        .unwrap();
        assert_eq!(resolved.motion.unwrap().threshold, 30);
        assert_eq!(resolved.floors.floor_for("person"), 0.8);
        assert_eq!(resolved.floors.emit_floor_for("person"), 0.2);
        assert!(resolved.epoch.is_some());
    }

    #[test]
    fn a_knob_no_run_could_honour_is_refused_as_config() {
        // Each arrives as a config error rather than as a stream that quietly
        // runs on defaults.
        for raw in [
            RawStreamParams {
                motion_json: Some(r#"{"alpha":0}"#.into()),
                ..params()
            },
            RawStreamParams {
                motion_json: Some(r#"{"nonsense":1}"#.into()),
                ..params()
            },
            RawStreamParams {
                track_floor_json: Some(r#"{"floor":0}"#.into()),
                ..params()
            },
        ] {
            assert_eq!(raw.resolve().unwrap_err().reason(), "config");
        }
        // …and the pairing check, which needs this camera's own min_score
        let raw = RawStreamParams {
            min_score: HashMap::from([("default".into(), 0.2)]),
            track_floor_json: Some(r#"{"floor":0.3}"#.into()),
            ..params()
        };
        assert_eq!(raw.resolve().unwrap_err().reason(), "config");
    }
}
