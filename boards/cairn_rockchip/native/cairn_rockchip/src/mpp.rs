//! The H.264 hardware decoder: Rockchip MPP through librockchip_mpp, opened
//! at run time ([`sys::Library::load`]) and never linked. One access unit in,
//! one packet; pictures out as [`Frame`]s that own MPP's frame and its
//! dma-buf.
//!
//! Blocking audit, because a NIF will call this on a dirty scheduler:
//! - [`MppDecoder::put`] makes one `decode_put_packet` with the input timeout
//!   at 0: no free task is `MPP_ERR_BUFFER_FULL` at once, and the packet is
//!   copied inside the call. That call polls *blocking* for a reserved EOS
//!   task on a context's first put (a fresh context has free tasks, so it
//!   returns) and on the first put after an EOS packet (where it can wait),
//!   so nothing is put after [`MppDecoder::finish`].
//! - [`MppDecoder::next_frame`] gets with the output timeout at 0, which
//!   returns no frame when none is ready, and takes at most
//!   [`GETS_PER_CALL`] frames per call.
//! - An info change makes two control commands: `MPP_DEC_SET_EXT_BUF_GROUP`,
//!   which MPP handles in the calling thread, then
//!   `MPP_DEC_SET_INFO_CHANGE_READY`, which it hands to its parser thread
//!   (waking it) and waits on until that thread has run it; decoding does not
//!   resume without it.
//! - Dropping the last holder of a context, the decoder or any frame, resets
//!   and destroys it, which joins MPP's threads: that blocks.
//!
//! Nothing here sleeps or retries. No test reaches a real MPP (x86 has none):
//! the stubs below pin the call sequences, the board run proves the library.

pub mod sys;

use std::ffi::{c_int, c_void, CStr, OsString};
use std::mem::size_of;
use std::os::fd::RawFd;
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering::Relaxed};
use std::sync::Arc;

use anyhow::{bail, Result};

/// `CAIRN_MPP_LIBRARY` names the library to load; unset, the loader's search
/// path finds this one.
const DEFAULT_LIBRARY: &str = "librockchip_mpp.so.1";

/// The most frames one [`MppDecoder::next_frame`] takes from MPP, so a run of
/// frames that are not pictures cannot hold the caller; the rest wait for the
/// next call.
pub const GETS_PER_CALL: usize = 8;

/// `mpi_dec_test`'s count. H.264's DPB can take 16 of these, and each frame
/// a caller holds keeps one.
const FRAME_BUFFERS: i32 = 24;

/// MPP's log tag and caller name for the buffer calls.
const CALLER: &CStr = c"cairn_rockchip";

fn check(call: &str, code: c_int) -> Result<()> {
    if code != sys::OK {
        bail!("{call} returned {code} ({})", sys::code_name(code));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Put {
    Accepted,
    /// MPP has no free input task; the packet was not taken.
    Full,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    /// Access units, not counting the EOS packet.
    pub accepted: u64,
    pub input_full: u64,
    pub frames: u64,
    pub info_changes: u64,
    pub errinfo: u64,
    pub discarded: u64,
}

/// The visible picture apart from the strides its buffer is laid out in,
/// which are padded (1080 visible lines are 1088 stored).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
    pub hor_stride: u32,
    pub ver_stride: u32,
    pub buf_size: usize,
}

/// The MPP context with its vtable entries and the frame buffer group, shared
/// by the decoder and every frame it handed out.
///
/// Dropping the last holder resets and destroys the context, which joins
/// MPP's threads, and then puts the group: it **blocks**. A NIF that holds a
/// decoder or a frame must hand its last reference to a teardown thread.
struct Context {
    library: sys::Library,
    ctx: sys::Ctx,
    put_packet: sys::DecodePutPacketFn,
    get_frame: sys::DecodeGetFrameFn,
    reset: sys::ResetFn,
    control: sys::ControlFn,
    /// Null until the first info change. Written only through
    /// `&mut MppDecoder`; atomic so that `Context` can be `Sync` without a lock.
    group: AtomicPtr<c_void>,
}

// SAFETY: put, get and `Context::control` are made through `&mut
// MppDecoder`, so from one thread at a time, and `drop` has the last
// reference. A `Frame` does reach the decoder, concurrently with those: its
// drop can release its buffer, and MPP then runs, under the group's lock, the
// callback it installed with the external group, which notifies the decoder
// under its parser thread's lock. MPP's locks make that sound, not `&mut`.
// `group` is atomic.
unsafe impl Send for Context {}
// SAFETY: as for `Send`.
unsafe impl Sync for Context {}

impl Context {
    /// `cmd` by its value, as `rk_mpi_cmd.h` lists it.
    fn control(&self, cmd: c_int, param: *mut c_void) -> Result<()> {
        // SAFETY: `ctx` is live; each caller passes the parameter its `cmd`
        // reads.
        let code = unsafe { (self.control)(self.ctx, cmd, param) };
        check(&format!("control({cmd:#x})"), code)
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        // SAFETY: the last reference: no frame from `ctx` is still held (each
        // holds this `Arc`), and nothing else calls into it. `mpp_destroy`
        // joins MPP's threads, so the group has no user left when it is put.
        unsafe {
            let mut codes = vec![("reset", (self.reset)(self.ctx))];
            codes.push(("mpp_destroy", (self.library.destroy)(self.ctx)));
            let group = *self.group.get_mut();
            if !group.is_null() {
                codes.push(("mpp_buffer_group_put", (self.library.group_put)(group)));
            }
            for (call, code) in codes.into_iter().filter(|&(_, code)| code != sys::OK) {
                cairn_detect::note!("mpp: {call} returned {code} ({})", sys::code_name(code));
            }
        }
    }
}

/// An `MppPacket`, deinit'd on every path out of a put.
struct Packet<'a>(&'a sys::Library, sys::Packet);

impl Drop for Packet<'_> {
    fn drop(&mut self) {
        // SAFETY: `self.1` came from a successful `mpp_packet_init` and is
        // deinit'd once, here.
        unsafe { (self.0.packet_deinit)(&mut self.1) };
    }
}

/// `Send` without an `unsafe impl`: its only pointers are in the `Context`.
pub struct MppDecoder {
    context: Arc<Context>,
    finished: bool,
    eos: bool,
    stats: Stats,
    geometry: Option<Geometry>,
    /// Only `MPP_DEC_SET_INFO_CHANGE_READY` lets MPP's parser past an info
    /// change, so after a failed one puts only fill up and gets come back empty.
    info_change_failed: bool,
}

impl MppDecoder {
    pub fn open() -> Result<Self> {
        let path = std::env::var_os("CAIRN_MPP_LIBRARY")
            .unwrap_or_else(|| OsString::from(DEFAULT_LIBRARY));
        Self::with_library(sys::Library::load(&path)?)
    }

    /// [`MppDecoder::open`] over a library already loaded, so the environment
    /// is read in one place.
    pub fn with_library(library: sys::Library) -> Result<Self> {
        let (mut ctx, mut mpi) = (ptr::null_mut(), ptr::null_mut());
        // SAFETY: two out-pointers to live locals.
        check("mpp_create", unsafe {
            (library.create)(&mut ctx, &mut mpi)
        })?;
        let initialised = (|| {
            if mpi.is_null() {
                bail!("mpp_create returned no vtable");
            }
            // SAFETY: `mpi` is non-null and MPP's vtable begins with its size.
            let size = unsafe { ptr::addr_of!((*mpi).size).read() } as usize;
            if size != size_of::<sys::Api>() {
                bail!(
                    "MPP's vtable is {size} bytes and this binding's {}: not the MPP it was written against",
                    size_of::<sys::Api>()
                );
            }
            // SAFETY: `ctx` came from `mpp_create`.
            check("mpp_init", unsafe {
                (library.init)(ctx, sys::CTX_DEC, sys::VIDEO_CODING_AVC)
            })?;
            // SAFETY: non-null, and its size is this binding's, whose layout
            // the assertions in `sys` pin to the header.
            Ok(unsafe { &*mpi })
        })();
        let api: &sys::Api = match initialised {
            Ok(api) => api,
            Err(err) => {
                // SAFETY: `ctx` came from `mpp_create` and nothing else holds
                // it. No reset: the context is not initialised, or its vtable
                // is not this binding's.
                unsafe { (library.destroy)(ctx) };
                return Err(err);
            }
        };
        let context = Arc::new(Context {
            library,
            ctx,
            put_packet: api.decode_put_packet,
            get_frame: api.decode_get_frame,
            reset: api.reset,
            control: api.control,
            group: AtomicPtr::new(ptr::null_mut()),
        });
        // A decoder's timeouts are already 0 after `mpp_init`; set here so
        // that put and get do not rest on that default. The header documents
        // an `RK_S64`, the code reads a 4-byte `MppPollType`: a zero `i64` is
        // zero to both on a little-endian target.
        for cmd in [sys::SET_INPUT_TIMEOUT, sys::SET_OUTPUT_TIMEOUT] {
            let mut zero = 0i64;
            context.control(cmd, ptr::from_mut(&mut zero).cast())?;
        }
        Ok(Self {
            context,
            finished: false,
            eos: false,
            stats: Stats::default(),
            geometry: None,
            info_change_failed: false,
        })
    }

    fn usable(&self) -> Result<()> {
        if self.info_change_failed {
            bail!("mpp: the decoder is unusable after a failed info change");
        }
        Ok(())
    }

    /// One `decode_put_packet` of `au` (a whole access unit), stamped `pts`.
    /// [`Put::Full`] is counted and never retried here.
    pub fn put(&mut self, au: &[u8], pts: i64) -> Result<Put> {
        self.usable()?;
        if self.finished {
            bail!("mpp: a put after the EOS packet can block in MPP");
        }
        let put = self.send(au, Some(pts))?;
        if put == Put::Accepted {
            self.stats.accepted += 1;
        }
        Ok(put)
    }

    /// The EOS packet. A [`Put::Full`] one was not taken and may be sent
    /// again; once taken, every later [`MppDecoder::put`] is refused.
    pub fn finish(&mut self) -> Result<Put> {
        self.usable()?;
        if self.finished {
            return Ok(Put::Accepted);
        }
        let put = self.send(&[], None)?;
        self.finished = put == Put::Accepted;
        Ok(put)
    }

    /// `pts` for an access unit, `None` for the EOS packet.
    fn send(&mut self, data: &[u8], pts: Option<i64>) -> Result<Put> {
        let context = &*self.context;
        let library = &context.library;
        let mut raw = ptr::null_mut();
        // SAFETY: an out-pointer to a live local. MPP keeps `data` only as a
        // pointer in the packet and reads it, never writes or frees it; a put
        // that takes the packet copies it, and the packet is deinit'd before
        // `data`'s borrow ends.
        check("mpp_packet_init", unsafe {
            (library.packet_init)(&mut raw, data.as_ptr().cast_mut().cast(), data.len())
        })?;
        let packet = Packet(library, raw);
        match pts {
            // SAFETY: `packet.1` is a live packet.
            Some(pts) => unsafe { (library.packet_set_pts)(packet.1, pts) },
            // SAFETY: as above.
            None => check("mpp_packet_set_eos", unsafe {
                (library.packet_set_eos)(packet.1)
            })?,
        }
        // SAFETY: `ctx` is live and `&mut self` makes this the only call into
        // it; the packet carries no MppBuffer, so MPP copies its data.
        let code = unsafe { (context.put_packet)(context.ctx, packet.1) };
        drop(packet);
        match code {
            sys::OK => Ok(Put::Accepted),
            sys::ERR_BUFFER_FULL => {
                self.stats.input_full += 1;
                Ok(Put::Full)
            }
            code => check("decode_put_packet", code).map(|()| Put::Accepted),
        }
    }

    /// The next picture, if MPP has one ready. Info changes are answered here
    /// (the decoder stalls until they are); error, discard and buffer-less
    /// frames are dropped.
    pub fn next_frame(&mut self) -> Result<Option<Frame>> {
        self.usable()?;
        for _ in 0..GETS_PER_CALL {
            let mut raw = ptr::null_mut();
            // SAFETY: `ctx` is live, `&mut self` makes this the only call
            // into it, and `raw` is a live out-pointer.
            check("decode_get_frame", unsafe {
                (self.context.get_frame)(self.context.ctx, &mut raw)
            })?;
            if raw.is_null() {
                return Ok(None);
            }
            // Owned from here, so every `continue` and `?` deinits it.
            let frame = Frame {
                context: Arc::clone(&self.context),
                frame: raw,
            };
            if frame.get(self.context.library.frame_get_info_change) != 0 {
                if let Err(err) = self.info_change(&frame) {
                    self.info_change_failed = true;
                    return Err(err);
                }
                continue;
            }
            if frame.get(self.context.library.frame_get_eos) != 0 {
                self.eos = true;
            }
            // Before the buffer check: MPP's buffer-less EOS frame carries
            // errinfo or discard when the stream ended in error.
            if frame.get(self.context.library.frame_get_errinfo) != 0 {
                self.stats.errinfo += 1;
                continue;
            }
            if frame.get(self.context.library.frame_get_discard) != 0 {
                self.stats.discarded += 1;
                continue;
            }
            if frame.buffer().is_null() {
                continue;
            }
            self.stats.frames += 1;
            return Ok(Some(frame));
        }
        Ok(None)
    }

    /// `mpi_dec_test`'s half-internal mode: MPP allocates from a group this
    /// decoder owns, so the limit bounds the memory a stream can take (MPP's
    /// own group is unlimited).
    fn info_change(&mut self, frame: &Frame) -> Result<()> {
        self.stats.info_changes += 1;
        let geometry = frame.geometry();
        self.geometry = Some(geometry);
        let library = &self.context.library;
        let mut group = self.context.group.load(Relaxed);
        if group.is_null() {
            // No CACHABLE flag, as `mpi_dec_test` has it: MPP's dma-heap
            // allocator then takes `system-uncached` (`system` where that
            // heap cannot be opened) and skips its sync ioctl on each frame
            // it hands out. The price is a slow CPU read of a mapped
            // picture; pictures are for a hardware scaler to import by fd.
            // In this image's MPP (built without ION), DMA_HEAP, DRM and ION
            // all try dma-heap, then DRM, then system memory.
            // SAFETY: an out-pointer to a live local and two C strings.
            check("mpp_buffer_group_get", unsafe {
                (library.group_get)(
                    &mut group,
                    sys::BUFFER_TYPE_DMA_HEAP,
                    sys::BUFFER_INTERNAL,
                    CALLER.as_ptr(),
                    CALLER.as_ptr(),
                )
            })?;
            self.context.group.store(group, Relaxed);
        } else {
            // Frees the old size's idle buffers; the ones frames still hold
            // go when they are released.
            // SAFETY: `group` came from `mpp_buffer_group_get`.
            check("mpp_buffer_group_clear", unsafe {
                (library.group_clear)(group)
            })?;
        }
        // SAFETY: as above.
        check("mpp_buffer_group_limit_config", unsafe {
            (library.group_limit_config)(group, geometry.buf_size, FRAME_BUFFERS)
        })?;
        self.context.control(sys::DEC_SET_EXT_BUF_GROUP, group)?;
        self.context
            .control(sys::DEC_SET_INFO_CHANGE_READY, ptr::null_mut())
    }

    /// Whether a frame carrying the EOS flag has come out.
    pub fn eos(&self) -> bool {
        self.eos
    }

    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// What the last info change announced, if one has come.
    pub fn geometry(&self) -> Option<Geometry> {
        self.geometry
    }
}

/// A decoded picture. It holds its context, so it may outlive later puts,
/// later gets and the decoder itself; dropping it returns the buffer to MPP.
/// Handed out only with a buffer.
///
/// Dropping one may drop the context's last holder, which resets and
/// destroys it, joining MPP's threads: it **blocks**. Only a holder that also
/// holds the decoder knows its drop is not the last, as `decode_au` does; any
/// other hands the frame to a teardown thread to drop.
pub struct Frame {
    context: Arc<Context>,
    frame: sys::Frame,
}

// SAFETY: this value alone owns `frame`. Its getters read the frame's own
// fields, and its drop puts the buffer back under the buffer's and the
// group's locks inside MPP, the decoder notify that can follow under the
// parser thread's (see `Context`), so either may run on any thread.
unsafe impl Send for Frame {}

impl Frame {
    fn get(&self, getter: unsafe extern "C" fn(sys::Frame) -> u32) -> u32 {
        // SAFETY: `frame` is live until drop; every getter passed here reads
        // one field of it.
        unsafe { getter(self.frame) }
    }

    fn buffer(&self) -> sys::Buffer {
        // SAFETY: `frame` is live until drop.
        unsafe { (self.context.library.frame_get_buffer)(self.frame) }
    }

    pub fn pts(&self) -> i64 {
        // SAFETY: `frame` is live until drop.
        unsafe { (self.context.library.frame_get_pts)(self.frame) }
    }

    pub fn geometry(&self) -> Geometry {
        let library = &self.context.library;
        Geometry {
            width: self.get(library.frame_get_width),
            height: self.get(library.frame_get_height),
            hor_stride: self.get(library.frame_get_hor_stride),
            ver_stride: self.get(library.frame_get_ver_stride),
            // SAFETY: `frame` is live until drop.
            buf_size: unsafe { (library.frame_get_buf_size)(self.frame) },
        }
    }

    /// `MppFrameFormat`: a format in the low bits, layout flags above.
    pub fn format(&self) -> u32 {
        self.get(self.context.library.frame_get_fmt)
    }

    /// Linear NV12: 8-bit 4:2:0 semi-planar, neither compressed nor tiled.
    pub fn is_nv12(&self) -> bool {
        let fmt = self.format();
        fmt & sys::FRAME_FMT_MASK == sys::FMT_YUV420SP
            && fmt & (sys::FRAME_FBC_MASK | sys::FRAME_TILE_FLAG) == 0
    }

    /// The picture's dma-buf. MPP owns the descriptor: it is valid only while
    /// this frame lives, and is not to be closed.
    pub fn fd(&self) -> RawFd {
        // SAFETY: a frame handed out has a buffer, live until drop.
        unsafe { (self.context.library.buffer_get_fd)(self.buffer(), CALLER.as_ptr()) }
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        // SAFETY: `frame` came from `decode_get_frame` and is deinit'd once,
        // here; the `Arc` keeps its context alive through the call.
        unsafe { (self.context.library.frame_deinit)(&mut self.frame) };
    }
}

// `pub(crate)`: the decoder's tests drive `MppDecoder` through these stubs.
#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::ffi::c_char;
    use std::sync::atomic::{AtomicI32, AtomicU32, Ordering::SeqCst};
    use std::sync::{Mutex, MutexGuard};

    // Process-global, so every test holds `STUBS` for its whole body.
    static STUBS: Mutex<()> = Mutex::new(());
    static CALLS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    static FRAMES: Mutex<VecDeque<StubFrame>> = Mutex::new(VecDeque::new());
    pub(crate) static PUT_CODE: AtomicI32 = AtomicI32::new(0);
    static INIT_CODE: AtomicI32 = AtomicI32::new(0);
    static LIMIT_CODE: AtomicI32 = AtomicI32::new(0);
    static API_SIZE: AtomicU32 = AtomicU32::new(184);

    #[derive(Clone, Copy, Default)]
    pub(crate) struct StubFrame {
        geometry: Geometry,
        pts: i64,
        fmt: u32,
        info_change: u32,
        errinfo: u32,
        discard: u32,
        eos: u32,
        buffer: usize,
    }

    fn geometry(width: u32, height: u32, buf_size: usize) -> Geometry {
        Geometry {
            width,
            height,
            hor_stride: width.next_multiple_of(16),
            ver_stride: height.next_multiple_of(16),
            buf_size,
        }
    }

    pub(crate) fn picture(pts: i64) -> StubFrame {
        let geometry = geometry(1920, 1080, 3_133_440);
        edit(StubFrame::default(), |f| {
            (f.geometry, f.pts, f.buffer) = (geometry, pts, 0x7000)
        })
    }

    fn info(width: u32, height: u32, buf_size: usize) -> StubFrame {
        let geometry = geometry(width, height, buf_size);
        edit(StubFrame::default(), |f| {
            (f.geometry, f.info_change) = (geometry, 1)
        })
    }

    fn edit(mut frame: StubFrame, change: impl FnOnce(&mut StubFrame)) -> StubFrame {
        change(&mut frame);
        frame
    }

    /// Data, pts and EOS flag.
    type StubPacket = (Vec<u8>, i64, bool);

    fn call(name: impl Into<String>) {
        CALLS.lock().unwrap().push(name.into());
    }

    /// The calls since the last read, space-separated.
    pub(crate) fn calls() -> String {
        std::mem::take(&mut *CALLS.lock().unwrap()).join(" ")
    }

    pub(crate) fn stubs() -> MutexGuard<'static, ()> {
        let guard = STUBS.lock().unwrap_or_else(|p| p.into_inner());
        CALLS.lock().unwrap().clear();
        FRAMES.lock().unwrap().clear();
        PUT_CODE.store(0, SeqCst);
        INIT_CODE.store(0, SeqCst);
        LIMIT_CODE.store(0, SeqCst);
        API_SIZE.store(184, SeqCst);
        guard
    }

    pub(crate) fn queue(frames: &[StubFrame]) {
        FRAMES.lock().unwrap().extend(frames);
    }

    unsafe extern "C" fn stub_create(ctx: *mut sys::Ctx, mpi: *mut *mut sys::Api) -> c_int {
        call("create");
        let none = ptr::null();
        let api = Box::leak(Box::new(sys::Api {
            size: API_SIZE.load(SeqCst),
            version: 0,
            decode_put_packet: stub_put_packet,
            decode_get_frame: stub_get_frame,
            reset: stub_reset,
            control: stub_control,
            reserv: [0; 16],
            decode: none,
            unused: [none; 9],
        }));
        // SAFETY: `with_library` passes two live out-pointers.
        unsafe {
            *ctx = ptr::without_provenance_mut(0x5000);
            *mpi = api;
        }
        0
    }

    unsafe extern "C" fn stub_init(_: sys::Ctx, ty: c_int, coding: c_int) -> c_int {
        call(format!("init({ty},{coding})"));
        INIT_CODE.load(SeqCst)
    }

    unsafe extern "C" fn stub_control(_: sys::Ctx, cmd: c_int, param: *mut c_void) -> c_int {
        // SAFETY: the timeout commands are passed a live `i64`.
        let timeout = || unsafe { *param.cast::<i64>() };
        match cmd {
            sys::SET_INPUT_TIMEOUT => call(format!("input_timeout({})", timeout())),
            sys::SET_OUTPUT_TIMEOUT => call(format!("output_timeout({})", timeout())),
            sys::DEC_SET_EXT_BUF_GROUP => call(format!("ext_buf_group({param:?})")),
            sys::DEC_SET_INFO_CHANGE_READY => call("info_change_ready"),
            _ => return -6,
        }
        0
    }

    unsafe extern "C" fn stub_packet_init(
        packet: *mut sys::Packet,
        data: *mut c_void,
        size: usize,
    ) -> c_int {
        // SAFETY: `send` passes its borrowed slice, dangling but non-null when
        // empty.
        let data = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size) }.to_vec();
        let stub: StubPacket = (data, -1, false);
        // SAFETY: a live out-pointer.
        unsafe { *packet = Box::into_raw(Box::new(stub)).cast() };
        0
    }

    unsafe extern "C" fn stub_packet_set_pts(packet: sys::Packet, pts: i64) {
        // SAFETY: a packet `stub_packet_init` made.
        unsafe { (*packet.cast::<StubPacket>()).1 = pts };
    }

    unsafe extern "C" fn stub_packet_set_eos(packet: sys::Packet) -> c_int {
        // SAFETY: as above.
        unsafe { (*packet.cast::<StubPacket>()).2 = true };
        0
    }

    unsafe extern "C" fn stub_packet_deinit(packet: *mut sys::Packet) -> c_int {
        call("packet_deinit");
        // SAFETY: a packet `stub_packet_init` boxed, freed once.
        drop(unsafe { Box::from_raw((*packet).cast::<StubPacket>()) });
        0
    }

    unsafe extern "C" fn stub_put_packet(_: sys::Ctx, packet: sys::Packet) -> c_int {
        // SAFETY: a live packet `stub_packet_init` made.
        let (data, pts, eos) = unsafe { &*packet.cast::<StubPacket>() };
        call(format!("put({data:02x?},{pts},{eos})"));
        PUT_CODE.load(SeqCst)
    }

    unsafe extern "C" fn stub_get_frame(_: sys::Ctx, frame: *mut sys::Frame) -> c_int {
        call("get");
        let next = FRAMES.lock().unwrap().pop_front();
        let raw = next.map_or(ptr::null_mut(), |f| Box::into_raw(Box::new(f)).cast());
        // SAFETY: a live out-pointer.
        unsafe { *frame = raw };
        0
    }

    unsafe extern "C" fn stub_frame_deinit(frame: *mut sys::Frame) -> c_int {
        call("frame_deinit");
        // SAFETY: a live pointer to a frame `stub_get_frame` boxed, freed
        // once.
        unsafe {
            drop(Box::from_raw((*frame).cast::<StubFrame>()));
            *frame = ptr::null_mut();
        }
        0
    }

    macro_rules! getters {
        ($($name:ident -> $ty:ty: |$f:ident| $read:expr;)*) => {$(
            unsafe extern "C" fn $name(frame: sys::Frame) -> $ty {
                // SAFETY: every frame the decoder reads came from
                // `stub_get_frame` and is live.
                let $f = unsafe { *frame.cast::<StubFrame>() };
                $read
            }
        )*};
    }

    getters! {
        get_width -> u32: |f| f.geometry.width;
        get_height -> u32: |f| f.geometry.height;
        get_hor_stride -> u32: |f| f.geometry.hor_stride;
        get_ver_stride -> u32: |f| f.geometry.ver_stride;
        get_buf_size -> usize: |f| f.geometry.buf_size;
        get_errinfo -> u32: |f| f.errinfo;
        get_discard -> u32: |f| f.discard;
        get_eos -> u32: |f| f.eos;
        get_info_change -> u32: |f| f.info_change;
        get_fmt -> u32: |f| f.fmt;
        get_pts -> i64: |f| f.pts;
        get_buffer -> sys::Buffer: |f| ptr::without_provenance_mut(f.buffer);
    }

    /// Stubs that log their call and succeed.
    macro_rules! logged {
        ($($name:ident($ty:ty) => $log:literal;)*) => {$(
            unsafe extern "C" fn $name(_: $ty) -> c_int {
                call($log);
                0
            }
        )*};
    }

    logged! {
        stub_destroy(sys::Ctx) => "destroy";
        stub_reset(sys::Ctx) => "reset";
        stub_group_put(sys::BufferGroup) => "group_put";
        stub_group_clear(sys::BufferGroup) => "group_clear";
    }

    unsafe extern "C" fn stub_get_fd(_: sys::Buffer, _: *const c_char) -> c_int {
        42
    }

    unsafe extern "C" fn stub_group_get(
        group: *mut sys::BufferGroup,
        ty: c_int,
        mode: c_int,
        _: *const c_char,
        _: *const c_char,
    ) -> c_int {
        call(format!("group_get({ty},{mode})"));
        // SAFETY: a live out-pointer.
        unsafe { *group = ptr::without_provenance_mut(0x6000) };
        0
    }

    unsafe extern "C" fn stub_group_limit(_: sys::BufferGroup, size: usize, count: i32) -> c_int {
        call(format!("limit({size},{count})"));
        LIMIT_CODE.load(SeqCst)
    }

    pub(crate) fn library() -> sys::Library {
        sys::Library {
            create: stub_create,
            init: stub_init,
            destroy: stub_destroy,
            packet_init: stub_packet_init,
            packet_set_pts: stub_packet_set_pts,
            packet_set_eos: stub_packet_set_eos,
            packet_deinit: stub_packet_deinit,
            frame_get_width: get_width,
            frame_get_height: get_height,
            frame_get_hor_stride: get_hor_stride,
            frame_get_ver_stride: get_ver_stride,
            frame_get_errinfo: get_errinfo,
            frame_get_discard: get_discard,
            frame_get_eos: get_eos,
            frame_get_info_change: get_info_change,
            frame_get_fmt: get_fmt,
            frame_get_pts: get_pts,
            frame_get_buf_size: get_buf_size,
            frame_get_buffer: get_buffer,
            frame_deinit: stub_frame_deinit,
            buffer_get_fd: stub_get_fd,
            group_get: stub_group_get,
            group_put: stub_group_put,
            group_clear: stub_group_clear,
            group_limit_config: stub_group_limit,
        }
    }

    fn open() -> MppDecoder {
        let decoder = MppDecoder::with_library(library()).unwrap();
        calls();
        decoder
    }

    fn err<T>(result: Result<T>) -> String {
        format!("{:#}", result.err().expect("an error"))
    }

    #[test]
    fn open_inits_an_avc_decoder_and_zeroes_both_timeouts() {
        let _guard = stubs();
        let decoder = MppDecoder::with_library(library()).unwrap();
        let opened = "create init(0,7) input_timeout(0) output_timeout(0)";
        assert_eq!(calls(), opened);
        drop(decoder);
        assert_eq!(calls(), "reset destroy");
    }

    #[test]
    fn a_vtable_of_another_size_is_refused_with_both_sizes_and_destroyed() {
        let _guard = stubs();
        API_SIZE.store(176, SeqCst);
        let msg = err(MppDecoder::with_library(library()));
        assert!(msg.contains("176 bytes") && msg.contains("184"), "{msg}");
        assert_eq!(calls(), "create destroy");
    }

    #[test]
    fn a_failed_init_is_destroyed_once_without_timeouts_or_reset() {
        let _guard = stubs();
        INIT_CODE.store(-1, SeqCst);
        let msg = err(MppDecoder::with_library(library()));
        assert!(msg.contains("mpp_init returned -1"), "{msg}");
        assert_eq!(calls(), "create init(0,7) destroy");
    }

    #[test]
    fn a_put_hands_over_data_and_pts_once_and_deinits_the_packet_either_way() {
        let _guard = stubs();
        let mut decoder = open();
        assert_eq!(decoder.put(&[0, 0, 1, 0x65], 7).unwrap(), Put::Accepted);
        PUT_CODE.store(sys::ERR_BUFFER_FULL, SeqCst);
        assert_eq!(decoder.put(&[0, 0, 1, 0x41], 8).unwrap(), Put::Full);
        let puts = "put([00, 00, 01, 65],7,false) packet_deinit \
                    put([00, 00, 01, 41],8,false) packet_deinit";
        assert_eq!(calls(), puts);
        let stats = decoder.stats();
        assert_eq!((stats.accepted, stats.input_full), (1, 1));

        PUT_CODE.store(-1004, SeqCst);
        let msg = err(decoder.put(&[9], 9));
        assert!(msg.contains("-1004 (MPP_ERR_STREAM)"), "{msg}");
        assert_eq!(calls(), "put([09],9,false) packet_deinit");
    }

    #[test]
    fn nothing_reaches_mpp_after_the_eos_packet_is_taken() {
        let _guard = stubs();
        let mut decoder = open();
        PUT_CODE.store(sys::ERR_BUFFER_FULL, SeqCst);
        assert_eq!(decoder.finish().unwrap(), Put::Full);
        PUT_CODE.store(0, SeqCst);
        assert_eq!(decoder.put(&[1], 0).unwrap(), Put::Accepted);
        assert_eq!(decoder.finish().unwrap(), Put::Accepted);
        assert!(calls().ends_with("put([],-1,true) packet_deinit"));
        assert!(err(decoder.put(&[2], 1)).contains("after the EOS packet"));
        assert_eq!(decoder.finish().unwrap(), Put::Accepted);
        assert_eq!(calls(), "");
    }

    #[test]
    fn an_info_change_gets_a_group_once_then_clears_it() {
        let _guard = stubs();
        let mut decoder = open();
        queue(&[info(1920, 1080, 3_133_440)]);
        assert!(decoder.next_frame().unwrap().is_none());
        let ready = "ext_buf_group(0x6000) info_change_ready frame_deinit get";
        let first = format!("get group_get(4,0) limit(3133440,24) {ready}");
        assert_eq!(calls(), first);
        queue(&[info(1280, 720, 1_382_400)]);
        assert!(decoder.next_frame().unwrap().is_none());
        assert_eq!(
            calls(),
            format!("get group_clear limit(1382400,24) {ready}")
        );
        assert_eq!(decoder.stats().info_changes, 2);
        let g = decoder.geometry().unwrap();
        assert_eq!((g.width, g.height, g.ver_stride), (1280, 720, 720));
        drop(decoder);
        assert_eq!(calls(), "reset destroy group_put");
    }

    #[test]
    fn after_a_failed_info_change_nothing_reaches_mpp() {
        let _guard = stubs();
        let mut decoder = open();
        LIMIT_CODE.store(-1, SeqCst);
        queue(&[info(1920, 1080, 3_133_440), picture(1)]);
        let msg = err(decoder.next_frame());
        assert!(msg.contains("limit_config returned -1"), "{msg}");
        let failed = "get group_get(4,0) limit(3133440,24) frame_deinit";
        assert_eq!(calls(), failed);
        LIMIT_CODE.store(0, SeqCst);
        let later = [
            err(decoder.put(&[1], 0)),
            err(decoder.finish()),
            err(decoder.next_frame()),
        ];
        for msg in later {
            assert!(msg.contains("unusable after a failed info change"), "{msg}");
        }
        assert_eq!(calls(), "");
    }

    #[test]
    fn error_discard_and_bufferless_frames_are_dropped_and_eos_is_kept() {
        let _guard = stubs();
        let mut decoder = open();
        let bad = edit(picture(1), |f| f.errinfo = 1);
        let discarded = edit(picture(2), |f| f.discard = 1);
        let eos = edit(StubFrame::default(), |f| f.eos = 1);
        queue(&[bad, discarded, eos]);
        assert!(decoder.next_frame().unwrap().is_none());
        assert!(decoder.eos());
        assert_eq!(calls().matches("frame_deinit").count(), 3);
        let stats = decoder.stats();
        assert_eq!((stats.errinfo, stats.discarded, stats.frames), (1, 1, 0));
    }

    #[test]
    fn an_error_marked_bufferless_eos_frame_is_counted_and_still_ends_the_stream() {
        let _guard = stubs();
        let mut decoder = open();
        queue(&[edit(StubFrame::default(), |f| {
            f.errinfo = 1;
            f.eos = 1;
        })]);
        assert!(decoder.next_frame().unwrap().is_none());
        assert!(decoder.eos());
        let stats = decoder.stats();
        assert_eq!((stats.errinfo, stats.discarded, stats.frames), (1, 0, 0));
    }

    #[test]
    fn a_picture_outlives_the_decoder_and_the_context_goes_with_the_last_frame() {
        let _guard = stubs();
        let mut decoder = open();
        queue(&[info(1920, 1080, 3_133_440), picture(5)]);
        let frame = decoder.next_frame().unwrap().unwrap();
        let g = frame.geometry();
        assert_eq!(
            (g.width, g.height, g.hor_stride, g.ver_stride),
            (1920, 1080, 1920, 1088)
        );
        assert_eq!((frame.pts(), frame.fd()), (5, 42));
        assert!(frame.is_nv12());
        assert_eq!(decoder.stats().frames, 1);
        calls();
        drop(decoder);
        assert_eq!(calls(), "", "the frame still holds the context");
        drop(frame);
        assert_eq!(calls(), "frame_deinit reset destroy group_put");
    }

    #[test]
    fn a_compressed_tiled_or_ten_bit_frame_is_not_nv12() {
        let _guard = stubs();
        let mut decoder = open();
        for fmt in [0x0010_0000, sys::FRAME_TILE_FLAG, 1] {
            queue(&[edit(picture(0), |f| f.fmt = fmt)]);
            assert!(
                !decoder.next_frame().unwrap().unwrap().is_nv12(),
                "{fmt:#x}"
            );
        }
    }

    #[test]
    fn a_run_of_non_pictures_stops_at_the_bound_and_resumes_next_call() {
        let _guard = stubs();
        let mut decoder = open();
        queue(&[edit(picture(0), |f| f.errinfo = 1); GETS_PER_CALL]);
        queue(&[picture(9)]);
        assert!(decoder.next_frame().unwrap().is_none());
        assert_eq!(calls().matches("get").count(), GETS_PER_CALL);
        assert_eq!(decoder.next_frame().unwrap().unwrap().pts(), 9);
    }
}
