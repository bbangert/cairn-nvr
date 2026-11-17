//! The slice of librga's im2d C API the blit calls, transcribed from the
//! 1.10.5 headers (`im2d_api/im2d_type.h`, `im2d_buffer.h`, `im2d_common.h`,
//! `im2d_single.h`, `include/rga.h`) and pinned below by `size_of` and
//! `offset_of!` assertions whose numbers a C program compiled against those
//! headers printed (gcc, LP64 — the layout aarch64 shares).
//!
//! Every symbol here is declared `extern "C"`; names C callers write, such as
//! `imfill` or `imStrError`, are macros over these, and `importbuffer_fd` and
//! `improcess` also have C++-mangled overloads.
//!
//! Opened with `dlopen` at [`Library::load`], never linked, as MPP is.

use std::ffi::{c_char, c_int, c_void, OsStr};
use std::mem::{offset_of, size_of};

use anyhow::{Context as _, Result};

pub type Handle = u32;

/// `IM_STATUS`. Both of these mean success; `IM_STATUS_FAILED` is 0, so a
/// zero handle from an import is a failure too.
pub const STATUS_SUCCESS: c_int = 1;
pub const STATUS_NOERROR: c_int = 2;
pub const STATUS_FAILED: c_int = 0;

pub const SYNC: c_int = 1 << 19;

/// `querystring`'s `RGA_VERSION`.
pub const INFO_VERSION: c_int = 1;

pub const FORMAT_RGB_888: c_int = 0x2 << 8;
pub const FORMAT_BGR_888: c_int = 0x7 << 8;
pub const FORMAT_YCBCR_420_SP: c_int = 0xa << 8;

/// `im_rect`.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: c_int,
    pub y: c_int,
    pub width: c_int,
    pub height: c_int,
}

impl Rect {
    pub const fn sized(width: c_int, height: c_int) -> Self {
        Self {
            x: 0,
            y: 0,
            width,
            height,
        }
    }
}

/// `im_handle_param_t`: the buffer's strides in pixels and its format, from
/// which the kernel checks the dma-buf is large enough.
#[repr(C)]
pub struct HandleParam {
    pub width: u32,
    pub height: u32,
    pub format: u32,
}

/// `rga_buffer_t`, passed and returned by value. Only [`Buffer::EMPTY`] and
/// `wrapbuffer_handle_t` make one here; the fields past `format` are opaque.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Buffer {
    pub vir_addr: *mut c_void,
    pub phy_addr: *mut c_void,
    pub fd: c_int,
    pub width: c_int,
    pub height: c_int,
    pub wstride: c_int,
    pub hstride: c_int,
    pub format: c_int,
    /// `color_space_mode`, the `global_alpha` union, `rd_mode`, `color`,
    /// `colorkey_range`, `nn`, `rop_code`.
    pub rest: [c_int; 13],
    pub handle: Handle,
}

const _: () = {
    assert!(size_of::<Buffer>() == 96);
    assert!(offset_of!(Buffer, vir_addr) == 0);
    assert!(offset_of!(Buffer, phy_addr) == 8);
    assert!(offset_of!(Buffer, fd) == 16);
    assert!(offset_of!(Buffer, width) == 20);
    assert!(offset_of!(Buffer, height) == 24);
    assert!(offset_of!(Buffer, wstride) == 28);
    assert!(offset_of!(Buffer, hstride) == 32);
    assert!(offset_of!(Buffer, format) == 36);
    // `color_space_mode` 40 through `rop_code` 88.
    assert!(offset_of!(Buffer, rest) == 40);
    assert!(offset_of!(Buffer, handle) == 92);
    assert!(size_of::<Rect>() == 16);
    assert!(size_of::<HandleParam>() == 12);
};

impl Buffer {
    /// An unused pattern channel: invalid to librga, which then ignores it.
    // SAFETY: every field is a raw pointer or an integer, for which zero is a
    // value.
    pub const EMPTY: Buffer = unsafe { std::mem::zeroed() };
}

type ImportFdFn = unsafe extern "C" fn(c_int, *mut HandleParam) -> Handle;
type ReleaseFn = unsafe extern "C" fn(Handle) -> c_int;
type WrapHandleFn = unsafe extern "C" fn(Handle, c_int, c_int, c_int, c_int, c_int) -> Buffer;
/// src, dst, pat, their rects, usage.
type ProcessFn = unsafe extern "C" fn(Buffer, Buffer, Buffer, Rect, Rect, Rect, c_int) -> c_int;
type FillFn = unsafe extern "C" fn(Buffer, Rect, c_int, c_int) -> c_int;
type StrErrorFn = unsafe extern "C" fn(c_int) -> *const c_char;
type QueryFn = unsafe extern "C" fn(c_int) -> *const c_char;

/// The entry points this crate calls, valid for the process: the library is
/// never unloaded.
#[derive(Clone, Copy)]
pub struct Library {
    pub(super) import_fd: ImportFdFn,
    pub(super) release: ReleaseFn,
    pub(super) wrap_handle: WrapHandleFn,
    pub(super) process: ProcessFn,
    pub(super) fill: FillFn,
    /// The text is in a thread-local buffer, so it is read on the thread
    /// whose call failed, before that thread calls librga again.
    pub(super) str_error: StrErrorFn,
    pub(super) query: QueryFn,
}

impl Library {
    pub fn load(path: &OsStr) -> Result<Self> {
        let shown = path.to_string_lossy();
        // SAFETY: loading runs the library's initialisers; librga's are what
        // every program that links it runs too.
        let library = unsafe { libloading::Library::new(path) }
            .with_context(|| format!("loading the RGA library {shown}"))?;
        // Never dropped, so a failed symbol lookup below does not `dlclose` a
        // library whose initialisers have already run.
        let library = std::mem::ManuallyDrop::new(library);
        macro_rules! symbol {
            ($name:literal) => {
                // SAFETY: the type is the C prototype this symbol has in
                // librga's headers; the pointer is copied out of the
                // `Symbol`, and `library` is never dropped, so it stays valid.
                *unsafe { library.get(concat!($name, "\0").as_bytes()) }
                    .with_context(|| format!("the RGA library {shown} has no {}", $name))?
            };
        }
        Ok(Self {
            import_fd: symbol!("importbuffer_fd"),
            release: symbol!("releasebuffer_handle"),
            wrap_handle: symbol!("wrapbuffer_handle_t"),
            process: symbol!("improcess"),
            fill: symbol!("imfill_t"),
            str_error: symbol!("imStrError_t"),
            query: symbol!("querystring"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_err(path: &str) -> String {
        match Library::load(OsStr::new(path)) {
            Ok(_) => panic!("{path} loaded as librga"),
            Err(err) => format!("{err:#}"),
        }
    }

    #[test]
    fn a_missing_library_is_named() {
        let msg = load_err("/nonexistent/librga.so.2");
        assert!(msg.contains("/nonexistent/librga.so.2"), "{msg}");
    }

    #[test]
    fn a_library_without_the_symbols_names_the_first_missing_one() {
        let msg = load_err("libm.so.6");
        assert!(msg.contains("has no importbuffer_fd"), "{msg}");
    }
}
