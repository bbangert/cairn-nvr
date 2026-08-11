//! Where a collected resource handle is actually dropped.
//!
//! A destructor runs on whichever thread released the last reference, and for a
//! collected term that is a normal scheduler. What is dropped is a libav decoder
//! — driver and device teardown on the hardware paths — and, for the last engine
//! handle, an ORT session release that on QNN gives back an HTP context: work
//! bounded by nothing this crate controls. Calling `close_stream` does not avoid
//! it, since nothing stops the BEAM from collecting a term.
//!
//! One thread, not one per drop: a supervisor restarting every camera at once
//! queues N teardowns rather than spawning N threads onto a busy box.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc::{self, SendError, Sender};
use std::sync::OnceLock;

type Discarded = Box<dyn Send + 'static>;

/// Drop `value` on the teardown thread rather than on this one, returning as soon
/// as it is queued. Dropped inline if the thread never started: slow on the
/// caller, but better than a leak.
///
/// Nothing in here may unwind. rustler does not wrap a destructor in
/// [`catch_unwind`] the way it wraps a NIF body, so an unwind out of this
/// function reaches C and aborts the node — hence every drop, the two inline
/// fallbacks included, goes through [`drop_swallowing_panics`].
pub fn defer<T: Send + 'static>(value: T) {
    defer_to(queue(), value)
}

/// [`defer`]'s body over an arbitrary queue, so a test can stage both inline
/// fallbacks: a worker that is gone (`Some`) and one that never started (`None`).
fn defer_to<T: Send + 'static>(queue: Option<&Sender<Discarded>>, value: T) {
    match queue {
        Some(queue) => {
            if let Err(SendError(orphan)) = queue.send(Box::new(value)) {
                drop_swallowing_panics(orphan);
            }
        }
        None => drop_swallowing_panics(value),
    }
}

/// Run one `Drop`, absorbing an unwind out of it. Swallowed rather than
/// reported: the caller is a C frame with no error channel.
fn drop_swallowing_panics<T>(value: T) {
    let _ = catch_unwind(AssertUnwindSafe(move || drop(value)));
}

/// Wait until every drop queued before this call has run, or `timeout` passes.
///
/// The exit path is why this exists: the queue's thread is detached, and a VM
/// halting while it is mid-drop races process teardown against a native
/// destructor. Observed on QCS6490 at exit, after all work completed, as both
/// an abort (`double free or corruption`) and a hang inside fastrpc deinit —
/// same race, different interleavings (`research/board-first-light.md`). The
/// sentinel rides the same FIFO queue, so its drop proves every drop queued
/// before it has already run.
pub fn drain(timeout: std::time::Duration) -> bool {
    let Some(queue) = queue() else {
        // The thread never started, so every drop so far ran inline.
        return true;
    };
    let (sink, done) = mpsc::sync_channel::<()>(1);
    if queue.send(Box::new(Flush { sink })).is_err() {
        // The worker is gone; sends fall back to inline drops, so nothing is
        // queued to race.
        return true;
    }
    done.recv_timeout(timeout).is_ok()
}

struct Flush {
    sink: mpsc::SyncSender<()>,
}

impl Drop for Flush {
    fn drop(&mut self) {
        let _ = self.sink.send(());
    }
}

/// The teardown thread's inbox, started on the first handle to be collected and
/// `None` for the rest of the run if that spawn failed: retrying per drop would
/// be retrying inside a destructor.
fn queue() -> Option<&'static Sender<Discarded>> {
    static QUEUE: OnceLock<Option<Sender<Discarded>>> = OnceLock::new();
    QUEUE
        .get_or_init(|| {
            let (sender, receiver) = mpsc::channel::<Discarded>();
            std::thread::Builder::new()
                .name("cairn-teardown".into())
                .spawn(move || {
                    for value in receiver {
                        // A panicking `Drop` must not end the thread: every later
                        // handle would then be dropped on a scheduler.
                        drop_swallowing_panics(value);
                    }
                })
                .ok()
                .map(|_handle| sender)
        })
        .as_ref()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::sync_channel;
    use std::time::{Duration, Instant};

    /// Reports where it was dropped, over a channel that outlives it.
    struct Slow {
        sink: mpsc::SyncSender<std::thread::ThreadId>,
        cost: Duration,
    }

    impl Drop for Slow {
        fn drop(&mut self) {
            std::thread::sleep(self.cost);
            let _ = self.sink.send(std::thread::current().id());
        }
    }

    #[test]
    fn deferring_a_slow_drop_does_not_block_the_caller() {
        let (sink, dropped) = sync_channel(1);
        let cost = Duration::from_millis(300);

        let started = Instant::now();
        defer(Slow { sink, cost });
        let handed_off = started.elapsed();

        let on = dropped
            .recv_timeout(cost * 10)
            .expect("the teardown thread never ran the drop");
        assert_ne!(on, std::thread::current().id(), "dropped inline after all");
        assert!(
            handed_off < cost / 2,
            "handing off took {handed_off:?} of the drop's {cost:?}"
        );
    }

    /// A burst — every camera on the box restarting at once.
    #[test]
    fn a_burst_is_queued_and_all_of_it_is_dropped() {
        let (sink, dropped) = sync_channel(64);
        for _ in 0..32 {
            defer(Slow {
                sink: sink.clone(),
                cost: Duration::from_millis(1),
            });
        }
        drop(sink);

        let threads: std::collections::HashSet<_> = dropped.iter().collect();
        assert_eq!(threads.len(), 1, "one teardown thread, not one per drop");
        assert!(!threads.contains(&std::thread::current().id()));
    }

    struct Explodes;

    impl Drop for Explodes {
        fn drop(&mut self) {
            panic!("teardown exploded");
        }
    }

    /// Neither inline fallback may unwind: an unwind there does not fail a call,
    /// it aborts the node.
    #[test]
    fn a_panicking_drop_does_not_unwind_out_of_either_fallback() {
        // the worker is gone: the send fails and the orphan comes back
        let (sender, receiver) = mpsc::channel::<Discarded>();
        drop(receiver);
        let orphaned = catch_unwind(AssertUnwindSafe(|| defer_to(Some(&sender), Explodes)));
        assert!(orphaned.is_ok(), "the orphaned value unwound into C");

        // …and the thread never started, so there is nothing to send to
        let inline = catch_unwind(AssertUnwindSafe(|| defer_to(None, Explodes)));
        assert!(inline.is_ok(), "the inline drop unwound into C");
    }

    #[test]
    fn drain_returns_once_everything_queued_before_it_has_dropped() {
        let (sink, dropped) = sync_channel(1);
        defer(Slow {
            sink,
            cost: Duration::from_millis(200),
        });

        assert!(drain(Duration::from_secs(10)), "drain timed out");
        // FIFO means the sentinel's drop PROVES the slow drop already ran.
        assert!(
            dropped.try_recv().is_ok(),
            "drain returned before the queued drop had run"
        );
    }

    #[test]
    fn drain_with_nothing_queued_answers_immediately() {
        let started = Instant::now();
        assert!(drain(Duration::from_secs(10)));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn a_panicking_drop_does_not_take_the_thread_with_it() {
        defer(Explodes);

        let (sink, dropped) = sync_channel(1);
        defer(Slow {
            sink,
            cost: Duration::from_millis(1),
        });
        dropped
            .recv_timeout(Duration::from_secs(10))
            .expect("the teardown thread died with the panicking drop");
    }
}
