//! Cairn detection plugin: H.264 RTP in, contract ndjson out.
//!
//! See `docs/plugin-contract.md`. Cairn appends `--camera-id`, `--udp-port`
//! and `--min-score-json` to whatever command it is configured with; the
//! model flags come from that configured command.

mod decode;
mod emit;
mod glibc_compat;
mod hwdecode;
mod infer;
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
    #[arg(long)]
    camera_id: String,

    /// UDP port on 127.0.0.1 carrying H.264 RTP (port + 1 is reserved for RTCP).
    #[arg(long)]
    udp_port: u16,

    /// JSON object of label -> minimum score, with an optional "default" key.
    #[arg(long, default_value = "{}")]
    min_score_json: String,

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
    let floors = ScoreFloors::parse(&args.min_score_json)?;
    let labels = Labels::load(args.labels.as_deref())?;
    let detector = Detector::open(&args.model)?;
    eprintln!(
        "cairn-detect up: camera={} udp={} model={} input={} decoder={}",
        args.camera_id,
        args.udp_port,
        args.model.display(),
        detector.input_name(),
        args.decoder
    );

    // Inference runs off the decode thread. Held inline, a ~100ms model pass
    // stalls the socket read, and at this bitrate the kernel receive buffer
    // overflows inside that window — which corrupts the stream rather than
    // merely dropping a sample. The decode loop must never block.
    let (tx, rx) = bounded::<Sample>(1);
    let camera_id = args.camera_id.clone();
    let worker = thread::Builder::new()
        .name("infer".into())
        .spawn(move || infer_loop(&rx, detector, &labels, &floors, &camera_id))
        .context("spawning the inference thread")?;

    let mut input = rtp::open_stream(args.udp_port)?;
    let (stream_index, _) = input
        .find_best_stream(ffi::AVMEDIA_TYPE_VIDEO)
        .context("looking for a video stream")?
        .ok_or_else(|| anyhow!("no video stream on udp port {}", args.udp_port))?;
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
