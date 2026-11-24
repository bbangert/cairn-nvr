//! The seam between "run this model on this frame" and the SDK that does it.
//!
//! This crate carries two backends, and both are onnxruntime sessions:
//! [`onnxruntime::OrtBackend`] on the CPU execution provider and
//! [`onnxruntime::QnnBackend`] on Qualcomm's HTP via the QNN plugin execution
//! provider. Any other runtime is a board library's: it implements [`Backend`]
//! in its own crate and registers a [`Provider`] under its own name, which
//! [`select`] resolves before this crate's names.
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

use anyhow::{bail, Result};

use super::encoding::{TensorLayout, TensorValues};
use super::geometry::InputSize;
use super::heads::Raw;
use super::qparams::IoQuant;
use super::resolve::Declared;

/// The backends this crate opens itself.
///
/// A board's backend is never a value of this type, only a [`Provider`], so
/// [`Detector::open`](super::Detector::open) cannot be handed a runtime this
/// crate does not carry. `qnn` executes, but the generic board marks it
/// experimental, so the host refuses a profile naming it unless the profile
/// and its group both acknowledge that
/// (`Cairn.Config.check_experimental_backend/5`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// onnxruntime, CPU execution provider.
    Ort,
    /// Qualcomm HTP via onnxruntime's QNN plugin execution provider. Needs
    /// `--qnn-library` and a full-op-coverage QDQ model.
    Qnn,
}

impl BackendKind {
    const ALL: [Self; 2] = [Self::Ort, Self::Qnn];

    pub fn descriptor(self) -> &'static Descriptor {
        match self {
            Self::Ort => &ORT,
            Self::Qnn => &QNN,
        }
    }
}

/// A backend's name and what it accepts, as static data.
///
/// Static because profile validation on the Elixir side has to answer the
/// same questions at config load, with no plugin running and possibly no
/// such hardware attached. Each board's `backends/0` mirrors the descriptors
/// of the backends it runs — [`ORT`] and [`QNN`] here, a board library's in
/// its own crate (`Cairn.Board.Generic` runs `ort` and `qnn`): `fused_nms` feeds
/// `Cairn.Config.Profile`'s `check_capabilities` rule, the Elixir row's
/// `artifact` is the `model:` key a profile is read by (not the extension
/// [`Capabilities::artifact`] carries — see [`QNN`]), and `dynamic_shapes`
/// is mirrored but read by no rule on either side (an `input_size:` disagreeing with a
/// compiled artifact is a fact about a file the host cannot open — the
/// authoring guide carries it instead). Every copy is a claim about the
/// runtime, not an observation of it — see the per-backend notes for which
/// are established and which are conservative readings.
#[derive(Debug)]
pub struct Descriptor {
    /// What `--backend` and the NIF config's `backend` call it.
    pub name: &'static str,
    pub capabilities: Capabilities,
}

// Both established on ort rather than inferred: every RF-DETR export leaves
// its spatial dims dynamic and ort runs them (that is why `--input-size`
// exists), and onnxruntime implements the ONNX `NonMaxSuppression` op on
// CPU, so an export with the head fused in loads.
// No shipped profile feeds it one — `catalog` pairs every grid family with
// `DEFAULT_NMS`, i.e. host-side suppression in `heads` — so this flag says
// what the backend would accept, not what cairn sends it.
static ORT: Descriptor = Descriptor {
    name: "ort",
    capabilities: Capabilities {
        supports_fused_nms: true,
        supports_dynamic_shapes: true,
        artifact: ".onnx",
    },
};

// Both established in `docs/npu-backends.md`: the NMS operator is not in
// QNN's supported op list, and HTP takes no dynamic shapes. The artifact is
// still `.onnx` — QNN is an onnxruntime execution provider, and what changes
// is that the graph must be quantized to QDQ, which is a property of the
// export rather than of the file format. The host's profile schema
// nonetheless keys QNN's artifact separately from ort's (`model.qnn:` against
// `model.onnx:`, `Cairn.Config.Profile`): a QDQ graph is a different *file*
// from the fp32 export, and which file to load is a different question from
// what format it is in. Neither is a stale copy of the other.
static QNN: Descriptor = Descriptor {
    name: "qnn",
    capabilities: Capabilities {
        supports_fused_nms: false,
        supports_dynamic_shapes: false,
        artifact: ".onnx",
    },
};

/// What a backend accepts. See [`Descriptor`] for where the values come from
/// and why they are a table rather than a probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    /// Whether a model whose export fuses the NMS op into the graph will run.
    /// `false` means that family must be paired with a head that needs no NMS,
    /// or with a decode that does it host-side.
    pub supports_fused_nms: bool,
    /// Whether the runtime will accept a graph that leaves a spatial dim
    /// symbolic. `false` means the artifact's geometry is fixed at compile
    /// time and `--input-size` can only agree with it.
    pub supports_dynamic_shapes: bool,
    /// The extension of the compiled artifact a profile must point this
    /// backend at, dot included. A profile names one artifact per backend
    /// rather than one model: a runtime's own format is compiled from an
    /// `.onnx` by a host-side toolchain, so the two are different files
    /// describing the same trained weights.
    pub artifact: &'static str,
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

/// A board library's backend, registered under its descriptor's name.
///
/// [`select`] consults providers before this crate's own names, so a provider
/// named `ort` or `qnn` replaces that backend: the detector opens on the
/// provider, and an embedder, which opens only on this crate's backends, is
/// refused beside it ([`embedder_backend`](super::embedder_backend)).
pub struct Provider {
    pub descriptor: &'static Descriptor,
    pub open: fn(&Path, &SessionOptions) -> Result<Box<dyn Backend>>,
}

/// What a backend name resolved to.
pub enum Selected<'a> {
    Provided(&'a Provider),
    Core(BackendKind),
}

/// `name` is `--backend` or the NIF config's `backend`, as sent.
///
/// At config load the host refuses a profile whose backend is not a key of its
/// board's `backends/0` (`check_backend` in `Cairn.Config.Profile`), so a miss
/// here is a board menu that disagrees with the library it routed to, or a
/// hand-typed `--backend`. The error lists what this build runs, so it reads as
/// a backend the build lacks rather than as a mistyped flag.
pub fn select<'a>(name: &str, providers: &'a [Provider]) -> Result<Selected<'a>> {
    if let Some(provider) = providers.iter().find(|p| p.descriptor.name == name) {
        return Ok(Selected::Provided(provider));
    }
    if let Some(kind) = BackendKind::ALL
        .into_iter()
        .find(|kind| kind.descriptor().name == name)
    {
        return Ok(Selected::Core(kind));
    }
    let mut known: Vec<&str> = providers.iter().map(|p| p.descriptor.name).collect();
    for kind in BackendKind::ALL {
        if !known.contains(&kind.descriptor().name) {
            known.push(kind.descriptor().name);
        }
    }
    bail!(
        "backend {name:?} is not one this build carries ({})",
        known.join(", ")
    )
}

/// Per-backend session settings, handed whole to [`Backend::open`] so a backend
/// reads its own group and ignores the rest.
///
/// There is no `ort` group: the only session setting the ort backend makes
/// is the CPU execution provider, which is not a profile knob and has
/// nothing to configure. The `qnn` group is read by
/// [`onnxruntime::QnnBackend`]. A board library's backend takes its own
/// settings outside this struct (its NIF's arguments, its environment), so
/// of this it reads `io_quant` at most.
#[derive(Debug, Default, Clone)]
pub struct SessionOptions {
    pub qnn: QnnOptions,
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
    /// artifact folds its normalisation and quantisation in, as a board
    /// runtime's compiled format can.
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

    /// Which backend this is, and what it accepts.
    ///
    /// Nothing checks that the capabilities a backend reports are true of its
    /// runtime; a provided backend's descriptor is checked to be the very
    /// static its [`Provider`] registered (by address, not by name).
    fn descriptor(&self) -> &'static Descriptor;

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

    fn provider(descriptor: &'static Descriptor) -> Provider {
        Provider {
            descriptor,
            open: |_, _| unreachable!("select never opens"),
        }
    }

    static BOARD: Descriptor = Descriptor {
        name: "board",
        capabilities: Capabilities {
            supports_fused_nms: false,
            supports_dynamic_shapes: false,
            artifact: ".board",
        },
    };

    static BOARD_ORT: Descriptor = Descriptor {
        name: "ort",
        capabilities: ORT.capabilities,
    };

    #[test]
    fn select_answers_a_provider_first_then_the_core_names() {
        let providers = [provider(&BOARD), provider(&BOARD_ORT)];
        let provided = |name| match select(name, &providers) {
            Ok(Selected::Provided(p)) => p.descriptor as *const Descriptor,
            _ => panic!("{name} was not answered by its provider"),
        };
        assert_eq!(provided("board"), &BOARD as *const _);
        assert_eq!(provided("ort"), &BOARD_ORT as *const _);

        for kind in BackendKind::ALL {
            match select(kind.descriptor().name, &[]) {
                Ok(Selected::Core(selected)) => assert_eq!(selected, kind),
                _ => panic!("{} did not select the core backend", kind.descriptor().name),
            }
        }
    }

    #[test]
    fn an_unknown_name_is_refused_naming_every_backend_the_build_carries() {
        let err = match select("tensorrt", &[provider(&BOARD), provider(&BOARD_ORT)]) {
            Ok(_) => panic!("an unknown name selected a backend"),
            Err(err) => err.to_string(),
        };
        assert_eq!(
            err,
            r#"backend "tensorrt" is not one this build carries (board, ort, qnn)"#
        );
        // A provider's name means nothing to a build without it.
        let err = match select("board", &[]) {
            Ok(_) => panic!("a provider's name selected without the provider"),
            Err(err) => err.to_string(),
        };
        assert!(err.ends_with("(ort, qnn)"), "{err}");
    }

    /// The rules `docs/npu-backends.md` turns into profile validation, in
    /// the form the Elixir table has to mirror. A change here is a change to
    /// what a profile may declare, not a refactor.
    #[test]
    fn capability_table_matches_the_researched_rules() {
        assert_eq!(BackendKind::Ort.descriptor().name, "ort");
        let ort = BackendKind::Ort.descriptor().capabilities;
        assert!(ort.supports_fused_nms);
        assert!(ort.supports_dynamic_shapes);
        assert_eq!(ort.artifact, ".onnx");

        // QNN: no NMS op on HTP, no dynamic shapes, still an ONNX artifact
        // because QNN is an onnxruntime execution provider.
        assert_eq!(BackendKind::Qnn.descriptor().name, "qnn");
        let qnn = BackendKind::Qnn.descriptor().capabilities;
        assert!(!qnn.supports_fused_nms);
        assert!(!qnn.supports_dynamic_shapes);
        assert_eq!(qnn.artifact, ".onnx");
    }

    #[test]
    fn capabilities_render_every_field() {
        assert_eq!(
            ORT.capabilities.to_string(),
            "artifact=.onnx fused-nms=yes dynamic-shapes=yes"
        );
        assert_eq!(
            QNN.capabilities.to_string(),
            "artifact=.onnx fused-nms=no dynamic-shapes=no"
        );
        // No real row mixes its booleans, so the two rows above would also
        // pass a Display that swapped the fields; this one would not.
        let mixed = Capabilities {
            supports_fused_nms: false,
            supports_dynamic_shapes: true,
            artifact: ".onnx",
        };
        assert_eq!(
            mixed.to_string(),
            "artifact=.onnx fused-nms=no dynamic-shapes=yes"
        );
    }
}
