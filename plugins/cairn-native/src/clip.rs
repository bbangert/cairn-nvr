//! The one end-to-end path: a real H.264 file, real model load, real decoder,
//! every access unit handed to `push_au` the way Membrane's H.264 parser will hand
//! them over. Only the demuxer stands in for the pipeline.
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
use std::sync::Arc;
use std::time::{Duration, Instant};

use rsmpeg::avformat::AVFormatContextInput;
use rsmpeg::ffi;

use crate::config::{RawInitConfig, RawQnnOptions, RawStreamParams};
use crate::engine::Engine;
use crate::error::Result;
use crate::observation::FrameObservations;
use crate::stream::Stream;
use crate::StreamRef;

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
    engine_at(artifacts, 30)
}

fn engine_at(artifacts: &Artifacts, sample_fps: u32) -> Arc<Engine> {
    let config = RawInitConfig {
        model: artifacts.model.display().to_string(),
        backend: "ort".into(),
        model_profile: None,
        input_size: None,
        labels: Some(artifacts.labels.display().to_string()),
        allow_label_mismatch: false,
        embedder_model: None,
        // Software decode: a box without the GPU the hardware paths need has to
        // get the same answer as one with it.
        decoder: "sw".into(),
        sample_fps,
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

fn feed(stream: &mut Stream, clip: &Clip) -> Vec<FrameObservations> {
    clip.units
        .iter()
        .flat_map(|(au, pts)| {
            stream
                .push_au(au, *pts, clip.time_base, Instant::now())
                .expect("every access unit is accepted")
        })
        .collect()
}

/// The same, with the arrival instants the test's own rather than the wall clock's:
/// `spacing` stands in for the camera's frame period, so what the rate gate does
/// with a feed is a property of the numbers and not of how fast this box infers.
fn feed_at(stream: &mut Stream, clip: &Clip, spacing: Duration) -> Vec<FrameObservations> {
    let start = Instant::now();
    clip.units
        .iter()
        .enumerate()
        .flat_map(|(i, (au, pts))| {
            stream
                .push_au(au, *pts, clip.time_base, start + spacing * i as u32)
                .expect("every access unit is accepted")
        })
        .collect()
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

/// The same through the resource handle, which is what serializes two callers on
/// one stream.
fn feed_shared(stream: &StreamRef, clip: &Clip) -> Result<Vec<FrameObservations>> {
    let mut frames = Vec::new();
    for (au, pts) in &clip.units {
        frames.extend(stream.push(au, *pts, clip.time_base)?);
    }
    Ok(frames)
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
    let mut stream = open(&engine, "front");
    let frames = feed(&mut stream, &read_clip(&artifacts.clip));

    assert!(
        !frames.is_empty(),
        "the clip produced no sampled frame at all"
    );
    // The motion gate is off, so every sample is a model pass.
    assert!(frames.iter().all(|frame| frame.inferred));
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
    let engine = engine_at(&artifacts, 5);
    let clip = read_clip(&artifacts.clip);
    let spacing = Duration::from_millis(50);

    let mut stream = open(&engine, "front");
    let frames = feed_at(&mut stream, &clip, spacing);

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
    let engine = engine_at(&artifacts, 5);
    let clip = read_clip(&artifacts.clip);

    // A spacing past the 200 ms interval, so the gate admits every unit and what
    // is left is the decoder's own answer.
    let mut stream = open(&engine, "front");
    let frames = feed_at(&mut stream, &clip, Duration::from_millis(250));
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

/// The registry, against a real engine rather than against itself.
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

/// A decoder that panics while being built leaves no [`Stream`] for the unwind to
/// drop, so the id has to come back on its own.
#[test]
fn a_panic_while_the_decoder_opens_hands_the_camera_id_back() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);

    engine.panic_in_the_next_open();
    let panicked = crate::guarded("open_stream", || {
        Stream::open(
            Arc::clone(&engine),
            "front".into(),
            params().resolve().unwrap(),
        )
        .map(|_| ())
    });
    assert_eq!(
        panicked.unwrap_err().reason(),
        "panicked",
        "the open did not panic, so nothing below is being tested"
    );

    // …and the camera is openable: the host retries an open that failed, and a
    // claim nothing released makes every retry a duplicate.
    let clip = read_clip(&artifacts.clip);
    let mut reopened = open(&engine, "front");
    assert!(!feed(&mut reopened, &clip).is_empty());
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

    let mut front = open(&engine, "front");
    let mut drive = open(&engine, "drive");
    let mut gate = open(&engine, "gate");

    assert!(feed(&mut drive, &garbage).is_empty(), "garbage decoded");
    let before = feed(&mut front, &clip);
    // …and interleaving changes nothing: the garbage lands in `drive`'s own
    // decoder, and `gate` is fed after it.
    assert!(feed(&mut drive, &garbage).is_empty());
    let after = feed(&mut gate, &clip);

    assert!(!before.is_empty(), "the healthy stream produced nothing");
    assert!(!after.is_empty(), "the neighbour after it produced nothing");
    assert_eq!(front.tolerated(), (0, 0), "the healthy stream took damage");
    assert_eq!(gate.tolerated(), (0, 0), "the neighbour took damage");
    println!("the garbage stream counted {:?}", drive.tolerated());
}

/// A stream's own failures are values, and cost it one call rather than itself.
#[test]
fn a_stream_error_is_a_value_and_the_stream_survives_it() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let (au, pts) = &clip.units[0];

    let mut front = open(&engine, "front");
    let mut drive = open(&engine, "drive");

    for bad in [
        front.push_au(&[], *pts, clip.time_base, Instant::now()),
        front.push_au(au, *pts, (0, 0), Instant::now()),
    ] {
        assert_eq!(bad.unwrap_err().reason(), "decode");
    }

    assert!(!feed(&mut front, &clip).is_empty(), "the stream is spent");
    assert!(
        !feed(&mut drive, &clip).is_empty(),
        "the neighbour is spent"
    );
}

/// Armed inside the model pass and reached through `push_au`, so the unwind goes
/// through the stream lock *and* the model lock — the only shape the frame path can
/// make, and one a model lock poisoned on its own cannot imitate.
#[test]
fn a_panic_in_a_model_pass_is_model_poisoned_on_every_stream_including_its_own() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);

    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));
    let drive = StreamRef::new(Arc::clone(&engine), open(&engine, "drive"));

    engine.panic_in_the_next_pass();
    let panicked = crate::guarded("push_au", || feed_shared(&front, &clip));
    assert_eq!(
        panicked.unwrap_err().reason(),
        "panicked",
        "the pass did not panic, so nothing below is being tested"
    );
    assert!(
        engine.model_is_poisoned(),
        "the panic did not reach the model lock"
    );

    for (name, stream) in [
        ("the stream it happened on", &front),
        ("its neighbour", &drive),
    ] {
        let error = feed_shared(stream, &clip).unwrap_err();
        assert_eq!(error.reason(), "model_poisoned", "{name}");
    }

    // …and what never reached the model still says whose fault it was, so a stream
    // sending nonsense cannot tell the host the engine is gone.
    let mut fresh = open(&engine, "gate");
    let refused = fresh.push_au(&[], 0, clip.time_base, Instant::now());
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

    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));
    let drive = StreamRef::new(Arc::clone(&engine), open(&engine, "drive"));
    front.poison_state();

    assert_eq!(
        feed_shared(&front, &clip).unwrap_err().reason(),
        "poisoned",
        "one camera's decoder took the whole engine with it"
    );
    assert!(!engine.model_is_poisoned());
    assert!(!feed_shared(&drive, &clip).unwrap().is_empty());
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

    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));
    front.poison_state();
    assert_eq!(
        feed_shared(&front, &clip).unwrap_err().reason(),
        "poisoned",
        "the stream is not in the state the rest of this test is about"
    );

    assert!(front.close(), "a poisoned stream did not close");
    assert!(
        !front.close(),
        "closing an emptied stream is not a second close"
    );

    let reopened = Stream::open(
        Arc::clone(&engine),
        "front".into(),
        params().resolve().unwrap(),
    )
    .expect("the camera id was never handed back, so the camera stays dark");
    let reopened = StreamRef::new(Arc::clone(&engine), reopened);
    assert!(!feed_shared(&reopened, &clip).unwrap().is_empty());
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
    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));
    let drive = StreamRef::new(Arc::clone(&engine), open(&engine, "drive"));

    let (a, b) = std::thread::scope(|scope| {
        let a = scope.spawn(|| feed_shared(&front, &clip));
        let b = scope.spawn(|| feed_shared(&drive, &clip));
        (a.join().unwrap(), b.join().unwrap())
    });

    assert!(!a.expect("the first stream failed").is_empty());
    assert!(!b.expect("the second stream failed").is_empty());
}

/// Two callers on *one* stream: the resource's mutex serializes them, so the
/// decoder is never entered twice.
#[test]
fn two_pushes_to_one_stream_serialize() {
    let Some(artifacts) = artifacts() else {
        return;
    };
    let engine = engine(&artifacts);
    let clip = read_clip(&artifacts.clip);
    let front = StreamRef::new(Arc::clone(&engine), open(&engine, "front"));

    let frames = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..2)
            .map(|_| scope.spawn(|| feed_shared(&front, &clip)))
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
    assert!(!front.state.is_poisoned(), "a push panicked");
    assert!(front.close());
}
