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
