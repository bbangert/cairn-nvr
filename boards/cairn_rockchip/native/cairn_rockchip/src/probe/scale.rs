//! `--scale`: every Nth picture through RGA into a two-slot pool, its content
//! rectangle read back under the dma-buf sync and hashed, then the lease let
//! go, so consecutive samples alternate slots. A sample of a new geometry
//! gets a new plan and pool. Two output lines: the last plan, and the
//! timings, hashes and a pad check over every pool.
//!
//! `blit_ms` covers the source's import, the blit and the import's release.
//! `read_ms` covers the sync start, the copy of the content rectangle and the
//! sync end. `first_hash` is FNV-1a 64 over the first sample's content
//! rectangle; `hash` is FNV-1a 64 over every sample's such hash, in order.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{ensure, Context as _, Result};
use cairn_detect::infer::{InputSize, ResizePolicy};
use serde_json::{json, Value};

use crate::dma::{DmaHeap, SYSTEM_HEAP};
use crate::mpp::Frame;
use crate::pool::Pool;
use crate::rga::{Blitter, ChannelOrder, Plan, Rga, Slot, SlotAllocator};

pub(super) const FLAGS: [&str; 5] = ["--scale", "--resize", "--pad", "--every", "--dump"];
const SLOTS: usize = 2;
/// YOLOX's.
const DEFAULT_PAD: u8 = 114;

#[derive(Debug, Clone, PartialEq)]
pub struct Scale {
    pub size: InputSize,
    pub policy: ResizePolicy,
    /// The 1st, (N+1)th, … frame returned.
    pub every: u64,
    pub dump: Option<PathBuf>,
}

/// [`FLAGS`] as given, the last of a repeated one winning.
pub(super) fn resolve(flags: &[(&str, &str)]) -> Result<Option<Scale>, String> {
    let given = |name| flags.iter().rev().find(|f| f.0 == name).map(|f| f.1);
    let Some(size) = given("--scale") else {
        return flags
            .first()
            .map_or(Ok(None), |f| Err(format!("{} needs --scale", f.0)));
    };
    let size = InputSize::parse(size).map_err(|e| format!("--scale: {e:#}"))?;
    let resize = given("--resize").unwrap_or("letterbox");
    let pad = match given("--pad") {
        Some(v) => super::number("--pad", v)?,
        None if resize == "letterbox" => DEFAULT_PAD,
        None => 0,
    };
    let policy = ResizePolicy::from_wire(resize, pad).map_err(|e| format!("--resize: {e:#}"))?;
    let every = given("--every").map_or(Ok(5), |v| super::number("--every", v))?;
    if every == 0 {
        return Err("--every counts from 1".into());
    }
    let dump = given("--dump").map(PathBuf::from);
    Ok(Some(Scale {
        size,
        policy,
        every,
        dump,
    }))
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    let step = |h: u64, &b: &u8| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3);
    bytes.iter().fold(hash, step)
}

/// `None` while no pool so far had a pad; a spoiled pad in any pool sticks.
fn fold_pad(run: Option<bool>, pool: Option<bool>) -> Option<bool> {
    match (run, pool) {
        (Some(run), Some(pool)) => Some(run && pool),
        (run, pool) => run.or(pool),
    }
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 1e6).round() / 1e3
}

fn summary(samples: &mut [f64]) -> Value {
    samples.sort_by(f64::total_cmp);
    let at = |p: f64| samples[((samples.len() - 1) as f64 * p).round() as usize];
    match samples.len() {
        0 => json!({"count": 0}),
        n => json!({"count": n, "p50": at(0.5), "p99": at(0.99), "max": at(1.0)}),
    }
}

/// One geometry's plan, its blitter and the pool filled for it.
struct Planned {
    blitter: Blitter,
    pool: Pool<Slot>,
}

#[derive(Default)]
struct Run {
    planned: Option<Planned>,
    plans: u64,
    /// Over the pools already dropped.
    exhausted: u64,
    /// Over the pools already dropped, by [`fold_pad`].
    pad_intact: Option<bool>,
    frames: u64,
    blit_ms: Vec<f64>,
    read_ms: Vec<f64>,
    /// The content rectangle's rows, reused.
    content: Vec<u8>,
    first_hash: Option<u64>,
    hash: Option<u64>,
}

pub(super) struct Scaler {
    rga: Rga,
    heap: DmaHeap,
    scale: Scale,
    run: Run,
}

impl Scaler {
    /// Opens librga and the heap now, so that either missing fails before
    /// anything is decoded.
    pub(super) fn open(scale: &Scale) -> Result<Self> {
        Ok(Self {
            rga: Rga::open()?,
            heap: DmaHeap::open(Path::new(SYSTEM_HEAP))?,
            scale: scale.clone(),
            run: Run::default(),
        })
    }

    pub(super) fn frame(&mut self, frame: &Frame) -> Result<()> {
        self.run.frames += 1;
        if !(self.run.frames - 1).is_multiple_of(self.scale.every) {
            return Ok(());
        }
        ensure!(frame.is_nv12(), "--scale needs linear NV12 frames");
        let geometry = frame.geometry();
        let current = self.run.planned.as_ref().map(|p| p.blitter.plan().source);
        if current != Some(geometry) {
            if let Some(old) = self.run.planned.take() {
                self.run.exhausted += old.pool.stats().exhausted;
                self.run.pad_intact = fold_pad(self.run.pad_intact, self.pad_intact(&old)?);
            }
            let plan = Plan::new(geometry, self.scale.size, self.scale.policy)?;
            let order = ChannelOrder::Rgb;
            let mut slots = SlotAllocator::new(self.rga, &self.heap, &plan, order);
            let pool = Pool::new(SLOTS, &mut slots)?;
            let blitter = Blitter::new(self.rga, plan);
            self.run.planned = Some(Planned { blitter, pool });
            self.run.plans += 1;
        }
        let Planned { blitter, pool } = self.run.planned.as_mut().expect("set above");
        // None is counted by the pool and reported as `exhausted`.
        let Some(mut lease) = pool.acquire() else {
            return Ok(());
        };
        let started = Instant::now();
        blitter.blit(frame.fd(), geometry, &mut lease)?;
        let blitted = Instant::now();
        let (inner, row) = (blitter.plan().fit.inner, self.scale.size.w * 3);
        let content = &mut self.run.content;
        content.clear();
        lease.slot().read(|bytes| {
            for rows in bytes.chunks(row).take(inner.h) {
                content.extend_from_slice(&rows[..inner.w * 3]);
            }
        })?;
        self.run.read_ms.push(ms(blitted.elapsed()));
        self.run.blit_ms.push(ms(blitted - started));
        let hash = fnv1a(FNV_OFFSET, content);
        self.run.first_hash.get_or_insert(hash);
        self.run.hash = Some(fnv1a(
            self.run.hash.unwrap_or(FNV_OFFSET),
            &hash.to_le_bytes(),
        ));
        if let (1, Some(path)) = (self.run.blit_ms.len(), &self.scale.dump) {
            let size = self.scale.size;
            let mut ppm = format!("P6\n{} {}\n255\n", size.w, size.h).into_bytes();
            lease.slot().read(|bytes| ppm.extend_from_slice(bytes))?;
            std::fs::write(path, ppm).with_context(|| format!("writing {}", path.display()))?;
        }
        Ok(())
    }

    /// Whether every byte outside the content rectangle of every slot of
    /// `planned`'s pool is still the pad; `None` when the content fills the
    /// slot.
    fn pad_intact(&self, planned: &Planned) -> Result<Option<bool>> {
        let (size, fit) = (self.scale.size, planned.blitter.plan().fit);
        if fit.inner == size {
            return Ok(None);
        }
        let leases: Vec<_> = (0..SLOTS).filter_map(|_| planned.pool.acquire()).collect();
        ensure!(leases.len() == SLOTS, "a slot is still held");
        let mut intact = true;
        for lease in &leases {
            intact &= lease.slot().read(|bytes| {
                bytes.chunks(size.w * 3).enumerate().all(|(y, row)| {
                    let from = if y < fit.inner.h { fit.inner.w * 3 } else { 0 };
                    row[from..].iter().all(|&b| b == fit.pad)
                })
            })?;
        }
        Ok(Some(intact))
    }

    pub(super) fn report(mut self) -> Result<Vec<Value>> {
        let mut plan =
            json!({"event": "scale_plan", "rga": self.rga.version(), "plans": self.run.plans});
        let (mut pad_intact, mut exhausted) = (self.run.pad_intact, self.run.exhausted);
        if let Some(planned) = &self.run.planned {
            let p = *planned.blitter.plan();
            let rect = |r: crate::rga::sys::Rect| [r.x, r.y, r.width, r.height];
            plan["plan"] = json!({
                "slot": [p.slot.w, p.slot.h], "policy": self.scale.policy.to_string(),
                "src_rect": rect(p.src), "src_strides": [p.source.hor_stride, p.source.ver_stride],
                "dst_rect": rect(p.dst), "scale": [p.scale.0, p.scale.1],
            });
            exhausted += planned.pool.stats().exhausted;
            pad_intact = fold_pad(pad_intact, self.pad_intact(planned)?);
        }
        let line = json!({
            "event": "scale", "every": self.scale.every, "sampled": self.run.blit_ms.len(),
            "blit_ms": summary(&mut self.run.blit_ms), "read_ms": summary(&mut self.run.read_ms),
            "first_hash": self.run.first_hash.map(|h| format!("{h:016x}")),
            "hash": self.run.hash.map(|h| format!("{h:016x}")), "pad_intact": pad_intact,
            "exhausted": exhausted,
        });
        Ok(vec![plan, line])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_is_the_reference_function_and_percentiles_are_of_the_sorted_samples() {
        assert_eq!(fnv1a(FNV_OFFSET, b"a"), 0xaf63_dc4c_8601_ec8c);
        let mut samples: Vec<f64> = (1..=100).rev().map(f64::from).collect();
        let expected = json!({"count": 100, "p50": 51.0, "p99": 99.0, "max": 100.0});
        assert_eq!(summary(&mut samples), expected);
        assert_eq!(summary(&mut []), json!({"count": 0}));
        assert_eq!([None, None].into_iter().fold(None, fold_pad), None);
        let pools = [Some(true), None, Some(false), Some(true)];
        assert_eq!(pools.into_iter().fold(None, fold_pad), Some(false));
        assert_eq!(
            [None, Some(true)].into_iter().fold(None, fold_pad),
            Some(true)
        );
    }
}
