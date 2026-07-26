//! Cairn detection plugin: H.264 RTP in, contract ndjson out.
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

mod decode;
mod emit;
mod glibc_compat;
mod hwdecode;
mod infer;
mod multiplex;
mod rtp;

use std::io::Write;
use std::path::PathBuf;
use std::thread;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use crossbeam_channel::{bounded, Receiver};
use rsmpeg::ffi;

use decode::{DecoderKind, Sample};
use infer::{Detector, Labels, ScoreFloors};

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

    /// NMS-free ONNX detection model ([1, N, 6] output).
    #[arg(long)]
    model: PathBuf,

    /// Newline-separated label names, indexed by class id.
    #[arg(long)]
    labels: Option<PathBuf>,

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

    match args.cameras_json.as_deref() {
        Some(json) => run_multiplexed(&args, json),
        None => run_single(&args),
    }
}

/// One process, a whole plugin group: see [`multiplex`] for the error policy.
fn run_multiplexed(args: &Args, cameras_json: &str) -> Result<()> {
    let specs = multiplex::parse_specs(cameras_json)?;
    let labels = Labels::load(args.labels.as_deref())?;
    let detector = Detector::open(&args.model)?;
    eprintln!(
        "cairn-detect up: cameras=[{}] model={} input={} decoder={}",
        specs
            .iter()
            .map(|spec| format!("{}@{}", spec.id, spec.udp_port))
            .collect::<Vec<_>>()
            .join(", "),
        args.model.display(),
        detector.input_name(),
        args.decoder
    );

    multiplex::run(&specs, args.decoder, detector, &labels)
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
    let floors = ScoreFloors::parse(args.min_score_json.as_deref().unwrap_or("{}"))?;
    let labels = Labels::load(args.labels.as_deref())?;
    let detector = Detector::open(&args.model)?;
    eprintln!(
        "cairn-detect up: camera={} udp={} model={} input={} decoder={}",
        camera_id,
        udp_port,
        args.model.display(),
        detector.input_name(),
        args.decoder
    );

    // Inference runs off the decode thread. Held inline, a ~100ms model pass
    // stalls the socket read, and at this bitrate the kernel receive buffer
    // overflows inside that window — which corrupts the stream rather than
    // merely dropping a sample. The decode loop must never block.
    let (tx, rx) = bounded::<Sample>(1);
    let worker = thread::Builder::new()
        .name("infer".into())
        .spawn(move || infer_loop(&rx, detector, &labels, &floors, &camera_id))
        .context("spawning the inference thread")?;

    let mut input = rtp::open_stream(udp_port)?;
    let (stream_index, _) = input
        .find_best_stream(ffi::AVMEDIA_TYPE_VIDEO)
        .context("looking for a video stream")?
        .ok_or_else(|| anyhow!("no video stream on udp port {udp_port}"))?;
    let (time_base, mut decoder) = {
        let stream = &input.streams()[stream_index];
        (
            stream.time_base,
            decode::open(args.decoder, &stream.codecpar())?,
        )
    };

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

fn infer_loop(
    rx: &Receiver<Sample>,
    mut detector: Detector,
    labels: &Labels,
    floors: &ScoreFloors,
    camera_id: &str,
) -> Result<()> {
    let mut out = std::io::stdout().lock();
    while let Ok(sample) = rx.recv() {
        let dets = detector.detect(sample.tensor, labels, floors)?;
        emit::emit(&mut out, camera_id, sample.pts_90k, &dets).context("writing to stdout")?;
    }
    out.flush().context("flushing stdout")?;
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
    fn one_of_the_two_forms_is_required() {
        assert!(parse(&[]).is_err());
        // half of the per-camera form is not enough
        assert!(parse(&["--camera-id", "front"]).is_err());
        assert!(parse(&["--udp-port", "17000"]).is_err());
    }
}
