//! `--infer`: `--scale`'s blit, then the slot handed to the model on the NPU
//! one of three ways, one way per run — `copy` reads the slot out under the
//! dma-buf sync and `rknn_inputs_set`s it; `fd` binds the slot's own dma-buf,
//! a dup of its fd wrapped once per slot with `rknn_create_mem_from_fd`;
//! `mem` blits into buffers `rknn_create_mem` allocated and binds those.
//! Outputs always come back through `rknn_outputs_get`. One geometry per run.
//!
//! Per sample, each on the wall clock: `blit_ms` the lease and the blit;
//! `input_ms` the hand-over (`copy`: the read and `rknn_inputs_set`; `fd` and
//! `mem`: `--sync` and `rknn_set_io_mem`); `run_ms` `rknn_run`; `output_ms`
//! `rknn_outputs_get`. `cpu_ms` is the calling thread's CPU time across the
//! four; `proc_cpu_ms` the whole process's over the same span, the runtime's
//! and MPP's threads included. Then, untimed, the hashes: `out_*` FNV-1a 64 over every output's f32
//! bytes in the model's order, `in_*` over the bytes the model was handed
//! (for `fd` and `mem` the slot read back under the sync), each chained over
//! the samples as `--scale`'s `hash` is. `slot_changes` counts samples whose
//! slot was not the previous sample's.
//!
//! In `fd` mode `slot_fds_intact` counts the dups handed to the runtime that
//! still name the same file after the backend is destroyed: the runtime's
//! behaviour on `rknn_destroy_mem` of an imported fd is undocumented. The
//! probe closes those the runtime left open. It is `null` for `copy` and
//! `mem`.

use std::ffi::c_void;
use std::os::fd::{BorrowedFd, FromRawFd as _, IntoRawFd as _, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context as _, Result};
use cairn_detect::infer::{Backend, InputTensor, SessionOptions, TensorLayout, TensorValues};
use serde_json::{json, Value};

use super::scale::{chain, fnv1a, hex, Planned, Scale, FNV_OFFSET};
use crate::decoder::{ms, summary};
use crate::dma::{DmaBuf, DmaHeap, SYSTEM_HEAP};
use crate::mpp::Frame;
use crate::pool::Allocator;
use crate::rga::{ChannelOrder, Plan, Rga, Slot, SlotAllocator};
use crate::rknn::{sys, InputMem, MemSync, RknnBackend};

pub(super) const FLAGS: [&str; 6] = [
    "--infer",
    "--input",
    "--sync",
    "--order",
    "--slots",
    "--samples",
];
const MAX_SLOTS: usize = 4;
/// `out_marks` gets the running `out_hash` every this many samples, at most
/// [`MAX_MARKS`] times.
const MARK_EVERY: u64 = 25;
const MAX_MARKS: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputMode {
    Copy,
    Fd,
    Mem,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    None,
    DmaBuf,
    Rknn(MemSync),
}

const INPUTS: [(&str, InputMode); 3] = [
    ("copy", InputMode::Copy),
    ("fd", InputMode::Fd),
    ("mem", InputMode::Mem),
];
const SYNCS: [(&str, SyncMode); 4] = [
    ("none", SyncMode::None),
    ("dmabuf", SyncMode::DmaBuf),
    ("to-device", SyncMode::Rknn(MemSync::ToDevice)),
    ("from-device", SyncMode::Rknn(MemSync::FromDevice)),
];
const ORDERS: [(&str, ChannelOrder); 2] = [("rgb", ChannelOrder::Rgb), ("bgr", ChannelOrder::Bgr)];

/// `value`'s entry in `table`, or a refusal naming the table's.
fn pick<T: Copy>(flag: &str, value: &str, table: &[(&str, T)]) -> Result<T, String> {
    let found = table.iter().find(|e| e.0 == value).map(|e| e.1);
    let names = || table.iter().map(|e| e.0).collect::<Vec<_>>().join(", ");
    found.ok_or_else(|| format!("{flag}: {value:?} is not one of {}", names()))
}

fn name<T: PartialEq>(table: &[(&'static str, T)], value: T) -> &'static str {
    table.iter().find(|e| e.1 == value).map_or("", |e| e.0)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Infer {
    pub model: PathBuf,
    pub input: InputMode,
    pub sync: SyncMode,
    /// The slot's, handed to the model unchanged.
    pub order: ChannelOrder,
    pub slots: usize,
    pub samples: u64,
}

/// [`FLAGS`] as given, the last of a repeated one winning.
pub(super) fn resolve(
    flags: &[(&str, &str)],
    scale: Option<&Scale>,
) -> Result<Option<Infer>, String> {
    let given = |name| flags.iter().rev().find(|f| f.0 == name).map(|f| f.1);
    let Some(model) = given("--infer") else {
        return flags
            .first()
            .map_or(Ok(None), |f| Err(format!("{} needs --infer", f.0)));
    };
    match scale {
        None => return Err("--infer needs --scale".into()),
        Some(scale) if scale.dump.is_some() => return Err("--dump is --scale's alone".into()),
        Some(_) => {}
    }
    let input = pick("--input", given("--input").unwrap_or("copy"), &INPUTS)?;
    let sync = pick("--sync", given("--sync").unwrap_or("none"), &SYNCS)?;
    if input == InputMode::Copy && sync != SyncMode::None {
        return Err("--sync needs --input fd or mem: copy reads under the dma-buf sync".into());
    }
    let order = pick("--order", given("--order").unwrap_or("rgb"), &ORDERS)?;
    let slots = given("--slots").map_or(Ok(2), |v| super::number("--slots", v))?;
    if !(1..=MAX_SLOTS).contains(&slots) {
        return Err(format!("--slots is 1 to {MAX_SLOTS}"));
    }
    let samples = given("--samples").map_or(Ok(200), |v| super::number("--samples", v))?;
    if samples == 0 {
        return Err("--samples counts from 1".into());
    }
    let model = model.into();
    Ok(Some(Infer {
        model,
        input,
        sync,
        order,
        slots,
        samples,
    }))
}

fn thread_cpu() -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: a live timespec, which the call fills.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

fn rusage() -> (Duration, Duration) {
    // SAFETY: all-zero is a valid `rusage`, which the call fills.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: a live `rusage`.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let tv = |t: libc::timeval| Duration::new(t.tv_sec as u64, t.tv_usec as u32 * 1000);
    (tv(usage.ru_utime), tv(usage.ru_stime))
}

fn process_cpu() -> Value {
    let (user, sys) = rusage();
    json!({"user": ms(user), "sys": ms(sys)})
}

fn process_cpu_total() -> Duration {
    let (user, sys) = rusage();
    user + sys
}

/// `fd`'s device and inode, which tell whether a descriptor number still
/// names the same file.
fn identity(fd: RawFd) -> Option<(u64, u64)> {
    // SAFETY: all-zero is a valid `stat`, which the call fills.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a live `stat`.
    (unsafe { libc::fstat(fd, &mut st) } == 0).then_some((st.st_dev as u64, st.st_ino as u64))
}

/// A dup of a slot's fd handed to `rknn_create_mem_from_fd`, and the file it
/// named. The runtime may close the number in `rknn_destroy_mem`, so nothing
/// owns it until the backend is gone.
struct ImportedFd {
    fd: RawFd,
    who: (u64, u64),
}

impl ImportedFd {
    /// Whether the runtime left the dup open, closing it if so. A number that
    /// names another file is the runtime's closed one, or someone else's by
    /// now, and is left alone.
    fn settle(self) -> bool {
        let intact = identity(self.fd) == Some(self.who);
        if intact {
            // SAFETY: still the dup, and the backend that held it is gone.
            drop(unsafe { OwnedFd::from_raw_fd(self.fd) });
        }
        intact
    }
}

/// `fd`'s dups; dropping it settles any still held.
#[derive(Default)]
struct Imports(Vec<ImportedFd>);

impl Imports {
    /// How many the runtime left open.
    fn settle(&mut self) -> usize {
        self.0
            .drain(..)
            .map(ImportedFd::settle)
            .filter(|&b| b)
            .count()
    }
}

impl Drop for Imports {
    fn drop(&mut self) {
        self.settle();
    }
}

/// `mem`'s slots: each a dup of a `rknn_create_mem` buffer's fd, adopted;
/// slot `index` is mem `index`.
struct FromMems<'a, 'b> {
    slots: SlotAllocator<'a>,
    backend: &'b mut RknnBackend,
    mems: Vec<InputMem>,
}

impl Allocator for FromMems<'_, '_> {
    type Slot = Slot;

    fn allocate(&mut self, _: usize) -> Result<Slot> {
        let mem = self.backend.create_input()?;
        self.mems.push(mem);
        let (fd, len) = self.backend.input_fd(mem)?;
        let fd = fd.try_clone_to_owned().context("dup of the mem's fd")?;
        self.slots.slot(DmaBuf::adopt(fd, len)?)
    }
}

#[derive(Default)]
struct Samples {
    blit_ms: Vec<f64>,
    input_ms: Vec<f64>,
    run_ms: Vec<f64>,
    output_ms: Vec<f64>,
    cpu_ms: Vec<f64>,
    proc_cpu_ms: Vec<f64>,
    binds: u64,
    slot_changes: u64,
    last_slot: Option<usize>,
    in_first: Option<u64>,
    in_hash: Option<u64>,
    out_first: Option<u64>,
    out_hash: Option<u64>,
    out_marks: Vec<String>,
}

pub(super) struct Inferer {
    // Declared in drop order: the backend's mems wrap, or are, the slots'
    // buffers, so they and the context go first, then the dups they were
    // handed, then the slots.
    backend: RknnBackend,
    /// One per slot, for `slot_fds_intact`.
    imported: Imports,
    planned: Option<Planned>,
    /// By slot index, for `fd` and `mem`.
    mems: Vec<InputMem>,
    rga: Rga,
    heap: DmaHeap,
    scale: Scale,
    infer: Infer,
    native: sys::TensorAttr,
    outputs: Vec<String>,
    frames: u64,
    /// `copy`'s bytes, reused.
    bytes: Vec<u8>,
    s: Samples,
}

impl Inferer {
    /// Opens librga, the heap and the model now, so that any missing, or a
    /// model whose input is not `--scale`, fails before anything is decoded.
    pub(super) fn open(scale: &Scale, infer: &Infer) -> Result<Self> {
        let rga = Rga::open()?;
        let heap = DmaHeap::open(Path::new(SYSTEM_HEAP))?;
        let mut backend = RknnBackend::open(&infer.model, &SessionOptions::default())?;
        let io = backend.io();
        let size = io
            .declared_input_size
            .context("the model declares no input size")?;
        if size != scale.size {
            bail!("--scale {} is not the model's input {size}", scale.size);
        }
        let outputs = io.outputs.iter().map(|d| d.name.clone()).collect();
        let native = backend.native_input()?;
        Ok(Self {
            backend,
            imported: Imports::default(),
            planned: None,
            mems: Vec::new(),
            rga,
            heap,
            scale: scale.clone(),
            infer: infer.clone(),
            native,
            outputs,
            frames: 0,
            bytes: Vec::new(),
            s: Samples::default(),
        })
    }

    fn plan(&mut self, frame: &Frame) -> Result<()> {
        let geometry = frame.geometry();
        if let Some(planned) = &self.planned {
            let planned = planned.blitter.plan().source;
            ensure!(
                planned == geometry,
                "--infer runs one geometry: {geometry:?} after {planned:?}"
            );
            return Ok(());
        }
        let plan = Plan::new(geometry, self.scale.size, self.scale.policy)?;
        let mut slots = SlotAllocator::new(self.rga, &self.heap, &plan, self.infer.order);
        let count = self.infer.slots;
        if self.infer.input == InputMode::Mem {
            let mut mems = FromMems {
                slots,
                backend: &mut self.backend,
                mems: Vec::new(),
            };
            self.planned = Some(Planned::new(self.rga, plan, count, &mut mems)?);
            self.mems = mems.mems;
            return Ok(());
        }
        // Stored before any import: the mems the backend holds are handed the
        // slots' mappings, so a failed import must leave the slots owned by
        // `self`, which drops them after the backend.
        let planned = self
            .planned
            .insert(Planned::new(self.rga, plan, count, &mut slots)?);
        if self.infer.input == InputMode::Fd {
            let mut leases: Vec<_> = (0..count).filter_map(|_| planned.pool.acquire()).collect();
            ensure!(leases.len() == count, "a slot is still held");
            leases.sort_by_key(|lease| lease.index());
            for lease in &leases {
                let slot = lease.slot();
                let who = identity(slot.fd()).context("fstat of a slot's fd")?;
                // SAFETY: the slot, and so its fd, is live while `lease` is.
                let dup = unsafe { BorrowedFd::borrow_raw(slot.fd()) }
                    .try_clone_to_owned()
                    .context("dup of a slot's fd")?
                    .into_raw_fd();
                // Before the import, which may fail having taken the dup.
                self.imported.0.push(ImportedFd { fd: dup, who });
                // SAFETY: `self.imported` keeps the dup open, and
                // `self.planned` the mapping, until after the backend drops
                // (see the field order); the mapping is only ever read.
                let mem = unsafe {
                    self.backend
                        .import_input(dup, slot.addr().as_ptr().cast::<c_void>())
                }?;
                self.mems.push(mem);
            }
        }
        Ok(())
    }

    pub(super) fn frame(&mut self, frame: &Frame) -> Result<()> {
        self.frames += 1;
        let due = (self.frames - 1).is_multiple_of(self.scale.every);
        if !due || self.s.blit_ms.len() as u64 >= self.infer.samples {
            return Ok(());
        }
        ensure!(frame.is_nv12(), "--infer needs linear NV12 frames");
        self.plan(frame)?;
        let Planned { blitter, pool } = self.planned.as_mut().expect("set above");
        let (backend, s) = (&mut self.backend, &mut self.s);

        let (cpu, proc_cpu) = (thread_cpu(), process_cpu_total());
        let started = Instant::now();
        // None is counted by the pool and reported as `exhausted`.
        let Some(mut lease) = pool.acquire() else {
            return Ok(());
        };
        if s.last_slot.is_some_and(|last| last != lease.index()) {
            s.slot_changes += 1;
        }
        s.last_slot = Some(lease.index());
        let geometry = frame.geometry();
        blitter.blit(frame.fd(), geometry, frame.is_full_range(), &mut lease)?;
        let blitted = Instant::now();
        if self.infer.input == InputMode::Copy {
            let mut bytes = std::mem::take(&mut self.bytes);
            bytes.clear();
            lease.slot().read(|slot| bytes.extend_from_slice(slot))?;
            let size = self.scale.size;
            let tensor = InputTensor::new(size, TensorLayout::Nhwc, TensorValues::U8(bytes));
            backend.set_input(tensor)?;
        } else {
            let mem = self.mems[lease.index()];
            match self.infer.sync {
                SyncMode::None => {}
                SyncMode::DmaBuf => lease.slot().read(|_| ())?,
                SyncMode::Rknn(mode) => backend.sync_input(mem, mode)?,
            }
            backend.bind_input(mem)?;
            s.binds += 1;
        }
        let handed = Instant::now();
        let read = backend.infer()?;
        let ran = Instant::now();
        let outputs = backend.outputs()?;
        let got = Instant::now();
        let cpu = thread_cpu().saturating_sub(cpu);
        let proc_cpu = process_cpu_total().saturating_sub(proc_cpu);

        let mut out = FNV_OFFSET;
        for name in &self.outputs {
            for v in outputs.get(name)?.values {
                out = fnv1a(out, &v.to_le_bytes());
            }
        }
        drop(outputs);
        let input = match read.map(|t| t.values) {
            Some(TensorValues::U8(bytes)) => {
                let hash = fnv1a(FNV_OFFSET, &bytes);
                self.bytes = bytes;
                hash
            }
            _ => lease.slot().read(|slot| fnv1a(FNV_OFFSET, slot))?,
        };
        drop(lease);

        s.blit_ms.push(ms(blitted - started));
        s.input_ms.push(ms(handed - blitted));
        s.run_ms.push(ms(ran - handed));
        s.output_ms.push(ms(got - ran));
        s.cpu_ms.push(ms(cpu));
        s.proc_cpu_ms.push(ms(proc_cpu));
        s.in_first.get_or_insert(input);
        s.in_hash = Some(chain(s.in_hash, input));
        s.out_first.get_or_insert(out);
        s.out_hash = Some(chain(s.out_hash, out));
        let n = s.blit_ms.len() as u64;
        if n.is_multiple_of(MARK_EVERY) && s.out_marks.len() < MAX_MARKS {
            s.out_marks.extend(hex(s.out_hash));
        }
        Ok(())
    }

    pub(super) fn report(mut self) -> Result<Vec<Value>> {
        // Destroys the mems and the context, so no dup settled below is
        // still the runtime's.
        drop(self.backend);
        let intact = (self.infer.input == InputMode::Fd).then(|| self.imported.settle());
        let mut plan = json!({"event": "scale_plan", "rga": self.rga.version(), "plans": 0});
        if let Some(planned) = &self.planned {
            plan["plans"] = 1.into();
            plan["plan"] = planned.json(self.scale.policy);
        }
        let exhausted = self
            .planned
            .as_ref()
            .map_or(0, |p| p.pool.stats().exhausted);
        let (n, s) = (&self.native, &mut self.s);
        let line = json!({
            "event": "infer",
            "input": name(&INPUTS, self.infer.input), "sync": name(&SYNCS, self.infer.sync),
            "order": name(&ORDERS, self.infer.order),
            "slots": self.infer.slots,
            "model": {
                "size": [self.scale.size.w, self.scale.size.h],
                "native_type": sys::type_name(n.type_), "w_stride": n.w_stride,
                "size_with_stride": n.size_with_stride, "outputs": self.outputs.len(),
            },
            "sampled": s.blit_ms.len(), "exhausted": exhausted, "binds": s.binds,
            "slot_changes": s.slot_changes,
            "blit_ms": summary(&mut s.blit_ms), "input_ms": summary(&mut s.input_ms),
            "run_ms": summary(&mut s.run_ms), "output_ms": summary(&mut s.output_ms),
            "cpu_ms": summary(&mut s.cpu_ms), "proc_cpu_ms": summary(&mut s.proc_cpu_ms),
            "slot_fds_intact": intact,
            "in_first_hash": hex(s.in_first), "in_hash": hex(s.in_hash),
            "out_first_hash": hex(s.out_first), "out_hash": hex(s.out_hash),
            "out_marks": s.out_marks,
            "process_cpu_ms": process_cpu(),
        });
        Ok(vec![plan, line])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    /// The file is returned too, so its inode outlives the assertions.
    fn dup_of(tag: &str) -> (File, ImportedFd) {
        let path = std::env::temp_dir().join(format!("infer-{}-{tag}", std::process::id()));
        let file = File::create(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        let fd = OwnedFd::from(file.try_clone().unwrap()).into_raw_fd();
        let who = identity(fd).unwrap();
        (file, ImportedFd { fd, who })
    }

    #[test]
    fn a_dup_left_open_is_closed() {
        let (_file, dup) = dup_of("open");
        let (fd, who) = (dup.fd, dup.who);
        assert!(dup.settle());
        assert_ne!(identity(fd), Some(who));
    }

    #[test]
    fn a_dup_closed_elsewhere_is_left_alone() {
        let (_file, dup) = dup_of("closed");
        // SAFETY: the test's own dup, closed as the runtime might.
        drop(unsafe { OwnedFd::from_raw_fd(dup.fd) });
        assert!(!dup.settle());
    }
}
