//! The qparams sidecar a uint8-IO artifact ships with.
//!
//! A QDQ export carries float32 graph IO, and its edge QuantizeLinear /
//! DequantizeLinear nodes hold the scale and zero-point. When
//! `tools/qdq-export/u8_io_surgery.py` strips those edges to make the graph's
//! IO uint8 — so the QNN EP runs the whole pass on the HTP instead of leaving
//! the edge conversion to the CPU — the qparams have to live somewhere the
//! host can read: `<model>.qparams.json`, next to the artifact. This module
//! is that file's reader; the packer quantizes input bytes with
//! [`QuantParams::quantize`] and the backend dequantizes output codes with
//! [`QuantParams::dequantize`], which are exactly the removed nodes' own
//! arithmetic (ONNX spec: round half to even, then saturate).

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use super::encoding::QuantParams;

/// The spelling this reader accepts, shared with the exporter.
const SPEC: &str = "cairn.u8io.qparams";
const VERSION: u32 = 1;

/// Both edges' qparams, as loaded from the sidecar. Either side absent means
/// that edge stayed float32 in the artifact (`--mode input`/`output` exports
/// convert one edge only).
#[derive(Debug, Clone, Default)]
pub struct IoQuant {
    /// The input edge's qparams and the input name the exporter recorded —
    /// checked against the model's own input name at open, because a sidecar
    /// copied next to the wrong artifact would otherwise quantize with
    /// another model's scale.
    pub input: Option<(String, QuantParams)>,
    /// Per-output qparams, keyed by the model's own output names.
    pub outputs: HashMap<String, QuantParams>,
}

#[derive(Deserialize)]
struct RawSidecar {
    spec: String,
    version: u32,
    input: Option<RawInput>,
    #[serde(default)]
    outputs: HashMap<String, RawQp>,
}

#[derive(Deserialize)]
struct RawInput {
    name: String,
    scale: f32,
    zero_point: u8,
}

#[derive(Deserialize)]
struct RawQp {
    scale: f32,
    zero_point: u8,
}

fn checked(scale: f32, zero_point: u8, where_: &str, path: &Path) -> Result<QuantParams> {
    // Finite-positive here is what lets QuantParams carry a derived-Eq-style
    // equality: no NaN scale ever constructs one.
    if !scale.is_finite() || scale <= 0.0 {
        bail!(
            "{}: {where_} scale {scale} is not finite-positive",
            path.display()
        );
    }
    Ok(QuantParams { scale, zero_point })
}

impl IoQuant {
    /// The sidecar path for a model: `<model>.qparams.json`, full filename
    /// appended so `yolox_s-qdq-a8-u8io.onnx` and its sidecar sort together.
    pub fn sidecar_path(model: &Path) -> PathBuf {
        let mut os = model.as_os_str().to_os_string();
        os.push(".qparams.json");
        PathBuf::from(os)
    }

    /// Load the sidecar next to `model`, `Ok(None)` when there is none —
    /// absence is the ordinary float-IO case, not an error. Only a real
    /// NotFound counts as absence: `exists()` would fold a permission error
    /// into "no sidecar" and silently run a u8 config as float.
    pub fn load_for(model: &Path) -> Result<Option<Self>> {
        let path = Self::sidecar_path(model);
        match fs::metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                return Err(e)
                    .with_context(|| format!("checking qparams sidecar {}", path.display()))
            }
            Ok(_) => {}
        }
        let text = fs::read_to_string(&path)
            .with_context(|| format!("reading qparams sidecar {}", path.display()))?;
        let raw: RawSidecar = serde_json::from_str(&text)
            .with_context(|| format!("parsing qparams sidecar {}", path.display()))?;
        if raw.spec != SPEC || raw.version != VERSION {
            bail!(
                "{}: spec {:?} version {} is not {SPEC} v{VERSION}",
                path.display(),
                raw.spec,
                raw.version
            );
        }
        let input = raw
            .input
            .map(|i| {
                Ok::<_, anyhow::Error>((
                    i.name.clone(),
                    checked(i.scale, i.zero_point, "input", &path)?,
                ))
            })
            .transpose()?;
        let outputs = raw
            .outputs
            .into_iter()
            .map(|(name, qp)| {
                let checked = checked(qp.scale, qp.zero_point, &format!("output {name}"), &path)?;
                Ok((name, checked))
            })
            .collect::<Result<HashMap<_, _>>>()?;
        if input.is_none() && outputs.is_empty() {
            bail!("{}: sidecar converts neither edge", path.display());
        }
        Ok(Some(Self { input, outputs }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Names are per-test (labels.rs's convention for `temp_dir` fixtures):
    /// the suite runs tests concurrently in one process.
    fn write(name: &str, json: &str) -> PathBuf {
        let model = std::env::temp_dir().join(format!("cairn-detect-qparams-{name}"));
        fs::write(&model, b"not a real model").unwrap();
        fs::write(IoQuant::sidecar_path(&model), json).unwrap();
        model
    }

    #[test]
    fn absent_sidecar_is_none_not_an_error() {
        assert!(IoQuant::load_for(Path::new("does/not/exist.onnx"))
            .unwrap()
            .is_none());
    }

    #[test]
    fn sidecar_round_trips_both_edges() {
        let model = write(
            "m.onnx",
            r#"{"spec":"cairn.u8io.qparams","version":1,
                "input":{"name":"images","scale":1.0,"zero_point":0},
                "outputs":{"output":{"scale":0.024440454,"zero_point":102}}}"#,
        );
        let quant = IoQuant::load_for(&model).unwrap().unwrap();
        let (name, input) = quant.input.unwrap();
        assert_eq!(name, "images");
        assert_eq!(
            input,
            QuantParams {
                scale: 1.0,
                zero_point: 0
            }
        );
        let out = quant.outputs["output"];
        assert_eq!(out.zero_point, 102);
        // The removed DequantizeLinear's own arithmetic.
        assert_eq!(out.dequantize(102), 0.0);
        assert!((out.dequantize(255) - 3.7393894).abs() < 1e-4);
    }

    #[test]
    fn wrong_spec_and_bad_scale_are_refused() {
        let model = write("wrong.onnx", r#"{"spec":"other","version":1}"#);
        assert!(IoQuant::load_for(&model).is_err());

        let model = write(
            "nan.onnx",
            r#"{"spec":"cairn.u8io.qparams","version":1,
                "input":{"name":"x","scale":0.0,"zero_point":0},"outputs":{}}"#,
        );
        assert!(IoQuant::load_for(&model).is_err());
    }

    #[test]
    fn a_sidecar_converting_neither_edge_is_refused() {
        // `input: null, outputs: {}` parses cleanly and would silently mean
        // "run float" — exactly the valid-but-inert config shape that must
        // warn or refuse, never no-op.
        let model = write(
            "inert.onnx",
            r#"{"spec":"cairn.u8io.qparams","version":1,"input":null,"outputs":{}}"#,
        );
        assert!(IoQuant::load_for(&model).is_err());
    }
}
