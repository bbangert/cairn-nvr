//! Cairn detection plugin: H.264 RTP in, protocol v1 ndjson out.
//!
//! See `docs/plugin-contract.md`. Cairn appends the arguments of one of the
//! two contract variants to whatever command it is configured with; the model
//! flags and the motion gate's `--motion-json` come from that configured
//! command, which is why the gate needs no host change to reach either mode.
//!
//!   * per-camera: `--camera-id`, `--udp-port`, `--min-score-json` — one
//!     process per camera, and any stream failure is fatal so Cairn restarts
//!     it (`run_single` below).
//!   * multiplexed: `--cameras-json` — one process for a whole plugin group,
//!     where a member's silence is normal and never exits ([`multiplex`]).
//!
//! Both directions of the protocol are live in both modes: detections go out
//! on stdout, and Cairn's per-camera stream epochs come in on stdin
//! ([`control`]). stdout carries protocol lines and nothing else — every
//! diagnostic, here and in the stages, goes to stderr where Cairn logs it.

// The library's deny, repeated because this is a separate crate — see `lib.rs` for
// why. Clippy exempts the call inside `fn main`, which is where this crate's one
// legitimate exit lives; the exemption goes by enclosing body, so `main` here
// spawns nothing.
#![deny(clippy::exit)]

use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use crossbeam_channel::{bounded, Receiver};
use rsmpeg::ffi;

use cairn_detect::note;
use cairn_detect::{control, decode, emit, gate, infer, motion, multiplex, rtp};
use control::Streams;
use decode::{DecoderKind, Sample};
use emit::Publisher;
use gate::Gate;
use infer::{
    BackendKind, Detector, Embedder, InputSize, Labels, ModelProfile, QnnOptions, ScoreFloors,
    TrackFloorOverrides,
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
        required_unless_present = "cameras_json",
        conflicts_with = "cameras_json"
    )]
    camera_id: Option<String>,

    /// UDP port on 127.0.0.1 carrying H.264 RTP (port + 1 is reserved for RTCP).
    #[arg(
        long,
        required_unless_present = "cameras_json",
        conflicts_with = "cameras_json"
    )]
    udp_port: Option<u16>,

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
    /// `--cameras-json`: the gate is the operator's own setting, written into
    /// the configured command rather than appended by Cairn, so it has to be
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
    /// not conflict with `--cameras-json`: it is written into the configured
    /// command rather than appended by Cairn, so it has to be expressible in
    /// both modes. In group mode it is the default for every member, and a
    /// member's own `track_floor` key replaces it.
    #[arg(long)]
    track_floor_json: Option<String>,

    /// Detection model: a yolox, rfdetr, yolov10 or yolov8/yolov9/yolo11/yolo26
    /// head, as the artifact `--backend` compiles against (`.onnx` for `ort`).
    #[arg(long)]
    model: PathBuf,

    /// Inference runtime. `ort` (CPU) and `qnn` (Qualcomm HTP, needs
    /// `--qnn-library` and a QDQ model) execute; `rknn` is accepted here and
    /// refused when the model opens, so a profile naming hardware whose
    /// runtime has not landed fails with a message about the backend rather
    /// than a usage error about the flag.
    #[arg(long, value_enum, default_value_t = BackendKind::Ort)]
    backend: BackendKind,

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
    /// is refused with `qnn` until a QDQ embedder artifact exists.
    #[arg(long)]
    embedder_model: Option<PathBuf>,

    /// Preprocessing and decode steps to run this model under: `yolox`,
    /// `rfdetr` (hyphenated spellings accepted), `yolov10` or `yolov8` (or
    /// `yolov9`, `yolo11`, `yolov11`, `yolo26` — its runnable exports are
    /// raw-head). Sniffed from the model's own input and output when
    /// omitted; required when a shape fits more than one profile, and for
    /// rfdetr, whose exports leave their input geometry dynamic.
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

fn main() {
    let failed = run().inspect_err(|e| {
        // Exit loudly: Cairn restarts us with jittered backoff.
        note!("fatal: {e:#}");
    });
    // On both paths, because `note!` only queues: a clean run has lines of its own
    // still in flight.
    cairn_detect::log::drain();
    if failed.is_err() {
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args = Args::parse();
    // The embedder's own open refuses qnn too, but it runs after the
    // detector's — which on qnn is a multi-second HTP graph compile. An
    // argv combination that is going down either way should say so before
    // that, not after.
    if args.embedder_model.is_some() && args.backend == BackendKind::Qnn {
        anyhow::bail!(
            "the embedder does not run on qnn yet (no QDQ embedder artifact) \
             — drop --embedder-model or use --backend ort"
        );
    }
    // Before the model load, which is seconds: the host logs the hello and
    // checks that protocol 1 is in `supported_versions`.
    emit::stdout_line(&emit::hello_line())?;

    match args.cameras_json.as_deref() {
        Some(json) => run_multiplexed(&args, json),
        None => run_single(&args),
    }
}

/// The control thread, started before anything slow.
///
/// Cairn writes `stream.started` for every camera as soon as it spawns us,
/// with `:nosuspend` — an unread pipe loses those announcements rather than
/// queueing them, and a lost epoch means every line that camera produces is
/// dropped host-side until the next restart. So stdin is drained from the
/// first moment, all the way through the model load.
fn start_control<'a>(camera_ids: impl IntoIterator<Item = &'a str>) -> Result<Arc<Streams>> {
    let streams = Arc::new(Streams::new(camera_ids));
    control::spawn_reader(Arc::clone(&streams))?;
    Ok(streams)
}

/// One process, a whole plugin group: see [`multiplex`] for the error policy.
fn run_multiplexed(args: &Args, cameras_json: &str) -> Result<()> {
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
    let detector = Detector::open(
        &args.model,
        args.backend,
        args.input_size,
        args.model_profile,
        &labels,
        args.allow_label_mismatch,
        qnn_options(args),
    )?;
    let embedder = open_embedder(args, &labels)?;
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

/// The `--qnn-*` flags as one group. Read by `Detector::open` only when
/// `--backend qnn` — always built, because collecting five `Option`s costs
/// nothing and keeps both call sites identical.
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

/// One process, one camera. Any stream failure is fatal by design: Cairn
/// restarts this process with jittered backoff, and there is nothing else
/// running here to keep alive.
fn run_single(args: &Args) -> Result<()> {
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
    let detector = Detector::open(
        &args.model,
        args.backend,
        args.input_size,
        args.model_profile,
        &labels,
        args.allow_label_mismatch,
        qnn_options(args),
    )?;
    let input_spec = detector.input_spec();
    let embedder = open_embedder(args, &labels)?;
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
            decode::open(args.decoder, &stream.codecpar(), input_spec, motion)?,
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
/// `args`: what ran is what this line should report. The capability half reads
/// from the static table in `infer::backend` — the one the Elixir side's
/// planned capability validation will mirror (today it mirrors only the
/// artifact column).
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
                let crop_source = embedder.as_ref().map(|_| input.tensor.clone());
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
fn open_embedder(args: &Args, labels: &Labels) -> Result<Option<Embedder>> {
    let Some(model) = args.embedder_model.as_deref() else {
        return Ok(None);
    };
    let embedder = Embedder::open(model, args.backend)?;
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
        // Cairn's own flags conflict with --cameras-json; this one is the
        // operator's, written into the configured command, so like
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
}
