//! A fixed set of destination slots, each handed out under a [`Lease`] only
//! while no other lease holds it. Running out is counted, never waited on.
//!
//! Acquire and release are a few atomics each, never a lock: a lease can be
//! released from a BEAM resource destructor on a normal scheduler.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use anyhow::{bail, Context as _, Result};

/// Builds the slots, so a test can hand the pool a fake slot type and fail
/// an allocation.
pub trait Allocator {
    type Slot;
    fn allocate(&mut self, index: usize) -> Result<Self::Slot>;
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub held: usize,
    pub acquired: u64,
    /// Acquires that found every slot held.
    pub exhausted: u64,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

struct Inner<S> {
    id: u64,
    slots: Box<[S]>,
    held: Box<[AtomicBool]>,
    /// Where the next acquire starts looking, so that consecutive leases
    /// rotate through the slots.
    next: AtomicUsize,
    acquired: AtomicU64,
    exhausted: AtomicU64,
}

/// The pool handle: a clone is another reference to the same slots, and
/// every [`Lease`] holds one.
///
/// Dropping the last reference drops every slot, which for an RGA slot
/// releases its RGA handle, unmaps and closes its dma-buf: it **blocks** in
/// the kernel. A NIF that holds a pool or a lease hands its last reference to
/// a teardown thread — [`Lease::release`] frees the slot without dropping it.
pub struct Pool<S> {
    inner: Arc<Inner<S>>,
}

impl<S> Clone for Pool<S> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<S> Pool<S> {
    /// `count` slots, allocated in order; the first failure drops the ones
    /// already made and names its index.
    pub fn new<A: Allocator<Slot = S>>(count: usize, allocator: &mut A) -> Result<Self> {
        if count == 0 {
            bail!("a pool of 0 slots");
        }
        let slots = (0..count)
            .map(|index| {
                allocator
                    .allocate(index)
                    .with_context(|| format!("allocating slot {index} of {count}"))
            })
            .collect::<Result<Box<[S]>>>()?;
        Ok(Self {
            inner: Arc::new(Inner {
                id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
                slots,
                held: (0..count).map(|_| AtomicBool::new(false)).collect(),
                next: AtomicUsize::new(0),
                acquired: AtomicU64::new(0),
                exhausted: AtomicU64::new(0),
            }),
        })
    }

    /// Unique in the process, so a consumer can tell a rebuilt pool from
    /// the one its lease came from.
    pub fn id(&self) -> u64 {
        self.inner.id
    }

    /// A lease on a free slot, or `None` — counted — when every slot is held.
    pub fn acquire(&self) -> Option<Lease<S>> {
        let inner = &*self.inner;
        let count = inner.slots.len();
        let start = inner.next.fetch_add(1, Ordering::Relaxed);
        for index in (0..count).map(|i| start.wrapping_add(i) % count) {
            // Acquire pairs with the release in `free`: the last holder's
            // accesses to the slot happen before this lease's.
            if inner.held[index]
                .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
                .is_ok()
            {
                inner.acquired.fetch_add(1, Ordering::Relaxed);
                return Some(Lease {
                    pool: Some(self.clone()),
                    index,
                });
            }
        }
        inner.exhausted.fetch_add(1, Ordering::Relaxed);
        None
    }

    fn free(&self, index: usize) {
        self.inner.held[index].store(false, Ordering::Release);
    }

    pub fn stats(&self) -> Stats {
        let inner = &*self.inner;
        let held = inner.held.iter().filter(|h| h.load(Ordering::Relaxed));
        Stats {
            held: held.count(),
            acquired: inner.acquired.load(Ordering::Relaxed),
            exhausted: inner.exhausted.load(Ordering::Relaxed),
        }
    }
}

/// One slot, held: the writer's handle while it fills the slot and the
/// consumer's while it reads it. Dropping it frees the slot.
///
/// It holds a [`Pool`] reference, so its drop can drop the last one, which
/// **blocks** (see [`Pool`]); [`Lease::release`] is the drop that cannot.
///
/// The pool hands a slot to one lease at a time and to no one else, and a
/// writer takes the lease by `&mut`, as [`crate::rga::Blitter::blit`] does:
/// no `&S` from [`Lease::slot`] is live while the slot is written.
pub struct Lease<S> {
    /// `None` once `release` or the drop has taken it.
    pool: Option<Pool<S>>,
    index: usize,
}

impl<S> Lease<S> {
    fn pool(&self) -> &Pool<S> {
        self.pool.as_ref().expect("taken only as the lease goes")
    }

    pub fn slot(&self) -> &S {
        &self.pool().inner.slots[self.index]
    }

    pub fn index(&self) -> usize {
        self.index
    }

    pub fn pool_id(&self) -> u64 {
        self.pool().id()
    }

    /// Frees the slot now, on this thread, and hands back the pool
    /// reference the lease held for the caller to drop where it may block.
    pub fn release(mut self) -> Pool<S> {
        let pool = self.pool.take().expect("a live lease holds its pool");
        pool.free(self.index);
        pool
    }
}

impl<S> Drop for Lease<S> {
    fn drop(&mut self) {
        if let Some(pool) = self.pool.take() {
            pool.free(self.index);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Slots that log their own drop and flag their own use.
    struct Fake {
        index: usize,
        dropped: Arc<Mutex<Vec<usize>>>,
        in_use: AtomicBool,
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            self.dropped.lock().unwrap().push(self.index);
        }
    }

    #[derive(Default)]
    struct Fakes {
        fail_at: Option<usize>,
        dropped: Arc<Mutex<Vec<usize>>>,
    }

    impl Allocator for Fakes {
        type Slot = Fake;
        fn allocate(&mut self, index: usize) -> Result<Fake> {
            if self.fail_at == Some(index) {
                bail!("no memory");
            }
            let dropped = Arc::clone(&self.dropped);
            let in_use = AtomicBool::new(false);
            Ok(Fake {
                index,
                dropped,
                in_use,
            })
        }
    }

    fn pool(count: usize) -> (Pool<Fake>, Arc<Mutex<Vec<usize>>>) {
        let mut fakes = Fakes::default();
        (Pool::new(count, &mut fakes).unwrap(), fakes.dropped)
    }

    #[test]
    fn a_held_slot_is_never_handed_out_and_none_free_is_counted() {
        let (pool, _) = pool(2);
        let a = pool.acquire().unwrap();
        let b = pool.acquire().unwrap();
        assert_ne!(a.slot().index, b.slot().index);
        assert!(pool.acquire().is_none());
        assert!(pool.acquire().is_none());
        let stats = pool.stats();
        assert_eq!((stats.held, stats.acquired, stats.exhausted), (2, 2, 2));
        drop(b);
        let next: Vec<usize> = (0..4).map(|_| pool.acquire().unwrap().index()).collect();
        assert_eq!(next, [1 - a.index(); 4]);
    }

    #[test]
    fn consecutive_leases_rotate_through_the_slots() {
        let (pool, _) = pool(2);
        let order: Vec<usize> = (0..4).map(|_| pool.acquire().unwrap().index()).collect();
        assert_eq!(order, [0, 1, 0, 1]);
    }

    #[test]
    fn release_frees_the_slot_now_and_returns_the_reference_undropped() {
        let (pool, dropped) = pool(1);
        let id = pool.id();
        let lease = pool.acquire().unwrap();
        drop(pool);
        let handle = lease.release();
        assert_eq!(handle.stats().held, 0);
        assert_eq!(handle.id(), id);
        let again = handle.acquire().unwrap();
        assert!(dropped.lock().unwrap().is_empty());
        drop(handle);
        assert!(dropped.lock().unwrap().is_empty(), "the lease holds it");
        drop(again);
        assert_eq!(*dropped.lock().unwrap(), [0]);
    }

    #[test]
    fn a_failed_allocation_names_its_slot_and_drops_the_ones_made() {
        let mut fakes = Fakes {
            fail_at: Some(2),
            ..Fakes::default()
        };
        let msg = format!("{:#}", Pool::new(3, &mut fakes).err().unwrap());
        assert!(msg.contains("slot 2 of 3: no memory"), "{msg}");
        assert_eq!(*fakes.dropped.lock().unwrap(), [0, 1]);
        let msg = format!("{:#}", Pool::new(0, &mut Fakes::default()).err().unwrap());
        assert!(msg.contains("0 slots"), "{msg}");
    }

    #[test]
    fn every_pool_has_its_own_id_and_an_rga_pool_crosses_threads() {
        let (a, _) = pool(1);
        assert_ne!(a.id(), pool(1).0.id());
        assert_eq!(a.acquire().unwrap().pool_id(), a.id());
        fn sync<T: Send + Sync>() {}
        sync::<Lease<crate::rga::Slot>>();
        sync::<Pool<crate::rga::Slot>>();
    }

    #[test]
    fn threads_racing_for_two_slots_never_share_one() {
        let (pool, _) = pool(2);
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| {
                    for _ in 0..10_000 {
                        let Some(lease) = pool.acquire() else {
                            continue;
                        };
                        let shared = lease.slot().in_use.swap(true, Ordering::Relaxed);
                        assert!(!shared, "two leases on slot {}", lease.index());
                        lease.slot().in_use.store(false, Ordering::Relaxed);
                    }
                });
            }
        });
        let stats = pool.stats();
        assert_eq!((stats.held, stats.acquired + stats.exhausted), (0, 40_000));
    }
}
