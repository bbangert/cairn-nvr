//! Scale and colour-convert a decoded NV12 picture into an RGB888 slot of
//! the model's input size on the RGA2 blitter, through librga's im2d C API
//! opened at run time ([`sys::Library::load`]).
//!
//! An import, a release, a fill and a blit are each synchronous ioctls on
//! RGA's device: they **block** until the kernel, and for a fill or a blit
//! the hardware, is done.
//!
//! librga takes buffers as all imported handles or none (a mix is refused in
//! the blit request it builds), so the slot's one-time import forces an
//! import of the source on every blit. That import is not cached: MPP
//! recycles and reallocates its buffers, so an fd number names no buffer for
//! long.
//!
//! librga logs to the process's **stdout**, through C stdio: one version line
//! when its session opens, which [`Rga::open`]'s query does, and its error
//! log. Opening the session also `setenv`s `ROCKCHIP_RGA_API_VERSION`.

pub mod sys;

use std::ffi::{c_char, c_int, CStr, OsString};
use std::os::fd::RawFd;
use std::sync::OnceLock;

use anyhow::{bail, ensure, Result};
use cairn_detect::infer::{Fit, InputSize, ResizePolicy};

use crate::dma::{DmaBuf, DmaHeap};
use crate::mpp::Geometry;
use crate::pool::{Allocator, Lease};

/// `CAIRN_RGA_LIBRARY` names the library to load; unset, the loader's search
/// path finds this one.
const DEFAULT_LIBRARY: &str = "librga.so.2";

/// librga's error and query texts run to 512 bytes; a message carries this
/// many characters of one.
const MAX_TEXT: usize = 160;

pub const MIN_SCALE: f64 = 1.0 / 16.0;
pub const MAX_SCALE: f64 = 16.0;

/// RGA2's largest destination per axis. It is also what bounds a slot's
/// allocation (48 MiB at most) and keeps its size's casts in range.
pub const MAX_SLOT: usize = 4096;

/// Read once per process: `querystring` builds its text in a process-global
/// string, so a second call on any thread frees the text a first is still
/// reading. librga also calls it itself, on its format-refusal paths, which
/// this crate's formats should never take.
static VERSION: OnceLock<String> = OnceLock::new();

/// Whitespace collapsed, cut at [`MAX_TEXT`].
fn bounded(text: *const c_char) -> String {
    if text.is_null() {
        return "(no text)".into();
    }
    // SAFETY: librga returns a NUL-terminated string that stays valid until
    // the call that rebuilds it: this thread's next for an error text, and
    // for the query text see `VERSION`.
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    let mut words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if let Some((at, _)) = words.char_indices().nth(MAX_TEXT) {
        words.truncate(at);
        words.push('…');
    }
    words
}

#[derive(Clone, Copy)]
pub struct Rga {
    library: sys::Library,
}

impl Rga {
    pub fn open() -> Result<Self> {
        let path = std::env::var_os("CAIRN_RGA_LIBRARY")
            .unwrap_or_else(|| OsString::from(DEFAULT_LIBRARY));
        let library = sys::Library::load(&path)?;
        // SAFETY: an integer argument; `get_or_init` runs this once, so this
        // crate never queries again, and `VERSION` names librga's own calls.
        VERSION.get_or_init(|| bounded(unsafe { (library.query)(sys::INFO_VERSION) }));
        Ok(Self { library })
    }

    /// librga's API version and the hardware's, bounded, as read at the
    /// first open.
    pub fn version(&self) -> &'static str {
        VERSION.get().map_or("", String::as_str)
    }

    fn check(&self, call: &str, status: c_int) -> Result<()> {
        if !matches!(status, sys::STATUS_SUCCESS | sys::STATUS_NOERROR) {
            // SAFETY: an integer argument, on the thread whose call failed.
            let text = bounded(unsafe { (self.library.str_error)(status) });
            bail!("{call} returned {status}: {text}");
        }
        Ok(())
    }

    /// `fd` laid out as `wstride` × `hstride` pixels of `format`; the kernel
    /// refuses a dma-buf smaller than that.
    fn import(&self, fd: RawFd, wstride: u32, hstride: u32, format: c_int) -> Result<Import> {
        let mut param = sys::HandleParam {
            width: wstride,
            height: hstride,
            format: format as u32,
        };
        // SAFETY: a live parameter struct, read during the call. librga
        // validates `fd` with the kernel, which owns the dma-buf behind it.
        let handle = unsafe { (self.library.import_fd)(fd, &mut param) };
        // An unknown format comes back as -1 cast to a handle.
        if handle == 0 || handle == u32::MAX {
            self.check("importbuffer_fd", sys::STATUS_FAILED)?;
        }
        Ok(Import {
            library: self.library,
            handle,
        })
    }

    fn wrap(&self, handle: sys::Handle, size: [u32; 4], format: c_int) -> sys::Buffer {
        let [w, h, ws, hs] = size.map(|v| v as c_int);
        // SAFETY: fills a struct from its arguments; no buffer is touched.
        unsafe { (self.library.wrap_handle)(handle, w, h, ws, hs, format) }
    }
}

/// An RGA buffer handle, released on drop.
struct Import {
    library: sys::Library,
    handle: sys::Handle,
}

impl Drop for Import {
    fn drop(&mut self) {
        // SAFETY: a handle `importbuffer_fd` returned, released once.
        let status = unsafe { (self.library.release)(self.handle) };
        if !matches!(status, sys::STATUS_SUCCESS | sys::STATUS_NOERROR) {
            cairn_detect::note!("rga: releasebuffer_handle returned {status}");
        }
    }
}

/// `Download` wants RGB; `Infer` wants the model's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelOrder {
    Rgb,
    Bgr,
}

impl ChannelOrder {
    fn format(self) -> c_int {
        match self {
            Self::Rgb => sys::FORMAT_RGB_888,
            Self::Bgr => sys::FORMAT_BGR_888,
        }
    }
}

/// librga's `rga_check_align` wants a row's bytes to be a multiple of the
/// core's byte stride, 4 on RGA2: for RGB888 a width stride that is a
/// multiple of 4. A slot's rows are packed, so that is its width.
pub(crate) fn check_slot(size: InputSize) -> Result<()> {
    ensure!(
        (2..=MAX_SLOT).contains(&size.w) && (2..=MAX_SLOT).contains(&size.h),
        "RGB888 slot {size} is outside RGA2's 2x2 to {MAX_SLOT}x{MAX_SLOT} output"
    );
    ensure!(
        size.w.is_multiple_of(4),
        "RGB888 width stride {} is not a multiple of 4 (RGA2)",
        size.w
    );
    Ok(())
}

/// A packed RGB888 dma-buf imported into RGA once. Its pad is filled once,
/// at allocation, around the content rectangle of the plan it was built
/// for, and blits write only that rectangle; [`Blitter::blit`] refuses a
/// slot built for another fit.
pub struct Slot {
    // Before `buf`, so the handle is released before the buffer goes.
    import: Import,
    buf: DmaBuf,
    size: InputSize,
    fit: Fit,
    order: ChannelOrder,
}

impl Slot {
    /// Rows of `size.w * 3` bytes, read under the dma-buf sync.
    pub fn read<R>(&self, read: impl FnOnce(&[u8]) -> R) -> Result<R> {
        self.buf.read(read)
    }

    fn buffer(&self, rga: &Rga) -> sys::Buffer {
        let (w, h) = (self.size.w as u32, self.size.h as u32);
        rga.wrap(self.import.handle, [w, h, w, h], self.order.format())
    }
}

/// Slots for one [`Plan`], in one channel order, from `heap`.
pub struct SlotAllocator<'a> {
    rga: Rga,
    heap: &'a DmaHeap,
    size: InputSize,
    fit: Fit,
    order: ChannelOrder,
}

impl<'a> SlotAllocator<'a> {
    pub fn new(rga: Rga, heap: &'a DmaHeap, plan: &Plan, order: ChannelOrder) -> Self {
        let (size, fit) = (plan.slot, plan.fit);
        Self {
            rga,
            heap,
            size,
            fit,
            order,
        }
    }
}

impl Allocator for SlotAllocator<'_> {
    type Slot = Slot;

    fn allocate(&mut self, _: usize) -> Result<Slot> {
        let (w, h) = (self.size.w as u32, self.size.h as u32);
        let buf = self.heap.alloc(self.size.tensor_len())?;
        let import = self.rga.import(buf.fd(), w, h, self.order.format())?;
        let slot = Slot {
            import,
            buf,
            size: self.size,
            fit: self.fit,
            order: self.order,
        };
        let all = sys::Rect::sized(w as c_int, h as c_int);
        // Every byte, alpha included, so the order of the channels is moot.
        let color = (u32::from(self.fit.pad) * 0x0101_0101) as c_int;
        let dst = slot.buffer(&self.rga);
        // SAFETY: `dst` wraps the live handle `slot` owns; sync, so the fill
        // is done on return.
        let status = unsafe { (self.rga.library.fill)(dst, all, color, 1) };
        self.rga.check("imfill_t", status)?;
        Ok(slot)
    }
}

/// What one source geometry blits to, computed once per geometry.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Plan {
    pub source: Geometry,
    pub slot: InputSize,
    /// The software path's numbers: `ResizePolicy::fit` of the visible
    /// picture.
    pub fit: Fit,
    /// The visible picture at the origin; the strides are the buffer's.
    pub src: sys::Rect,
    /// `fit.inner` at the origin.
    pub dst: sys::Rect,
    /// Destination over source, per axis.
    pub scale: (f64, f64),
}

impl Plan {
    pub fn new(source: Geometry, slot: InputSize, policy: ResizePolicy) -> Result<Self> {
        check_slot(slot)?;
        let g = source;
        let stride = g.hor_stride;
        ensure!(
            stride.is_multiple_of(4),
            "NV12 width stride {stride} is not a multiple of 4 (RGA2)"
        );
        for (what, v) in [
            ("width", g.width),
            ("height", g.height),
            ("height stride", g.ver_stride),
        ] {
            ensure!(
                v >= 2 && v.is_multiple_of(2),
                "NV12 {what} {v} is not even (RGA2)"
            );
        }
        let visible = InputSize {
            w: g.width as usize,
            h: g.height as usize,
        };
        let fit = policy.fit(slot, visible);
        ensure!(
            fit.offset == (0, 0),
            "content at {:?}, not the origin",
            fit.offset
        );
        let (from, to) = (visible, fit.inner);
        let scale = (to.w as f64 / from.w as f64, to.h as f64 / from.h as f64);
        for (axis, from, to, factor) in [
            ("horizontal", from.w, to.w, scale.0),
            ("vertical", from.h, to.h, scale.1),
        ] {
            ensure!(
                (MIN_SCALE..=MAX_SCALE).contains(&factor),
                "{axis} scale {from} -> {to} px is {factor:.4}x; RGA2 scales 1/16x to 16x"
            );
        }
        let rect = |size: InputSize| sys::Rect::sized(size.w as c_int, size.h as c_int);
        Ok(Self {
            source,
            slot,
            fit,
            src: rect(visible),
            dst: rect(fit.inner),
            scale,
        })
    }
}

/// [`Plan`]'s blits. Usage is `IM_SYNC` alone and every buffer's colour space
/// is left at its default, so librga picks both conversion and kernel. Its
/// guide gives BT.601 limited range as the default YUV-to-RGB conversion
/// (under `imcvtcolor`) and, for RK3566's RGA2, average for a downscale and
/// bilinear or bicubic for an upscale. On the HA Green a downscaled test
/// pattern sat closest to a software reference of exactly that (about 30 dB,
/// 7 dB clear of BT.709 or full range); parity with the software path's own
/// resize is not established.
pub struct Blitter {
    rga: Rga,
    plan: Plan,
}

impl Blitter {
    pub fn new(rga: Rga, plan: Plan) -> Self {
        Self { rga, plan }
    }

    pub fn plan(&self) -> &Plan {
        &self.plan
    }

    /// The NV12 picture on `fd`, laid out as `geometry`, into the leased
    /// slot's content rectangle. `fd` need only be live for the call. The
    /// `&mut` is what keeps every read of the slot out while RGA writes it.
    pub fn blit(&mut self, fd: RawFd, geometry: Geometry, lease: &mut Lease<Slot>) -> Result<()> {
        let (plan, slot) = (self.plan, lease.slot());
        ensure!(
            geometry == plan.source,
            "a {geometry:?} picture through a plan for {:?}",
            plan.source
        );
        ensure!(
            slot.size == plan.slot && slot.fit == plan.fit,
            "a {} slot filled for {:?} through a plan for {} and {:?}",
            slot.size,
            slot.fit,
            plan.slot,
            plan.fit
        );
        let g = geometry;
        let format = sys::FORMAT_YCBCR_420_SP;
        let import = self.rga.import(fd, g.hor_stride, g.ver_stride, format)?;
        let size = [g.width, g.height, g.hor_stride, g.ver_stride];
        let src = self.rga.wrap(import.handle, size, format);
        let dst = slot.buffer(&self.rga);
        let (none, nowhere) = (sys::Buffer::EMPTY, sys::Rect::default());
        // SAFETY: both buffers wrap live handles; `IM_SYNC`, so the hardware
        // is done on return and `import` may then be released. librga checks
        // the request (`rga_check`) on every call.
        let status = unsafe {
            (self.rga.library.process)(src, dst, none, plan.src, plan.dst, nowhere, sys::SYNC)
        };
        self.rga.check("improcess", status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sys::Rect;

    fn geometry(width: u32, height: u32) -> Geometry {
        let (hor_stride, ver_stride) = (width.next_multiple_of(16), height.next_multiple_of(16));
        let buf_size = (hor_stride * ver_stride * 3 / 2) as usize;
        Geometry {
            width,
            height,
            hor_stride,
            ver_stride,
            buf_size,
        }
    }

    const LETTERBOX: ResizePolicy = ResizePolicy::Letterbox { pad: 114 };

    fn plan(source: Geometry, w: usize, h: usize, policy: ResizePolicy) -> Result<Plan> {
        Plan::new(source, InputSize { w, h }, policy)
    }

    /// The refusal of a plan, which must mention `says`.
    fn refused(plan: Result<Plan>, says: &str) {
        let msg = format!("{:#}", plan.expect_err("refused"));
        assert!(msg.contains(says), "{msg}");
    }

    #[test]
    fn a_1080p_letterbox_into_640_reads_1080_of_1088_rows_and_fills_640x360() {
        let plan = plan(geometry(1920, 1080), 640, 640, LETTERBOX).unwrap();
        assert_eq!(plan.source.ver_stride, 1088);
        let rects = (Rect::sized(1920, 1080), Rect::sized(640, 360));
        assert_eq!((plan.src, plan.dst), rects);
        assert_eq!((plan.fit.pad, plan.scale), (114, (1.0 / 3.0, 1.0 / 3.0)));
    }

    #[test]
    fn a_4_3_source_letterboxes_to_its_own_width_limited_rectangle() {
        let source = geometry(2560, 1920);
        let fitted = plan(source, 640, 640, LETTERBOX).unwrap();
        let rects = (Rect::sized(2560, 1920), Rect::sized(640, 480));
        assert_eq!(
            (fitted.src, fitted.dst, fitted.scale),
            (rects.0, rects.1, (0.25, 0.25))
        );
        let stretched = plan(source, 640, 640, ResizePolicy::Stretch).unwrap();
        assert_eq!(stretched.dst, Rect::sized(640, 640));
    }

    #[test]
    fn a_scale_past_16x_either_way_is_refused_with_its_numbers() {
        let stretch = ResizePolicy::Stretch;
        let down = |h| plan(geometry(1280, 720), 640, h, stretch);
        assert_eq!(down(45).unwrap().scale.1, 1.0 / 16.0);
        refused(down(44), "vertical scale 720 -> 44 px is 0.0611x");
        let up = |side| plan(geometry(side, side), 640, 640, stretch);
        assert_eq!(up(40).unwrap().scale, (16.0, 16.0));
        refused(up(32), "horizontal scale 32 -> 640 px is 20.0000x");
    }

    #[test]
    fn what_rga2_alignment_forbids_is_refused() {
        let hd = geometry(1920, 1080);
        for (w, h) in [(640, 1_000_000), (8192, 640), (640, 0)] {
            let says = format!("RGB888 slot {w}x{h} is outside RGA2's 2x2 to 4096x4096 output");
            refused(plan(hd, w, h, ResizePolicy::Stretch), &says);
        }
        assert!(check_slot(InputSize::square(MAX_SLOT)).is_ok());
        refused(
            plan(hd, 642, 640, LETTERBOX),
            "RGB888 width stride 642 is not a multiple of 4",
        );
        let odd = Geometry { height: 1079, ..hd };
        refused(
            plan(odd, 640, 640, LETTERBOX),
            "NV12 height 1079 is not even",
        );
        let unaligned = Geometry {
            hor_stride: 1922,
            ..hd
        };
        refused(
            plan(unaligned, 640, 640, LETTERBOX),
            "NV12 width stride 1922 is not a multiple of 4",
        );
    }

    #[test]
    fn librga_text_is_bounded_and_on_one_line() {
        let long = std::ffi::CString::new(format!("a\n  b {}", "x".repeat(400))).unwrap();
        let text = bounded(long.as_ptr());
        assert!(text.starts_with("a b xxx") && text.ends_with('…'), "{text}");
        assert_eq!(text.chars().count(), MAX_TEXT + 1);
        let exact = std::ffi::CString::new("y".repeat(MAX_TEXT)).unwrap();
        assert_eq!(bounded(exact.as_ptr()), "y".repeat(MAX_TEXT));
        assert_eq!(bounded(std::ptr::null()), "(no text)");
    }
}
