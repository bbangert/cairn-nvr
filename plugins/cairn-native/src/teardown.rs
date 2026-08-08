//! Where a collected resource handle is actually dropped.
//!
//! The BEAM runs a resource destructor on whichever thread released the last
//! reference, and for a garbage-collected term that is the **normal** scheduler
//! running the owning process. What these handles own is a libav decoder — on
//! the hardware paths, driver and device teardown — and, for the last engine
//! handle, an ORT session release, which on QNN gives back an HTP context.
//! Both are driver-side and neither is bounded by anything this crate controls,
//! which is what makes them dirty-scheduler work; the host cannot opt out by
//! calling `close_stream`, because nothing stops the BEAM from collecting a
//! term.
//!
//! So a destructor hands the value here and returns. **One thread, not one per
//! drop**: a supervisor restarting every camera at once queues N teardowns
//! rather than spawning N threads onto a box that is already busy.
//!
//! Nothing joins the thread. It parks on the channel for the life of the VM,
//! and the VM exiting takes it with the process — which is why it holds no
//! state of its own, only the values it is about to drop.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc::{self, SendError, Sender};
use std::sync::OnceLock;

/// One thing to drop somewhere other than here.
type Discarded = Box<dyn Send + 'static>;

/// Drop `value` on the teardown thread rather than on this one.
///
/// Returns as soon as the value is queued. If the thread could not be started
/// the value is dropped inline instead: slow on the caller, which is the whole
/// problem this avoids, but a leak or an unwind into the emulator is worse.
///
/// **Nothing in here may panic.** A destructor is called from C, and rustler
/// does not wrap it in [`catch_unwind`] the way it wraps a NIF body, so an
/// unwind out of this function reaches the C boundary and aborts the node.
pub fn defer<T: Send + 'static>(value: T) {
    match queue() {
        Some(queue) => {
            if let Err(SendError(orphan)) = queue.send(Box::new(value)) {
                drop(orphan);
            }
        }
        None => drop(value),
    }
}

/// The teardown thread's inbox, started on the first handle to be collected.
///
/// `None` for the rest of the run if the thread could not be spawned. Retrying
/// per drop would be retrying inside a destructor, and a box that cannot start
/// one thread will not start the next one either.
fn queue() -> Option<&'static Sender<Discarded>> {
    static QUEUE: OnceLock<Option<Sender<Discarded>>> = OnceLock::new();
    QUEUE
        .get_or_init(|| {
            let (sender, receiver) = mpsc::channel::<Discarded>();
            std::thread::Builder::new()
                .name("cairn-teardown".into())
                .spawn(move || {
                    for value in receiver {
                        // A panicking `Drop` must not end the thread: the next
                        // handle the BEAM collected would then be dropped on
                        // its scheduler, which is what this exists to prevent.
                        let _ = catch_unwind(AssertUnwindSafe(move || drop(value)));
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

    /// The property the blocker is about: the thread that lets go of a handle
    /// is not the thread that pays for the teardown.
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

    /// A burst — every camera on the box restarting at once — is queued, not
    /// fanned out, and every one of them is still dropped.
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

    /// A `Drop` that panics costs its own teardown and nothing after it.
    #[test]
    fn a_panicking_drop_does_not_take_the_thread_with_it() {
        struct Explodes;
        impl Drop for Explodes {
            fn drop(&mut self) {
                panic!("teardown exploded");
            }
        }

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
