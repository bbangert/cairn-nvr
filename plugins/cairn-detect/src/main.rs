//! Cairn detection plugin: H.264 RTP in, protocol v1 ndjson out.
//!
//! See `docs/plugin-contract.md`. Cairn appends the arguments of one of the
//! two contract variants to whatever command it is configured with; the model
//! flags come from that configured command.
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
//! diagnostic in this crate goes to stderr, where Cairn logs it.

mod control;
mod decode;
mod emit;
mod glibc_compat;
mod hwdecode;
mod infer;
mod multiplex;
mod rtp;

use std::path::PathBuf;
use std::sync::Arc;
use std::thread;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use crossbeam_channel::{bounded, Receiver};
use rsmpeg::ffi;

use control::Streams;
use decode::{DecoderKind, Sample};
use emit::Publisher;
use infer::{Detector, InputSize, Labels, ModelProfile, ScoreFloors};

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

    /// JSON array of `{id, udp_port, min_score}` — serve a whole plugin group
    /// from this one process instead of a single camera.
    #[arg(long)]
    cameras_json: Option<String>,

    /// ONNX detection model: a yolox, rfdetr, yolov10/yolo26 or
    /// yolov8/yolov9/yolo11 head.
    #[arg(long)]
    model: PathBuf,

    /// Preprocessing and decode steps to run this model under: `yolox`,
    /// `rfdetr`, `yolov10` (or `yolo26`) or `yolov8` (or `yolov9`, `yolo11`,
    /// `yolov11`). Sniffed from the model's own input and output when
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

    /// Decode backend. Probed at startup; any failure falls back to software.
    #[arg(long, value_enum, default_value_t = DecoderKind::Auto)]
    decoder: DecoderKind,
}

fn main() {
    if let Err(e) = run() {
        // Exit loudly: Cairn restarts us with jittered backoff.
        eprintln!("fatal: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args = Args::parse();
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
    let streams = start_control(specs.iter().map(|spec| spec.id.as_str()))?;
    // No `camera_id`: this is the process talking, and the group host applies
    // an untargeted status to every member.
    emit::stdout_line(&emit::status_line(None, "starting", Some("loading model")))?;

    let labels = Labels::load(args.labels.as_deref())?;
    // Before any decoder: every scaler and GPU filter graph is built for the
    // size the model resolves to.
    let detector = Detector::open(
        &args.model,
        args.input_size,
        args.model_profile,
        &labels,
        args.allow_label_mismatch,
    )?;
    eprintln!(
        "cairn-detect up: cameras=[{}] {}",
        specs
            .iter()
            .map(|spec| format!("{}@{}", spec.id, spec.udp_port))
            .collect::<Vec<_>>()
            .join(", "),
        model_summary(args, &detector)
    );
    // The decoders open per member, and re-open forever after a drop, so the
    // process is as ready as it gets once the model is loaded.
    emit::stdout_line(&emit::status_line(None, "ready", None))?;

    multiplex::run(
        &specs,
        args.decoder,
        detector,
        &labels,
        Publisher::new(streams),
    )
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
    ))?;

    let floors = ScoreFloors::parse(args.min_score_json.as_deref().unwrap_or("{}"))?;
    let labels = Labels::load(args.labels.as_deref())?;
    // Before the stream opens: `decode::open` below needs the resolved size.
    let detector = Detector::open(
        &args.model,
        args.input_size,
        args.model_profile,
        &labels,
        args.allow_label_mismatch,
    )?;
    let input_spec = detector.input_spec();
    eprintln!(
        "cairn-detect up: camera={camera_id} udp={udp_port} {}",
        model_summary(args, &detector)
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
            .spawn(move || infer_loop(&rx, detector, &labels, &floors, &camera_id, &mut publisher))
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
            decode::open(args.decoder, &stream.codecpar(), input_spec)?,
        )
    };

    emit::stdout_line(&emit::status_line(Some(&camera_id), "ready", None))?;

    let decoded = decode::run(&mut input, stream_index, time_base, decoder.as_mut(), &tx);
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
/// model or a wrong profile is visible before any frame arrives rather than
/// inferred later from bad boxes.
fn model_summary(args: &Args, detector: &Detector) -> String {
    let spec = detector.input_spec();
    format!(
        "model={} profile={} input={} input size={} ({}) encoding={} resize={} layout={} \
         decoder={}",
        args.model.display(),
        detector.profile(),
        detector.input_name(),
        spec.size,
        detector.input_size_source(),
        spec.encoding,
        spec.resize,
        detector.layout_summary(),
        args.decoder
    )
}

fn infer_loop(
    rx: &Receiver<Sample>,
    mut detector: Detector,
    labels: &Labels,
    floors: &ScoreFloors,
    camera_id: &str,
    publisher: &mut Publisher,
) -> Result<()> {
    while let Ok(sample) = rx.recv() {
        let dets = detector.detect(sample.input.tensor, sample.input.projection, labels, floors)?;
        if let Some(line) = publisher.line_for(camera_id, sample.pts_90k, sample.observed_at, &dets)
        {
            emit::stdout_line(&line).context("writing to stdout")?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODEL: &[&str] = &["cairn-detect", "--model", "m.onnx"];

    fn parse(extra: &[&str]) -> Result<Args, clap::Error> {
        Args::try_parse_from(MODEL.iter().chain(extra).copied())
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
}
