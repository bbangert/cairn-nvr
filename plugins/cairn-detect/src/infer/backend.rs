//! The seam between "run this model on this frame" and the SDK that does it.
//!
//! This crate carries two backends, and both are onnxruntime sessions:
//! [`onnxruntime::OrtBackend`] on the CPU execution provider and
//! [`onnxruntime::QnnBackend`] on Qualcomm's HTP via the QNN plugin execution
//! provider. The third name in [`BackendKind`], `rknn`, is a runtime a board
//! library provides: it implements [`Backend`] in its own crate and hands the
//! open backend to [`Detector::with_backend`](super::Detector::with_backend).
//! A build without that library refuses the name at
//! [`Detector::open`](super::Detector::open).
//!
//! No SDK type appears in a signature here. A backend reports its model as
//! [`ModelIo`] — a name, a size, a batch, the input's element kind, the uint8
//! outputs, the input layout and a [`Declared`] per output — and answers a
//! run with [`Raw`] tensors, dims plus floats. Both of those types predate this
//! module and neither mentions `ort`, which is what let the seam go in without
//! touching sniffing, sizing or decode. The one place ort types still reach
//! outside [`onnxruntime`] is `resolve`'s trio of `ort::value::ValueType`
//! readers, `declared_input_size`/`declared_input_batch`/`static_output_dims`: the ort backend
//! calls them to fill its [`ModelIo`], and a board library's backend fills the
//! same struct from its own runtime's metadata — those readers are private to
//! `infer`.
//!
//! Opening is [`Backend::open`] rather than a free function so each backend
//! owns its own failure modes, and the run half is two calls rather than one
//! because the tensors a run produces are *borrowed from the backend*: ort
//! hands back a `SessionOutputs` that borrows the session, so a `run` returning
//! owned buffers would have to copy every output tensor on every frame.

pub(super) mod onnxruntime;

use std::fmt;
use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::ValueEnum;

use super::encoding::{TensorLayout, TensorValues};
use super::geometry::InputSize;
use super::heads::Raw;
use super::qparams::IoQuant;
use super::resolve::Declared;

/// Which runtime executes the model.
///
/// `rknn` is accepted by `--backend` everywhere and executes only where a
/// board library hands its backend to
/// [`Detector::with_backend`](super::Detector::with_backend); this crate's own
/// [`Detector::open`](super::Detector::open) rejects it. Parsing it is the
/// point: the host already refuses to run a group on a non-`ort` profile unless the
/// profile declares `experimental: true` *and* the group sets
/// `allow_experimental: true` (`Cairn.Config.check_backend_implemented/3`), and
/// this is the belt to that suspender — a name that reached the plugin anyway
/// stops here with a message about the backend, instead of being a clap usage
/// error the operator reads as a typo in the flag. `qnn` executes, but stays
/// behind the same host-side experimental gate until it has soaked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum BackendKind {
    /// onnxruntime, CPU execution provider.
    Ort,
    /// Rockchip NPU (rk3566/rk3576) via librknnrt, from a board library.
    Rknn,
    /// Qualcomm HTP via onnxruntime's QNN plugin execution provider. Needs
    /// `--qnn-library` and a full-op-coverage QDQ model.
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
    /// such hardware attached. Each board's `backends/0` mirrors the rows of
    /// this table for the backends it runs (`Cairn.Board.Generic`: `ort` and
    /// `qnn`; `Cairn.Rockchip.Board`: `ort` and `rknn`): `fused_nms` feeds
    /// `Cairn.Config.Profile`'s `check_capabilities` rule, `artifact` picks
    /// the `model:` key a profile is read by, and `dynamic_shapes` is mirrored
    /// but read by no rule on either side (an `input_size:` disagreeing with a
    /// compiled artifact is a fact about a file the host cannot open — the
    /// authoring guide carries it instead). Every copy is a claim about the
    /// runtime, not an observation of it — see the per-row notes for which are
    /// established and which are conservative readings.
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
            // conservative reading: `docs/npu-backends.md` establishes the
            // ban for QNN only, and no source it cites puts an NMS op on the
            // RKNN NPU either. Refusing an export we may not be able to run
            // costs an operator a profile edit; accepting one that silently
            // does not run costs a deployment.
            Self::Rknn => Capabilities {
                supports_fused_nms: false,
                supports_dynamic_shapes: false,
                artifact: ArtifactFormat::Rknn,
            },
            // Both established in `docs/npu-backends.md`: the NMS operator
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
/// is the CPU execution provider, which is not a profile knob and has
/// nothing to configure. The `qnn` group is read by
/// [`onnxruntime::QnnBackend`]; `rknn` is read by a board library's backend,
/// and nothing in this crate fills it — the CLI has no flag for it, so it
/// arrives at its default.
#[derive(Debug, Default, Clone)]
pub struct SessionOptions {
    pub qnn: QnnOptions,
    pub rknn: RknnOptions,
    /// The uint8-IO artifact's edge qparams (`<model>.qparams.json`), `None`
    /// for the ordinary float-IO contract. At the session level this carries
    /// two obligations: the backend dequantizes the outputs it names, and a
    /// QNN session must keep the u8 edges on the HTP
    /// (`offload_graph_io_quantization=0` — the EP's default offloads them
    /// to the CPU EP, which silently costs the entire uint8-IO win).
    pub io_quant: Option<IoQuant>,
}

/// Qualcomm HTP knobs, per onnxruntime's QNN execution-provider options.
///
/// `None` on any of them means "leave the provider's own default", which is
/// what an unset profile field expands to — except that the spike found
/// platform detection fails on the QCS6490 without explicit `soc_model` and
/// `htp_arch` (`tools/qnn-spike/README.md`), so a working profile sets both.
#[derive(Debug, Default, Clone)]
pub struct QnnOptions {
    /// `--qnn-library` — path to the QNN plugin execution-provider library
    /// (`libonnxruntime_providers_qnn.so`, from the `onnxruntime-qnn`
    /// distribution). Required to open a `qnn` session: the EP is not
    /// compiled into onnxruntime, it is registered from this file at open.
    pub library: Option<PathBuf>,
    /// `soc_model` — Qualcomm's numeric SoC id (35 on QCS6490). Without it,
    /// QNN's platform detection fails on this board.
    pub soc_model: Option<u32>,
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
#[derive(Debug, Default, Clone)]
pub struct RknnOptions {
    /// Which NPU core(s) the model is bound to, as librknnrt's core mask. The
    /// runtime is sequential per model (`docs/npu-backends.md`), so this
    /// spreads *models* across cores and never one model's frames.
    pub core_mask: Option<u32>,
}

/// What the bytes of a model's input are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputElement {
    /// Floats in the profile's encoding: the ordinary contract.
    F32,
    /// uint8 codes of a uint8-IO artifact. The caller must pass a qparams
    /// sidecar whose input entry names [`ModelIo::input_name`]; its qparams
    /// are what make the packer emit the codes.
    U8Codes,
    /// The frame's own bytes, in the profile encoding's channel order: the
    /// artifact folds its normalisation and quantisation in (an `.rknn`).
    /// A sidecar input entry is refused as belonging to some other artifact.
    ///
    /// The bytes go through the quantized packer under
    /// [`TensorEncoding::pixel_quant`](super::TensorEncoding::pixel_quant),
    /// so an encoding that has none is refused at open: a limit of that
    /// route, not of such an artifact. Nothing at open can check that the
    /// channel order and scale folded into the artifact are the profile's.
    U8Pixels,
}

/// What a backend reports about the model it opened, in terms no SDK defines.
///
/// Whatever reads a field reads it at open, before any frame, which is what
/// lets a wrong artifact fail while the operator is watching. Each field's doc
/// says what reporting it commits to.
pub struct ModelIo {
    /// The model's own name for its first input. Printed on the startup line
    /// and matched against the qparams sidecar's input entry; binding the
    /// input on a run is the backend's own business.
    pub input_name: String,
    /// The input's spatial size when the artifact pins it, `None` when the
    /// export left it symbolic and `--input-size` has to supply it. `Some` is
    /// binding: it outranks the profile's default and a disagreeing
    /// `--input-size` is refused at open, so a fixed-geometry runtime reports
    /// it.
    pub declared_input_size: Option<InputSize>,
    /// The input's declared batch when it is a fixed positive rank-4 dim,
    /// `None` for symbolic/dynamic. The embedder's open refuses a fixed
    /// batch other than 1; the detector's own N=1 discipline predates the
    /// field and never reads it.
    pub declared_input_batch: Option<i64>,
    /// Every output the model declares, in the model's own order — which a
    /// single-output layout depends on: it reads the first. A two-output
    /// layout binds its roles by shape where the dims pin them, by name where
    /// they do not, and a split layout by exact name (`box0..box2`,
    /// `cls0..cls2`), so a backend reports the names the artifact carries.
    /// Without `--model-profile` the profile is sniffed from
    /// these dims, and the bound names are what [`Tensors::get`] is asked
    /// for. [`Declared::dims`] `None` defers the class count to the first
    /// run's [`Raw::dims`] and gives the sniff nothing to match.
    pub outputs: Vec<Declared>,
    /// What the input tensor's elements are. Read at open, so an artifact
    /// and a qparams sidecar that disagree fail while the operator is
    /// watching, not at the first pass. See [`InputElement`] for what each
    /// variant commits the caller to.
    pub input_element: InputElement,
    /// The declared outputs whose element type is uint8, by name. Must match
    /// the sidecar's `outputs` keys exactly, and listing one commits the
    /// backend to dequantizing it: [`Raw::values`] is f32 whatever the model
    /// emitted.
    pub u8_outputs: Vec<String>,
    /// The order the backend wants the input's values in. The detector copies
    /// it into its resolved [`InputSpec`](super::InputSpec), which is what the
    /// packer reads, so the backend decides it and no profile does. The
    /// onnxruntime backends always report NCHW, which is also the only shape
    /// `declared_input_size` reads a size from; an NHWC ONNX export gets no
    /// declared size there and is not detected as NHWC anywhere — onnxruntime
    /// refuses the NCHW tensor at its first run.
    pub input_layout: TensorLayout,
}

/// One tensor, packed for the model this backend opened — a frame for the
/// detector, a person crop for the embedder.
///
/// N=1: this plugin infers one tensor per run, and nothing in the crate
/// batches. `shape` is `[1, 3, h, w]` or `[1, h, w, 3]` as `layout` says:
/// outside this crate the only constructor is [`InputTensor::new`], which
/// derives one from the other. `values` carries the packer's dtype choice
/// (f32, u8 codes for a uint8-IO artifact, or u8 pixel bytes) to the
/// session bind.
#[non_exhaustive]
pub struct InputTensor {
    pub shape: [i64; 4],
    pub layout: TensorLayout,
    pub values: TensorValues,
}

impl InputTensor {
    pub fn new(size: InputSize, layout: TensorLayout, values: TensorValues) -> Self {
        let (w, h) = (size.w as i64, size.h as i64);
        let shape = match layout {
            TensorLayout::Nchw => [1, 3, h, w],
            TensorLayout::Nhwc => [1, h, w, 3],
        };
        Self {
            shape,
            layout,
            values,
        }
    }
}

/// An inference runtime holding one open model.
///
/// Implementable outside this crate: a board library provides its runtime
/// this way. What [`Backend::io`] reports is checked and acted on at open (see
/// [`ModelIo`]); what follows is what the rest of the contract holds.
///
/// **Output ownership.** [`Backend::run`] returns tensors that borrow the
/// backend, and [`Tensors::get`] lends a [`Raw`] whose `values` is `&[f32]`
/// and whose `dims` are this run's — a deferred class count is settled from
/// them and every decode re-checks its layout against them. A runtime whose
/// outputs are not f32 it can lend in place (quantized codes, f16) converts
/// them into f32 buffers the returned [`Tensors`] owns, and lends those: the
/// uint8-IO path in [`onnxruntime`] dequantizes its outputs inside `run`
/// exactly that way.
///
/// **`Send`, not `Sync`.** A detector moves between threads: `run_single` in
/// `cli.rs` hands it to a spawned inference thread, and `cairn-ort` keeps one
/// behind a mutex that NIF calls take from whichever scheduler thread runs
/// them. Nothing calls one backend from two threads at once, so it never has
/// to be `Sync`.
pub trait Backend: Send {
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
pub trait Tensors {
    /// The tensor the model calls `name`, or an error naming what was asked
    /// for. Roles are looked up by name, never by position, so a family with
    /// several outputs never depends on the order the export listed them in.
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

    /// The rules `docs/npu-backends.md` turns into profile validation, in
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
