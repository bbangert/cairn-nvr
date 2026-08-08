//! The one end-to-end path, on a recorded clip.
//!
//! A real H.264 file through the real crate: a real model load, a real decoder,
//! and every access unit in the file handed to `push_au` the way Membrane's
//! H.264 parser will hand them over — whole AUs, Annex-B, with the container's
//! own pts and time base. Nothing here is a stub; the only thing standing in
//! for the pipeline is the file demuxer that splits the clip into units.
//!
//! It needs artifacts this repository does not carry (`*.onnx` is gitignored),
//! and **a missing artifact fails the run**. Not skips: these are the crate's
//! only end-to-end tests, and one that returns without running is
//! indistinguishable in `cargo test`'s output from one that ran and passed —
//! which is how a harness rots away unnoticed. The Elixir side draws the same
//! line with `--only native_parity`.
//!
//! ```text
//! CAIRN_NATIVE_CLIP=data/events/…/clip.mp4 \
//! CAIRN_NATIVE_MODEL=plugins/cairn-detect/yolox_nano.onnx \
//! CAIRN_NATIVE_LABELS=plugins/cairn-detect/coco.names \
//!   cargo test clip -- --nocapture --test-threads=1
//! ```
//!
//! The paths above have repository defaults, so a checkout with the model in
//! place needs none of them. A checkout without one is expected to say so:
//!
//! ```text
//! CAIRN_NATIVE_SKIP_CLIP=1 cargo test
//! ```
//!
//! which prints, per test, what it skipped and why (add `-- --nocapture` to
//! read it). That waiver is the only way past these tests, and it is a decision
//! someone has to make out loud.
//!
//! Sampling is wall-clock (`--sample-fps`, as in the plugin), so a clip pushed
//! as fast as it decodes yields a handful of samples rather than one per frame.
//! That is the right behaviour for a live stream and the reason task 2.5's
//! parity harness feeds clips at their own rate.

use std::collections::HashMap;
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use rsmpeg::avformat::AVFormatContextInput;
use rsmpeg::ffi;

use crate::config::{RawInitConfig, RawQnnOptions, RawStreamParams};
use crate::engine::Engine;
use crate::error::Result;
use crate::observation::FrameObservations;
use crate::stream::Stream;
use crate::StreamRef;

/// The waiver for a checkout that has no model: `CAIRN_NATIVE_SKIP_CLIP=1`.
const WAIVER: &str = "CAIRN_NATIVE_SKIP_CLIP";

/// An artifact path from the environment, or the repository default.
///
/// `None` means "not here". A named path that does not exist is a failure
/// whatever the waiver says, because the caller said where to look.
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

/// What this harness runs against, or `None` if the run waived it.
///
/// Missing artifacts panic. Every test here opens with `let Some(artifacts) =
/// artifacts() else { return }`, so an early return has to be a *decision* —
/// otherwise the whole harness reports green on a box where it never ran. Run
/// with `--nocapture` to see the skip lines.
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
        // Software decode: this asserts about what came out, and a box without
        // the GPU the hardware paths need should get the same answer as one
        // with it.
        decoder: "sw".into(),
        sample_fps: 30,
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

/// The clip as the pipeline will hand it over: whole access units with their
/// own pts, read once so several streams can be fed the same bytes.
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

/// Push every access unit in `clip` through `stream`.
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

/// The same, through the resource handle the NIF holds — which is the only
/// thing that serializes two callers on one stream.
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
    // The motion gate is off for this stream, so every sample is a model pass
    // and nothing is ever re-reported.
    assert!(frames.iter().all(|frame| frame.inferred));
    // pts is the stream's own clock rescaled to 90 kHz, and the clip plays
    // forwards.
    assert!(frames.windows(2).all(|pair| pair[0].pts <= pair[1].pts));
    assert!(frames.iter().all(|frame| frame.observed_at_ms > 0));

    for object in frames.iter().flat_map(|frame| &frame.objects) {
        assert!(!object.label.is_empty());
        assert!((0.0..=1.0).contains(&object.score), "{object:?}");
        assert!(
            object.bbox.iter().all(|value| (0.0..=1.0).contains(value)),
            "boxes are frame-relative: {object:?}"
        );
        // With no embedder configured the field is absent, not empty.
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

    // …and dropping the handle — which is what `close_stream` does — hands the
    // id back without anything else having to say so.
    drop(stream);
    assert!(Stream::open(
        Arc::clone(&engine),
        "front".into(),
        params().resolve().unwrap()
    )
    .is_ok());
}

/// The 2.2 claim, on real streams: a camera that is producing nothing the
/// decoder can use must cost its neighbours nothing.
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
    // …and interleaving the two changes nothing: the garbage lands in `drive`'s
    // own decoder, and `gate` is fed after it.
    assert!(feed(&mut drive, &garbage).is_empty());
    let after = feed(&mut gate, &clip);

    assert!(!before.is_empty(), "the healthy stream produced nothing");
    assert!(!after.is_empty(), "the neighbour after it produced nothing");
    assert_eq!(front.tolerated(), (0, 0), "the healthy stream took damage");
    assert_eq!(gate.tolerated(), (0, 0), "the neighbour took damage");
    println!("the garbage stream counted {:?}", drive.tolerated());
}

/// A stream's own failures are values, and they cost the stream one call
/// rather than the stream itself.
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

/// The distinction 2.3 escalates on, from the panic that actually produces it.
///
/// The panic is armed inside the model pass and reached through `push_au`, so
/// it unwinds through the stream lock *and* the model lock — the only shape the
/// frame path can make, and the one that a model lock poisoned on its own
/// cannot imitate. What it costs the stream it happened on is the whole
/// question: that stream's own lock is poisoned too, and answering `poisoned`
/// from it tells the host to reopen one camera against an engine that will
/// never serve any.
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

    // …and what never reached the model still says whose fault it was, so the
    // host is not told the engine is gone by a stream sending nonsense.
    let mut fresh = open(&engine, "gate");
    let refused = fresh.push_au(&[], 0, clip.time_base, Instant::now());
    assert_eq!(refused.unwrap_err().reason(), "decode");
}

/// The other half of the same question: a panic in one camera's own state is
/// that camera's, and saying `model_poisoned` for it would have the host stop
/// trusting an engine that is fine.
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

/// Two Elixir processes, two streams, one engine: they contend only on the
/// model pass, so both must finish.
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

/// Two Elixir processes on *one* stream: the resource's mutex serializes them,
/// so the decoder is never entered twice and both callers are answered.
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
    // Still the same stream afterwards — not a poisoned one, and not one the
    // second caller closed out from under the first.
    assert!(front.close().expect("the stream is not poisoned"));
}
