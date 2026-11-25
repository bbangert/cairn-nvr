//! The slice of librknnrt's C API this crate calls, written from the field
//! lists in `tools/rknn-export/board/rk.py` — whose layouts were checked on
//! the board against librknnrt 2.3.2 — and pinned below by `size_of` and
//! `offset_of!` assertions. Rockchip's header is not in the repo and is
//! never to be copied in.
//!
//! No board script declares the prototype of `rknn_create_mem_from_fd`, and
//! `zc.py` passes [`MEM_SYNC_FROM_DEVICE`]'s value only for an output mem;
//! the probe's `--infer` is the one caller of either here, and ran both on
//! the board.
//!
//! The library is opened with `dlopen` at [`Library::load`], never linked: a
//! build host has no librknnrt, and a board that lacks it should fail on the
//! open naming the file rather than refuse to start the binary.

use std::ffi::{c_int, c_void, OsStr};
use std::mem::{offset_of, size_of};

use anyhow::{Context as _, Result};

/// `rknn_context`: a 64-bit handle on every LP64 target, aarch64 included
/// (the runtime narrows it on 32-bit arm only, which no Cairn board is).
pub type Context = u64;

pub const MAX_DIMS: usize = 16;
pub const MAX_NAME_LEN: usize = 256;

pub const TENSOR_FLOAT32: c_int = 0;
pub const TENSOR_FLOAT16: c_int = 1;
pub const TENSOR_INT8: c_int = 2;
pub const TENSOR_UINT8: c_int = 3;

pub const TENSOR_NCHW: c_int = 0;
pub const TENSOR_NHWC: c_int = 1;

pub const QUERY_IN_OUT_NUM: c_int = 0;
pub const QUERY_INPUT_ATTR: c_int = 1;
pub const QUERY_OUTPUT_ATTR: c_int = 2;
pub const QUERY_SDK_VERSION: c_int = 5;
pub const QUERY_NATIVE_INPUT_ATTR: c_int = 8;

/// `rknn_mem_sync` directions. The probe's `--infer --sync` ran both on an
/// input mem on the board.
pub const MEM_SYNC_TO_DEVICE: c_int = 1;
pub const MEM_SYNC_FROM_DEVICE: c_int = 2;

/// A return code's name, for an error message that can be looked up.
pub fn code_name(code: c_int) -> &'static str {
    match code {
        0 => "RKNN_SUCC",
        -1 => "RKNN_ERR_FAIL",
        -2 => "RKNN_ERR_TIMEOUT",
        -3 => "RKNN_ERR_DEVICE_UNAVAILABLE",
        -4 => "RKNN_ERR_MALLOC_FAIL",
        -5 => "RKNN_ERR_PARAM_INVALID",
        -6 => "RKNN_ERR_MODEL_INVALID",
        -7 => "RKNN_ERR_CTX_INVALID",
        -8 => "RKNN_ERR_INPUT_INVALID",
        -9 => "RKNN_ERR_OUTPUT_INVALID",
        -10 => "RKNN_ERR_DEVICE_UNMATCH",
        -11 => "RKNN_ERR_INCOMPATILE_PRE_COMPILE_MODEL",
        -12 => "RKNN_ERR_INCOMPATILE_OPTIMIZATION_LEVEL_VERSION",
        -13 => "RKNN_ERR_TARGET_PLATFORM_UNMATCH",
        _ => "an unknown code",
    }
}

/// A tensor-type value's name, for refusals that say what an artifact has.
pub fn type_name(ty: c_int) -> String {
    match ty {
        TENSOR_FLOAT32 => "FP32".to_string(),
        TENSOR_FLOAT16 => "FP16".to_string(),
        TENSOR_INT8 => "INT8".to_string(),
        TENSOR_UINT8 => "UINT8".to_string(),
        other => format!("tensor type {other}"),
    }
}

/// A tensor-format value's name, likewise.
pub fn format_name(fmt: c_int) -> String {
    match fmt {
        TENSOR_NCHW => "NCHW".to_string(),
        TENSOR_NHWC => "NHWC".to_string(),
        other => format!("tensor format {other}"),
    }
}

#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct IoNum {
    pub n_input: u32,
    pub n_output: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TensorAttr {
    pub index: u32,
    pub n_dims: u32,
    pub dims: [u32; MAX_DIMS],
    pub name: [u8; MAX_NAME_LEN],
    pub n_elems: u32,
    pub size: u32,
    pub fmt: c_int,
    pub type_: c_int,
    pub qnt_type: c_int,
    pub fl: i8,
    pub zp: i32,
    pub scale: f32,
    pub w_stride: u32,
    pub size_with_stride: u32,
    pub pass_through: u8,
    pub h_stride: u32,
}

impl TensorAttr {
    pub fn zeroed() -> Self {
        // SAFETY: every field is an integer, a float or an array of them, for
        // which all-zero bytes are a valid value.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
pub struct Input {
    pub index: u32,
    pub buf: *mut c_void,
    pub size: u32,
    pub pass_through: u8,
    pub type_: c_int,
    pub fmt: c_int,
}

#[repr(C)]
pub struct Output {
    pub want_float: u8,
    pub is_prealloc: u8,
    pub index: u32,
    pub buf: *mut c_void,
    pub size: u32,
}

#[repr(C)]
pub struct TensorMem {
    pub virt_addr: *mut c_void,
    pub phys_addr: u64,
    pub fd: i32,
    pub offset: i32,
    pub size: u32,
    pub flags: u32,
    pub priv_data: *mut c_void,
}

#[repr(C)]
pub struct SdkVersion {
    pub api_version: [u8; 256],
    pub drv_version: [u8; 256],
}

impl SdkVersion {
    pub fn zeroed() -> Self {
        Self {
            api_version: [0; 256],
            drv_version: [0; 256],
        }
    }
}

// The layouts rk.py read on the board, which Rockchip's 2.5.0 header also
// gives under gcc for LP64. A field that moves is a compile error here
// instead of a runtime reading another field's bytes.
const _: () = {
    assert!(size_of::<IoNum>() == 8);
    assert!(offset_of!(IoNum, n_input) == 0);
    assert!(offset_of!(IoNum, n_output) == 4);

    assert!(size_of::<TensorAttr>() == 376);
    assert!(offset_of!(TensorAttr, index) == 0);
    assert!(offset_of!(TensorAttr, n_dims) == 4);
    assert!(offset_of!(TensorAttr, dims) == 8);
    assert!(offset_of!(TensorAttr, name) == 72);
    assert!(offset_of!(TensorAttr, n_elems) == 328);
    assert!(offset_of!(TensorAttr, size) == 332);
    assert!(offset_of!(TensorAttr, fmt) == 336);
    assert!(offset_of!(TensorAttr, type_) == 340);
    assert!(offset_of!(TensorAttr, qnt_type) == 344);
    assert!(offset_of!(TensorAttr, fl) == 348);
    assert!(offset_of!(TensorAttr, zp) == 352);
    assert!(offset_of!(TensorAttr, scale) == 356);
    assert!(offset_of!(TensorAttr, w_stride) == 360);
    assert!(offset_of!(TensorAttr, size_with_stride) == 364);
    assert!(offset_of!(TensorAttr, pass_through) == 368);
    assert!(offset_of!(TensorAttr, h_stride) == 372);

    assert!(size_of::<Input>() == 32);
    assert!(offset_of!(Input, index) == 0);
    assert!(offset_of!(Input, buf) == 8);
    assert!(offset_of!(Input, size) == 16);
    assert!(offset_of!(Input, pass_through) == 20);
    assert!(offset_of!(Input, type_) == 24);
    assert!(offset_of!(Input, fmt) == 28);

    assert!(size_of::<Output>() == 24);
    assert!(offset_of!(Output, want_float) == 0);
    assert!(offset_of!(Output, is_prealloc) == 1);
    assert!(offset_of!(Output, index) == 4);
    assert!(offset_of!(Output, buf) == 8);
    assert!(offset_of!(Output, size) == 16);

    assert!(size_of::<TensorMem>() == 40);
    assert!(offset_of!(TensorMem, virt_addr) == 0);
    assert!(offset_of!(TensorMem, phys_addr) == 8);
    assert!(offset_of!(TensorMem, fd) == 16);
    assert!(offset_of!(TensorMem, offset) == 20);
    assert!(offset_of!(TensorMem, size) == 24);
    assert!(offset_of!(TensorMem, flags) == 28);
    assert!(offset_of!(TensorMem, priv_data) == 32);

    assert!(size_of::<SdkVersion>() == 512);
    assert!(offset_of!(SdkVersion, api_version) == 0);
    assert!(offset_of!(SdkVersion, drv_version) == 256);
};

type InitFn = unsafe extern "C" fn(*mut Context, *mut c_void, u32, u32, *mut c_void) -> c_int;
type DestroyFn = unsafe extern "C" fn(Context) -> c_int;
type QueryFn = unsafe extern "C" fn(Context, c_int, *mut c_void, u32) -> c_int;
type InputsSetFn = unsafe extern "C" fn(Context, u32, *mut Input) -> c_int;
type RunFn = unsafe extern "C" fn(Context, *mut c_void) -> c_int;
type OutputsGetFn = unsafe extern "C" fn(Context, u32, *mut Output, *mut c_void) -> c_int;
type OutputsReleaseFn = unsafe extern "C" fn(Context, u32, *mut Output) -> c_int;
type CreateMemFn = unsafe extern "C" fn(Context, u32) -> *mut TensorMem;
type CreateMemFromFdFn =
    unsafe extern "C" fn(Context, c_int, *mut c_void, u32, c_int) -> *mut TensorMem;
type DestroyMemFn = unsafe extern "C" fn(Context, *mut TensorMem) -> c_int;
type SetIoMemFn = unsafe extern "C" fn(Context, *mut TensorMem, *mut TensorAttr) -> c_int;
type MemSyncFn = unsafe extern "C" fn(Context, *mut TensorMem, c_int) -> c_int;

/// The input-mem entry points, loaded as a set apart from the required ones:
/// a runtime without them still opens and runs by copy.
pub struct MemApi {
    pub(super) create_mem: CreateMemFn,
    pub(super) create_mem_from_fd: CreateMemFromFdFn,
    pub(super) destroy_mem: DestroyMemFn,
    pub(super) set_io_mem: SetIoMemFn,
    pub(super) mem_sync: MemSyncFn,
}

/// The entry points this crate calls. The runtime is never unloaded, so they
/// stay valid for the process: a `dlclose` under whatever threads and exit
/// handlers a vendor runtime leaves behind risks a crash at exit that would
/// hide the probe's own exit status, or take the node down with it.
pub struct Library {
    pub(super) init: InitFn,
    pub(super) destroy: DestroyFn,
    pub(super) query: QueryFn,
    pub(super) inputs_set: InputsSetFn,
    pub(super) run: RunFn,
    pub(super) outputs_get: OutputsGetFn,
    pub(super) outputs_release: OutputsReleaseFn,
    /// Or the first of them the runtime lacks, named.
    pub(super) mem: std::result::Result<MemApi, String>,
}

impl Library {
    pub fn load(path: &OsStr) -> Result<Self> {
        let shown = path.to_string_lossy();
        // SAFETY: loading runs the library's initialisers; librknnrt's are
        // what every program that links it runs too.
        let library = unsafe { libloading::Library::new(path) }
            .with_context(|| format!("loading the RKNN runtime {shown}"))?;
        // Never dropped, so a failed symbol lookup below does not `dlclose` a
        // runtime whose initialisers have already run.
        let library = std::mem::ManuallyDrop::new(library);
        macro_rules! symbol {
            ($name:literal) => {
                // SAFETY: the type is the C prototype this symbol has in
                // librknnrt; the pointer is copied out of the `Symbol`, and
                // `library` is never dropped, so it stays valid.
                *unsafe { library.get(concat!($name, "\0").as_bytes()) }
                    .with_context(|| format!("the RKNN runtime {shown} has no {}", $name))?
            };
        }
        let mem = (|| -> Result<MemApi> {
            Ok(MemApi {
                create_mem: symbol!("rknn_create_mem"),
                create_mem_from_fd: symbol!("rknn_create_mem_from_fd"),
                destroy_mem: symbol!("rknn_destroy_mem"),
                set_io_mem: symbol!("rknn_set_io_mem"),
                mem_sync: symbol!("rknn_mem_sync"),
            })
        })()
        .map_err(|err| format!("{err:#}"));
        Ok(Self {
            init: symbol!("rknn_init"),
            destroy: symbol!("rknn_destroy"),
            query: symbol!("rknn_query"),
            inputs_set: symbol!("rknn_inputs_set"),
            run: symbol!("rknn_run"),
            outputs_get: symbol!("rknn_outputs_get"),
            outputs_release: symbol!("rknn_outputs_release"),
            mem,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_err(path: &str) -> String {
        match Library::load(OsStr::new(path)) {
            Ok(_) => panic!("{path} loaded as the RKNN runtime"),
            Err(err) => format!("{err:#}"),
        }
    }

    #[test]
    fn a_missing_library_is_named() {
        let msg = load_err("/nonexistent/librknnrt.so");
        assert!(msg.contains("/nonexistent/librknnrt.so"), "{msg}");
    }

    /// A real library that is not the runtime fails on the first required
    /// symbol, by name: the mem entry points are looked up before it, and
    /// their absence is kept, not raised.
    #[test]
    fn a_library_without_the_symbols_names_the_first_required_one() {
        let msg = load_err("libm.so.6");
        assert!(msg.contains("has no rknn_init"), "{msg}");
    }
}
