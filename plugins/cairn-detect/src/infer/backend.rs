//! The seam between "run this model on this frame" and the SDK that does it.
//!
//! One backend is implemented, [`onnxruntime::OrtBackend`], and it is the only
//! one that executes. The other two names in [`BackendKind`] parse on the
//! command line and fail at [`Detector::open`](super::Detector::open) — they
//! exist so a hardware profile can *name* the runtime it targets before that
//! runtime lands, and so [`BackendKind::capabilities`] has somewhere to say
//! what each one will and will not accept.
//!
//! No SDK type appears in a signature here. A backend reports its model as
//! [`ModelIo`] — a name, a size and a [`Declared`] per output — and answers a
//! run with [`Raw`] tensors, dims plus floats. Both of those types predate this
//! module and neither mentions `ort`, which is what let the seam go in without
//! touching sniffing, sizing or decode. The one place ort types still reach
//! outside [`onnxruntime`] is `resolve`'s pair of `ort::value::ValueType`
//! readers, `declared_input_size` and `static_output_dims`: the ort backend
//! calls them to fill its [`ModelIo`], and a second backend would fill the same
//! struct from its own metadata without going near them.
//!
//! Opening is [`Backend::open`] rather than a free function so each backend
//! owns its own failure modes, and the run half is two calls rather than one
//! because the tensors a run produces are *borrowed from the backend*: ort
//! hands back a `SessionOutputs` that borrows the session, so a `run` returning
//! owned buffers would have to copy every output tensor on every frame.

pub(super) mod onnxruntime;

use std::fmt;
use std::path::Path;

use anyhow::Result;
use clap::ValueEnum;

use super::geometry::InputSize;
use super::heads::Raw;
use super::resolve::Declared;

/// Which runtime executes the model.
///
/// `rknn` and `qnn` are accepted by `--backend` and rejected at
/// [`Detector::open`](super::Detector::open). Parsing them is the point: the
/// host already refuses to run a group on a non-`ort` profile unless the
/// profile declares `experimental: true` *and* the group sets
/// `allow_experimental: true` (`Cairn.Config.check_backend_implemented/3`), and
/// this is the belt to that suspender — a name that reached the plugin anyway
/// stops here with a message about the backend, instead of being a clap usage
/// error the operator reads as a typo in the flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum BackendKind {
    /// onnxruntime, CPU execution provider. The only one that runs today.
    Ort,
    /// Rockchip NPU (rk3566/rk3576) via librknnrt. Not implemented.
    Rknn,
    /// Qualcomm HTP via onnxruntime's QNN execution provider. Not implemented.
    Qnn,
}

impl fmt::Display for BackendKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Ort => "ort",
            Self::Rknn => "rknn",
            Self::Qnn => "qnn",
        })
    }
}

impl BackendKind {
    /// What this backend accepts, as static data.
    ///
    /// Static because profile validation on the Elixir side has to answer the
    /// same questions at config load, with no plugin running and possibly no
    /// such hardware attached. Today it mirrors only the artifact column
    /// (`Cairn.Config.Profile`'s backend→`model:`-key map); the capability
    /// booleans are consumed by nothing but this crate's own summary line
    /// until the plan's phase-7 validation table mirrors them too. Both
    /// copies are claims about the runtime, not observations of it — see the
    /// per-row notes for which are established and which are conservative
    /// readings.
    pub(super) fn capabilities(self) -> Capabilities {
        match self {
            // Both yes, and both load-bearing in this crate rather than
            // inferred: every RF-DETR export leaves its spatial dims dynamic
            // and ort runs them (that is why `--input-size` exists), and
            // onnxruntime implements the ONNX `NonMaxSuppression` op on CPU, so
            // an export with the head fused in loads. No shipped profile feeds
            // it one — `catalog` pairs every grid family with `DEFAULT_NMS`,
            // i.e. host-side suppression in `heads` — so this flag says what
            // the backend would accept, not what cairn sends it.
            Self::Ort => Capabilities {
                supports_fused_nms: true,
                supports_dynamic_shapes: true,
                artifact: ArtifactFormat::Onnx,
            },
            // Dynamic shapes: rknn-toolkit2 compiles to a fixed input geometry,
            // so there is nothing to leave dynamic. Fused NMS is the
            // conservative reading: `research/npu-backends.md` establishes the
            // ban for QNN only, and no source it cites puts an NMS op on the
            // RKNN NPU either. Refusing an export we may not be able to run
            // costs an operator a profile edit; accepting one that silently
            // does not run costs a deployment.
            Self::Rknn => Capabilities {
                supports_fused_nms: false,
                supports_dynamic_shapes: false,
                artifact: ArtifactFormat::Rknn,
            },
            // Both established in `research/npu-backends.md`: the NMS operator
            // is not in QNN's supported op list, and HTP takes no dynamic
            // shapes. The artifact is still `.onnx` — QNN is an onnxruntime
            // execution provider, and what changes is that the graph must be
            // quantized to QDQ, which is a property of the export rather than
            // of the file format. The host's profile schema nonetheless keys
            // QNN's artifact separately from ort's (`model.qnn:` against
            // `model.onnx:`, `Cairn.Config.Profile`): a QDQ graph is a
            // different *file* from the fp32 export, and which file to load is
            // a different question from what format it is in. Neither is a
            // stale copy of the other.
            Self::Qnn => Capabilities {
                supports_fused_nms: false,
                supports_dynamic_shapes: false,
                artifact: ArtifactFormat::Onnx,
            },
        }
    }
}

/// What a backend accepts. See [`BackendKind::capabilities`] for where the
/// values come from and why they are a table rather than a probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Capabilities {
    /// Whether a model whose export fuses the NMS op into the graph will run.
    /// `false` means that family must be paired with a head that needs no NMS,
    /// or with a decode that does it host-side.
    pub supports_fused_nms: bool,
    /// Whether the runtime will accept a graph that leaves a spatial dim
    /// symbolic. `false` means the artifact's geometry is fixed at compile
    /// time and `--input-size` can only agree with it.
    pub supports_dynamic_shapes: bool,
    /// The compiled artifact a profile must point this backend at.
    pub artifact: ArtifactFormat,
}

impl fmt::Display for Capabilities {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "artifact={} fused-nms={} dynamic-shapes={}",
            self.artifact,
            if self.supports_fused_nms { "yes" } else { "no" },
            if self.supports_dynamic_shapes {
                "yes"
            } else {
                "no"
            }
        )
    }
}

/// The compiled model file a backend loads.
///
/// A profile names one artifact per backend rather than one model: an `.rknn`
/// is produced from an `.onnx` by a host-side toolchain, so the two are
/// different files describing the same trained weights.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ArtifactFormat {
    Onnx,
    Rknn,
}

impl fmt::Display for ArtifactFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Onnx => ".onnx",
            Self::Rknn => ".rknn",
        })
    }
}

/// Per-backend session settings, handed whole to [`Backend::open`] so a backend
/// reads its own group and ignores the rest.
///
/// There is no `ort` group: the only session setting the ort backend makes
/// today is the CPU execution provider, which is not a profile knob and has
/// nothing to configure. The other two groups are the knobs a profile will
/// carry when those backends land.
///
/// `#[allow(dead_code)]`: every field below is written by `Default` and read by
/// nothing, because the code that would read it is the backend that does not
/// exist yet. `-D warnings` would otherwise make the option surface of an
/// unimplemented backend inexpressible, which is the opposite of designing it
/// in. Each backend's `open` reading its own group removes the need for the
/// attribute on that group.
#[allow(dead_code)]
#[derive(Debug, Default, Clone)]
pub(super) struct SessionOptions {
    pub qnn: QnnOptions,
    pub rknn: RknnOptions,
}

/// Qualcomm HTP knobs, per onnxruntime's QNN execution-provider options.
///
/// `None` on any of them means "leave the provider's own default", which is
/// what an unset profile field expands to.
#[allow(dead_code)]
#[derive(Debug, Default, Clone)]
pub(super) struct QnnOptions {
    /// `htp_arch` — the HTP architecture version of the target SoC (68 on
    /// QCS6490). Wrong here is not slow, it is a provider that declines the
    /// graph.
    pub htp_arch: Option<u32>,
    /// `htp_performance_mode` — the DSP power/latency point, e.g. `burst`
    /// against `balanced`. Left as a string because the accepted set is the
    /// provider's, and mirroring it here would be a second list to keep true.
    pub performance_mode: Option<String>,
    /// `vtcm_mb` — tightly-coupled memory to reserve, in MB.
    pub vtcm_mb: Option<u32>,
}

/// Rockchip NPU knobs, per librknnrt.
#[allow(dead_code)]
#[derive(Debug, Default, Clone)]
pub(super) struct RknnOptions {
    /// Which NPU core(s) the model is bound to, as librknnrt's core mask. The
    /// runtime is sequential per model (`research/npu-backends.md`), so this
    /// spreads *models* across cores and never one model's frames.
    pub core_mask: Option<u32>,
}

/// What a backend reports about the model it opened, in terms no SDK defines.
pub(super) struct ModelIo {
    /// The model's own name for its first input, settled at startup so a run
    /// never looks one up by index.
    pub input_name: String,
    /// The input's spatial size when the artifact pins it, `None` when the
    /// export left it symbolic and `--input-size` has to supply it.
    pub declared_input_size: Option<InputSize>,
    /// Every output the model declares, in the model's own order.
    pub outputs: Vec<Declared>,
}

/// One frame, packed for the model this backend opened.
///
/// `shape` is NCHW with N=1: this plugin infers one frame per run, and nothing
/// in the crate batches.
pub(super) struct InputTensor {
    pub shape: [i64; 4],
    pub values: Vec<f32>,
}

/// An inference runtime holding one open model.
///
/// `Send` because single-camera mode moves the whole
/// [`Detector`](super::Detector) onto a spawned inference thread (`run_single`
/// in main.rs); multiplexed mode keeps it on the thread that opened it. Either
/// way one detector is owned by one thread — nothing shares one.
pub(super) trait Backend: Send {
    /// Load `model` and settle everything [`ModelIo`] reports.
    ///
    /// Failing here rather than on the first frame is deliberate: a wrong
    /// artifact or a shape nothing can decode should stop the process while the
    /// operator who typed the flag is still watching.
    fn open(model: &Path, options: &SessionOptions) -> Result<Self>
    where
        Self: Sized;

    /// Which backend this is — the value `--backend` named.
    ///
    /// Capabilities are deliberately NOT a trait method: they live on
    /// [`BackendKind::capabilities`] alone, so an implementation has no way
    /// to report something its kind's row denies.
    fn kind(&self) -> BackendKind;

    /// The model's inputs and outputs as settled at [`Backend::open`].
    fn io(&self) -> &ModelIo;

    /// Infer one frame. The returned tensors borrow this backend until they are
    /// dropped, which is what keeps a run from copying every output.
    fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>>;
}

/// One run's output tensors, still owned by the backend that produced them.
pub(super) trait Tensors {
    /// The tensor the model calls `name`, or an error naming what was asked
    /// for. Roles are looked up by name, never by position, so a family with
    /// two outputs never depends on the order the export listed them in.
    fn get(&self, name: &str) -> Result<Raw<'_>>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_names_round_trip_through_clap() {
        for kind in [BackendKind::Ort, BackendKind::Rknn, BackendKind::Qnn] {
            let rendered = kind.to_string();
            let parsed = BackendKind::from_str(&rendered, true)
                .unwrap_or_else(|e| panic!("clap does not accept {rendered:?}: {e}"));
            assert_eq!(parsed, kind, "--backend {rendered} parsed as {parsed}");
        }
    }

    /// The rules `research/npu-backends.md` turns into profile validation, in
    /// the form the Elixir table has to mirror. A change here is a change to
    /// what a profile may declare, not a refactor.
    #[test]
    fn capability_table_matches_the_researched_rules() {
        let ort = BackendKind::Ort.capabilities();
        assert!(ort.supports_fused_nms);
        assert!(ort.supports_dynamic_shapes);
        assert_eq!(ort.artifact, ArtifactFormat::Onnx);

        // QNN: no NMS op on HTP, no dynamic shapes, still an ONNX artifact
        // because QNN is an onnxruntime execution provider.
        let qnn = BackendKind::Qnn.capabilities();
        assert!(!qnn.supports_fused_nms);
        assert!(!qnn.supports_dynamic_shapes);
        assert_eq!(qnn.artifact, ArtifactFormat::Onnx);

        // RKNN: its own compiled artifact, fixed geometry.
        let rknn = BackendKind::Rknn.capabilities();
        assert!(!rknn.supports_fused_nms);
        assert!(!rknn.supports_dynamic_shapes);
        assert_eq!(rknn.artifact, ArtifactFormat::Rknn);
    }

    #[test]
    fn capabilities_render_every_field() {
        assert_eq!(
            BackendKind::Ort.capabilities().to_string(),
            "artifact=.onnx fused-nms=yes dynamic-shapes=yes"
        );
        assert_eq!(
            BackendKind::Rknn.capabilities().to_string(),
            "artifact=.rknn fused-nms=no dynamic-shapes=no"
        );
        // No real row mixes its booleans, so the two table rows above would
        // also pass a Display that swapped the fields; this one would not.
        let mixed = Capabilities {
            supports_fused_nms: false,
            supports_dynamic_shapes: true,
            artifact: ArtifactFormat::Onnx,
        };
        assert_eq!(
            mixed.to_string(),
            "artifact=.onnx fused-nms=no dynamic-shapes=yes"
        );
    }
}
