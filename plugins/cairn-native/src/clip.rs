//! The one end-to-end path: a real H.264 file, real model load, real decoder,
//! every access unit handed over the way Membrane's H.264 parser will hand
//! them over — through both halves of the split boundary, `decode_au`'s and
//! `push_frame`'s, with the [`Rig`] standing in for the Elixir orchestration
//! between them (the rate gate and the frame handoff). Only the demuxer
//! stands in for the pipeline.
//!
//! It needs artifacts this repository does not carry (`*.onnx` is gitignored), and
//! a missing one fails the run rather than skipping: a test that returns without
//! running is indistinguishable in `cargo test`'s output from one that passed.
//!
//! ```text
//! CAIRN_NATIVE_CLIP=data/events/…/clip.mp4 \
//! CAIRN_NATIVE_MODEL=plugins/cairn-detect/yolox_nano.onnx \
//! CAIRN_NATIVE_LABELS=plugins/cairn-detect/coco.names \
//!   cargo test clip -- --nocapture --test-threads=1
//! ```
//!
//! Those paths have repository defaults. A checkout without the artifacts has to
//! say so out loud, which is the only way past these tests:
//!
//! ```text
//! CAIRN_NATIVE_SKIP_CLIP=1 cargo test
//! ```
//!
//! A real model load and a real decode per access unit is what makes these the
//! slowest tests in the crate. How many of those access units [`feed`] turns into
//! model passes is a property of how fast this box infers — the gate's interval
//! against the loop's own pace — so nothing here asserts a ratio off it. Anything
//! measuring the gate itself uses [`feed_at`] instead, where the arrival instants
//! are the test's own.

use std::collections::HashMap;
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rsmpeg::avformat::AVFormatContextInput;
use rsmpeg::ffi;

use cairn_detect::decode::sample_interval;
use cairn_detect::infer::InputSize;

use crate::config::RawDecoderParams;
use crate::decoder::DecodeStream;
use crate::DecoderRef;
use cairn_ort::{
    Engine, Frame, FrameObservations, RawInitConfig, RawQnnOptions, RawStreamParams, Stream,
    StreamRef,
};

const WAIVER: &str = "CAIRN_NATIVE_SKIP_CLIP";

/// An artifact path from the environment, or the repository default. A *named*
/// path that does not exist fails whatever the waiver says, because the caller
/// said where to look.
fn artifact(variable: &str, default: &str) -> Option<PathBuf> {
    match std::env::var(variable) {
        Ok(named) => {
            let path = PathBuf::from(named);
            assert!(
                path.exists(),
                "{variable} names {}, which does not exist",
                path.display()
            );
            Some(path)
        }
        Err(_) => {
            let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(default);
            path.exists().then_some(path)
        }
    }
}

struct Artifacts {
    model: PathBuf,
    labels: PathBuf,
    clip: PathBuf,
}

/// What this harness runs against, or `None` if the run waived it. Every test
/// opens with `let Some(artifacts) = artifacts() else { return }`, so an early
/// return has to be a *decision*: missing artifacts panic instead.
fn artifacts() -> Option<Artifacts> {
    let found = || {
        Some(Artifacts {
            model: artifact("CAIRN_NATIVE_MODEL", "../cairn-detect/yolox_nano.onnx")?,
            labels: artifact("CAIRN_NATIVE_LABELS", "../cairn-detect/coco.names")?,
            clip: artifact(
                "CAIRN_NATIVE_CLIP",
                "../../test/support/fixtures/media/testsrc.h264",
            )?,
        })
    };
    match found() {
        Some(artifacts) => Some(artifacts),
        None if std::env::var_os(WAIVER).is_some() => {
            println!("skipped: {WAIVER} is set and the clip artifacts are not all present");
            None
        }
        None => panic!(
            "the clip harness has no model, labels or clip — see this module's doc for the \
             three paths, or set {WAIVER}=1 to waive the end-to-end tests for this run"
        ),
    }
}

fn engine(artifacts: &Artifacts) -> Arc<Engine> {
    let config = RawInitConfig {
        model: artifacts.model.display().to_string(),
        backend: "ort".into(),
        model_profile: None,
        input_size: None,
        labels: Some(artifacts.labels.display().to_string()),
        allow_label_mismatch: false,
        embedder_model: None,
        qnn: RawQnnOptions {
            library: None,
            soc_model: None,
            htp_arch: None,
            performance_mode: None,
            vtcm_mb: None,
        },
    };
    Arc::new(Engine::open(config.resolve().expect("the config resolves")).expect("the model opens"))
}

/// The decode half's params, spelled the way the Elixir host spells them:
/// through the same `wire` names `engine_spec` exports — so this harness
/// exercises the exact term path a resolved spec takes between the two NIF
/// libraries. Software decode: a box without the GPU the hardware paths need
/// has to get the same answer as one with it.
fn decoder_params(engine: &Engine, sample_fps: u32) -> RawDecoderParams {
    let spec = engine.input_spec;
    let (resize, resize_pad) = spec.resize.wire();
    RawDecoderParams {
        decoder: "sw".into(),
        width: spec.size.w,
        height: spec.size.h,
        encoding: spec.encoding.wire_name().into(),
        resize: resize.into(),
        resize_pad,
        motion_json: None,
        sample_fps,
    }
}

fn params() -> RawStreamParams {
    RawStreamParams {
        min_score: HashMap::from([("default".to_string(), 0.3)]),
        motion_json: None,
        track_floor_json: None,
        stream_epoch: Some("01K1B2C3D4E5F6G7H8J9K0M1N2".to_string()),
    }
}

/// Whole access units with their own pts, read once so several streams can be fed
/// the same bytes.
struct Clip {
    units: Vec<(Vec<u8>, i64)>,
    time_base: (i32, i32),
}

fn read_clip(path: &Path) -> Clip {
    let url = CString::new(path.display().to_string()).expect("a path with no interior nul");
    let mut input = AVFormatContextInput::open(&url).expect("the clip opens");
    let (index, _) = input
        .find_best_stream(ffi::AVMEDIA_TYPE_VIDEO)
        .expect("looking for a video stream")
        .expect("the clip has a video stream");
    let time_base = {
        let stream = &input.streams()[index];
        (stream.time_base.num, stream.time_base.den)
    };

    let mut units = Vec::new();
    while let Some(mut packet) = input.read_packet().expect("reading the clip") {
        if packet.stream_index as usize != index {
            continue;
        }
        // SAFETY: a packet the demuxer returned owns `size` bytes at `data`,
        // and the slice does not outlive the packet.
        let au = unsafe {
            let raw = packet.as_mut_ptr();
            std::slice::from_raw_parts((*raw).data, (*raw).size as usize).to_vec()
        };
        units.push((au, packet.pts));
    }
    assert!(!units.is_empty(), "the clip has no access unit");
    Clip { units, time_base }
}

/// The two halves answer with two error types now — same reason vocabulary,
/// different crates — and the Rig folds them into one so a test can assert on
/// `reason()` without caring which half refused.
#[derive(Debug)]
struct RigError {
    reason: &'static str,
    message: String,
}

impl RigError {
    fn reason(&self) -> &'static str {
        self.reason
    }
}

impl From<crate::error::NativeError> for RigError {
    fn from(error: crate::error::NativeError) -> Self {
        Self {
            reason: error.reason(),
            message: error.message().to_string(),
        }
    }
}

impl From<cairn_ort::NativeError> for RigError {
    fn from(error: cairn_ort::NativeError) -> Self {
        Self {
            reason: error.reason(),
            message: error.message().to_string(),
        }
    }
}

/// Both halves of the boundary plus the orchestration the Elixir side owns
/// between them: the wall-clock rate gate (`Cairn.Pipeline.SampleGate`'s
/// semantics, restated here because the whole point of the split is that the
/// crate no longer has them) and the frame handoff. Everything goes through
/// the same resource wrappers the NIFs use, so the locks under test are the
/// production locks.
struct Rig {
    decoder: DecoderRef,
    stream: StreamRef,
    time_base: (i32, i32),
    interval: Duration,
    last_sample: Mutex<Option<Instant>>,
}

impl Rig {
    fn open(engine: &Arc<Engine>, camera_id: &str, time_base: (i32, i32), sample_fps: u32) -> Self {
        Self {
            decoder: DecoderRef::new(
                DecodeStream::open(
                    camera_id.to_string(),
                    decoder_params(engine, sample_fps)
                        .resolve()
                        .expect("the params resolve"),
                )
                .expect("the decoder opens"),
            ),
            stream: StreamRef::new(Arc::clone(engine), open(engine, camera_id)),
            time_base,
            interval: sample_interval(sample_fps),
            last_sample: Mutex::new(None),
        }
    }

    /// Forget the gate's last sample, so the next completed frame samples for
    /// certain — for tests that feed one clip several times faster than the
    /// sample interval and need each feed to reach the inference half.
    fn rearm(&self) {
        *self.last_sample.lock().unwrap() = None;
    }

    /// One access unit through decode, the rate gate and — when a frame was
    /// sampled — inference. The gate's semantics are the element's: `sample`
    /// is decided before the decode call, and the interval is spent when a
    /// frame *completed*, whatever became of its conversion.
    fn push_au(
        &self,
        au: &[u8],
        pts: i64,
        now: Instant,
    ) -> std::result::Result<Vec<FrameObservations>, RigError> {
        let sample = {
            let last = self.last_sample.lock().unwrap();
            last.is_none_or(|last| now.duration_since(last) >= self.interval)
        };
        let decoded = self.decoder.push(au, pts, sample)?;
        if sample && decoded.completed {
            *self.last_sample.lock().unwrap() = Some(now);
        }
        match decoded.frame {
            Some(frame) => Ok(self.stream.push(Frame {
                rgb: &frame.rgb,
                content: InputSize {
                    w: frame.width,
                    h: frame.height,
                },
                orig: InputSize {
                    w: frame.orig_width,
                    h: frame.orig_height,
                },
                pts: frame.pts,
                time_base: self.time_base,
                observed_at_ms: frame.observed_at_ms,
                motion: frame.motion,
            })?),
            None => Ok(Vec::new()),
        }
    }
}

fn feed(rig: &Rig, clip: &Clip) -> Vec<FrameObservations> {
    try_feed(rig, clip).expect("every access unit is accepted")
}

/// The same, with the arrival instants the test's own rather than the wall clock's:
/// `spacing` stands in for the camera's frame period, so what the rate gate does
/// with a feed is a property of the numbers and not of how fast this box infers.
fn feed_at(rig: &Rig, clip: &Clip, spacing: Duration) -> Vec<FrameObservations> {
    let start = Instant::now();
    clip.units
        .iter()
        .enumerate()
        .flat_map(|(i, (au, pts))| {
            rig.push_au(au, *pts, start + spacing * i as u32)
                .expect("every access unit is accepted")
        })
        .collect()
}

/// [`feed`] with the error in hand, for the tests about refusals.
fn try_feed(rig: &Rig, clip: &Clip) -> std::result::Result<Vec<FrameObservations>, RigError> {
    let mut frames = Vec::new();
    for (au, pts) in &clip.units {
        frames.extend(rig.push_au(au, *pts, Instant::now())?);
    }
    Ok(frames)
}

/// Whether an access unit is keyframe-headed, by the walk `Cairn.Pipeline.Picker`
/// does: the first VCL NAL's type, 5 for an IDR slice.
fn is_keyframe(au: &[u8]) -> bool {
    let mut rest = au;
    while let Some(at) = rest.windows(3).position(|w| w == [0, 0, 1]) {
        let Some((header, after)) = rest[at + 3..].split_first() else {
            return false;
        };
        match header & 0x1F {
            5 => return true,
            1..=4 => return false,
            _parameter_or_delimiter => rest = after,
        }
    }
    false
}

fn open(engine: &Arc<Engine>, camera_id: &str) -> Stream {
    Stream::open(
        Arc::clone(engine),
        camera_id.to_string(),
        params().resolve().expect("the params resolve"),
    )
    .expect("the stream opens")
}

#[test]
fn a_recorded_clip_decodes_and_infers() {
    let Some(artifacts) = artifacts() else {
        return;
    };

    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let rig = Rig::open(&engine, "front", clip.time_base, 30);
    let frames = feed(&rig, &clip);

    assert!(
        !frames.is_empty(),
        "the clip produced no sampled frame at all"
    );
    // The motion gate is off, so every sample is a model pass.
    assert!(frames.iter().all(|frame| frame.inferred));
    // …and a real model pass costs real time — the D-P5 ratio's whole input.
    assert!(frames.iter().all(|frame| frame.infer_us > 0));
    assert!(frames.windows(2).all(|pair| pair[0].pts <= pair[1].pts));
    assert!(frames.iter().all(|frame| frame.observed_at_ms > 0));

    for object in frames.iter().flat_map(|frame| &frame.objects) {
        assert!(!object.label.is_empty());
        assert!((0.0..=1.0).contains(&object.score), "{object:?}");
        assert!(
            object.bbox.iter().all(|value| (0.0..=1.0).contains(value)),
            "boxes are frame-relative: {object:?}"
        );
        // With no embedder the field is absent, not empty.
        assert!(object.embedding.is_none());
    }

    println!(
        "{} sampled frame(s), {} detection(s): {:?}",
        frames.len(),
        frames
            .iter()
            .map(|frame| frame.objects.len())
            .sum::<usize>(),
        frames
            .iter()
            .flat_map(|frame| &frame.objects)
            .map(|object| (&object.label, object.score))
            .collect::<Vec<_>>()
    );
}

/// The rate is `--sample-fps`, and specifically not the clip's keyframe rate: a
/// gate upstream of the decoder could only ever admit keyframe-headed access units,
/// which on the fleet's 2-5 s GOPs is 10-24x under what was asked for.
#[test]
fn the_rate_gate_admits_sample_fps_and_not_the_gop_rate() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let spacing = Duration::from_millis(50);

    let rig = Rig::open(&engine, "front", clip.time_base, 5);
    let frames = feed_at(&rig, &clip, spacing);

    // One admitted every 200 ms over a feed of `units - 1` spacings, less the
    // decoder's start-up latency, which costs whole intervals at the head.
    let span = spacing * (clip.units.len() - 1) as u32;
    let expected = span.as_millis() / 200 + 1;
    let keyframes = clip.units.iter().filter(|(au, _)| is_keyframe(au)).count();
    println!(
        "{} access units, {keyframes} keyframe(s) -> {} model pass(es), {expected} asked for",
        clip.units.len(),
        frames.len()
    );

    assert!(
        frames.len() as u128 + 3 >= expected && frames.len() as u128 <= expected,
        "{} model pass(es) against the {expected} that 5 fps over {span:?} asks for",
        frames.len()
    );
    assert!(
        frames.len() > 2 * keyframes,
        "the achieved rate is the clip's keyframe rate, which is the defect this pins"
    );
    assert!(frames.iter().all(|frame| frame.inferred));
}

/// The property the rate's move past the decoder rests on: an access unit that is
/// not keyframe-headed is a frame like any other, because its predecessors were fed.
#[test]
fn a_mid_gop_access_unit_decodes_and_infers() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    // A spacing past the 200 ms interval, so the gate admits every unit and what
    // is left is the decoder's own answer.
    let rig = Rig::open(&engine, "front", clip.time_base, 5);
    let frames = feed_at(&rig, &clip, Duration::from_millis(250));
    let keyframes = clip.units.iter().filter(|(au, _)| is_keyframe(au)).count();

    assert!(
        keyframes < clip.units.len(),
        "a clip of nothing but keyframes cannot test this"
    );
    assert!(
        frames.len() > keyframes,
        "{} model pass(es) from {} access units, {keyframes} of them keyframes: the \
         non-keyframe units decoded to nothing",
        frames.len(),
        clip.units.len()
    );
    assert!(frames.iter().all(|frame| frame.inferred));
    assert!(frames.windows(2).all(|pair| pair[0].pts <= pair[1].pts));
}

/// The registry, against a real engine rather than against itself. The claim
/// belongs to the *inference* stream — a decoder holds none, because two
/// decoders for one camera only waste work while two inference streams would
/// double-report it.
#[test]
fn one_camera_holds_one_stream_and_gets_it_back_when_it_closes() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);

    let stream = open(&engine, "front");
    let refused = Stream::open(
        Arc::clone(&engine),
        "front".into(),
        params().resolve().unwrap(),
    );
    match refused {
        Ok(_) => panic!("a second stream for one camera was allowed"),
        Err(error) => assert_eq!(error.reason(), "open_stream"),
    }

    // …and dropping the handle, which is what `close_stream` does, hands the id
    // back without anything else having to say so.
    drop(stream);
    assert!(Stream::open(
        Arc::clone(&engine),
        "front".into(),
        params().resolve().unwrap()
    )
    .is_ok());
}

/// A decoder that panics while being built must leave the camera fully openable:
/// there is no claim on this half to leak, and the inference half's claim is
/// nothing the decode open ever touched.
#[test]
fn a_panic_while_the_decoder_opens_leaves_the_camera_openable() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);

    crate::decoder::panic_in_the_next_open();
    let panicked = crate::guarded("open_decoder", || {
        DecodeStream::open(
            "front".into(),
            decoder_params(&engine, 30).resolve().unwrap(),
        )
        .map(|_| ())
        .map_err(|e| crate::error::NativeError::OpenStream(e.message().to_string()))
    });
    assert_eq!(
        panicked.unwrap_err().reason(),
        "panicked",
        "the open did not panic, so nothing below is being tested"
    );

    let clip = read_clip(&artifacts.clip);
    let rig = Rig::open(&engine, "front", clip.time_base, 30);
    assert!(!feed(&rig, &clip).is_empty());
}

/// A camera producing nothing the decoder can use must cost its neighbours nothing.
#[test]
fn a_stream_fed_garbage_leaves_its_neighbours_alone() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let garbage = Clip {
        units: (0..32u8)
            .map(|i| (vec![i; 1024], i64::from(i) * 3_000))
            .collect(),
        time_base: clip.time_base,
    };

    let front = Rig::open(&engine, "front", clip.time_base, 30);
    let drive = Rig::open(&engine, "drive", clip.time_base, 30);
    let gate = Rig::open(&engine, "gate", clip.time_base, 30);

    assert!(feed(&drive, &garbage).is_empty(), "garbage decoded");
    let before = feed(&front, &clip);
    // …and interleaving changes nothing: the garbage lands in `drive`'s own
    // decoder, and `gate` is fed after it.
    assert!(feed(&drive, &garbage).is_empty());
    let after = feed(&gate, &clip);

    assert!(!before.is_empty(), "the healthy stream produced nothing");
    assert!(!after.is_empty(), "the neighbour after it produced nothing");
    let counted = |rig: &Rig| {
        let mut state = rig.decoder.state.lock().unwrap();
        state.as_mut().expect("the decoder is open").tolerated()
    };
    assert_eq!(counted(&front), (0, 0), "the healthy stream took damage");
    assert_eq!(counted(&gate), (0, 0), "the neighbour took damage");
    println!("the garbage stream counted {:?}", counted(&drive));
}

/// A stream's own failures are values, and cost it one call rather than itself.
#[test]
fn a_stream_error_is_a_value_and_the_stream_survives_it() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    let front = Rig::open(&engine, "front", clip.time_base, 30);
    let drive = Rig::open(&engine, "drive", clip.time_base, 30);

    // An empty access unit is refused on the decode half…
    let bad = front.push_au(&[], 0, Instant::now());
    assert_eq!(bad.unwrap_err().reason(), "decode");

    // …and a time base that would fault the rescale is refused on the
    // inference half, before any of it runs.
    let refused = front.stream.push(Frame {
        rgb: &[],
        content: InputSize { w: 1, h: 1 },
        orig: InputSize { w: 1, h: 1 },
        pts: Some(0),
        time_base: (0, 0),
        observed_at_ms: 0,
        motion: None,
    });
    assert_eq!(refused.unwrap_err().reason(), "decode");

    assert!(!feed(&front, &clip).is_empty(), "the stream is spent");
    assert!(!feed(&drive, &clip).is_empty(), "the neighbour is spent");
}

/// A frame whose geometry disagrees with the engine's own input spec is a
/// producer bug, not a tolerated skip: every later frame would be wrong the
/// same way, so it is refused loudly as an inference error.
#[test]
fn a_frame_for_a_different_spec_is_refused_not_projected() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let rig = Rig::open(&engine, "front", clip.time_base, 30);

    let refused = rig.stream.push(Frame {
        rgb: &[0u8; 12],
        content: InputSize { w: 2, h: 2 },
        orig: InputSize { w: 1920, h: 1080 },
        pts: Some(0),
        time_base: clip.time_base,
        observed_at_ms: 0,
        motion: None,
    });
    assert_eq!(refused.unwrap_err().reason(), "infer");

    // …and the refusal cost the stream nothing.
    assert!(!feed(&rig, &clip).is_empty());
}

/// Armed inside the model pass and reached through `push_frame`, so the unwind
/// goes through the stream lock *and* the model lock — the only shape the frame
/// path can make, and one a model lock poisoned on its own cannot imitate.
#[test]
fn a_panic_in_a_model_pass_is_model_poisoned_on_every_stream_including_its_own() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    let front = Rig::open(&engine, "front", clip.time_base, 30);
    let drive = Rig::open(&engine, "drive", clip.time_base, 30);

    engine.panic_in_the_next_pass();
    let panicked = cairn_ort::guarded("push_frame", || {
        try_feed(&front, &clip).map_err(|e| cairn_ort::NativeError::Infer(e.message))?;
        Ok(())
    });
    assert_eq!(
        panicked.unwrap_err().reason(),
        "panicked",
        "the pass did not panic, so nothing below is being tested"
    );
    assert!(
        engine.model_is_poisoned(),
        "the panic did not reach the model lock"
    );

    for (name, rig) in [
        ("the stream it happened on", &front),
        ("its neighbour", &drive),
    ] {
        // Rearmed so this feed reaches the inference half at all: the verdict
        // under test lives past the rate gate.
        rig.rearm();
        let error = try_feed(rig, &clip).unwrap_err();
        assert_eq!(error.reason(), "model_poisoned", "{name}");
    }

    // …and what never reached the model still says whose fault it was, so a stream
    // sending nonsense cannot tell the host the engine is gone.
    let fresh = Rig::open(&engine, "gate", clip.time_base, 30);
    let refused = fresh.push_au(&[], 0, Instant::now());
    assert_eq!(refused.unwrap_err().reason(), "decode");
}

/// The other half: `model_poisoned` for a panic in one camera's own state would
/// have the host stop trusting an engine that is fine.
#[test]
fn a_panic_in_a_streams_own_state_stays_that_streams_problem() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    let front = Rig::open(&engine, "front", clip.time_base, 30);
    let drive = Rig::open(&engine, "drive", clip.time_base, 30);
    front.stream.poison_state();

    assert_eq!(
        try_feed(&front, &clip).unwrap_err().reason(),
        "poisoned",
        "one camera's stream took the whole engine with it"
    );
    assert!(!engine.model_is_poisoned());
    assert!(!try_feed(&drive, &clip).unwrap().is_empty());
}

/// A `close` that refused the poisoned lock would leave the id claimed until GC, so
/// the reopen `poisoned` asks for would be refused as a duplicate.
#[test]
fn a_poisoned_stream_closes_and_its_camera_can_be_opened_again() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    let front = Rig::open(&engine, "front", clip.time_base, 30);
    front.stream.poison_state();
    assert_eq!(
        try_feed(&front, &clip).unwrap_err().reason(),
        "poisoned",
        "the stream is not in the state the rest of this test is about"
    );

    assert!(front.stream.close(), "a poisoned stream did not close");
    assert!(
        !front.stream.close(),
        "closing an emptied stream is not a second close"
    );

    let reopened = Stream::open(
        Arc::clone(&engine),
        "front".into(),
        params().resolve().unwrap(),
    )
    .expect("the camera id was never handed back, so the camera stays dark");
    let reopened = StreamRef::new(Arc::clone(&engine), reopened);
    drop(front);
    let rig = Rig {
        decoder: DecoderRef::new(
            DecodeStream::open(
                "front".into(),
                decoder_params(&engine, 30).resolve().unwrap(),
            )
            .unwrap(),
        ),
        stream: reopened,
        time_base: clip.time_base,
        interval: sample_interval(30),
        last_sample: Mutex::new(None),
    };
    assert!(!try_feed(&rig, &clip).unwrap().is_empty());
}

/// The other way a stream ends: the BEAM collected the handle.
#[test]
fn a_collected_poisoned_stream_hands_its_camera_id_back() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);

    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));
    front.poison_state();
    crate::teardown::defer(front);

    // The teardown thread owns the drop, so the id comes back on its clock.
    let deadline = Instant::now() + std::time::Duration::from_secs(10);
    let reopened = loop {
        match Stream::open(
            Arc::clone(&engine),
            "front".into(),
            params().resolve().unwrap(),
        ) {
            Ok(stream) => break stream,
            Err(error) => {
                assert!(
                    Instant::now() < deadline,
                    "the camera id was never handed back: {error:?}"
                );
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    };
    drop(reopened);
}

/// Two streams on one engine contend only on the model pass, so both must finish.
#[test]
fn two_streams_make_progress_at_once() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let front = Rig::open(&engine, "front", clip.time_base, 30);
    let drive = Rig::open(&engine, "drive", clip.time_base, 30);

    let (a, b) = std::thread::scope(|scope| {
        let a = scope.spawn(|| try_feed(&front, &clip));
        let b = scope.spawn(|| try_feed(&drive, &clip));
        (a.join().unwrap(), b.join().unwrap())
    });

    assert!(!a.expect("the first stream failed").is_empty());
    assert!(!b.expect("the second stream failed").is_empty());
}

/// Two callers on *one* camera's pair: the resources' mutexes serialize them, so
/// neither the decoder nor the stream is ever entered twice.
#[test]
fn two_pushes_to_one_stream_serialize() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let front = Rig::open(&engine, "front", clip.time_base, 30);

    let frames = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..2)
            .map(|_| scope.spawn(|| try_feed(&front, &clip)))
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap().expect("a push was refused"))
            .map(|frames| frames.len())
            .sum::<usize>()
    });

    assert!(frames > 0, "two callers produced no frame between them");
    // `close` recovers a poisoned guard, so the poisoning half has to be asked
    // separately.
    assert!(!front.stream.state_is_poisoned(), "a push panicked");
    assert!(!front.decoder.state.is_poisoned(), "a decode panicked");
    assert!(front.stream.close());
    assert!(front.decoder.close());
}
