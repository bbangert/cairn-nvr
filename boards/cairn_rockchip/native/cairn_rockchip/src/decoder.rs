//! The decoder NIFs: access units into [`MppDecoder`], a sampled call's
//! newest picture blitted by RGA into a [`Pool`] slot, handed to the host as
//! a lease that `download/1` reads and `release/1` gives back. Terms are
//! `cairn-native`'s (`Cairn.Stage.DecoderNif`), with `lease` and `pool` in
//! a frame where that library's has `payload`.
//!
//! What blocks on drop — an `MppDecoder` (reset, destroy, thread join), a
//! pool's last reference (RGA release, munmap, close) — goes to
//! `cairn_ort`'s teardown thread: resource destructors run on normal
//! schedulers.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::ensure;
use cairn_detect::infer::{InputSize, ResizePolicy};
use cairn_ort::teardown;
use rustler::types::atom::{self, Atom};
use rustler::{Binary, Encoder, Env, NifMap, OwnedBinary, Resource, ResourceArc, Term};
use serde_json::{json, Value};

use crate::dma::{DmaHeap, SYSTEM_HEAP};
use crate::mpp::{Frame, MppDecoder, Put, GETS_PER_CALL};
use crate::pool::{Lease, Pool};
use crate::rga::{self, Blitter, ChannelOrder, Plan, Rga, Slot, SlotAllocator};

/// The core's pending slot, one in `Download`'s mailbox, one being read and
/// one being written.
const POOL_SLOTS: usize = 4;

const MINUTE: Duration = Duration::from_secs(60);

/// Timings kept per series per window. Only a stall stretches a window past
/// a minute, and `sample_fps` tops out at 30, so one has at most 1,800.
const MAX_SAMPLES: usize = 2048;

/// `cairn-native`'s `NativeError` vocabulary, which `DecoderCore` dispatches
/// on: `closed`, `poisoned` and `panicked` close and reopen the decoder,
/// `decoder_refused` turns it off, anything else is counted.
#[derive(Debug)]
enum DecodeError {
    Config(String),
    OpenStream(String),
    Decode(String),
    /// Permanent for this stream: a reopen would refuse again.
    DecoderRefused(String),
    Closed(String),
    Poisoned(String),
    Panicked(String),
}

impl DecodeError {
    /// The reason atom's name and the operator's message.
    fn parts(&self) -> (&'static str, &str) {
        match self {
            Self::Config(m) => ("config", m),
            Self::OpenStream(m) => ("open_stream", m),
            Self::Decode(m) => ("decode", m),
            Self::DecoderRefused(m) => ("decoder_refused", m),
            Self::Closed(m) => ("closed", m),
            Self::Poisoned(m) => ("poisoned", m),
            Self::Panicked(m) => ("panicked", m),
        }
    }
}

impl Encoder for DecodeError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let (reason, message) = self.parts();
        // As `cairn-native`'s: reporting an error must not itself panic.
        let reason = match Atom::from_str(env, reason) {
            Ok(atom) => atom.encode(env),
            Err(_) => reason.encode(env),
        };
        (reason, message).encode(env)
    }
}

type Result<T> = std::result::Result<T, DecodeError>;

fn chain(error: &anyhow::Error) -> String {
    format!("{error:#}")
}

/// For state a panic cannot leave half-written: taken whole, or timings.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The slot and the fit into it.
type Target = (InputSize, ResizePolicy);

/// The map `cairn-native`'s `RawDecoderParams` takes; every key required.
#[derive(NifMap)]
struct RawDecoderParams {
    decoder: String,
    width: usize,
    height: usize,
    /// Unread: a frame is RGB24 whatever the model's encoding, as `cairn-native`'s.
    encoding: String,
    resize: String,
    resize_pad: u8,
    /// Unread: MPP learns the geometry from the stream.
    source_width: Option<usize>,
    source_height: Option<usize>,
    motion_json: Option<String>,
}

impl RawDecoderParams {
    fn resolve(&self) -> Result<Target> {
        let resolved = || -> anyhow::Result<Target> {
            let decoder = &self.decoder;
            ensure!(
                decoder == "rkmpp",
                "decoder {decoder:?}: this library decodes rkmpp"
            );
            let motion = self.motion_json.is_some();
            ensure!(!motion, "motion_json: the rkmpp decoder measures no motion");
            let slot = InputSize {
                w: self.width,
                h: self.height,
            };
            rga::check_slot(slot)?;
            Ok((
                slot,
                ResizePolicy::from_wire(&self.resize, self.resize_pad)?,
            ))
        };
        resolved().map_err(|e| DecodeError::Config(chain(&e)))
    }
}

/// RGA and the lease resource behind a seam, so that the decode flow is
/// testable without either.
trait Scaler: Send + 'static {
    type Slot: Send + Sync + 'static;
    type Handle;
    fn pool(&mut self, plan: &Plan) -> anyhow::Result<Pool<Self::Slot>>;
    fn handle(lease: Lease<Self::Slot>, plan: &Plan, downloads: &Timings) -> Self::Handle;
    fn blit(
        &mut self,
        plan: &Plan,
        frame: &Frame,
        lease: &mut Lease<Self::Slot>,
    ) -> anyhow::Result<()>;
}

struct Rk {
    rga: Rga,
    heap: DmaHeap,
}

impl Scaler for Rk {
    type Slot = Slot;
    type Handle = ResourceArc<LeaseRef>;

    fn pool(&mut self, plan: &Plan) -> anyhow::Result<Pool<Slot>> {
        let mut slots = SlotAllocator::new(self.rga, &self.heap, plan, ChannelOrder::Rgb);
        Pool::new(POOL_SLOTS, &mut slots)
    }

    fn blit(&mut self, plan: &Plan, frame: &Frame, lease: &mut Lease<Slot>) -> anyhow::Result<()> {
        let (fd, geometry) = (frame.fd(), frame.geometry());
        Blitter::new(self.rga, *plan).blit(fd, geometry, frame.is_full_range(), lease)
    }

    fn handle(lease: Lease<Slot>, plan: &Plan, downloads: &Timings) -> Self::Handle {
        ResourceArc::new(LeaseRef {
            held: Held(Mutex::new(Some(lease))),
            content: plan.fit.inner,
            row: plan.slot.w * 3,
            downloads: Arc::clone(downloads),
        })
    }
}

/// `download/1`'s timings, shared by a decoder and every lease it handed out.
type Timings = Arc<Mutex<Vec<f64>>>;

fn push_capped(samples: &mut Vec<f64>, sample: f64) {
    if samples.len() < MAX_SAMPLES {
        samples.push(sample);
    }
}

#[derive(Default)]
struct Minute {
    aus: u64,
    frames: u64,
    blitted: u64,
    exhausted: u64,
    dropped_aus: u64,
    blit_ms: Vec<f64>,
}

struct Stream<S: Scaler> {
    camera_id: String,
    mpp: MppDecoder,
    scaler: S,
    target: Target,
    planned: Option<(Plan, Pool<S::Slot>)>,
    poisoned: Option<String>,
    minute: Minute,
    minute_from: Instant,
    downloads: Timings,
}

/// Whether a picture completed, and the sampled one's frame map.
type Decoded<H> = (bool, Option<RawLeasedFrame<H>>);

impl<S: Scaler> Stream<S> {
    fn new(camera_id: String, mpp: MppDecoder, scaler: S, target: Target) -> Self {
        Self {
            camera_id,
            mpp,
            scaler,
            target,
            planned: None,
            poisoned: None,
            minute: Minute::default(),
            minute_from: Instant::now(),
            downloads: Timings::default(),
        }
    }

    /// `completed` is whether a picture came out of MPP in this call, which
    /// pipelines: it need not be `au`'s.
    fn decode_au(&mut self, au: &[u8], pts: i64, sample: bool) -> Result<Decoded<S::Handle>> {
        if let Some(why) = &self.poisoned {
            return Err(DecodeError::Poisoned(why.clone()));
        }
        self.report();
        if au.is_empty() {
            return Err(DecodeError::Decode("empty access unit".into()));
        }
        self.minute.aus += 1;
        let mut newest = None;
        let mut put = self.put(au, pts);
        if matches!(put, Ok(Put::Full)) {
            self.drain(&mut newest)?;
            put = self.put(au, pts);
            if matches!(put, Ok(Put::Full)) {
                self.minute.dropped_aus += 1;
            }
        }
        // A failed put still drains, or pictures already decoded stay in MPP.
        self.drain(&mut newest)?;
        put?;
        let completed = newest.is_some();
        let Some(frame) = newest.filter(|_| sample) else {
            return Ok((completed, None));
        };
        let leased = self.lease(&frame);
        // Every `Frame` is gone before this returns, dropped while `mpp`
        // still holds MPP's context, so a drop only hands MPP its buffer
        // back: a lease holds a pool slot, never a frame, and no picture of
        // MPP's waits on the BEAM's collector.
        drop(frame);
        if let Err(DecodeError::DecoderRefused(_)) = &leased {
            self.flush();
        }
        Ok((completed, leased?))
    }

    fn put(&mut self, au: &[u8], pts: i64) -> Result<Put> {
        let put = self.mpp.put(au, pts);
        put.map_err(|e| DecodeError::Decode(chain(&e)))
    }

    /// Up to [`GETS_PER_CALL`] pictures, keeping the newest.
    fn drain(&mut self, newest: &mut Option<Frame>) -> Result<()> {
        for _ in 0..GETS_PER_CALL {
            match self.mpp.next_frame() {
                Ok(Some(frame)) => {
                    self.minute.frames += 1;
                    *newest = Some(frame);
                }
                Ok(None) => break,
                Err(e) => return Err(self.poison(chain(&e))),
            }
        }
        Ok(())
    }

    /// `None` when every slot is held: a counted drop, the sample is lost.
    fn lease(&mut self, frame: &Frame) -> Result<Option<RawLeasedFrame<S::Handle>>> {
        let observed_at_ms = unix_ms(SystemTime::now());
        if !frame.is_nv12() {
            return Err(DecodeError::DecoderRefused(format!(
                "MPP decoded format {:#x}, not the linear NV12 RGA is planned for",
                frame.format()
            )));
        }
        let geometry = frame.geometry();
        if self.planned.as_ref().map(|p| p.0.source) != Some(geometry) {
            // The slot passed `check_slot` at open, so what a plan refuses
            // (scale range, NV12 alignment) is the stream's own geometry.
            let plan = Plan::new(geometry, self.target.0, self.target.1)
                .map_err(|e| DecodeError::DecoderRefused(format!("rga: {}", chain(&e))))?;
            let pool = match self.scaler.pool(&plan) {
                Ok(pool) => pool,
                Err(e) => return Err(self.poison(format!("rga pool: {}", chain(&e)))),
            };
            if let Some((_, old)) = self.planned.replace((plan, pool)) {
                // Leases still out hold it too, so this may or may not be
                // the last reference.
                teardown::defer(old);
            }
        }
        let (plan, pool) = self.planned.as_ref().expect("planned above");
        let (plan, started) = (*plan, Instant::now());
        let Some(mut lease) = pool.acquire() else {
            self.minute.exhausted += 1;
            return Ok(None);
        };
        if let Err(e) = self.scaler.blit(&plan, frame, &mut lease) {
            // librga logs every failure to the process's stdout: end the
            // stream (`DecoderCore` reopens it after a cooldown) rather than
            // repeat the failure, and its log, per frame.
            return Err(self.poison(format!("rga: {}", chain(&e))));
        }
        push_capped(&mut self.minute.blit_ms, ms(started.elapsed()));
        self.minute.blitted += 1;
        let pool = lease.pool_id();
        let handle = S::handle(lease, &plan, &self.downloads);
        let pts = frame.pts();
        Ok(Some(RawLeasedFrame::new(
            handle,
            pool,
            &plan,
            pts,
            observed_at_ms,
        )))
    }

    fn poison(&mut self, why: String) -> DecodeError {
        self.poisoned = Some(why.clone());
        self.flush();
        DecodeError::Poisoned(why)
    }

    fn report(&mut self) {
        if self.minute_from.elapsed() >= MINUTE {
            self.flush();
        }
    }

    /// Also run when the stream ends: its partial window explains why. The
    /// window runs from the last report, which a stall can stretch past a
    /// minute; MPP's counters are the decoder's running totals.
    fn flush(&mut self) {
        let mut m = std::mem::take(&mut self.minute);
        let mut downloads = std::mem::take(&mut *lock(&self.downloads));
        let counts = [m.aus, m.frames, m.blitted, m.exhausted, m.dropped_aus];
        let mpp = self.mpp.stats();
        let totals = [mpp.errinfo, mpp.discarded, mpp.info_changes];
        cairn_detect::note!(
            "rkmpp {}: {}s aus/frames/blitted/exhausted/dropped_aus={counts:?} \
             total_errinfo/discarded/info_changes={totals:?} blit_ms={} download_ms={}",
            self.camera_id,
            self.minute_from.elapsed().as_secs(),
            summary(&mut m.blit_ms),
            summary(&mut downloads)
        );
        self.minute_from = Instant::now();
    }
}

/// Shared with the probe's `--scale`.
pub(crate) fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 1e6).round() / 1e3
}

pub(crate) fn summary(samples: &mut [f64]) -> Value {
    samples.sort_by(f64::total_cmp);
    let at = |p: f64| samples[((samples.len() - 1) as f64 * p).round() as usize];
    match samples.len() {
        0 => json!({"count": 0}),
        n => json!({"count": n, "p50": at(0.5), "p99": at(0.99), "max": at(1.0)}),
    }
}

fn unix_ms(at: SystemTime) -> i64 {
    let since = at.duration_since(UNIX_EPOCH).unwrap_or_default();
    i64::try_from(since.as_millis()).unwrap_or(i64::MAX)
}

/// One camera's stream, `None` once closed.
struct Shared<S: Scaler>(Mutex<Option<Stream<S>>>);

impl<S: Scaler> Shared<S> {
    fn decode_au(&self, au: &[u8], pts: i64, sample: bool) -> Result<Decoded<S::Handle>> {
        let mut state = self.0.lock().map_err(|_| {
            DecodeError::Poisoned("a previous call panicked holding this decoder's state".into())
        })?;
        let stream = state
            .as_mut()
            .ok_or(DecodeError::Closed("the decoder is closed".into()))?;
        stream.decode_au(au, pts, sample)
    }

    /// Recovers a poisoned lock: closing only logs and drops the state.
    fn close(&self) -> bool {
        let stream = lock(&self.0).take();
        let flushed = stream.map(|mut s| {
            // Empty when a poison or a refusal already flushed it.
            if s.minute.aus > 0 {
                s.flush();
            }
            teardown::defer(s)
        });
        flushed.is_some()
    }
}

/// A lease the host holds, `None` once released.
struct Held<S: Send + Sync + 'static>(Mutex<Option<Lease<S>>>);

impl<S: Send + Sync + 'static> Held<S> {
    /// [`Lease::release`] frees the slot here, on atomics; the pool reference
    /// it hands back may be a closed decoder's last or a replaced pool's last,
    /// so it goes to teardown.
    fn release(&self) {
        if let Some(lease) = lock(&self.0).take() {
            teardown::defer(lease.release());
        }
    }
}

impl<S: Send + Sync + 'static> Drop for Held<S> {
    fn drop(&mut self) {
        self.release();
    }
}

/// The content rectangle's rows out of a slot whose rows are `row` bytes.
fn pack(slot: &[u8], row: usize, content: InputSize, out: &mut [u8]) {
    let width = content.w * 3;
    for (from, to) in slot.chunks(row).zip(out.chunks_exact_mut(width)) {
        to.copy_from_slice(&from[..width]);
    }
}

static RGA: OnceLock<std::result::Result<Rga, String>> = OnceLock::new();

/// librga's first session open `setenv`s `ROCKCHIP_RGA_API_VERSION` (and
/// prints its banner), so it happens here, before this library starts any
/// MPP thread;
/// `setenv` races only native `getenv` callers, since the BEAM's `os:getenv`
/// reads its own copy. A failure is kept for `open_decoder` to report: the
/// engine NIFs in this library do not need librga.
pub(crate) fn load(_: Env<'_>, _: Term<'_>) -> bool {
    let _ = rga();
    true
}

fn rga() -> std::result::Result<Rga, String> {
    RGA.get_or_init(|| Rga::open().map_err(|e| chain(&e)))
        .clone()
}

struct DecoderRef(Shared<Rk>);

#[rustler::resource_impl]
impl Resource for DecoderRef {
    const IMPLEMENTS_DESTRUCTOR: bool = true;

    fn destructor(self, _env: Env<'_>) {
        teardown::defer(self);
    }
}

/// [`Held`] drops a lease never released the way `release/1` does.
struct LeaseRef {
    held: Held<Slot>,
    content: InputSize,
    row: usize,
    downloads: Timings,
}

#[rustler::resource_impl]
impl Resource for LeaseRef {}

/// `lease` is a [`LeaseRef`] outside tests.
#[derive(NifMap)]
struct RawLeasedFrame<L> {
    lease: L,
    pool: u64,
    width: usize,
    height: usize,
    orig_width: usize,
    orig_height: usize,
    pts: Option<i64>,
    observed_at_ms: i64,
    scale_x: f64,
    scale_y: f64,
    pad_w: usize,
    pad_h: usize,
    /// Always `nil`: the chain's motion gate sits after `Download`.
    motion: Option<()>,
}

impl<L> RawLeasedFrame<L> {
    /// The content is the plan's `fit.inner`, at the slot's top left.
    fn new(lease: L, pool: u64, plan: &Plan, pts: i64, observed_at_ms: i64) -> Self {
        let (content, slot, source) = (plan.fit.inner, plan.slot, plan.source);
        Self {
            lease,
            pool,
            width: content.w,
            height: content.h,
            orig_width: source.width as usize,
            orig_height: source.height as usize,
            pts: Some(pts),
            observed_at_ms,
            scale_x: plan.scale.0,
            scale_y: plan.scale.1,
            pad_w: slot.w - content.w,
            pad_h: slot.h - content.h,
            motion: None,
        }
    }
}

/// MPP identifies the SoC from `/proc/device-tree/compatible`, and without
/// it fails the open with a bare `MPP_NOK`.
fn open_mpp() -> Result<MppDecoder> {
    MppDecoder::open().map_err(|e| {
        let mut message = format!("mpp: {}", chain(&e));
        if message.contains("MPP_NOK") {
            message.push_str("; MPP reads /proc/device-tree/compatible (no device tree?)");
        }
        DecodeError::OpenStream(message)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_decoder(camera_id: String, params: RawDecoderParams) -> Result<ResourceArc<DecoderRef>> {
    guarded("open_decoder", || {
        let target = params.resolve()?;
        let rga = rga().map_err(|e| DecodeError::OpenStream(format!("librga: {e}")))?;
        let heap = DmaHeap::open(Path::new(SYSTEM_HEAP))
            .map_err(|e| DecodeError::OpenStream(chain(&e)))?;
        let stream = Stream::new(camera_id, open_mpp()?, Rk { rga, heap }, target);
        let shared = Shared(Mutex::new(Some(stream)));
        Ok(ResourceArc::new(DecoderRef(shared)))
    })
}

/// DirtyIo, not DirtyCpu: a sampled call's blit is an ioctl that waits on
/// RGA.
#[rustler::nif(schedule = "DirtyIo")]
fn decode_au(
    decoder: ResourceArc<DecoderRef>,
    au: Binary<'_>,
    pts: i64,
    sample: bool,
) -> Result<Decoded<ResourceArc<LeaseRef>>> {
    guarded("decode_au", || {
        decoder.0.decode_au(au.as_slice(), pts, sample)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn close_decoder(decoder: ResourceArc<DecoderRef>) -> Result<bool> {
    guarded("close_decoder", || Ok(decoder.0.close()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn download<'a>(env: Env<'a>, lease: ResourceArc<LeaseRef>) -> Result<Binary<'a>> {
    guarded("download", || {
        let started = Instant::now();
        let content = lease.content;
        let len = content.w * content.h * 3;
        let mut out = OwnedBinary::new(len).ok_or_else(|| {
            DecodeError::Decode(format!("allocating a {len}-byte frame binary failed"))
        })?;
        let held = lock(&lease.held.0);
        let slot = held
            .as_ref()
            .ok_or(DecodeError::Closed("the lease is released".into()))?
            .slot();
        slot.read(|bytes| pack(bytes, lease.row, content, out.as_mut_slice()))
            .map_err(|e| DecodeError::Decode(chain(&e)))?;
        drop(held);
        push_capped(&mut lock(&lease.downloads), ms(started.elapsed()));
        Ok(Binary::from_owned(out, env))
    })
}

/// DirtyIo for the lock alone: it is the one `download/1` holds across the
/// dma-buf sync bracket and the copy, so a release racing a download waits
/// behind both. The rest is atomics and a channel send.
#[rustler::nif(schedule = "DirtyIo")]
fn release(lease: ResourceArc<LeaseRef>) -> Atom {
    lease.held.release();
    atom::ok()
}

/// `cairn-native`'s: a panic becomes a `panicked` term the host can act on.
fn guarded<T>(what: &'static str, body: impl FnOnce() -> Result<T>) -> Result<T> {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or_else(|payload: Box<dyn Any + Send>| {
        let message = (payload.downcast_ref::<&str>().copied())
            .or_else(|| payload.downcast_ref::<String>().map(String::as_str));
        let message = message.unwrap_or("unknown payload");
        Err(DecodeError::Panicked(format!("{what} panicked: {message}")))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mpp::{sys, tests as stub, Geometry};
    use crate::pool::Allocator;
    use std::sync::atomic::Ordering::SeqCst;

    const LETTERBOX: ResizePolicy = ResizePolicy::Letterbox { pad: 114 };

    /// Slots of nothing, a blit that fails when told to, and the range of
    /// each picture it blitted.
    struct Fake(bool, Vec<bool>);

    impl Allocator for Fake {
        type Slot = ();
        fn allocate(&mut self, _: usize) -> anyhow::Result<()> {
            Ok(())
        }
    }

    impl Scaler for Fake {
        type Slot = ();
        type Handle = Lease<()>;
        fn pool(&mut self, _: &Plan) -> anyhow::Result<Pool<()>> {
            Pool::new(POOL_SLOTS, self)
        }
        fn blit(&mut self, _: &Plan, frame: &Frame, _: &mut Lease<()>) -> anyhow::Result<()> {
            ensure!(!self.0, "improcess returned -1");
            self.1.push(frame.is_full_range());
            Ok(())
        }
        fn handle(lease: Lease<()>, _: &Plan, _: &Timings) -> Lease<()> {
            lease
        }
    }

    fn stream(blit_fails: bool) -> Stream<Fake> {
        let mpp = MppDecoder::with_library(stub::library()).unwrap();
        stub::calls();
        let target = (InputSize::square(640), LETTERBOX);
        Stream::new("cam".into(), mpp, Fake(blit_fails, Vec::new()), target)
    }

    fn err<T>(result: Result<T>) -> DecodeError {
        result.err().expect("an error")
    }

    fn params() -> RawDecoderParams {
        RawDecoderParams {
            decoder: "rkmpp".into(),
            width: 640,
            height: 640,
            encoding: "raw_bgr".into(),
            resize: "letterbox".into(),
            resize_pad: 114,
            source_width: None,
            source_height: None,
            motion_json: None,
        }
    }

    #[test]
    fn params_refuse_another_decoder_a_bad_slot_motion_and_a_bad_resize() {
        let resolved = params().resolve().unwrap();
        assert_eq!(resolved, (InputSize::square(640), LETTERBOX));
        let refused = |edit: fn(&mut RawDecoderParams), says: &str| {
            let mut raw = params();
            edit(&mut raw);
            let error = err(raw.resolve());
            assert_eq!(error.parts().0, "config");
            assert!(error.parts().1.contains(says), "{error:?}");
        };
        refused(|p| p.decoder = "sw".into(), "decodes rkmpp");
        refused(|p| p.width = 0, "outside RGA2's");
        refused(|p| p.motion_json = Some("{}".into()), "no motion");
        refused(|p| p.resize = "crop".into(), "resize policy");
    }

    #[test]
    fn a_frame_map_agrees_with_the_software_fit_for_16_9_and_4_3() {
        let slot = InputSize::square(640);
        for (w, h) in [(1920, 1080), (2560, 1920)] {
            let mut source = Geometry::default();
            (source.width, source.height) = (w as u32, h as u32);
            (source.hor_stride, source.ver_stride) = (w as u32, h as u32);
            let plan = Plan::new(source, slot, LETTERBOX).unwrap();
            let map = RawLeasedFrame::new((), 7, &plan, 9, 0);
            let fit = LETTERBOX.fit(slot, InputSize { w, h }).inner;
            let got = (map.width, map.height, map.orig_width, map.orig_height);
            assert_eq!(got, (fit.w, fit.h, w, h));
            let scale = (fit.w as f64 / w as f64, fit.h as f64 / h as f64);
            assert_eq!((map.scale_x, map.scale_y), scale);
            assert_eq!((map.pad_w, map.pad_h), (640 - fit.w, 640 - fit.h));
            assert_eq!((map.pool, map.pts, map.motion), (7, Some(9), None));
        }
    }

    #[test]
    fn a_full_put_is_retried_once_after_a_drain_then_counted() {
        let _guard = stub::stubs();
        let mut s = stream(false);
        stub::PUT_CODE.store(sys::ERR_BUFFER_FULL, SeqCst);
        stub::queue(&[stub::picture(1), stub::picture(2)]);
        let (completed, leased) = s.decode_au(&[1], 7, false).unwrap();
        assert!(completed && leased.is_none());
        let calls = stub::calls();
        assert_eq!(calls.matches("put(").count(), 2);
        assert_eq!(
            calls.matches("frame_deinit").count(),
            2,
            "every frame got is gone"
        );
        assert_eq!((s.minute.dropped_aus, s.minute.frames), (1, 2));
        s.minute_from -= MINUTE;
        assert!(matches!(s.decode_au(&[1], 8, true), Ok((false, None))));
        assert_eq!((s.minute.aus, s.minute.dropped_aus), (1, 1), "a new minute");
        assert_eq!(err(s.decode_au(&[], 9, true)).parts().0, "decode");
        assert_eq!((s.minute.aus, s.minute.blitted), (1, 0));
    }

    #[test]
    fn the_newest_picture_is_leased_and_exhaustion_is_a_counted_drop() {
        let _guard = stub::stubs();
        let mut s = stream(false);
        let sample = |s: &mut Stream<Fake>, pts| {
            stub::queue(&[stub::picture(pts - 1), stub::picture(pts)]);
            let (completed, leased) = s.decode_au(&[1], pts, true).unwrap();
            assert!(completed);
            assert_eq!(stub::calls().matches("frame_deinit").count(), 2);
            leased
        };
        let mut leases: Vec<_> = (1..=4).map(|i| sample(&mut s, i * 10).unwrap()).collect();
        let pts: Vec<_> = leases.iter().map(|l| l.pts).collect();
        assert_eq!(pts, [10, 20, 30, 40].map(Some));
        assert!(sample(&mut s, 50).is_none());
        assert_eq!((s.minute.blitted, s.minute.exhausted), (4, 1));

        let held = Held(Mutex::new(Some(leases.remove(0).lease)));
        assert!(
            sample(&mut s, 60).is_none(),
            "the other three are still held"
        );
        held.release();
        held.release();
        let again = sample(&mut s, 70).expect("the slot is free again");
        let never_released = Held(Mutex::new(Some(again.lease)));
        assert!(sample(&mut s, 80).is_none());
        drop(never_released);
        assert!(
            sample(&mut s, 90).is_some(),
            "dropping a lease frees its slot"
        );
    }

    #[test]
    fn a_range_change_between_two_pictures_of_one_geometry_reaches_the_next_blit() {
        let _guard = stub::stubs();
        let mut s = stream(false);
        for frame in [stub::picture(1), stub::full_range(2), stub::picture(3)] {
            stub::queue(&[frame]);
            assert!(s.decode_au(&[1], 1, true).unwrap().1.is_some());
        }
        assert_eq!(s.scaler.1, [false, true, false]);
    }

    #[test]
    fn a_failed_blit_poisons_the_stream_until_it_is_closed() {
        let _guard = stub::stubs();
        let shared = Shared(Mutex::new(Some(stream(true))));
        stub::queue(&[stub::picture(1)]);
        let reason = |sample| err(shared.decode_au(&[1], 1, sample)).parts().0;
        let error = err(shared.decode_au(&[1], 1, true));
        assert_eq!(error.parts(), ("poisoned", "rga: improcess returned -1"));
        assert_eq!(stub::calls().matches("frame_deinit").count(), 1);
        assert_eq!(reason(false), "poisoned");
        assert!(shared.close());
        assert_eq!(reason(false), "closed");
        assert!(!shared.close());
    }

    #[test]
    fn download_packs_the_content_rows_and_a_panic_is_a_term() {
        let (slot, mut out): (Vec<u8>, _) = ((0..24).collect(), [0; 12]);
        pack(&slot, 12, InputSize { w: 2, h: 2 }, &mut out);
        assert_eq!(out, [0, 1, 2, 3, 4, 5, 12, 13, 14, 15, 16, 17]);
        let caught = guarded("t", || -> Result<()> { panic!("boom") });
        assert_eq!(err(caught).parts(), ("panicked", "t panicked: boom"));
    }
}
