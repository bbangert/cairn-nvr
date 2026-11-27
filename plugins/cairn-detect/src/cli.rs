//! The `cairn-detect` command line: H.264 RTP in, protocol v1 ndjson out.
//!
//! A library function rather than the binary's body so that a board crate's
//! probe binary is one call to [`run`], naming the backends it carries.
//!
//! This is the plugin side of `docs/archive/plugin-contract.md`. Cairn no
//! longer launches it as a plugin — the stages run in the node, through the
//! NIFs — and nothing restarts it. What runs it is the canary's probe load
//! (`Cairn.Native.Canary`), `--cpu-baseline`, which measures and exits, and
//! the harnesses — parity, `verify/` and the scripts under `tools/`; "the
//! host" below is whichever of them launched the process, standing where the
//! contract's host stood.
//!
//! The host appends the arguments of one of the two contract variants to its
//! own command; the model flags and the motion gate's `--motion-json` come
//! from that command, which is why the gate needs no host change to reach
//! either mode.
//!
//!   * per-camera: `--camera-id`, `--udp-port`, `--min-score-json` — one
//!     process per camera, and any stream failure is fatal: the contract
//!     has a plugin exit on what it cannot recover (`run_single` below).
//!   * multiplexed: `--cameras-json` — one process for a whole plugin group,
//!     where a member's silence is normal and never exits ([`multiplex`]).
//!
//! Both directions of the protocol are live in both modes: detections go out
//! on stdout, and the host's per-camera stream epochs come in on stdin
//! ([`control`]). stdout carries protocol lines and nothing else — every
//! diagnostic, here and in the stages, goes to stderr.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use crossbeam_channel::{bounded, Receiver};
use rsmpeg::ffi;

use crate::note;
use crate::{control, decode, emit, gate, infer, motion, multiplex, rtp};
use control::Streams;
use decode::{DecoderKind, Sample};
use emit::Publisher;
use gate::Gate;
use infer::{
    Detector, Embedder, InputSize, InputSpec, IoQuant, Labels, ModelProfile, Provider, QnnOptions,
    ScoreFloors, Selected, SessionOptions, TensorLayout, TrackFloorOverrides,
};
use motion::{MotionConfig, MotionOverrides};

#[derive(Parser, Debug)]
#[command(
    name = "cairn-detect",
    about = "Cairn detection plugin (RTP in, ndjson out)"
)]
struct Args {
    /// Camera id, echoed back on every output line.
    #[arg(
        long,
        required_unless_present_any = ["cameras_json", "cpu_baseline"],
        conflicts_with = "cameras_json"
    )]
    camera_id: Option<String>,

    /// UDP port on 127.0.0.1 carrying H.264 RTP (port + 1 is reserved for RTCP).
    #[arg(
        long,
        required_unless_present_any = ["cameras_json", "cpu_baseline"],
        conflicts_with = "cameras_json"
    )]
    udp_port: Option<u16>,

    /// Measure the median CPU model-pass latency and exit: one untimed
    /// warmup, then this many timed passes on a synthetic input, printed as
    /// `cpu-baseline-ms: <median>`. Always the CPU, whatever `--backend`
    /// says — and always a fresh process that has never registered an
    /// accelerator EP, which is the point: `Cairn.Native.Health`'s D-P5
    /// ratio is only evidence if this number's venue is provable, and the
    /// engine's own process cannot prove it after its first QNN load.
    #[arg(long)]
    cpu_baseline: Option<usize>,

    /// JSON object of label -> minimum score, with an optional "default" key.
    #[arg(long, conflicts_with = "cameras_json")]
    min_score_json: Option<String>,

    /// JSON array of `{id, udp_port, min_score, motion}` — serve a whole
    /// plugin group from this one process instead of a single camera.
    #[arg(long)]
    cameras_json: Option<String>,

    /// JSON object of motion-gate knobs: `enabled` (default false),
    /// `threshold`, `min_area_fraction`, `alpha`, `linger_ms`,
    /// `epoch_bypass_ms`, `reverify_ms`.
    ///
    /// Unlike `--min-score-json` this does *not* conflict with
    /// `--cameras-json`: the gate is the operator's own setting, a flag of
    /// the command rather than an argument the host appends, so it has to be
    /// expressible in both modes. In group mode it is the default for every
    /// member, and a member's own `motion` key overrides the knobs it names.
    #[arg(long)]
    motion_json: Option<String>,

    /// JSON object with one knob, `floor`: the score down to which detections
    /// below their class's `min_score` are emitted anyway, at their real
    /// scores, for the host's low-confidence association stage. Absent — the
    /// default — emits exactly what the per-class floors admit.
    ///
    /// Operator-owned like `--motion-json`, and for the same reason it does
    /// not conflict with `--cameras-json`: it is a flag of the command rather
    /// than an argument the host appends, so it has to be expressible in
    /// both modes. In group mode it is the default for every member, and a
    /// member's own `track_floor` key replaces it.
    #[arg(long)]
    track_floor_json: Option<String>,

    /// Detection model: a yolox, rfdetr, yolov10 or yolov8/yolov9/yolo11/yolo26
    /// head, or a split-head export, as the artifact `--backend` compiles against (`.onnx` for `ort`).
    #[arg(long)]
    model: PathBuf,

    /// Inference runtime. `ort` (CPU) and `qnn` (Qualcomm HTP, needs
    /// `--qnn-library` and a QDQ model) in every build, plus any a board
    /// library's binary registers. A name the build does not carry is
    /// refused before the model opens, listing the ones it does.
    #[arg(long, default_value = "ort")]
    backend: String,

    /// The QNN plugin execution-provider library
    /// (`libonnxruntime_providers_qnn.so`). Required with `--backend qnn`:
    /// the EP is not compiled into onnxruntime, it is loaded from this file.
    /// The QNN backend libraries (`libQnnHtp*.so`, `libQnnSystem.so`) must be
    /// resolvable from it, and the DSP skel via `ADSP_LIBRARY_PATH`.
    #[arg(long)]
    qnn_library: Option<PathBuf>,

    /// Qualcomm SoC id for QNN (35 on QCS6490). QNN's own platform detection
    /// fails on some boards without it.
    #[arg(long)]
    qnn_soc_model: Option<u32>,

    /// HTP architecture version for QNN (68 on QCS6490).
    #[arg(long)]
    qnn_htp_arch: Option<u32>,

    /// HTP power/latency point for QNN, e.g. `burst`, `balanced`. The
    /// accepted set is the provider's own.
    #[arg(long)]
    qnn_performance_mode: Option<String>,

    /// Tightly-coupled memory for QNN to reserve, in MB.
    #[arg(long)]
    qnn_vtcm_mb: Option<u32>,

    /// Person Re-ID embedder (osnet-class, NCHW 3-channel with a declared
    /// input size and one static feature output). When given, every emitted
    /// `person` detection carries a base64 int8 `embedding`, cropped from the
    /// detection pass's own input tensor. Shares `--backend` — which means it
    /// is refused with anything but this build's own `ort`: with `qnn` until a
    /// QDQ embedder artifact exists, and with any board library's backend, one
    /// registered as `ort` included.
    #[arg(long)]
    embedder_model: Option<PathBuf>,

    /// Preprocessing and decode steps to run this model under: `yolox`,
    /// `rfdetr` (hyphenated spellings accepted), `yolov10`, `yolov8` (or
    /// `yolov9`, `yolo11`, `yolov11`, `yolo26` — its whole-head exports that
    /// run are raw-head), or `yolov8split` / `yolov9split` (the MIT YOLOv9,
    /// letterboxed) / `yolo26split` for a head cut before its box decode.
    /// Sniffed from the model's own input and output when omitted; required
    /// when a shape fits more than one profile (every split-DFL head does),
    /// and for rfdetr, whose exports leave their input geometry dynamic.
    #[arg(long, value_parser = ModelProfile::parse)]
    model_profile: Option<ModelProfile>,

    /// Newline-separated label names, indexed by class id.
    #[arg(long)]
    labels: Option<PathBuf>,

    /// Start even when `--labels` lists a different number of names than the
    /// model has classes. Off by default: labels are indexed positionally, so
    /// a count mismatch means every detection is emitted under another class's
    /// name and the per-label `min_score` floors gate the wrong class.
    #[arg(long)]
    allow_label_mismatch: bool,

    /// Model input geometry, `N` (square) or `WxH`. Read from the model when
    /// omitted; required for a model with dynamic spatial dims.
    #[arg(long, value_parser = InputSize::parse)]
    input_size: Option<InputSize>,

    /// H.264 decode backend — the video path, not `--backend`'s inference one.
    /// Probed at startup; any failure falls back to software.
    #[arg(long, value_enum, default_value_t = DecoderKind::Auto)]
    decoder: DecoderKind,

    /// Frames per second the decode thread's sample gate lets through to the
    /// model — the ceiling `--motion-json`'s gate skips *within*, never a
    /// floor it can push inference under. One rate for the whole process:
    /// group mode shares it across every member rather than taking a
    /// per-camera rate. `1..=30`: below 1 there is no rate to sample at, and
    /// above 30 is almost certainly a mistyped frame count rather than an
    /// intended sample rate.
    #[arg(long, default_value_t = decode::DEFAULT_SAMPLE_FPS, value_parser = clap::value_parser!(u32).range(1..=30))]
    sample_fps: u32,
}

/// Everything a binary's `main` does: argv in, exit code out, with a failure
/// reported on stderr as `fatal: …`.
pub fn run(providers: &[Provider]) -> ExitCode {
    let failed = serve(providers).inspect_err(|e| {
        // Exit loudly: this line and the status are all the host learns.
        note!("fatal: {e:#}");
    });
    // On both paths, because `note!` only queues: a clean run has lines of its own
    // still in flight.
    crate::log::drain();
    if failed.is_err() {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

fn serve(providers: &[Provider]) -> Result<()> {
    let args = Args::parse();
    // Before everything, as clap's own refusals are: the baseline ignores the
    // backend it names, but a name the build lacks is a broken argv either way.
    let backend = infer::select(&args.backend, providers).context("--backend")?;

    if let Some(passes) = args.cpu_baseline {
        let labels = Labels::load(args.labels.as_deref())?;
        let median = infer::cpu_baseline_ms(
            &args.model,
            args.input_size,
            args.model_profile,
            &labels,
            args.allow_label_mismatch,
            passes,
        )?;
        // The line format is a contract: `Cairn.Native.Canary` parses it.
        println!("cpu-baseline-ms: {median:.3}");
        return Ok(());
    }

    // `open_embedder` asks the same question, but after the detector's open —
    // on qnn a multi-second HTP graph compile. An argv combination that is
    // going down either way should say so before that, not after.
    if args.embedder_model.is_some() {
        infer::embedder_backend(&backend).context("--embedder-model")?;
    }
    // The early case, before the detector's open, of the refusal
    // `open_embedder` makes for any uint8-fed detector: the embedder crops
    // from the detector's packed tensor, which under a quantized input holds
    // u8 codes its affine inversion cannot read. The sidecar answers it here.
    if args.embedder_model.is_some() {
        if let Some(quant) = infer::IoQuant::load_for(&args.model)? {
            if quant.input.is_some() {
                anyhow::bail!(
                    "--embedder-model cannot run with a uint8-input detector artifact \
                     (the reid crop source is the detector's packed tensor) — \
                     use the float-IO artifact or drop the embedder"
                );
            }
        }
    }
    // Before the model load, which is seconds: the contract wants the hello
    // ahead of everything else and reads its absence as a v0 plugin.
    emit::stdout_line(&emit::hello_line())?;

    match args.cameras_json.as_deref() {
        Some(json) => run_multiplexed(&args, json, &backend),
        None => run_single(&args, &backend),
    }
}

/// The control thread, started before anything slow.
///
/// The contract's host writes `stream.started` for every camera as soon as
/// it spawns the process, and never blocks on the write: once the pipe is
/// full an announcement is dropped rather than queued, and a camera that
/// missed one is silent or emitting under an epoch the host has retired.
/// So stdin is drained from the first moment, all the way through the model
/// load.
fn start_control<'a>(camera_ids: impl IntoIterator<Item = &'a str>) -> Result<Arc<Streams>> {
    let streams = Arc::new(Streams::new(camera_ids));
    control::spawn_reader(Arc::clone(&streams))?;
    Ok(streams)
}

/// One process, a whole plugin group: see [`multiplex`] for the error policy.
fn run_multiplexed(args: &Args, cameras_json: &str, backend: &Selected<'_>) -> Result<()> {
    let specs = multiplex::parse_specs(cameras_json)?;
    // Every argument check before the control thread and the model load: a
    // malformed argument is a start-up failure the operator should see
    // immediately, not seconds of ONNX later. The floors are resolved here
    // rather than inside `multiplex::run` for the same reason — pairing a
    // track floor with a member's `min_score` map is the check that can fail,
    // and it has to fail before the model does anything.
    let motion = motion_overrides(args)?;
    let floors = multiplex::floors_for(&specs, &track_floor_overrides(args)?)?;
    let streams = start_control(specs.iter().map(|spec| spec.id.as_str()))?;
    // No `camera_id`: this is the process talking, and the group host applies
    // an untargeted status to every member.
    emit::stdout_line(&emit::status_line(
        None,
        "starting",
        Some("loading model"),
        None,
    ))?;

    let labels = Labels::load(args.labels.as_deref())?;
    // Before any decoder: every scaler and GPU filter graph is built for the
    // size the model resolves to.
    let detector = open_detector(args, &labels, backend)?;
    let embedder = open_embedder(args, &labels, backend, detector.input_spec())?;
    note!(
        "cairn-detect up: cameras=[{}] {} {}",
        specs
            .iter()
            .map(|spec| format!("{}@{}", spec.id, spec.udp_port))
            .collect::<Vec<_>>()
            .join(", "),
        model_summary(args, &detector),
        embedder_summary(&embedder)
    );
    // The decoders open per member, and re-open forever after a drop, so the
    // process is as ready as it gets once the model is loaded.
    emit::stdout_line(&emit::status_line(None, "ready", None, None))?;

    multiplex::run(
        &specs,
        multiplex::DecodeSettings {
            kind: args.decoder,
            sample_fps: args.sample_fps,
        },
        &motion,
        floors,
        detector,
        embedder,
        &labels,
        Publisher::new(streams),
    )
}

/// The detector `args` describe, on the backend `--backend` resolved to.
fn open_detector(args: &Args, labels: &Labels, backend: &Selected<'_>) -> Result<Detector> {
    let options = SessionOptions {
        qnn: qnn_options(args),
        io_quant: IoQuant::load_for(&args.model)?,
    };
    match *backend {
        Selected::Provided(provider) => {
            let backend = (provider.open)(&args.model, &options)?;
            // The startup line renders the backend's own descriptor, so without
            // this it could describe a runtime `--backend` did not ask for.
            let opened = backend.descriptor();
            if !std::ptr::eq(opened, provider.descriptor) {
                bail!(
                    "the provider registered for --backend {} opened backend {} \
                     under a descriptor it did not register",
                    provider.descriptor.name,
                    opened.name,
                );
            }
            Detector::with_backend(
                backend,
                &args.model,
                args.input_size,
                args.model_profile,
                labels,
                args.allow_label_mismatch,
                options.io_quant.as_ref(),
            )
        }
        Selected::Core(kind) => Detector::open(
            &args.model,
            kind,
            args.input_size,
            args.model_profile,
            labels,
            args.allow_label_mismatch,
            options.qnn,
            options.io_quant,
        ),
    }
}

/// The `--qnn-*` flags as one group, read only by a `qnn` session.
fn qnn_options(args: &Args) -> QnnOptions {
    QnnOptions {
        library: args.qnn_library.clone(),
        soc_model: args.qnn_soc_model,
        htp_arch: args.qnn_htp_arch,
        performance_mode: args.qnn_performance_mode.clone(),
        vtcm_mb: args.qnn_vtcm_mb,
    }
}

/// The process-wide `--motion-json` knobs, defaulting to "every knob at its
/// default", which is a gate that is off.
fn motion_overrides(args: &Args) -> Result<MotionOverrides> {
    MotionOverrides::parse(args.motion_json.as_deref().unwrap_or("{}"))
}

/// The process-wide `--track-floor-json` knob, defaulting to absent — which is
/// the feature off and emission unchanged.
fn track_floor_overrides(args: &Args) -> Result<TrackFloorOverrides> {
    TrackFloorOverrides::parse(args.track_floor_json.as_deref().unwrap_or("{}"))
}

/// One process, one camera. Any stream failure is fatal by design: the
/// contract's host restarts a plugin that exits, and there is nothing else
/// running here to keep alive.
fn run_single(args: &Args, backend: &Selected<'_>) -> Result<()> {
    let camera_id = args
        .camera_id
        .clone()
        .expect("clap requires --camera-id unless --cameras-json is given");
    let udp_port = args
        .udp_port
        .expect("clap requires --udp-port unless --cameras-json is given");
    let streams = start_control([camera_id.as_str()])?;
    emit::stdout_line(&emit::status_line(
        Some(&camera_id),
        "starting",
        Some("loading model"),
        None,
    ))?;

    // One camera, so there is nothing to override the process-wide knobs with,
    // here or below.
    let floors = ScoreFloors::parse(args.min_score_json.as_deref().unwrap_or("{}"))?
        .with_track_floor(TrackFloorOverrides::resolve(
            &track_floor_overrides(args)?,
            &TrackFloorOverrides::default(),
        ))?;
    let motion = motion::resolve(&motion_overrides(args)?, &MotionOverrides::default());
    let labels = Labels::load(args.labels.as_deref())?;
    // Before the stream opens: `decode::open` below needs the resolved size.
    let detector = open_detector(args, &labels, backend)?;
    let input_spec = detector.input_spec();
    let embedder = open_embedder(args, &labels, backend, input_spec)?;
    note!(
        "cairn-detect up: camera={camera_id} udp={udp_port} {} {}",
        model_summary(args, &detector),
        embedder_summary(&embedder)
    );

    // Inference runs off the decode thread. Held inline, a ~100ms model pass
    // stalls the socket read, and at this bitrate the kernel receive buffer
    // overflows inside that window — which corrupts the stream rather than
    // merely dropping a sample. The decode loop must never block.
    let (tx, rx) = bounded::<Sample>(1);
    let mut publisher = Publisher::new(streams);
    let worker = {
        let camera_id = camera_id.clone();
        thread::Builder::new()
            .name("infer".into())
            .spawn(move || {
                infer_loop(
                    &rx,
                    detector,
                    embedder,
                    &labels,
                    &floors,
                    &camera_id,
                    motion,
                    &mut publisher,
                )
            })
            .context("spawning the inference thread")?
    };

    let mut input = rtp::open_stream(udp_port)?;
    let (stream_index, _) = input
        .find_best_stream(ffi::AVMEDIA_TYPE_VIDEO)
        .context("looking for a video stream")?
        .ok_or_else(|| anyhow!("no video stream on udp port {udp_port}"))?;
    let (time_base, mut decoder) = {
        let stream = &input.streams()[stream_index];
        (
            stream.time_base,
            decode::open(
                args.decoder,
                &stream.codecpar(),
                input_spec,
                motion,
                decode::NamedFallback::Allowed,
            )?,
        )
    };

    emit::stdout_line(&emit::status_line(Some(&camera_id), "ready", None, None))?;

    let decoded = decode::run(
        &mut input,
        stream_index,
        time_base,
        decoder.as_mut(),
        &tx,
        args.sample_fps,
    );
    drop(tx);

    // A dead inference thread shows up in the decode loop as a closed
    // channel; its own error is the one worth reporting.
    match worker.join() {
        Ok(inferred) => inferred?,
        Err(_) => return Err(anyhow!("inference thread panicked")),
    }
    decoded
}

/// The one line that says what this process will actually run, so a wrong
/// model, a wrong profile or a backend that is not the one a profile asked for
/// is visible before any frame arrives rather than inferred later from bad
/// boxes.
///
/// The backend and its capabilities come from the opened [`Detector`], not from
/// `args`: what ran is what this line should report. The capability half is
/// the opened backend's static descriptor — this crate's in `infer::backend`,
/// a board library's in its own crate. The Elixir boards' `backends/0`
/// tables mirror their fused-NMS and dynamic-shapes columns (their `artifact`
/// is the `model:` key, not the descriptor's extension), and
/// `Cairn.Config.Profile.check_capabilities/5` enforces the fused-NMS one.
fn model_summary(args: &Args, detector: &Detector) -> String {
    let spec = detector.input_spec();
    format!(
        "model={} backend={} profile={} input={} input size={} ({}) encoding={} \
         resize={} layout={} score={} decoder={} sample_fps={}",
        args.model.display(),
        detector.backend_summary(),
        detector.profile(),
        detector.input_name(),
        spec.size,
        detector.input_size_source(),
        spec.encoding,
        spec.resize,
        detector.layout_summary(),
        // Not deferred the way the layout's `nc` can be: `resolve::fit_output`
        // rewrites only `layout` and keeps the rest of the profile's
        // `OutputSpec`, so the composition is settled before any frame arrives.
        detector.profile().output.score,
        args.decoder,
        args.sample_fps
    )
}

/// Sample in, protocol line out, for this process's one camera.
///
/// `motion` is that camera's resolved gate config, or `None` with the gate off
/// — in which case [`Gate::decide`] infers on every sample and the loop is what
/// it was before the gate existed, down to the lines it writes. When it is on,
/// a skipped sample still emits: the seeded line is the host's evidence that
/// this camera is alive and that what it last saw is still there. A sample may
/// also owe a `plugin.status` reporting the gate's effect
/// ([`gate::Lines::status`]), which is the only line here that is not one
/// frame's own.
#[allow(clippy::too_many_arguments)]
fn infer_loop(
    rx: &Receiver<Sample>,
    mut detector: Detector,
    mut embedder: Option<Embedder>,
    labels: &Labels,
    floors: &ScoreFloors,
    camera_id: &str,
    motion: Option<MotionConfig>,
    publisher: &mut Publisher,
) -> Result<()> {
    let mut gate = Gate::default();
    let spec = detector.input_spec();
    while let Ok(sample) = rx.recv() {
        let lines = gate::sample_line(
            &mut gate,
            publisher,
            camera_id,
            motion,
            sample,
            Instant::now(),
            |input| {
                // Path A: the one copy the feature pays for, taken only when
                // an embedder is configured — `detect` consumes the tensor.
                // The f32 demand is startup-guaranteed (embedder + u8 input
                // is refused at open); the bail is for the invariant, not a
                // reachable path.
                let crop_source = match (embedder.as_ref(), input.tensor.as_f32()) {
                    (Some(_), Some(tensor)) => Some(tensor.to_vec()),
                    (Some(_), None) => bail!("embedder cannot crop from a u8-packed tensor"),
                    (None, _) => None,
                };
                let projection = input.projection;
                let mut dets = detector.detect(input.tensor, input.projection, labels, floors)?;
                if let (Some(embedder), Some(tensor)) = (embedder.as_mut(), crop_source) {
                    infer::embed_persons(embedder, &tensor, &spec, &projection, &mut dets)?;
                }
                Ok(dets)
            },
        )?;
        // The frame first: a status is this camera's commentary on the samples
        // up to and including that line.
        for line in [lines.objects, lines.status].into_iter().flatten() {
            emit::stdout_line(&line).context("writing to stdout")?;
        }
    }
    Ok(())
}

/// Opens the embedder when `--embedder-model` is given. A labels file with
/// no `person` entry means every crop filter below will match nothing; that
/// is a configuration worth flagging once, at startup, not a reason to
/// refuse a run.
///
/// `spec` is the opened detector's. The crop source is the tensor packed for
/// it and the crop reads that as float NCHW planes, so any other layout or a
/// uint8 input is refused here for every backend, before the embedder's
/// session load — [`serve`] makes the sidecar-answerable uint8 case earlier.
fn open_embedder(
    args: &Args,
    labels: &Labels,
    backend: &Selected<'_>,
    spec: InputSpec,
) -> Result<Option<Embedder>> {
    let Some(model) = args.embedder_model.as_deref() else {
        return Ok(None);
    };
    if spec.layout != TensorLayout::Nchw {
        bail!(
            "--embedder-model cannot run with a detector whose input is {:?} \
             (the reid crop source is the detector's packed tensor, read as NCHW \
             planes) — drop the embedder",
            spec.layout
        );
    }
    if spec.input_quant.is_some() {
        bail!(
            "--embedder-model cannot run with a detector fed uint8 \
             (the reid crop source is the detector's packed tensor, read as floats) \
             — drop the embedder"
        );
    }
    let kind = infer::embedder_backend(backend).context("--embedder-model")?;
    let embedder = Embedder::open(model, kind)?;
    if !labels.contains("person") {
        note!(
            "cairn-detect: --embedder-model is set but the label set has no \
             `person` entry; no detection will carry an embedding"
        );
    }
    Ok(Some(embedder))
}

/// The embedder's half of the `up:` line — `embedder=off` when none is
/// configured, so the line always says which it was.
fn embedder_summary(embedder: &Option<Embedder>) -> String {
    match embedder {
        Some(embedder) => format!("embedder={}", embedder.summary()),
        None => "embedder=off".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use infer::BackendKind;

    const MODEL: &[&str] = &["cairn-detect", "--model", "m.onnx"];

    fn parse(extra: &[&str]) -> Result<Args, clap::Error> {
        Args::try_parse_from(MODEL.iter().chain(extra).copied())
    }

    #[test]
    fn the_embedder_flag_is_optional_and_parses() {
        let args = parse(&["--camera-id", "front", "--udp-port", "17000"]).unwrap();
        assert!(args.embedder_model.is_none());

        let args = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--embedder-model",
            "osnet.onnx",
        ])
        .unwrap();
        assert_eq!(
            args.embedder_model.as_deref(),
            Some(std::path::Path::new("osnet.onnx"))
        );
    }

    #[test]
    fn per_camera_form_parses() {
        let args = parse(&["--camera-id", "front", "--udp-port", "17000"]).unwrap();
        assert_eq!(args.camera_id.as_deref(), Some("front"));
        assert_eq!(args.udp_port, Some(17_000));
        assert!(args.cameras_json.is_none());
        // the floors default is applied where they are parsed, not by clap
        assert!(args.min_score_json.is_none());
    }

    #[test]
    fn multiplexed_form_parses_on_its_own() {
        let args = parse(&["--cameras-json", r#"[{"id":"a","udp_port":17000}]"#]).unwrap();
        assert!(args.camera_id.is_none());
        assert!(args.udp_port.is_none());
        assert_eq!(
            args.cameras_json.as_deref(),
            Some(r#"[{"id":"a","udp_port":17000}]"#)
        );
    }

    #[test]
    fn the_two_forms_are_mutually_exclusive() {
        let both = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--cameras-json",
            "[]",
        ]);
        assert!(both.is_err());
        assert!(parse(&["--cameras-json", "[]", "--camera-id", "front"]).is_err());
        assert!(parse(&["--cameras-json", "[]", "--udp-port", "17000"]).is_err());
        assert!(parse(&["--cameras-json", "[]", "--min-score-json", "{}"]).is_err());
    }

    #[test]
    fn the_motion_gate_is_configurable_in_both_forms() {
        // The one flag that belongs to the operator rather than to Cairn's
        // contract, so unlike --min-score-json it has to survive next to
        // --cameras-json.
        let knobs = r#"{"enabled":true,"threshold":30}"#;
        let group = parse(&["--cameras-json", "[]", "--motion-json", knobs]).unwrap();
        assert_eq!(group.motion_json.as_deref(), Some(knobs));
        let single = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--motion-json",
            knobs,
        ])
        .unwrap();
        assert_eq!(single.motion_json.as_deref(), Some(knobs));
    }

    #[test]
    fn the_gate_defaults_to_off_and_a_bad_knob_never_reaches_a_decode_thread() {
        let base = &["--camera-id", "front", "--udp-port", "17000"];
        let bare = parse(base).unwrap();
        assert!(bare.motion_json.is_none());
        let overrides = motion_overrides(&bare).unwrap();
        assert!(motion::resolve(&overrides, &MotionOverrides::default()).is_none());

        let with = |knobs: &str| {
            let mut argv = base.to_vec();
            argv.extend_from_slice(&["--motion-json", knobs]);
            motion_overrides(&parse(&argv).unwrap())
        };
        assert!(with(r#"{"enabled":true}"#).is_ok());
        assert!(with(r#"{"alpha":0}"#).is_err());
        assert!(with(r#"{"nonsense":1}"#).is_err());
    }

    #[test]
    fn the_track_floor_is_configurable_in_both_forms() {
        // The host's per-camera arguments conflict with --cameras-json; this
        // one is the operator's, a flag of the command, so like
        // --motion-json it has to survive next to either form.
        let knobs = r#"{"floor":0.15}"#;
        let group = parse(&["--cameras-json", "[]", "--track-floor-json", knobs]).unwrap();
        assert_eq!(group.track_floor_json.as_deref(), Some(knobs));
        let single = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--track-floor-json",
            knobs,
        ])
        .unwrap();
        assert_eq!(single.track_floor_json.as_deref(), Some(knobs));
    }

    #[test]
    fn the_track_floor_defaults_to_absent_and_a_bad_one_never_reaches_a_camera() {
        let base = &["--camera-id", "front", "--udp-port", "17000"];
        let bare = parse(base).unwrap();
        assert!(bare.track_floor_json.is_none());
        assert!(track_floor_overrides(&bare).unwrap().floor.is_none());

        let with = |knobs: &str| {
            let mut argv = base.to_vec();
            argv.extend_from_slice(&["--track-floor-json", knobs]);
            track_floor_overrides(&parse(&argv).unwrap())
        };
        assert_eq!(with(r#"{"floor":0.1}"#).unwrap().floor, Some(0.1));
        // the two the plan names: a floor of 0 is noise with no matcher, and
        // a mistyped knob is a setting that silently did nothing
        assert!(with(r#"{"floor":0}"#).is_err());
        assert!(with(r#"{"nonsense":1}"#).is_err());
    }

    #[test]
    fn input_size_is_optional_and_accepts_both_forms() {
        let base = &["--camera-id", "front", "--udp-port", "17000"];
        let with = |spec: &str| {
            let mut argv = base.to_vec();
            argv.extend_from_slice(&["--input-size", spec]);
            parse(&argv)
        };
        // absent means "take it from the model"
        assert!(parse(base).unwrap().input_size.is_none());
        assert_eq!(
            with("320").unwrap().input_size,
            Some(InputSize::square(320))
        );
        assert_eq!(
            with("640x352").unwrap().input_size,
            Some(InputSize { w: 640, h: 352 })
        );
        assert!(with("0").is_err());
        assert!(with("huge").is_err());
    }

    #[test]
    fn one_of_the_two_forms_is_required() {
        assert!(parse(&[]).is_err());
        // half of the per-camera form is not enough
        assert!(parse(&["--camera-id", "front"]).is_err());
        assert!(parse(&["--udp-port", "17000"]).is_err());
    }

    #[test]
    fn sample_fps_defaults_to_the_decoder_constant_and_accepts_both_forms() {
        let base = &["--camera-id", "front", "--udp-port", "17000"];
        // absent means the clap default, which is `decode::DEFAULT_SAMPLE_FPS`
        // by construction — not a coincidence a comment could drift out of.
        assert_eq!(parse(base).unwrap().sample_fps, decode::DEFAULT_SAMPLE_FPS);

        let with = |value: &str| {
            let mut argv = base.to_vec();
            argv.extend_from_slice(&["--sample-fps", value]);
            parse(&argv)
        };
        assert_eq!(with("10").unwrap().sample_fps, 10);

        let group = parse(&["--cameras-json", "[]", "--sample-fps", "12"]).unwrap();
        assert_eq!(group.sample_fps, 12);
    }

    #[test]
    fn sample_fps_rejects_zero_and_anything_over_thirty() {
        let base = &["--camera-id", "front", "--udp-port", "17000"];
        let with = |value: &str| {
            let mut argv = base.to_vec();
            argv.extend_from_slice(&["--sample-fps", value]);
            parse(&argv)
        };
        assert!(with("0").is_err(), "0 has no interval to sample at");
        assert!(with("31").is_err(), "just over the ceiling");
        // the edges of the accepted range are legal
        assert!(with("1").is_ok());
        assert!(with("30").is_ok());
        assert_eq!(with("30").unwrap().sample_fps, 30);
    }

    /// A provider replaces the core's backend of the same name, and is
    /// trusted for nothing but an open: one whose backend reports any
    /// descriptor but the one it registered is refused before the model is
    /// resolved.
    #[test]
    fn a_provider_is_consulted_first_and_must_open_its_own_backend() {
        use infer::{Backend, Capabilities, Descriptor, InputTensor, ModelIo, Tensors};
        use std::path::Path;

        static BOARD: Descriptor = Descriptor {
            name: "board",
            capabilities: Capabilities {
                supports_fused_nms: false,
                supports_dynamic_shapes: false,
                artifact: ".board",
            },
        };
        struct Fake(&'static Descriptor, ModelIo);
        impl Backend for Fake {
            fn open(_: &Path, _: &SessionOptions) -> Result<Self> {
                unreachable!("built by the provider")
            }
            fn descriptor(&self) -> &'static Descriptor {
                self.0
            }
            fn io(&self) -> &ModelIo {
                &self.1
            }
            fn run(&mut self, _: InputTensor) -> Result<Box<dyn Tensors + '_>> {
                unreachable!("refused before any run")
            }
        }
        fn io(declared_input_size: Option<InputSize>) -> ModelIo {
            ModelIo {
                input_name: "images".to_string(),
                declared_input_size,
                declared_input_batch: None,
                outputs: Vec::new(),
                input_element: infer::InputElement::F32,
                u8_outputs: Vec::new(),
                input_layout: TensorLayout::Nhwc,
            }
        }
        fn fake(declared_input_size: Option<InputSize>) -> Box<dyn Backend> {
            Box::new(Fake(BackendKind::Ort.descriptor(), io(declared_input_size)))
        }
        fn mislabelled(_: &Path, _: &SessionOptions) -> Result<Box<dyn Backend>> {
            Ok(fake(None))
        }
        fn ort_provider(_: &Path, _: &SessionOptions) -> Result<Box<dyn Backend>> {
            Ok(fake(Some(InputSize::square(64))))
        }
        let labels = Labels::load(None).unwrap();
        // Not `unwrap_err`: `Detector` has no `Debug`, deliberately.
        let fail = |args: &Args, providers: &[Provider]| {
            let opened = infer::select(&args.backend, providers)
                .context("--backend")
                .and_then(|backend| open_detector(args, &labels, &backend));
            match opened {
                Ok(_) => panic!("the open succeeded"),
                Err(err) => format!("{err:#}"),
            }
        };

        let args = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--backend",
            "board",
        ])
        .unwrap();
        let msg = fail(&args, &[Provider::new(&BOARD, mislabelled)]);
        assert!(msg.contains("--backend board opened backend ort"), "{msg}");

        // Identity, not the name: a copy under the registered name is refused.
        static BOARD_COPY: Descriptor = Descriptor {
            name: "board",
            capabilities: Capabilities {
                supports_fused_nms: true,
                ..BOARD.capabilities
            },
        };
        fn copied(_: &Path, _: &SessionOptions) -> Result<Box<dyn Backend>> {
            Ok(Box::new(Fake(&BOARD_COPY, io(None))))
        }
        let msg = fail(&args, &[Provider::new(&BOARD, copied)]);
        assert!(
            msg.contains("--backend board opened backend board under a descriptor"),
            "{msg}"
        );

        // The core's ort backend would have failed on the missing file.
        let args = parse(&["--camera-id", "front", "--udp-port", "17000"]).unwrap();
        let msg = fail(
            &args,
            &[Provider::new(BackendKind::Ort.descriptor(), ort_provider)],
        );
        assert!(msg.contains("has no outputs"), "{msg}");

        // Without its provider the name is no backend at all, refused before
        // any model access.
        let args = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--backend",
            "board",
        ])
        .unwrap();
        let msg = fail(&args, &[]);
        assert!(
            msg.contains("--backend: backend \"board\" is not one this build carries (ort, qnn)"),
            "{msg}"
        );
    }

    /// The embedder opens on this crate's `ort` only: a provider registered
    /// under that name is refused like any other, by the name it resolved to.
    #[test]
    fn the_embedder_backend_is_core_ort_or_refused() {
        let provider = Provider::new(BackendKind::Ort.descriptor(), |_, _| {
            unreachable!("refused before any open")
        });
        let providers = [provider];
        let embedder_on = |name: &str, providers: &[Provider]| {
            infer::embedder_backend(&infer::select(name, providers).unwrap())
                .map_err(|err| err.to_string())
        };
        assert_eq!(embedder_on("ort", &[]), Ok(BackendKind::Ort));
        let msg = embedder_on("ort", &providers).unwrap_err();
        assert!(
            msg.contains("does not run on a board library's backend (ort)"),
            "{msg}"
        );
        let msg = embedder_on("qnn", &[]).unwrap_err();
        assert!(msg.contains("does not run on qnn yet"), "{msg}");
    }

    /// Refused on the spec alone, before the embedder's model is touched —
    /// proven by a path that does not exist.
    #[test]
    fn an_embedder_is_refused_over_a_non_nchw_or_uint8_fed_detector() {
        use infer::{ResizePolicy, TensorEncoding};

        let args = parse(&[
            "--camera-id",
            "front",
            "--udp-port",
            "17000",
            "--embedder-model",
            "does/not/exist.onnx",
        ])
        .unwrap();
        let spec = InputSpec {
            size: InputSize::square(64),
            encoding: TensorEncoding::UnitRgb,
            resize: ResizePolicy::Stretch,
            input_quant: None,
            layout: TensorLayout::Nhwc,
        };
        let labels = Labels::load(None).unwrap();
        let refusal =
            |spec| match open_embedder(&args, &labels, &Selected::Core(BackendKind::Ort), spec) {
                Ok(_) => panic!("an embedder opened over {spec:?}"),
                Err(err) => format!("{err:#}"),
            };
        assert!(refusal(spec)
            .contains("--embedder-model cannot run with a detector whose input is Nhwc"),);
        let uint8 = InputSpec {
            input_quant: TensorEncoding::UnitRgb.pixel_quant(),
            layout: TensorLayout::Nchw,
            ..spec
        };
        assert!(refusal(uint8).contains("detector fed uint8"));
    }
}
