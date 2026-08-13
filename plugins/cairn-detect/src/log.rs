//! Diagnostics that can neither take the host down nor hold it up.
//!
//! In production stderr is a pipe or a redirect — `run_erl`, a journal socket,
//! `> log 2>&1` — and writing to one from the frame path goes wrong two ways: a
//! reader that is gone makes `eprintln!` panic on `EPIPE`, and one that is alive
//! and not draining fills the pipe and blocks the write. In `cairn-native` the
//! per-frame stages run under the shared model lock, so the first poisons a
//! session nothing recovers and the second stalls detection on every camera —
//! which the host's health check, inferring from latency, reads as a wedged
//! accelerator.
//!
//! So [`crate::note!`] writes nothing on the calling thread: it formats the line,
//! hands it to a bounded queue and returns, and one worker does the writing. A
//! full queue drops the line rather than blocking or growing, and the worker
//! reports the count with the next line it writes.
//!
//! What that costs: a line is no longer ordered against libav's own writes, and
//! whatever is still queued at an exit is lost unless something calls [`drain`]
//! first — `main` and the control thread do.

use std::fmt::Arguments;
use std::io::Write;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

/// Lines the queue holds before it starts dropping them: enough to absorb a burst
/// — every camera reporting a decode error on the same frame — at a few tens of KB.
const BOUND: usize = 256;

/// How long [`drain`] waits at an exit: enough for a healthy stderr to take the
/// queue, not enough to hold a restart up behind a wedged one.
const DRAIN_TIMEOUT: Duration = Duration::from_millis(500);

/// A bounded queue of formatted lines and the thread that empties it.
struct Sink {
    lines: SyncSender<String>,
    /// Handed over and not yet written — what [`Sink::drain`] waits on.
    pending: Arc<AtomicUsize>,
    /// Dropped since the worker last said so.
    dropped: Arc<AtomicU64>,
}

impl Sink {
    /// Generic over the writer so a test can stall it: stderr's own reader cannot
    /// be stalled from inside this process.
    fn start<W: Write + Send + 'static>(bound: usize, mut writer: W) -> Option<Self> {
        let (lines, queued) = sync_channel::<String>(bound);
        let pending = Arc::new(AtomicUsize::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let (worker_pending, worker_dropped) = (Arc::clone(&pending), Arc::clone(&dropped));
        std::thread::Builder::new()
            .name("cairn-log".into())
            .spawn(move || {
                for line in queued {
                    // The sink is the only channel there is to report on, so the
                    // report rides in front of the next line that gets through.
                    let lost = worker_dropped.swap(0, Ordering::SeqCst);
                    if lost > 0 {
                        write_line(&mut writer, format!("log: dropped {lost} diagnostic lines"));
                    }
                    write_line(&mut writer, line);
                    worker_pending.fetch_sub(1, Ordering::SeqCst);
                }
            })
            .ok()?;
        Some(Self {
            lines,
            pending,
            dropped,
        })
    }

    /// Queue one line, or count it as dropped. Never blocks.
    fn line(&self, args: Arguments<'_>) {
        self.pending.fetch_add(1, Ordering::SeqCst);
        // A disconnected queue counts as dropped too: the worker is gone either way.
        if self.lines.try_send(std::fmt::format(args)).is_err() {
            self.pending.fetch_sub(1, Ordering::SeqCst);
            self.dropped.fetch_add(1, Ordering::SeqCst);
        }
    }

    /// Wait for everything queued so far to be written, up to `timeout`;
    /// `false` if it was still unwritten when that ran out.
    fn drain(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while self.pending.load(Ordering::SeqCst) > 0 {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        true
    }
}

/// One line and its newline in a single `write_all`, discarding a failed write.
/// One call and not two because libav writes this stderr directly in the plugin,
/// and could otherwise land between a line and its newline.
fn write_line(writer: &mut impl Write, mut line: String) {
    line.push('\n');
    let _ = writer.write_all(line.as_bytes());
}

/// The process's sink, started on the first line written and `None` for the rest of
/// the run if that spawn failed.
fn sink() -> Option<&'static Sink> {
    static SINK: OnceLock<Option<Sink>> = OnceLock::new();
    SINK.get_or_init(|| Sink::start(BOUND, std::io::stderr()))
        .as_ref()
}

/// Queue one line for stderr. Use [`crate::note!`].
pub fn line(args: Arguments<'_>) {
    match sink() {
        Some(sink) => sink.line(args),
        // Inline, blocking risk and all: a process that says nothing at all is
        // harder to diagnose than one that stalls behind a reader.
        None => write_line(&mut std::io::stderr(), std::fmt::format(args)),
    }
}

/// Wait, bounded, for the queued lines to reach stderr. Call before exiting: an
/// exit that does not come through here loses whatever the process last said — the
/// `fatal:` line, the control-channel line.
pub fn drain() {
    if let Some(sink) = sink() {
        sink.drain(DRAIN_TIMEOUT);
    }
}

/// `eprintln!` that cannot panic on a broken stderr and cannot block on a full
/// one — same arguments, same output.
#[macro_export]
macro_rules! note {
    ($($arg:tt)*) => {
        $crate::log::line(format_args!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{channel, Receiver, Sender};
    use std::sync::Mutex;

    /// What a stalled writer has written, readable while it is stalled.
    type Written = Arc<Mutex<Vec<String>>>;

    /// A writer that costs `cost` per line — a slow disk, a busy journal.
    struct Slow {
        cost: Duration,
        written: Written,
    }

    /// The reader that is alive and not draining: writes nothing until it is given
    /// a permit, and forever if it never is. Dropping the sender releases it.
    struct Gated {
        permits: Receiver<()>,
        written: Written,
    }

    impl Write for Slow {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            std::thread::sleep(self.cost);
            record(&self.written, buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Write for Gated {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let _ = self.permits.recv();
            record(&self.written, buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn record(written: &Written, buf: &[u8]) {
        let line = String::from_utf8_lossy(buf).trim_end().to_string();
        written
            .lock()
            .expect("the written log is poisoned")
            .push(line);
    }

    fn gated(bound: usize) -> (Sink, Sender<()>, Written) {
        let (permits, gate) = channel();
        let written = Written::default();
        let sink = Sink::start(
            bound,
            Gated {
                permits: gate,
                written: Arc::clone(&written),
            },
        )
        .expect("the log thread did not start");
        (sink, permits, written)
    }

    /// In `cairn-native` the caller is holding the shared model lock, so what it
    /// waits for, every camera waits for.
    #[test]
    fn handing_over_a_line_does_not_wait_for_the_writer() {
        let cost = Duration::from_millis(300);
        let written = Written::default();
        let sink = Sink::start(
            4,
            Slow {
                cost,
                written: Arc::clone(&written),
            },
        )
        .expect("the log thread did not start");

        let started = Instant::now();
        for i in 0..4 {
            sink.line(format_args!("line {i}"));
        }
        let handed_off = started.elapsed();
        assert!(
            handed_off < cost / 2,
            "handing off 4 lines took {handed_off:?} of one write's {cost:?}"
        );

        assert!(sink.drain(cost * 20), "the worker never wrote the queue");
        let written = written.lock().unwrap();
        assert_eq!(written.len(), 4, "{written:?}");
        assert_eq!(written[0], "line 0");
        assert_eq!(written[3], "line 3");
    }

    /// A writer that has stopped is the case a queue alone does not survive:
    /// blocking on it stalls the frame path, and growing to fit is the node's
    /// memory. So the lines are dropped — and *counted*.
    #[test]
    fn a_full_queue_drops_lines_and_says_how_many() {
        const OFFERED: usize = 64;
        let bound = 2;
        let (sink, permits, written) = gated(bound);

        let started = Instant::now();
        for i in 0..OFFERED {
            sink.line(format_args!("line {i}"));
        }
        let offered_in = started.elapsed();
        assert!(
            offered_in < Duration::from_millis(100),
            "offering {OFFERED} lines to a stalled writer took {offered_in:?}"
        );

        drop(permits);
        assert!(
            sink.drain(Duration::from_secs(10)),
            "the worker never drained"
        );
        let written = written.lock().unwrap();
        assert!(written.len() < OFFERED, "{written:?}");
        // The worker flushes its drop counter whenever it next gets a line
        // out, which under an unlucky interleaving is more than once — the
        // invariant is over the SUM of the notices, not their count.
        let (notices, lines): (Vec<_>, Vec<_>) = written
            .iter()
            .partition(|line| line.starts_with("log: dropped "));
        assert!(
            !notices.is_empty(),
            "no dropped-line count reached the sink: {written:?}"
        );
        let lost: usize = notices
            .iter()
            .map(|notice| {
                notice
                    .trim_start_matches("log: dropped ")
                    .trim_end_matches(" diagnostic lines")
                    .parse::<usize>()
                    .unwrap_or_else(|e| panic!("{notice:?}: {e}"))
            })
            .sum();
        // Every offered line is either written or counted, once.
        assert_eq!(lines.len() + lost, OFFERED, "{written:?}");
        assert!(lines.len() >= bound, "{written:?}");
    }

    /// An exit behind a wedged writer gives up on the tail rather than hanging:
    /// Cairn is waiting to respawn the process.
    #[test]
    fn draining_a_wedged_writer_gives_up_instead_of_hanging() {
        let (sink, _permits, _written) = gated(1);
        sink.line(format_args!("queued"));
        sink.line(format_args!("also queued"));

        let timeout = Duration::from_millis(50);
        let started = Instant::now();
        assert!(
            !sink.drain(timeout),
            "a wedged writer reported a clean drain"
        );
        let waited = started.elapsed();
        assert!(waited < timeout * 20, "draining waited {waited:?}");
    }

    /// The macro over the real sink: the arguments format and nothing panics.
    #[test]
    fn a_note_formats_its_arguments_and_returns() {
        line(format_args!("{} {:?} {:.2}", 1, "two", 3.0));
        note!("plain");
        note!("camera {}: {} error", "front", "decode");
        drain();
    }
}
