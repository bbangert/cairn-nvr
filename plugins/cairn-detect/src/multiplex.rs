//! Multiplexed mode: one process, N camera streams.
//!
//! Cairn launches a plugin *group* with a single `--cameras-json` argument
//! instead of `--camera-id`/`--udp-port`/`--min-score-json`. Each member gets
//! its own decode thread and its own latest-sample slot; one inference thread
//! drains the slots, applying the floors and stamping the id of whichever
//! camera the sample came from.
//!
//! The error policy is the mirror image of single-camera mode. A member
//! camera that is stopped, restarting, or not yet sending is *normal* here —
//! Cairn deliberately leaves a group running when a member's ffmpeg bounces —
//! so a stream never takes the process down: it logs and re-opens forever.
//! Only the inference thread's failures are fatal (exit 1 -> Cairn's backoff
//! restart of the whole group).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use crossbeam_channel::{bounded, Receiver, Select, Sender, TrySendError};
use rsmpeg::ffi;
use serde::Deserialize;

use crate::decode::{self, DecoderKind, Sample, SampleSink};
use crate::emit::{self, Publisher};
use crate::gate::{self, Gate};
use crate::infer::{Detector, InputSpec, Labels, ScoreFloors, TrackFloorOverrides};
use crate::motion::{self, MotionConfig, MotionOverrides};
use crate::rtp;

/// First wait after a stream drops, doubled up to [`REOPEN_MAX`].
const REOPEN_MIN: Duration = Duration::from_secs(5);
const REOPEN_MAX: Duration = Duration::from_secs(30);
/// A stream that stayed up this long is treated as healthy: the next drop
/// starts over at [`REOPEN_MIN`] rather than inheriting a dark camera's wait.
const HEALTHY_RUN: Duration = Duration::from_secs(60);

/// One group member, as Cairn writes it into `--cameras-json` — plus `motion`
/// and `track_floor`, which Cairn does not write and an operator can add by
/// hand.
#[derive(Debug, Clone, Deserialize)]
pub struct CameraSpec {
    pub id: String,
    pub udp_port: u16,
    /// Same shape as `--min-score-json`; absent means "all defaults".
    #[serde(default)]
    pub min_score: HashMap<String, f64>,
    /// Motion-gate knobs for this member alone, overriding the process-wide
    /// `--motion-json`. Absent — which is what Cairn writes today — means the
    /// member takes the global settings unchanged.
    #[serde(default)]
    pub motion: MotionOverrides,
    /// Track floor for this member alone, replacing the process-wide
    /// `--track-floor-json`. Absent — which is also what Cairn writes today —
    /// means the member takes the global setting unchanged.
    #[serde(default)]
    pub track_floor: TrackFloorOverrides,
}

/// Decode the `--cameras-json` argument.
pub fn parse_specs(json: &str) -> Result<Vec<CameraSpec>> {
    let specs: Vec<CameraSpec> = serde_json::from_str(json)
        .context("--cameras-json is not a JSON array of {id, udp_port, min_score, motion}")?;
    if specs.is_empty() {
        bail!("--cameras-json is empty; a group serves at least one camera");
    }
    let mut seen = HashSet::with_capacity(specs.len());
    for spec in &specs {
        if !seen.insert(spec.id.as_str()) {
            bail!("--cameras-json repeats camera id {}", spec.id);
        }
        // Checked here rather than where the gate is built, so an out-of-range
        // knob fails the whole group at startup instead of one member's decode
        // thread minutes later. The track floor's *range* is checkable here
        // too; what it pairs with — this member's `min_score` map — is
        // [`floors_for`], which the caller runs at startup for the same reason.
        spec.motion
            .validate()
            .with_context(|| format!("--cameras-json camera {}", spec.id))?;
        spec.track_floor
            .validate()
            .with_context(|| format!("--cameras-json camera {}", spec.id))?;
    }
    Ok(specs)
}

/// Score floors per member, in the same order as `specs`, each carrying the
/// track floor that member resolved to.
///
/// Fallible because that is where the pairing check lives: a track floor has to
/// sit strictly below every `min_score` on the camera it applies to, and the
/// two halves only meet here. The error names the member, since a group can
/// hold one camera the floor is legal for and one it is not.
pub fn floors_for(
    specs: &[CameraSpec],
    track_floor: &TrackFloorOverrides,
) -> Result<Vec<ScoreFloors>> {
    specs
        .iter()
        .map(|spec| {
            ScoreFloors::from_map(spec.min_score.clone())
                .with_track_floor(TrackFloorOverrides::resolve(track_floor, &spec.track_floor))
                .with_context(|| format!("--cameras-json camera {}", spec.id))
        })
        .collect()
}

/// Resolved motion gate per member, in the same order as `specs`. `None` for a
/// member whose gate ends up disabled, which is the default.
pub fn motion_for(specs: &[CameraSpec], global: &MotionOverrides) -> Vec<Option<MotionConfig>> {
    specs
        .iter()
        .map(|spec| motion::resolve(global, &spec.motion))
        .collect()
}

/// The two process-wide decode knobs every member's stream thread needs, from
/// `--decoder` and `--sample-fps`. Bundled only to keep [`run`]'s own
/// parameter list under clippy's arity limit — the bundle rides intact down
/// the stream-thread call chain and splits back into its two values only
/// where they are finally consumed, since `kind` and `sample_fps` mean
/// nothing to each other.
///
/// One value of each for the whole group: both flags are per-process by
/// design, so there is no per-camera decoder or per-camera rate to carry
/// here instead.
#[derive(Debug, Clone, Copy)]
pub struct DecodeSettings {
    pub kind: DecoderKind,
    pub sample_fps: u32,
}

/// Run every member's stream through one detector until inference fails.
///
/// `floors` comes from the caller rather than from [`floors_for`] here: it can
/// fail (see there), and a startup argument that cannot be honoured has to say
/// so before the model load rather than after it. It is indexed by slot like
/// everything else in this module.
pub fn run(
    specs: &[CameraSpec],
    decode_settings: DecodeSettings,
    motion: &MotionOverrides,
    floors: Vec<ScoreFloors>,
    detector: Detector,
    labels: &Labels,
    publisher: Publisher,
) -> Result<()> {
    let motion = motion_for(specs, motion);
    // One resolved spec for the whole group: the members share the detector,
    // so they share the geometry, the encoding *and* the resize policy every
    // decoder has to produce.
    let input_spec = detector.input_spec();
    let mut slots = Vec::with_capacity(specs.len());

    for (index, spec) in specs.iter().enumerate() {
        let (slot, sink) = slot_pair::<Sample>();
        slots.push(slot);
        let owned = spec.clone();
        let motion = motion[index];
        thread::Builder::new()
            .name(format!("stream-{}", spec.id))
            .spawn(move || stream_loop(&owned, decode_settings, input_spec, motion, &sink))
            .with_context(|| format!("spawning the decode thread for camera {}", spec.id))?;
    }

    infer_loop(&slots, specs, &floors, &motion, detector, labels, publisher)
}

/// Open -> decode -> log -> re-open, forever. Never returns.
///
/// The single-camera contract is the opposite: there, an open failure or the
/// 30s read timeout is fatal so Cairn restarts the process (see `run_single`
/// in main.rs). Here the process serves other cameras that are still live,
/// and a member's silence is an expected state rather than a fault.
fn stream_loop(
    spec: &CameraSpec,
    decode_settings: DecodeSettings,
    input_spec: InputSpec,
    motion: Option<MotionConfig>,
    sink: &LatestSink<Sample>,
) {
    let mut delay = REOPEN_MIN;
    let mut failures: u64 = 0;

    loop {
        let started = Instant::now();
        let outcome = open_and_run(spec, decode_settings, input_spec, motion, sink);
        if started.elapsed() >= HEALTHY_RUN {
            failures = 0;
            delay = REOPEN_MIN;
        }

        failures += 1;
        if failures.is_multiple_of(10) || failures == 1 {
            match &outcome {
                Ok(()) => eprintln!(
                    "camera {}: stream ended ({failures} so far); reopening",
                    spec.id
                ),
                Err(e) => eprintln!(
                    "camera {}: stream down ({failures} so far): {e:#}; reopening",
                    spec.id
                ),
            }
        }

        thread::sleep(delay);
        delay = (delay * 2).min(REOPEN_MAX);
    }
}

fn open_and_run(
    spec: &CameraSpec,
    decode_settings: DecodeSettings,
    input_spec: InputSpec,
    motion: Option<MotionConfig>,
    sink: &LatestSink<Sample>,
) -> Result<()> {
    let DecodeSettings { kind, sample_fps } = decode_settings;
    let mut input = rtp::open_stream_once(spec.udp_port)?;
    let (stream_index, _) = input
        .find_best_stream(ffi::AVMEDIA_TYPE_VIDEO)
        .context("looking for a video stream")?
        .ok_or_else(|| anyhow!("no video stream on udp port {}", spec.udp_port))?;
    let (time_base, mut decoder) = {
        let stream = &input.streams()[stream_index];
        (
            stream.time_base,
            decode::open(kind, &stream.codecpar(), input_spec, motion, sample_fps)
                .with_context(|| format!("opening a decoder for camera {}", spec.id))?,
        )
    };

    decode::run(
        &mut input,
        stream_index,
        time_base,
        decoder.as_mut(),
        sink,
        sample_fps,
    )
}

/// Drain every member's slot through the one detector.
///
/// `motion` and the gates are indexed by slot, like `specs` and `floors`: the
/// policy is per camera, and one busy member must not spend another's linger
/// or re-verify window. What happens to a sample once its slot is known is
/// [`gate::sample_line`], the same call single mode makes — the two modes
/// differ in which camera's state they hand it and in nothing else.
///
/// The length checks below are the checkable slice of that invariant: a
/// caller handing this loop slices of different lengths has built them from
/// different rosters, and an index that is valid in one would be a wrong
/// camera — or a panic — in another. What no local assertion can catch is a
/// *reordering* (four same-length vectors in different orders), nor
/// `motion[0]` written where `motion[index]` belongs: the vectors are built
/// in `specs` order at startup and nothing re-orders them, but the gate tests
/// drive their own members and cannot see this call; a harness running real
/// clips through the group loop is what would.
fn infer_loop(
    slots: &[LatestSlot<Sample>],
    specs: &[CameraSpec],
    floors: &[ScoreFloors],
    motion: &[Option<MotionConfig>],
    mut detector: Detector,
    labels: &Labels,
    mut publisher: Publisher,
) -> Result<()> {
    debug_assert_eq!(slots.len(), specs.len());
    debug_assert_eq!(floors.len(), specs.len());
    debug_assert_eq!(motion.len(), specs.len());
    let mut gates: Vec<Gate> = specs.iter().map(|_| Gate::default()).collect();

    for (index, sample) in Slots::new(slots) {
        let camera_id = &specs[index].id;
        // The epoch gate is per member too, inside the publisher: a camera
        // Cairn has not announced yet (or has stopped) emits nothing while its
        // neighbours keep going.
        let lines = gate::sample_line(
            &mut gates[index],
            &mut publisher,
            camera_id,
            motion[index],
            sample,
            Instant::now(),
            |input| detector.detect(input.tensor, input.projection, labels, &floors[index]),
        )?;
        // The frame first, and a status — which names this member, not the
        // group — after it, as in single mode.
        for line in [lines.objects, lines.status].into_iter().flatten() {
            emit::stdout_line(&line).context("writing to stdout")?;
        }
    }

    // Only reachable once every decode thread is gone, which they never do on
    // their own — so this is a real fault worth restarting the group for.
    bail!("every camera stream is gone")
}

/// One camera's single-sample handoff, newest wins.
///
/// The pending value lives in the mutex, not in the channel: a decode thread
/// that produces while inference is busy *replaces* the waiting sample rather
/// than keeping the stale one, so inference always runs on the freshest frame
/// that camera has produced. The bounded(1) channel carries only the wakeup,
/// which is why a redundant token is harmless — the taker just finds the slot
/// already emptied and waits again.
struct LatestSlot<T> {
    pending: Arc<Mutex<Option<T>>>,
    ready: Receiver<()>,
}

/// The producing half of a [`LatestSlot`], held by one decode thread.
struct LatestSink<T> {
    pending: Arc<Mutex<Option<T>>>,
    ready: Sender<()>,
}

fn slot_pair<T>() -> (LatestSlot<T>, LatestSink<T>) {
    let pending = Arc::new(Mutex::new(None));
    let (tx, rx) = bounded::<()>(1);
    (
        LatestSlot {
            pending: Arc::clone(&pending),
            ready: rx,
        },
        LatestSink { pending, ready: tx },
    )
}

impl<T> LatestSlot<T> {
    /// The pending value, if this wakeup was not already served.
    fn take(&self) -> Option<T> {
        lock(&self.pending).take()
    }
}

impl<T> LatestSink<T> {
    fn offer_value(&self, value: T) -> Result<bool> {
        let replaced = lock(&self.pending).replace(value).is_some();
        match self.ready.try_send(()) {
            // Full means the previous wakeup is still queued, which is
            // exactly what the taker needs to come back for this value.
            Ok(()) | Err(TrySendError::Full(())) => Ok(!replaced),
            Err(TrySendError::Disconnected(())) => bail!("inference thread is gone"),
        }
    }
}

impl SampleSink for LatestSink<Sample> {
    fn offer(&self, sample: Sample) -> Result<bool> {
        self.offer_value(sample)
    }
}

/// A poisoned slot only ever holds `Option<T>`; the panic that poisoned it is
/// already being reported by the thread that took it down.
fn lock<T>(pending: &Mutex<Option<T>>) -> std::sync::MutexGuard<'_, Option<T>> {
    pending.lock().unwrap_or_else(|e| e.into_inner())
}

/// The N slots, drained as samples arrive.
///
/// `Select` picks at random among the slots that are ready, so a busy camera
/// cannot starve a quiet one. A slot whose decode thread died (a panic — the
/// loop above never exits) is dropped from the set; iteration ends only when
/// every slot is gone.
struct Slots<'a, T> {
    slots: &'a [LatestSlot<T>],
    live: Vec<usize>,
}

impl<'a, T> Slots<'a, T> {
    fn new(slots: &'a [LatestSlot<T>]) -> Self {
        Self {
            slots,
            live: (0..slots.len()).collect(),
        }
    }
}

impl<T> Iterator for Slots<'_, T> {
    /// `(slot index, value)` — the index selects the camera's id and floors.
    type Item = (usize, T);

    fn next(&mut self) -> Option<Self::Item> {
        while !self.live.is_empty() {
            let mut select = Select::new();
            for &index in &self.live {
                select.recv(&self.slots[index].ready);
            }

            let operation = select.select();
            let position = operation.index();
            let slot = self.live[position];
            match operation.recv(&self.slots[slot].ready) {
                // A wakeup whose value was already collected alongside a
                // newer one leaves the slot empty: wait for the next.
                Ok(()) => {
                    if let Some(value) = self.slots[slot].take() {
                        return Some((slot, value));
                    }
                }
                Err(_) => {
                    eprintln!("camera slot {slot}: decode thread is gone");
                    self.live.remove(position);
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TWO: &str = r#"[{"id":"front","udp_port":17000,"min_score":{"default":0.4,"person":0.8}},
                          {"id":"drive","udp_port":17004,"min_score":{"default":0.9}}]"#;

    /// `floors_for` with the flag absent, which is every run Cairn launches
    /// today: no track floor anywhere, so the call cannot fail.
    fn no_track_floor(specs: &[CameraSpec]) -> Vec<ScoreFloors> {
        floors_for(specs, &TrackFloorOverrides::default())
            .expect("a group with no track floor has nothing to pair")
    }

    #[test]
    fn parses_the_member_array() {
        let specs = parse_specs(TWO).unwrap();
        assert_eq!(specs.len(), 2);
        assert_eq!(specs[0].id, "front");
        assert_eq!(specs[0].udp_port, 17_000);
        assert_eq!(specs[1].id, "drive");
        assert_eq!(specs[1].udp_port, 17_004);
    }

    #[test]
    fn min_score_is_optional() {
        let specs = parse_specs(r#"[{"id":"a","udp_port":17000}]"#).unwrap();
        assert!(specs[0].min_score.is_empty());
        assert_eq!(no_track_floor(&specs)[0].floor_for("person"), 0.5);
    }

    #[test]
    fn floors_are_selected_per_camera() {
        let floors = no_track_floor(&parse_specs(TWO).unwrap());
        assert_eq!(floors[0].floor_for("person"), 0.8);
        assert_eq!(floors[0].floor_for("car"), 0.4);
        assert_eq!(floors[1].floor_for("person"), 0.9);
        assert_eq!(floors[1].floor_for("car"), 0.9);
    }

    #[test]
    fn rejects_malformed_and_empty_input() {
        assert!(parse_specs("not json").is_err());
        assert!(parse_specs("[]").is_err());
        // an object, not an array of members
        assert!(parse_specs(r#"{"id":"a","udp_port":17000}"#).is_err());
        // missing required fields
        assert!(parse_specs(r#"[{"id":"a"}]"#).is_err());
        assert!(parse_specs(r#"[{"udp_port":17000}]"#).is_err());
        // a port that cannot be a u16
        assert!(parse_specs(r#"[{"id":"a","udp_port":170000}]"#).is_err());
        // min_score must stay label -> number
        assert!(parse_specs(r#"[{"id":"a","udp_port":1,"min_score":{"p":"high"}}]"#).is_err());
    }

    #[test]
    fn the_track_floor_key_is_optional_and_replaces_the_group_default() {
        let specs = parse_specs(
            r#"[{"id":"front","udp_port":17000,"min_score":{"default":0.5},
                 "track_floor":{"floor":0.25}},
                {"id":"drive","udp_port":17004,"min_score":{"default":0.5}}]"#,
        )
        .unwrap();
        let global = TrackFloorOverrides::parse(r#"{"floor":0.1}"#).unwrap();

        let floors = floors_for(&specs, &global).unwrap();
        assert_eq!(floors[0].emit_floor_for("person"), 0.25, "the member's own");
        assert_eq!(floors[1].emit_floor_for("person"), 0.1, "the group default");

        // ...and with no --track-floor-json the band is closed for every
        // member that did not open it itself.
        let floors = no_track_floor(&specs);
        assert_eq!(floors[0].emit_floor_for("person"), 0.25);
        assert_eq!(floors[1].emit_floor_for("person"), 0.5);
    }

    #[test]
    fn a_track_floor_a_member_cannot_honour_fails_the_group_by_name() {
        // A group is one failure domain and the floors are per member, so the
        // same `--track-floor-json` can be legal for one camera and not for
        // its neighbour. The message has to say which.
        let specs = parse_specs(
            r#"[{"id":"front","udp_port":17000,"min_score":{"default":0.5}},
                {"id":"drive","udp_port":17004,"min_score":{"default":0.2}}]"#,
        )
        .unwrap();
        let err = floors_for(
            &specs,
            &TrackFloorOverrides::parse(r#"{"floor":0.3}"#).unwrap(),
        )
        .unwrap_err();
        let err = format!("{err:#}");
        assert!(err.contains("drive"), "{err}");
        assert!(err.contains("0.2"), "{err}");

        // a member's own floor is checked against that member's floors too
        let specs = parse_specs(
            r#"[{"id":"front","udp_port":17000,"min_score":{"default":0.5},
                 "track_floor":{"floor":0.6}}]"#,
        )
        .unwrap();
        assert!(floors_for(&specs, &TrackFloorOverrides::default()).is_err());

        // and the range check is the earlier one, at parse time, where it
        // needs no floors to pair with
        assert!(parse_specs(r#"[{"id":"a","udp_port":1,"track_floor":{"floor":0}}]"#).is_err());
        assert!(parse_specs(r#"[{"id":"a","udp_port":1,"track_floor":{"flor":0.1}}]"#).is_err());
    }

    #[test]
    fn the_motion_key_is_optional_and_overrides_the_group_default() {
        let specs = parse_specs(
            r#"[{"id":"front","udp_port":17000,"motion":{"threshold":10}},
                {"id":"drive","udp_port":17004}]"#,
        )
        .unwrap();
        let global = MotionOverrides::parse(r#"{"enabled":true,"threshold":40}"#).unwrap();

        let motion = motion_for(&specs, &global);
        assert_eq!(motion[0].unwrap().threshold, 10, "the member's own value");
        assert_eq!(motion[1].unwrap().threshold, 40, "the group default");

        // ...and with no --motion-json the gate is off for every member, own
        // knobs or not.
        assert_eq!(
            motion_for(&specs, &MotionOverrides::default()),
            vec![None, None]
        );
    }

    #[test]
    fn a_member_can_switch_its_own_gate_on() {
        let specs =
            parse_specs(r#"[{"id":"a","udp_port":17000,"motion":{"enabled":true}}]"#).unwrap();
        assert!(motion_for(&specs, &MotionOverrides::default())[0].is_some());
    }

    #[test]
    fn rejects_out_of_range_member_motion_knobs() {
        // Refused for the whole group at startup, naming the member: one
        // camera's typo must not surface as that camera's decode thread
        // behaving oddly later.
        let err = parse_specs(r#"[{"id":"driveway","udp_port":1,"motion":{"alpha":2.0}}]"#)
            .unwrap_err()
            .to_string();
        assert!(err.contains("camera driveway"), "{err}");
        assert!(parse_specs(r#"[{"id":"a","udp_port":1,"motion":{"threshold":0}}]"#).is_err());
        assert!(parse_specs(r#"[{"id":"a","udp_port":1,"motion":{"thresh":10}}]"#).is_err());
    }

    #[test]
    fn rejects_duplicate_ids() {
        let json = r#"[{"id":"a","udp_port":17000},{"id":"a","udp_port":17004}]"#;
        assert!(parse_specs(json).is_err());
    }

    fn slots<T>(count: usize) -> (Vec<LatestSlot<T>>, Vec<LatestSink<T>>) {
        (0..count).map(|_| slot_pair::<T>()).unzip()
    }

    #[test]
    fn a_busy_slot_keeps_the_newest_value() {
        let (slots, sinks) = slots::<usize>(1);

        assert!(sinks[0].offer_value(1).unwrap(), "first offer is accepted");
        // the taker never woke: the second offer replaces the first
        assert!(
            !sinks[0].offer_value(2).unwrap(),
            "replaced a pending value"
        );
        assert!(
            !sinks[0].offer_value(3).unwrap(),
            "replaced a pending value"
        );

        let mut iter = Slots::new(&slots);
        assert_eq!(iter.next(), Some((0, 3)));

        // the replaced values left no extra wakeups behind
        drop(sinks);
        assert_eq!(iter.next(), None);
    }

    #[test]
    fn a_gone_producer_ends_its_slot() {
        let (slots, mut sinks) = slots::<usize>(1);
        drop(sinks.pop());

        assert_eq!(Slots::new(&slots).next(), None);
    }

    #[test]
    fn offering_to_a_gone_taker_is_an_error() {
        let (slots, sinks) = slots::<usize>(1);
        drop(slots);

        assert!(sinks[0].offer_value(1).is_err());
    }

    #[test]
    fn every_slot_is_drained() {
        let (slots, sinks) = slots::<usize>(4);
        for (index, sink) in sinks.iter().enumerate() {
            sink.offer_value(index).unwrap();
        }
        drop(sinks);

        let mut seen: Vec<(usize, usize)> = Slots::new(&slots).collect();
        seen.sort_unstable();
        assert_eq!(seen, vec![(0, 0), (1, 1), (2, 2), (3, 3)]);
    }

    #[test]
    fn a_dead_slot_does_not_stop_the_others() {
        let (slots, mut sinks) = slots::<usize>(3);
        // slot 1's producer is gone before it ever offers
        drop(sinks.remove(1));
        sinks[0].offer_value(10).unwrap();
        sinks[1].offer_value(20).unwrap();

        let mut iter = Slots::new(&slots);
        let mut seen = vec![iter.next().unwrap(), iter.next().unwrap()];
        seen.sort_unstable();
        assert_eq!(seen, vec![(0, 10), (2, 20)]);

        drop(sinks);
        assert_eq!(iter.next(), None);
    }

    #[test]
    fn samples_keep_arriving_while_a_camera_is_quiet() {
        let (slots, sinks) = slots::<usize>(3);
        let mut iter = Slots::new(&slots);

        // the quiet cameras never offer; the busy one must still be drained,
        // one value at a time so nothing is replaced under the taker
        for i in 0..20 {
            sinks[2].offer_value(i).unwrap();
            assert_eq!(iter.next(), Some((2, i)));
        }

        drop(sinks);
        assert_eq!(iter.next(), None);
    }
}
