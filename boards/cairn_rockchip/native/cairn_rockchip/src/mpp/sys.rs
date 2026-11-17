//! The slice of Rockchip MPP's C API the decoder calls, transcribed from the
//! headers under `inc/` at upstream commit c08762e and pinned below by
//! `size_of` and `offset_of!` assertions whose numbers a C program compiled
//! against those headers printed (gcc, LP64 — the layout aarch64 shares).
//!
//! The library is opened with `dlopen` at [`Library::load`], never linked: a
//! build host has no MPP, and a board that lacks it should fail on the open
//! naming the file rather than refuse to start the binary.

use std::ffi::{c_char, c_int, c_void, OsStr};
use std::mem::{offset_of, size_of};

use anyhow::{Context as _, Result};

pub type Ctx = *mut c_void;
pub type Packet = *mut c_void;
pub type Frame = *mut c_void;
pub type Buffer = *mut c_void;
pub type BufferGroup = *mut c_void;

pub const OK: c_int = 0;
pub const ERR_BUFFER_FULL: c_int = -1012;

pub const CTX_DEC: c_int = 0;
pub const VIDEO_CODING_AVC: c_int = 7;

pub const SET_INPUT_TIMEOUT: c_int = 0x0020_0006;
pub const SET_OUTPUT_TIMEOUT: c_int = 0x0020_0007;
pub const DEC_SET_EXT_BUF_GROUP: c_int = 0x0031_0002;
pub const DEC_SET_INFO_CHANGE_READY: c_int = 0x0031_0003;

pub const BUFFER_INTERNAL: c_int = 0;
pub const BUFFER_TYPE_DMA_HEAP: c_int = 4;

pub const FMT_YUV420SP: u32 = 0;
pub const FRAME_FMT_MASK: u32 = 0x000f_ffff;
pub const FRAME_FBC_MASK: u32 = 0x00f0_0000;
pub const FRAME_TILE_FLAG: u32 = 0x0200_0000;

/// `MPP_FRAME_RANGE_JPEG`; `UNSPECIFIED` is 0 and `MPEG` 1.
pub const RANGE_FULL: u32 = 2;

/// A return code's name, for an error message that can be looked up.
pub fn code_name(code: c_int) -> &'static str {
    match code {
        0 => "MPP_OK",
        -1 => "MPP_NOK",
        -2 => "MPP_ERR_UNKNOW",
        -3 => "MPP_ERR_NULL_PTR",
        -4 => "MPP_ERR_MALLOC",
        -6 => "MPP_ERR_VALUE",
        -8 => "MPP_ERR_TIMEOUT",
        -1002 => "MPP_ERR_INIT",
        -1003 => "MPP_ERR_VPU_CODEC_INIT",
        -1004 => "MPP_ERR_STREAM",
        -1005 => "MPP_ERR_FATAL_THREAD",
        -1006 => "MPP_ERR_NOMEM",
        -1009 => "MPP_ERR_VPUHW",
        -1012 => "MPP_ERR_BUFFER_FULL",
        -1013 => "MPP_ERR_DISPLAY_FULL",
        _ => "an unknown code",
    }
}

pub type DecodePutPacketFn = unsafe extern "C" fn(Ctx, Packet) -> c_int;
pub type DecodeGetFrameFn = unsafe extern "C" fn(Ctx, *mut Frame) -> c_int;
pub type ResetFn = unsafe extern "C" fn(Ctx) -> c_int;
pub type ControlFn = unsafe extern "C" fn(Ctx, c_int, *mut c_void) -> c_int;

/// `MppApi`, the vtable `mpp_create` hands back. The entries this crate never
/// calls are opaque pointers; the four it calls are set by MPP's `mpi.c` to
/// its own functions, never null.
#[repr(C)]
pub struct Api {
    pub size: u32,
    pub version: u32,
    pub decode: *const c_void,
    pub decode_put_packet: DecodePutPacketFn,
    pub decode_get_frame: DecodeGetFrameFn,
    /// `encode`, `encode_put_frame`, `encode_get_packet`, `isp`,
    /// `isp_put_frame`, `isp_get_frame`, `poll`, `dequeue`, `enqueue`.
    pub unused: [*const c_void; 9],
    pub reset: ResetFn,
    pub control: ControlFn,
    pub reserv: [u32; 16],
}

const _: () = {
    assert!(size_of::<Api>() == 184);
    assert!(offset_of!(Api, size) == 0);
    assert!(offset_of!(Api, version) == 4);
    assert!(offset_of!(Api, decode) == 8);
    assert!(offset_of!(Api, decode_put_packet) == 16);
    assert!(offset_of!(Api, decode_get_frame) == 24);
    // `encode` through `enqueue`, 32 to 96.
    assert!(offset_of!(Api, unused) == 32);
    assert!(offset_of!(Api, reset) == 104);
    assert!(offset_of!(Api, control) == 112);
    assert!(offset_of!(Api, reserv) == 120);
};

type CreateFn = unsafe extern "C" fn(*mut Ctx, *mut *mut Api) -> c_int;
type InitFn = unsafe extern "C" fn(Ctx, c_int, c_int) -> c_int;
type DestroyFn = unsafe extern "C" fn(Ctx) -> c_int;
type PacketInitFn = unsafe extern "C" fn(*mut Packet, *mut c_void, usize) -> c_int;
type PacketSetPtsFn = unsafe extern "C" fn(Packet, i64);
type PacketSetEosFn = unsafe extern "C" fn(Packet) -> c_int;
type PacketDeinitFn = unsafe extern "C" fn(*mut Packet) -> c_int;
type FrameU32Fn = unsafe extern "C" fn(Frame) -> u32;
type FramePtsFn = unsafe extern "C" fn(Frame) -> i64;
type FrameBufSizeFn = unsafe extern "C" fn(Frame) -> usize;
type FrameBufferFn = unsafe extern "C" fn(Frame) -> Buffer;
type FrameDeinitFn = unsafe extern "C" fn(*mut Frame) -> c_int;
type BufferGetFdFn = unsafe extern "C" fn(Buffer, *const c_char) -> c_int;
type GroupGetFn =
    unsafe extern "C" fn(*mut BufferGroup, c_int, c_int, *const c_char, *const c_char) -> c_int;
type GroupFn = unsafe extern "C" fn(BufferGroup) -> c_int;
type GroupLimitFn = unsafe extern "C" fn(BufferGroup, usize, i32) -> c_int;

/// The entry points this crate calls. The library is never unloaded, so they
/// stay valid for the process — including in the drop of a frame that
/// outlives its decoder, and under MPP's own threads.
#[derive(Clone, Copy)]
pub struct Library {
    pub(super) create: CreateFn,
    pub(super) init: InitFn,
    pub(super) destroy: DestroyFn,
    pub(super) packet_init: PacketInitFn,
    pub(super) packet_set_pts: PacketSetPtsFn,
    pub(super) packet_set_eos: PacketSetEosFn,
    pub(super) packet_deinit: PacketDeinitFn,
    pub(super) frame_get_width: FrameU32Fn,
    pub(super) frame_get_height: FrameU32Fn,
    pub(super) frame_get_hor_stride: FrameU32Fn,
    pub(super) frame_get_ver_stride: FrameU32Fn,
    pub(super) frame_get_errinfo: FrameU32Fn,
    pub(super) frame_get_discard: FrameU32Fn,
    pub(super) frame_get_eos: FrameU32Fn,
    pub(super) frame_get_info_change: FrameU32Fn,
    /// `MppFrameFormat`, a 4-byte enum.
    pub(super) frame_get_fmt: FrameU32Fn,
    /// `MppFrameColorRange`, a 4-byte enum.
    pub(super) frame_get_color_range: FrameU32Fn,
    pub(super) frame_get_pts: FramePtsFn,
    pub(super) frame_get_buf_size: FrameBufSizeFn,
    pub(super) frame_get_buffer: FrameBufferFn,
    pub(super) frame_deinit: FrameDeinitFn,
    pub(super) buffer_get_fd: BufferGetFdFn,
    pub(super) group_get: GroupGetFn,
    pub(super) group_put: GroupFn,
    pub(super) group_clear: GroupFn,
    pub(super) group_limit_config: GroupLimitFn,
}

impl Library {
    pub fn load(path: &OsStr) -> Result<Self> {
        let shown = path.to_string_lossy();
        // SAFETY: loading runs the library's initialisers; MPP's are what
        // every program that links it runs too.
        let library = unsafe { libloading::Library::new(path) }
            .with_context(|| format!("loading the MPP library {shown}"))?;
        // Never dropped, so a failed symbol lookup below does not `dlclose` a
        // library whose initialisers have already run.
        let library = std::mem::ManuallyDrop::new(library);
        macro_rules! symbol {
            ($name:literal) => {
                // SAFETY: the type is the C prototype this symbol has in MPP's
                // headers; the pointer is copied out of the `Symbol`, and
                // `library` is never dropped, so it stays valid.
                *unsafe { library.get(concat!($name, "\0").as_bytes()) }
                    .with_context(|| format!("the MPP library {shown} has no {}", $name))?
            };
        }
        Ok(Self {
            create: symbol!("mpp_create"),
            init: symbol!("mpp_init"),
            destroy: symbol!("mpp_destroy"),
            packet_init: symbol!("mpp_packet_init"),
            packet_set_pts: symbol!("mpp_packet_set_pts"),
            packet_set_eos: symbol!("mpp_packet_set_eos"),
            packet_deinit: symbol!("mpp_packet_deinit"),
            frame_get_width: symbol!("mpp_frame_get_width"),
            frame_get_height: symbol!("mpp_frame_get_height"),
            frame_get_hor_stride: symbol!("mpp_frame_get_hor_stride"),
            frame_get_ver_stride: symbol!("mpp_frame_get_ver_stride"),
            frame_get_errinfo: symbol!("mpp_frame_get_errinfo"),
            frame_get_discard: symbol!("mpp_frame_get_discard"),
            frame_get_eos: symbol!("mpp_frame_get_eos"),
            frame_get_info_change: symbol!("mpp_frame_get_info_change"),
            frame_get_fmt: symbol!("mpp_frame_get_fmt"),
            frame_get_color_range: symbol!("mpp_frame_get_color_range"),
            frame_get_pts: symbol!("mpp_frame_get_pts"),
            frame_get_buf_size: symbol!("mpp_frame_get_buf_size"),
            frame_get_buffer: symbol!("mpp_frame_get_buffer"),
            frame_deinit: symbol!("mpp_frame_deinit"),
            // `mpp_buffer_get_fd` and `mpp_buffer_group_get_internal` are
            // macros over these two.
            buffer_get_fd: symbol!("mpp_buffer_get_fd_with_caller"),
            group_get: symbol!("mpp_buffer_group_get"),
            group_put: symbol!("mpp_buffer_group_put"),
            group_clear: symbol!("mpp_buffer_group_clear"),
            group_limit_config: symbol!("mpp_buffer_group_limit_config"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_err(path: &str) -> String {
        match Library::load(OsStr::new(path)) {
            Ok(_) => panic!("{path} loaded as MPP"),
            Err(err) => format!("{err:#}"),
        }
    }

    #[test]
    fn a_missing_library_is_named() {
        let msg = load_err("/nonexistent/librockchip_mpp.so.1");
        assert!(msg.contains("/nonexistent/librockchip_mpp.so.1"), "{msg}");
    }

    #[test]
    fn a_library_without_the_symbols_names_the_first_missing_one() {
        let msg = load_err("libm.so.6");
        assert!(msg.contains("has no mpp_create"), "{msg}");
    }
}
