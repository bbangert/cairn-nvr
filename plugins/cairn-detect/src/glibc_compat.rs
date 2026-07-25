//! glibc 2.38 compatibility shims for the prebuilt ONNX Runtime.
//!
//! `ort`'s prebuilt `libonnxruntime.a` is compiled against glibc >= 2.38,
//! whose headers redirect `strtol` and friends to `__isoc23_*` symbols. On an
//! older glibc (Debian 12 ships 2.36) those symbols do not exist and the link
//! fails. The ISO C23 variants differ from the C99 ones only in accepting
//! binary literals, which ONNX Runtime's config parsing never sees, so
//! forwarding is safe.
//!
//! Delete this file once the build host's glibc is >= 2.38 or ONNX Runtime is
//! linked dynamically against a matching build.

#![cfg(all(target_os = "linux", target_env = "gnu"))]

use std::ffi::{c_char, c_int, c_long, c_longlong, c_ulong, c_ulonglong};

extern "C" {
    fn strtol(nptr: *const c_char, endptr: *mut *mut c_char, base: c_int) -> c_long;
    fn strtoll(nptr: *const c_char, endptr: *mut *mut c_char, base: c_int) -> c_longlong;
    fn strtoul(nptr: *const c_char, endptr: *mut *mut c_char, base: c_int) -> c_ulong;
    fn strtoull(nptr: *const c_char, endptr: *mut *mut c_char, base: c_int) -> c_ulonglong;
}

/// # Safety
/// Same contract as `strtol(3)`.
#[no_mangle]
pub unsafe extern "C" fn __isoc23_strtol(
    nptr: *const c_char,
    endptr: *mut *mut c_char,
    base: c_int,
) -> c_long {
    unsafe { strtol(nptr, endptr, base) }
}

/// # Safety
/// Same contract as `strtoll(3)`.
#[no_mangle]
pub unsafe extern "C" fn __isoc23_strtoll(
    nptr: *const c_char,
    endptr: *mut *mut c_char,
    base: c_int,
) -> c_longlong {
    unsafe { strtoll(nptr, endptr, base) }
}

/// # Safety
/// Same contract as `strtoul(3)`.
#[no_mangle]
pub unsafe extern "C" fn __isoc23_strtoul(
    nptr: *const c_char,
    endptr: *mut *mut c_char,
    base: c_int,
) -> c_ulong {
    unsafe { strtoul(nptr, endptr, base) }
}

/// # Safety
/// Same contract as `strtoull(3)`.
#[no_mangle]
pub unsafe extern "C" fn __isoc23_strtoull(
    nptr: *const c_char,
    endptr: *mut *mut c_char,
    base: c_int,
) -> c_ulonglong {
    unsafe { strtoull(nptr, endptr, base) }
}
