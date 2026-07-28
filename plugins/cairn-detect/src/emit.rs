//! Protocol v1 ndjson writer (see `docs/plugin-contract.md`).
//!
//! Every line this module produces is a self-describing envelope —
//! `{"spec":"cairn.plugin","version":1,"type":...}` — and stdout carries
//! nothing else. Diagnostics go to stderr.
//!
//! The host revalidates everything here and bounds it again on its side, so
//! the caps below are not belt-and-braces: an `objects` list over the host's
//! cap drops the *whole* line, and a label the host refuses drops that
//! detection. Both are shaped here instead, where the detection that would
//! have been lost is still in hand.

use std::collections::HashMap;
use std::io::Write;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::control::Streams;

/// Cairn drops any line longer than this, so a too-long line is a lost
/// sample rather than a soft error — we shed detections to stay under it.
///
/// This is the contract's framing bound (`docs/plugin-contract.md` §Framing):
/// both host ports open the plugin with `{:line, 65_536}`.
pub const MAX_LINE_BYTES: usize = 65_536;

/// The host's `|pts| <= 2^62` bound. `av_rescale_q` saturates to `i64::MIN`
/// on overflow, whose magnitude is past this, and the host drops the *whole*
/// line for it — including the empty-`objects` liveness signal.
pub const MAX_PTS: i64 = 4_611_686_018_427_387_904;

/// What a label shapes down to when nothing printable survives. The host
/// requires 1..64 bytes, so an empty label costs the detection outright.
const FALLBACK_LABEL: &str = "object";

/// Host cap on one frame's `objects`; an over-cap list drops the line there,
/// so the list is cut here instead.
pub const MAX_OBJECTS: usize = 64;

/// Host cap on `label`, in bytes.
pub const MAX_LABEL_BYTES: usize = 64;

const SPEC: &str = "cairn.plugin";
const VERSION: u32 = 1;

/// The clock `pts` is expressed in — the RTP 90 kHz clock, which is also the
/// host's default when `time_base` is absent. Sent explicitly anyway: the
/// field is what makes a line readable without knowing the transport.
const TIME_BASE: [i64; 2] = [1, 90_000];

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Det {
    pub label: String,
    pub score: f64,
    pub bbox: [f64; 4],
}

// `observation_kind` is deliberately absent: the host defaults it to
// "detected", which is the only kind this plugin produces, and 64 copies of
// the field would add ~1.9 KB per line for nothing.
#[derive(Serialize)]
struct Objects<'a> {
    spec: &'static str,
    version: u32,
    #[serde(rename = "type")]
    kind: &'static str,
    camera_id: &'a str,
    stream_epoch: &'a str,
    sequence: u64,
    frame: Frame<'a>,
    objects: &'a [Det],
}

#[derive(Serialize)]
struct Frame<'a> {
    pts: i64,
    time_base: [i64; 2],
    observed_at: &'a str,
}

#[derive(Serialize)]
struct Hello {
    spec: &'static str,
    version: u32,
    #[serde(rename = "type")]
    kind: &'static str,
    hello: HelloBody,
}

#[derive(Serialize)]
struct HelloBody {
    name: &'static str,
    version: &'static str,
    supported_versions: [u32; 1],
    capabilities: Capabilities,
}

#[derive(Serialize)]
struct Capabilities {
    /// Detection-only: every object is a fresh observation with no identity
    /// carried across frames, so the host runs its own tracker.
    object_tracking: bool,
}

#[derive(Serialize)]
struct Status<'a> {
    spec: &'static str,
    version: u32,
    #[serde(rename = "type")]
    kind: &'static str,
    /// Absent means "the whole process": a group host applies it to every
    /// member. Naming a camera targets that member alone.
    #[serde(skip_serializing_if = "Option::is_none")]
    camera_id: Option<&'a str>,
    status: StatusBody<'a>,
}

#[derive(Serialize)]
struct StatusBody<'a> {
    state: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<&'a str>,
}

/// The startup announcement, sent before anything that can take time.
pub fn hello_line() -> String {
    serialize(&Hello {
        spec: SPEC,
        version: VERSION,
        kind: "plugin.hello",
        hello: HelloBody {
            name: "cairn-detect",
            version: env!("CARGO_PKG_VERSION"),
            supported_versions: [VERSION],
            capabilities: Capabilities {
                object_tracking: false,
            },
        },
    })
}

/// A lifecycle status. The host rate-limits these to change-or-heartbeat, so
/// they are sent on transitions only, never per frame.
pub fn status_line(camera_id: Option<&str>, state: &str, detail: Option<&str>) -> String {
    serialize(&Status {
        spec: SPEC,
        version: VERSION,
        kind: "plugin.status",
        camera_id,
        status: StatusBody { state, detail },
    })
}

/// Serialize one `frame.objects` line, shedding the lowest-scoring
/// detections until it fits the byte budget. Returns the line and how many
/// objects survived.
///
/// Detections arrive sorted by score, so both the cap and the truncation drop
/// the least interesting ones. A line with zero objects is emitted even if it
/// somehow still exceeds the budget: a valid oversized line is dropped by
/// Cairn, a truncated one would be malformed for every consumer.
///
/// At 64 shaped objects a full line runs to roughly 11 KB, so the shedding
/// loop is a guard on the framing bound rather than a routine path.
pub fn objects_line(
    camera_id: &str,
    stream_epoch: &str,
    sequence: u64,
    pts: i64,
    observed_at: &str,
    dets: &[Det],
) -> (String, usize) {
    let mut kept = dets.len().min(MAX_OBJECTS);
    loop {
        let json = serialize(&Objects {
            spec: SPEC,
            version: VERSION,
            kind: "frame.objects",
            camera_id,
            stream_epoch,
            sequence,
            frame: Frame {
                pts,
                time_base: TIME_BASE,
                observed_at,
            },
            objects: &dets[..kept],
        });
        // `<=`: Cairn reads with erlang line mode `{:line, 65_536}`, whose
        // limit applies to the line data excluding the newline delimiter and
        // is inclusive — a payload of exactly 65 536 bytes still arrives as
        // one `{:eol, _}`, and only 65 537 splits.
        if kept == 0 || json.len() <= MAX_LINE_BYTES {
            return (json, kept);
        }
        kept -= 1;
    }
}

/// Write one protocol line, newline-terminated and flushed.
///
/// Flushing per line is the contract: the host is reading a pipe and a
/// buffered detection is an undelivered one.
pub fn write_line(out: &mut impl Write, line: &str) -> std::io::Result<()> {
    out.write_all(line.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()
}

/// Write one protocol line to stdout, taking the lock only for that write.
///
/// The lock is never held across calls: `plugin.status` is written from the
/// main thread while the inference thread is emitting frames, and a held
/// `StdoutLock` would park one of them for the life of the process.
pub fn stdout_line(line: &str) -> std::io::Result<()> {
    write_line(&mut std::io::stdout().lock(), line)
}

/// The per-camera output state every `frame.objects` line needs: the epoch
/// the host is currently expecting, and this camera's sequence counter.
///
/// One publisher serves the whole process — a single inference thread emits
/// for every camera in group mode — so the counters live in a map rather
/// than in a per-camera struct.
pub struct Publisher {
    streams: Arc<Streams>,
    sequences: HashMap<String, u64>,
    ungated: u64,
    unbounded_pts: u64,
}

impl Publisher {
    pub fn new(streams: Arc<Streams>) -> Self {
        Self {
            streams,
            sequences: HashMap::new(),
            ungated: 0,
            unbounded_pts: 0,
        }
    }

    /// The line to write for one frame, or `None` when this camera has no
    /// epoch yet.
    ///
    /// A frame decoded before the host's first `stream.started` for its
    /// camera produces no output at all. There is no epoch to put on it that
    /// the host would accept: it compares every line's `stream_epoch` against
    /// its own table and drops the mismatches as stale, so an invented or
    /// omitted one is a line thrown away after being paid for. Decoding
    /// continues throughout — the first control line simply starts the
    /// output. It is also the normal state for a member whose camera is
    /// stopped, which is why it is counted rather than escalated.
    ///
    /// The sequence counter advances only for lines actually emitted: the
    /// host reads a jump as frames lost between us and it, and a suppressed
    /// frame was never on the wire to lose.
    ///
    /// A `pts` outside the host's ±2^62 is refused the same way. It means the
    /// rescale from the stream's time base overflowed (`av_rescale_q`
    /// saturates to `i64::MIN`), so the timestamp is not a timestamp; the
    /// host would drop the line whole for it anyway.
    pub fn line_for(
        &mut self,
        camera_id: &str,
        pts: i64,
        observed_at: SystemTime,
        dets: &[Det],
    ) -> Option<String> {
        let Some(epoch) = self.streams.epoch_of(camera_id) else {
            self.ungated += 1;
            if self.ungated.is_multiple_of(100) || self.ungated == 1 {
                eprintln!(
                    "camera {camera_id}: no stream epoch yet, \
                     {} frame(s) not emitted so far",
                    self.ungated
                );
            }
            return None;
        };

        // `(-MAX..=MAX)`, not `pts.abs()`: `i64::MIN.abs()` is itself an
        // overflow, and `i64::MIN` is exactly the saturated value at issue.
        if !(-MAX_PTS..=MAX_PTS).contains(&pts) {
            self.unbounded_pts += 1;
            if self.unbounded_pts.is_multiple_of(100) || self.unbounded_pts == 1 {
                eprintln!(
                    "camera {camera_id}: pts {pts} is outside the contract's +-2^62, \
                     {} frame(s) not emitted so far",
                    self.unbounded_pts
                );
            }
            return None;
        }

        let sequence = self.sequences.entry(camera_id.to_string()).or_insert(0);
        let (json, kept) = objects_line(
            camera_id,
            &epoch,
            *sequence,
            pts,
            &rfc3339_utc(observed_at),
            dets,
        );
        *sequence += 1;

        if kept < dets.len() {
            eprintln!(
                "camera {camera_id}: line budget dropped {} of {} objects at pts {pts}",
                dets.len() - kept,
                dets.len()
            );
        }
        Some(json)
    }
}

/// Shape a label into what the host accepts: non-empty, printable, at most
/// [`MAX_LABEL_BYTES`] bytes.
///
/// Labels come from the user's `--labels` file, which is arbitrary text. The
/// host refuses a label with control bytes or over its cap and drops that
/// detection, so the trimming happens here where the detection survives it.
/// A line of nothing but control bytes survives `Labels::load`'s `trim`
/// (which only strips whitespace) and would shape down to `""`, which the
/// host refuses just as hard — so it becomes [`FALLBACK_LABEL`] instead.
pub fn shape_label(label: &str) -> String {
    let cleaned: String = label.chars().filter(|c| !c.is_control()).collect();
    let end = cleaned
        .char_indices()
        .map(|(i, c)| i + c.len_utf8())
        .take_while(|&end| end <= MAX_LABEL_BYTES)
        .last()
        .unwrap_or(0);
    if end == 0 {
        return FALLBACK_LABEL.to_string();
    }
    cleaned[..end].to_string()
}

/// Wall-clock instant as RFC3339 UTC with millisecond precision.
///
/// Rolled by hand rather than pulled in as a dependency: this is the only
/// date arithmetic in the crate. A clock before the epoch (an unset RTC on a
/// cold-booted SBC) formats as the epoch itself rather than failing — the
/// host wants a parseable timestamp, and a wrong one is visible in the data
/// where a dropped line is not.
pub fn rfc3339_utc(at: SystemTime) -> String {
    let since_epoch = at.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = since_epoch.as_secs() as i64;
    let millis = since_epoch.subsec_millis();
    let (year, month, day) = civil_from_days(secs.div_euclid(86_400));
    let second_of_day = secs.rem_euclid(86_400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        second_of_day / 3600,
        (second_of_day % 3600) / 60,
        second_of_day % 60,
    )
}

/// Days since 1970-01-01 -> proleptic Gregorian `(year, month, day)`.
///
/// Hinnant's `civil_from_days`: the era arithmetic works on any day number,
/// including negative ones, without a leap-year table.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    // Shift the epoch to 0000-03-01 so leap days land at the end of the year.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

fn serialize<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("a protocol line is always serializable")
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPOCH: &str = "01K1B2C3D4E5F6G7H8J9K0M1N2";
    const AT: &str = "2026-07-26T12:34:56.789Z";

    fn det(label: &str, score: f64) -> Det {
        Det {
            label: label.to_string(),
            score,
            bbox: [0.1234, 0.5678, 0.25, 0.5],
        }
    }

    fn objects(dets: &[Det]) -> (String, usize) {
        objects_line("front_door", EPOCH, 7, 90_000, AT, dets)
    }

    fn parse(json: &str) -> serde_json::Value {
        serde_json::from_str(json).expect("emitted line is valid json")
    }

    #[test]
    fn emits_the_v1_envelope() {
        let (json, kept) = objects(&[det("person", 0.87)]);
        assert_eq!(kept, 1);
        assert_eq!(
            json,
            concat!(
                r#"{"spec":"cairn.plugin","version":1,"type":"frame.objects","#,
                r#""camera_id":"front_door","stream_epoch":"01K1B2C3D4E5F6G7H8J9K0M1N2","#,
                r#""sequence":7,"frame":{"pts":90000,"time_base":[1,90000],"#,
                r#""observed_at":"2026-07-26T12:34:56.789Z"},"#,
                r#""objects":[{"label":"person","score":0.87,"bbox":[0.1234,0.5678,0.25,0.5]}]}"#,
            )
        );
    }

    #[test]
    fn an_empty_frame_is_still_a_line() {
        // The host reads an empty `objects` list as "this camera is alive and
        // saw nothing", which is what keeps liveness separate from silence.
        let (json, kept) = objects(&[]);
        assert_eq!(kept, 0);
        assert_eq!(parse(&json)["objects"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn pts_and_sequence_carry_the_full_contract_range() {
        // The host bounds both at +-2^62 and drops anything past it.
        const MAX: i64 = 4_611_686_018_427_387_904;
        for pts in [-MAX, 0, MAX] {
            let (json, _) = objects_line("cam", EPOCH, MAX as u64, pts, AT, &[]);
            let value = parse(&json);
            assert_eq!(value["frame"]["pts"].as_i64(), Some(pts));
            assert_eq!(value["sequence"].as_u64(), Some(MAX as u64));
        }
    }

    #[test]
    fn objects_are_capped_at_the_host_limit() {
        // Over the cap the host drops the whole line, so the cut happens here
        // — and short labels keep the byte budget out of it.
        let dets: Vec<Det> = (0..MAX_OBJECTS + 20)
            .map(|i| det("p", 0.9 - 0.001 * i as f64))
            .collect();
        let (json, kept) = objects(&dets);
        assert_eq!(kept, MAX_OBJECTS);
        assert_eq!(
            parse(&json)["objects"].as_array().unwrap().len(),
            MAX_OBJECTS
        );
    }

    #[test]
    fn a_full_shaped_frame_is_nowhere_near_the_framing_bound() {
        // 64 objects with capped labels and full-precision f64s — the worst
        // line `det_from` can produce — against the contract's 64 KiB. The
        // shedding loop below is a guard, not a working part of the emit path.
        let dets: Vec<Det> = (0..MAX_OBJECTS)
            .map(|i| Det {
                label: "x".repeat(MAX_LABEL_BYTES),
                score: 0.8123456789012345 - f64::from(i as u32) * 1e-16,
                bbox: [0.1234567890123456; 4],
            })
            .collect();

        let (json, kept) = objects(&dets);
        assert_eq!(kept, MAX_OBJECTS);
        assert!(json.len() < MAX_LINE_BYTES / 4, "{} bytes", json.len());
    }

    #[test]
    fn sheds_objects_to_fit_the_byte_budget() {
        // Reaching the guard takes labels no shaped detection carries: a
        // 64-byte cap times 64 objects cannot fill 64 KiB on its own.
        let dets: Vec<Det> = (0..MAX_OBJECTS)
            .map(|i| Det {
                label: "x".repeat(2_000),
                score: 0.8123456789012345 - f64::from(i as u32) * 1e-16,
                bbox: [0.1234567890123456; 4],
            })
            .collect();

        let (json, kept) = objects(&dets);
        assert!(
            kept > 0 && kept < dets.len(),
            "shed some but not all: {kept}"
        );
        assert!(json.len() <= MAX_LINE_BYTES);
        parse(&json);
    }

    #[test]
    fn writes_one_flushed_line() {
        let mut out = Vec::new();
        write_line(&mut out, &objects(&[det("car", 0.5)]).0).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches('\n').count(), 1);
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn hello_declares_v1_and_detection_only() {
        let value = parse(&hello_line());
        assert_eq!(value["spec"], "cairn.plugin");
        assert_eq!(value["version"], 1);
        assert_eq!(value["type"], "plugin.hello");
        assert_eq!(value["hello"]["name"], "cairn-detect");
        assert_eq!(value["hello"]["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(value["hello"]["supported_versions"], serde_json::json!([1]));
        assert_eq!(value["hello"]["capabilities"]["object_tracking"], false);
    }

    #[test]
    fn a_status_without_a_camera_omits_the_field() {
        // Group hosts read an absent `camera_id` as "every member".
        let value = parse(&status_line(None, "ready", None));
        assert_eq!(value["type"], "plugin.status");
        assert!(value.get("camera_id").is_none());
        assert_eq!(value["status"]["state"], "ready");
        assert!(value["status"].get("detail").is_none());
    }

    #[test]
    fn a_status_can_target_one_camera_and_carry_detail() {
        let value = parse(&status_line(
            Some("front_door"),
            "starting",
            Some("loading model"),
        ));
        assert_eq!(value["camera_id"], "front_door");
        assert_eq!(value["status"]["state"], "starting");
        assert_eq!(value["status"]["detail"], "loading model");
    }

    #[test]
    fn labels_are_trimmed_to_what_the_host_accepts() {
        assert_eq!(shape_label("person"), "person");
        // control bytes would reach an operator's terminal; the host refuses
        // the detection outright, so they are stripped rather than kept
        assert_eq!(shape_label("per\u{1b}[31mson\n"), "per[31mson");
        assert_eq!(shape_label(&"a".repeat(100)).len(), MAX_LABEL_BYTES);
        // truncation lands on a char boundary, never mid-codepoint
        let wide = shape_label(&"é".repeat(100));
        assert!(wide.len() <= MAX_LABEL_BYTES);
        assert_eq!(wide.chars().count(), MAX_LABEL_BYTES / 2);
        // a labels line of pure control bytes survives `Labels::load`'s trim;
        // shaping it to "" would lose the detection the shaping exists to keep
        assert_eq!(shape_label("\u{1}\u{2}"), FALLBACK_LABEL);
        assert_eq!(shape_label(""), FALLBACK_LABEL);
    }

    #[test]
    fn formats_rfc3339_utc() {
        let at = |secs, nanos| UNIX_EPOCH + std::time::Duration::new(secs, nanos);
        assert_eq!(rfc3339_utc(at(0, 0)), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            rfc3339_utc(at(1_769_431_496, 789_000_000)),
            "2026-01-26T12:44:56.789Z"
        );
        // a leap day, and the last second of a year
        assert_eq!(
            rfc3339_utc(at(1_709_208_000, 0)),
            "2024-02-29T12:00:00.000Z"
        );
        assert_eq!(
            rfc3339_utc(at(1_735_689_599, 0)),
            "2024-12-31T23:59:59.000Z"
        );
        // a clock behind the epoch degrades to the epoch instead of panicking
        assert_eq!(
            rfc3339_utc(UNIX_EPOCH - std::time::Duration::from_secs(60)),
            "1970-01-01T00:00:00.000Z"
        );
    }

    mod publisher {
        use super::*;
        use crate::control::Control;

        const OTHER: &str = "01K1B2C3D4E5F6G7H8J9K0M1N3";

        fn publisher(camera_ids: &[&str]) -> (Arc<Streams>, Publisher) {
            let streams = Arc::new(Streams::new(camera_ids.iter().copied()));
            (Arc::clone(&streams), Publisher::new(streams))
        }

        fn start(streams: &Streams, camera_id: &str, epoch: &str) {
            streams.apply(Control::Started {
                camera_id: camera_id.to_string(),
                stream_epoch: epoch.to_string(),
            });
        }

        fn end(streams: &Streams, camera_id: &str, epoch: &str) {
            streams.apply(Control::Ended {
                camera_id: camera_id.to_string(),
                stream_epoch: epoch.to_string(),
            });
        }

        fn publish(publisher: &mut Publisher, camera_id: &str) -> Option<serde_json::Value> {
            publish_pts(publisher, camera_id, 900)
        }

        fn publish_pts(
            publisher: &mut Publisher,
            camera_id: &str,
            pts: i64,
        ) -> Option<serde_json::Value> {
            publisher
                .line_for(camera_id, pts, SystemTime::UNIX_EPOCH, &[])
                .map(|json| parse(&json))
        }

        #[test]
        fn a_pts_outside_the_contract_range_is_refused_whole() {
            // `av_rescale_q` saturates to `i64::MIN` on overflow; emitting it
            // costs the host the whole line, liveness signal included.
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);

            for pts in [i64::MIN, i64::MAX, MAX_PTS + 1, -MAX_PTS - 1] {
                assert!(publish_pts(&mut publisher, "front", pts).is_none(), "{pts}");
            }
            // the bounds themselves are emittable, and nothing above consumed
            // a sequence number: a frame never on the wire cannot be a gap
            for pts in [-MAX_PTS, MAX_PTS] {
                let line = publish_pts(&mut publisher, "front", pts).unwrap();
                assert_eq!(line["frame"]["pts"].as_i64(), Some(pts));
            }
            assert_eq!(publish(&mut publisher, "front").unwrap()["sequence"], 2);
        }

        #[test]
        fn a_frame_before_the_first_stream_started_produces_nothing() {
            let (streams, mut publisher) = publisher(&["front"]);
            assert!(publish(&mut publisher, "front").is_none());

            start(&streams, "front", EPOCH);
            assert!(publish(&mut publisher, "front").is_some());
        }

        #[test]
        fn a_suppressed_frame_does_not_consume_a_sequence_number() {
            // A gap would read host-side as frames lost in transit; nothing
            // was ever on the wire to lose.
            let (streams, mut publisher) = publisher(&["front"]);
            for _ in 0..5 {
                assert!(publish(&mut publisher, "front").is_none());
            }

            start(&streams, "front", EPOCH);
            assert_eq!(publish(&mut publisher, "front").unwrap()["sequence"], 0);
        }

        #[test]
        fn sequences_start_at_zero_and_run_per_camera() {
            let (streams, mut publisher) = publisher(&["front", "drive"]);
            start(&streams, "front", EPOCH);
            start(&streams, "drive", OTHER);

            for expected in 0..3u64 {
                let line = publish(&mut publisher, "front").unwrap();
                assert_eq!(line["sequence"], expected);
                assert_eq!(line["stream_epoch"], EPOCH);
            }
            // the busy camera's count never leaks into the quiet one's
            let line = publish(&mut publisher, "drive").unwrap();
            assert_eq!(line["sequence"], 0);
            assert_eq!(line["stream_epoch"], OTHER);
            assert_eq!(line["camera_id"], "drive");

            assert_eq!(publish(&mut publisher, "front").unwrap()["sequence"], 3);
        }

        #[test]
        fn lines_follow_the_epoch_across_a_stream_bounce() {
            let (streams, mut publisher) = publisher(&["front"]);
            start(&streams, "front", EPOCH);
            assert_eq!(
                publish(&mut publisher, "front").unwrap()["stream_epoch"],
                EPOCH
            );

            // the host's bounce: ended, then a silent window, then started
            end(&streams, "front", EPOCH);
            assert!(publish(&mut publisher, "front").is_none());

            start(&streams, "front", OTHER);
            let line = publish(&mut publisher, "front").unwrap();
            assert_eq!(line["stream_epoch"], OTHER);
            // the counter is per camera, not per epoch: it keeps climbing
            assert_eq!(line["sequence"], 1);
        }
    }

    #[test]
    fn observed_at_round_trips_through_the_envelope() {
        let now = SystemTime::now();
        let stamp = rfc3339_utc(now);
        let (json, _) = objects_line("cam", EPOCH, 0, 0, &stamp, &[]);
        assert_eq!(parse(&json)["frame"]["observed_at"], stamp);
    }
}
