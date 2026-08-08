//! The control channel: Cairn's protocol v1 lines on our stdin.
//!
//! Cairn tells a plugin which *stream epoch* each camera's frames belong to.
//! An epoch is a ULID minted per ffmpeg run: it changes whenever a camera's
//! stream restarts, and the host drops any `frame.objects` line whose epoch
//! is not the one currently in its own table. So a camera's epoch is not
//! decoration — it is the routing key that decides whether our work is
//! counted at all, and the only place it can come from is this channel.
//!
//! ```text
//! {"spec":"cairn.plugin","version":1,"type":"stream.started",
//!  "camera_id":"front_door","stream_epoch":"01K…","rtp":{"clock_rate":90000}}
//! {"spec":"cairn.plugin","version":1,"type":"stream.ended",
//!  "camera_id":"front_door","stream_epoch":"01K…","reason":"restarted"}
//! ```
//!
//! Both modes read the same lines: the per-camera host sends them for its one
//! camera, and a group host tags every line with the member it is about.
//!
//! Reading happens on a dedicated thread that does nothing else, because the
//! host writes with `:nosuspend` — a plugin that stops draining its stdin does
//! not block the host, it silently *loses* the epoch announcements, and then
//! every line it emits is discarded as stale.

use std::collections::HashMap;
use std::io::BufRead;
use std::sync::{Arc, Mutex};
use std::thread;

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::note;

/// A control line long enough to be a mistake rather than a message. The
/// host's own lines are a few hundred bytes; past this the line is skipped
/// instead of parsed. This bounds the parse, not the read — stdin is the
/// host's own pipe, not a network peer, so bounding the read is machinery
/// without a threat to spend it on.
const MAX_CONTROL_LINE: usize = 64 * 1024;

/// What one parsed control line asks of us.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Control {
    Started {
        camera_id: String,
        stream_epoch: String,
    },
    Ended {
        camera_id: String,
        stream_epoch: String,
    },
    /// Well-formed and not ours to act on — a future message type, another
    /// protocol version. Forward compatibility is one-directional: we ignore
    /// what we do not understand rather than failing on it.
    Ignored,
}

/// Only the fields this plugin acts on; the host sends more (`rtp`,
/// `reason`) and may grow others.
#[derive(Deserialize)]
struct Raw {
    spec: Option<String>,
    version: Option<u32>,
    #[serde(rename = "type")]
    kind: Option<String>,
    camera_id: Option<String>,
    stream_epoch: Option<String>,
}

/// Parse one control line.
///
/// `Err` is a line that claims to be a v1 `stream.*` message but is missing
/// what that message means; everything else is [`Control::Ignored`].
pub fn parse(line: &str) -> Result<Control> {
    let raw: Raw = serde_json::from_str(line).context("control line is not a JSON object")?;
    if raw.spec.as_deref() != Some("cairn.plugin") || raw.version != Some(1) {
        return Ok(Control::Ignored);
    }
    let kind = raw.kind.as_deref().unwrap_or_default();
    if kind != "stream.started" && kind != "stream.ended" {
        return Ok(Control::Ignored);
    }

    let camera_id = non_empty(raw.camera_id).context("stream event without a camera_id")?;
    let stream_epoch =
        non_empty(raw.stream_epoch).context("stream event without a stream_epoch")?;
    Ok(if kind == "stream.started" {
        Control::Started {
            camera_id,
            stream_epoch,
        }
    } else {
        Control::Ended {
            camera_id,
            stream_epoch,
        }
    })
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.is_empty())
}

/// The current stream epoch of every camera this process serves.
///
/// Written by the control thread, read by the inference thread on every
/// frame. The map's key set is fixed at construction from the argv roster, so
/// a control line naming a camera we do not serve is a diagnostic rather than
/// an entry that grows the map.
pub struct Streams {
    epochs: Mutex<HashMap<String, Option<String>>>,
}

impl Streams {
    pub fn new<I, S>(camera_ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            epochs: Mutex::new(camera_ids.into_iter().map(|id| (id.into(), None)).collect()),
        }
    }

    /// The epoch to tag this camera's frames with, or `None` before its first
    /// `stream.started`.
    pub fn epoch_of(&self, camera_id: &str) -> Option<String> {
        self.lock().get(camera_id).cloned().flatten()
    }

    /// Fold one control line into the map.
    ///
    /// `stream.ended` clears the epoch only when it names the one currently
    /// held. The host always writes `ended(prior)` immediately before
    /// `started(next)`, but the pair is not atomic from here — honouring a
    /// stale `ended` would blank an epoch we had just been given and silence
    /// the camera until its next restart.
    pub fn apply(&self, event: Control) {
        let (camera_id, epoch, started) = match event {
            Control::Started {
                camera_id,
                stream_epoch,
            } => (camera_id, stream_epoch, true),
            Control::Ended {
                camera_id,
                stream_epoch,
            } => (camera_id, stream_epoch, false),
            Control::Ignored => return,
        };

        // The map moves first; the log line is written after the guard drops.
        // Stderr here is the host's append-redirect into a log file, so a write
        // can block for as long as the disk takes — and this lock is taken once
        // per frame by the inference thread, which would stall behind it.
        // ([`crate::note!`] is what keeps a *failed* write from being worse than that.)
        let announcement = {
            let mut epochs = self.lock();
            match epochs.get_mut(&camera_id) {
                None => Some(format!(
                    "control: ignoring a stream event for unserved camera {camera_id}"
                )),
                Some(held) if started => {
                    let changed = held.as_deref() != Some(epoch.as_str());
                    *held = Some(epoch.clone());
                    changed.then(|| format!("camera {camera_id}: stream epoch {epoch}"))
                }
                Some(held) if held.as_deref() == Some(epoch.as_str()) => {
                    *held = None;
                    Some(format!("camera {camera_id}: stream epoch {epoch} ended"))
                }
                Some(_stale_end) => None,
            }
        };

        if let Some(message) = announcement {
            note!("{message}");
        }
    }

    /// A poisoned map only ever holds ids and epochs; the panic that poisoned
    /// it is already being reported by the thread that took it down.
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Option<String>>> {
        self.epochs.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Start the control thread. It owns stdin for the life of the process.
///
/// The thread ending — EOF, a read error, or a panic — ends the *process*.
/// Without that the epoch map freezes: a stream bounce is never learned, and
/// every line emitted afterwards is discarded host-side as `stale_epoch`
/// while this process stays alive and keeps the accelerator busy. Neither
/// `Cairn.PluginPort` nor `Cairn.PluginGroupPort` watches for that; both
/// respawn on exit, which is why exiting is the recovery.
pub fn spawn_reader(streams: Arc<Streams>) -> Result<()> {
    thread::Builder::new()
        .name("control".into())
        .spawn(move || {
            // `catch_unwind` rather than `panic = "abort"`: the release
            // profile is shared with the inference thread, whose panic is
            // reported with a diagnostic worth keeping. `Streams::lock`
            // absorbs poisoning, so nothing here is left unsound by an
            // unwind.
            let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                read_loop(&streams, std::io::stdin().lock());
            }))
            .is_err();
            let cause = if panicked { "panicked" } else { "stdin closed" };
            note!("control: control channel gone ({cause}), exiting so Cairn respawns us");
            // `_exit`, not `process::exit`, because this fires on a thread while
            // the main thread may be anywhere — including inside onnxruntime's
            // session constructor. `spawn_reader` is called *before* the model
            // load on purpose (an unread pipe drops the `stream.started` lines
            // Cairn writes at spawn), so that overlap is the normal case, not a
            // corner. `process::exit` runs atexit handlers and C++ static
            // destructors, and doing that under a half-built session killed
            // roughly 40% of runs with SIGSEGV and gave the rest a fabricated
            // error such as `Invalid tensor data type 3` (#19).
            //
            // `_exit` ends the process at the kernel and runs no user-space
            // teardown at all, which is what makes it safe from any thread at
            // any time. Nothing is lost by skipping the flush: `emit::write_line`
            // flushes every protocol line as it writes it — the host is reading a
            // pipe and a buffered detection is an undelivered one — and stderr
            // is unbuffered, which is what [`crate::note!`] writes to.
            //
            // Non-zero: this is an abnormal end, and the host logs the status.
            //
            // SAFETY: `_exit` is async-signal-safe and terminates immediately.
            // It touches no Rust state, so there is nothing for another thread
            // to observe half-done.
            unsafe { libc::_exit(3) };
        })
        .context("spawning the control thread")?;
    Ok(())
}

/// Drain control lines until stdin closes.
///
/// A malformed line is logged and skipped: the host is trusted to frame its
/// own writes, and one bad line must not cost every epoch announcement after
/// it. Returning at all — closed stdin, or a read error — means no epoch will
/// ever change again, which [`spawn_reader`] turns into a process exit.
pub fn read_loop(streams: &Streams, input: impl BufRead) {
    let mut malformed: u64 = 0;
    for line in input.lines() {
        let line = match line {
            Ok(line) => line,
            Err(e) => {
                note!("control: stdin read failed: {e}");
                return;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line.len() > MAX_CONTROL_LINE {
            note!("control: skipping a {}-byte line", line.len());
            continue;
        }

        match parse(line) {
            Ok(event) => streams.apply(event),
            Err(e) => {
                malformed += 1;
                if malformed.is_multiple_of(50) || malformed == 1 {
                    note!("control: malformed line ({malformed} so far): {e:#}");
                }
            }
        }
    }
    note!("control: stdin closed");
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "01K1B2C3D4E5F6G7H8J9K0M1N2";
    const B: &str = "01K1B2C3D4E5F6G7H8J9K0M1N3";

    /// Byte-for-byte what `Cairn.PluginGroupPort.stream_started/2` writes.
    fn started(camera_id: &str, epoch: &str) -> String {
        format!(
            r#"{{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"{camera_id}","stream_epoch":"{epoch}","rtp":{{"clock_rate":90000}}}}"#
        )
    }

    fn ended(camera_id: &str, epoch: &str) -> String {
        format!(
            r#"{{"spec":"cairn.plugin","version":1,"type":"stream.ended","camera_id":"{camera_id}","stream_epoch":"{epoch}","reason":"restarted"}}"#
        )
    }

    fn streams() -> Streams {
        Streams::new(["front", "drive"])
    }

    fn apply(streams: &Streams, line: &str) {
        streams.apply(parse(line).expect("a well-formed control line"));
    }

    #[test]
    fn parses_the_host_stream_events() {
        assert_eq!(
            parse(&started("front", A)).unwrap(),
            Control::Started {
                camera_id: "front".into(),
                stream_epoch: A.into(),
            }
        );
        assert_eq!(
            parse(&ended("front", A)).unwrap(),
            Control::Ended {
                camera_id: "front".into(),
                stream_epoch: A.into(),
            }
        );
    }

    #[test]
    fn ignores_what_it_does_not_understand() {
        // another spec, another protocol version, a message type from a later
        // revision — all forward compatibility, none of them errors
        for line in [
            r#"{"spec":"something.else","version":1,"type":"stream.started"}"#,
            r#"{"spec":"cairn.plugin","version":2,"type":"stream.started"}"#,
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.hint"}"#,
            r#"{"hello":"world"}"#,
        ] {
            assert_eq!(parse(line).unwrap(), Control::Ignored, "{line}");
        }
    }

    #[test]
    fn rejects_a_stream_event_missing_its_routing() {
        for line in [
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.started","stream_epoch":"01K"}"#,
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"front"}"#,
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.ended","camera_id":"","stream_epoch":"01K"}"#,
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.ended","camera_id":"front","stream_epoch":""}"#,
            "not json at all",
        ] {
            assert!(parse(line).is_err(), "{line}");
        }
    }

    #[test]
    fn a_camera_has_no_epoch_until_its_first_start() {
        let streams = streams();
        assert_eq!(streams.epoch_of("front"), None);

        apply(&streams, &started("front", A));
        assert_eq!(streams.epoch_of("front"), Some(A.to_string()));
    }

    #[test]
    fn each_camera_keeps_its_own_epoch() {
        let streams = streams();
        apply(&streams, &started("front", A));
        apply(&streams, &started("drive", B));

        assert_eq!(streams.epoch_of("front"), Some(A.to_string()));
        assert_eq!(streams.epoch_of("drive"), Some(B.to_string()));
    }

    #[test]
    fn a_restart_replaces_the_epoch() {
        let streams = streams();
        // the host's own sequence for a bounce: end the old, start the new
        apply(&streams, &started("front", A));
        apply(&streams, &ended("front", A));
        assert_eq!(streams.epoch_of("front"), None);

        apply(&streams, &started("front", B));
        assert_eq!(streams.epoch_of("front"), Some(B.to_string()));
        // the other member is untouched by its neighbour's bounce
        assert_eq!(streams.epoch_of("drive"), None);
    }

    #[test]
    fn a_stale_end_does_not_blank_the_current_epoch() {
        let streams = streams();
        apply(&streams, &started("front", A));
        apply(&streams, &started("front", B));

        apply(&streams, &ended("front", A));
        assert_eq!(streams.epoch_of("front"), Some(B.to_string()));
    }

    #[test]
    fn a_camera_stop_leaves_the_member_without_an_epoch() {
        // `:camera_stopped` mints an epoch nothing streams under: the host
        // sends the `ended` and no matching `started`.
        let streams = streams();
        apply(&streams, &started("front", A));
        apply(&streams, &ended("front", A));

        assert_eq!(streams.epoch_of("front"), None);
    }

    #[test]
    fn an_unserved_camera_never_enters_the_map() {
        let streams = streams();
        apply(&streams, &started("stranger", A));

        assert_eq!(streams.epoch_of("stranger"), None);
        assert_eq!(streams.lock().len(), 2);
    }

    #[test]
    fn the_read_loop_drains_every_line_past_bad_ones() {
        let streams = streams();
        let input = format!(
            "{}\n\nnot json\n{}\n{}\n",
            started("front", A),
            r#"{"spec":"cairn.plugin","version":1,"type":"stream.hint"}"#,
            started("drive", B),
        );

        read_loop(&streams, input.as_bytes());

        assert_eq!(streams.epoch_of("front"), Some(A.to_string()));
        assert_eq!(streams.epoch_of("drive"), Some(B.to_string()));
    }
}
