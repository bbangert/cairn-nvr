//! dma-buf allocation from a dma-heap, each buffer mapped once for CPU reads.
//!
//! The `system` heap is cached memory that hardware writes behind the CPU's
//! back, so every CPU read is bracketed by `DMA_BUF_IOCTL_SYNC`; without it
//! the read can see stale cache lines.

use std::fs::File;
use std::mem::{offset_of, size_of};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::ptr::NonNull;

use anyhow::{bail, Context as _, Result};

/// Not a CMA heap: contiguous memory is scarce, and RGA2's MMU does not need
/// it. That MMU takes 32-bit physical addresses only, so where RAM reaches
/// past 4 GiB a page up there is bounced through swiotlb or refused,
/// depending on the driver (librga's FAQ, A1.9).
pub const SYSTEM_HEAP: &str = "/dev/dma_heap/system";

/// `struct dma_heap_allocation_data`.
#[repr(C)]
struct AllocationData {
    len: u64,
    fd: u32,
    fd_flags: u32,
    heap_flags: u64,
}

/// `struct dma_buf_sync`.
#[repr(C)]
struct BufSync {
    flags: u64,
}

/// `_IOC` as asm-generic lays it out, which x86_64 and aarch64 both use.
const fn ioc(dir: u64, ty: u8, nr: u64, size: usize) -> u64 {
    dir << 30 | (size as u64) << 16 | (ty as u64) << 8 | nr
}

const IOC_WRITE: u64 = 1;
const IOC_READ: u64 = 2;
const HEAP_IOCTL_ALLOC: u64 = ioc(IOC_READ | IOC_WRITE, b'H', 0, size_of::<AllocationData>());
const BUF_IOCTL_SYNC: u64 = ioc(IOC_WRITE, b'b', 0, size_of::<BufSync>());

const SYNC_READ: u64 = 1;
const SYNC_START: u64 = 0;
const SYNC_END: u64 = 4;

// The numbers a C program printed from `linux/dma-heap.h` and
// `linux/dma-buf.h`.
const _: () = {
    assert!(size_of::<AllocationData>() == 24);
    assert!(offset_of!(AllocationData, len) == 0);
    assert!(offset_of!(AllocationData, fd) == 8);
    assert!(offset_of!(AllocationData, fd_flags) == 12);
    assert!(offset_of!(AllocationData, heap_flags) == 16);
    assert!(size_of::<BufSync>() == 8);
    assert!(HEAP_IOCTL_ALLOC == 0xc018_4800);
    assert!(BUF_IOCTL_SYNC == 0x4008_6200);
};

/// A CPU read's sync start or end.
fn sync(fd: RawFd, edge: u64) -> std::io::Result<()> {
    ioctl(
        fd,
        BUF_IOCTL_SYNC,
        &mut BufSync {
            flags: edge | SYNC_READ,
        },
    )
}

/// `ioctl` with libdrm's retry on `EINTR`/`EAGAIN`, bounded.
fn ioctl<T>(fd: RawFd, request: u64, arg: &mut T) -> std::io::Result<()> {
    let mut tries = 0;
    loop {
        // SAFETY: each caller passes the struct its `request` encodes.
        if unsafe { libc::ioctl(fd, request as _, std::ptr::from_mut(arg)) } == 0 {
            return Ok(());
        }
        let err = std::io::Error::last_os_error();
        tries += 1;
        let again = matches!(err.raw_os_error(), Some(libc::EINTR | libc::EAGAIN));
        if !again || tries == 8 {
            return Err(err);
        }
    }
}

pub struct DmaHeap {
    file: File,
    path: String,
}

impl DmaHeap {
    pub fn open(path: &Path) -> Result<Self> {
        let shown = path.display().to_string();
        // Read-only is enough: the heap's ioctl does not check the mode.
        let file = File::open(path).with_context(|| format!("opening the dma-heap {shown}"))?;
        Ok(Self { file, path: shown })
    }

    pub fn alloc(&self, len: usize) -> Result<DmaBuf> {
        if len == 0 {
            bail!("a dma-buf of 0 bytes");
        }
        let mut data = AllocationData {
            len: len as u64,
            fd: 0,
            fd_flags: (libc::O_RDWR | libc::O_CLOEXEC) as u32,
            heap_flags: 0,
        };
        ioctl(self.file.as_raw_fd(), HEAP_IOCTL_ALLOC, &mut data)
            .with_context(|| format!("allocating {len} bytes from {}", self.path))?;
        // SAFETY: the kernel returned a new descriptor that nothing else owns.
        let fd = unsafe { OwnedFd::from_raw_fd(data.fd as RawFd) };
        // SAFETY: a fresh shared read-only mapping of a buffer of `len` bytes.
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                fd.as_raw_fd(),
                0,
            )
        };
        if map == libc::MAP_FAILED {
            let err = std::io::Error::last_os_error();
            bail!("mapping a {len}-byte dma-buf from {}: {err}", self.path);
        }
        let map = NonNull::new(map.cast()).context("mmap returned null")?;
        Ok(DmaBuf { fd, map, len })
    }
}

/// A dma-buf and its read-only mapping, both released on drop: a munmap,
/// then a close.
pub struct DmaBuf {
    fd: OwnedFd,
    map: NonNull<u8>,
    len: usize,
}

// SAFETY: the mapping is read-only, owned by this value alone and unmapped
// only in its drop; the CPU never writes through it.
unsafe impl Send for DmaBuf {}
// SAFETY: concurrent `read`s each bracket their own access. A device write
// during a `read` is the obligation `fd` states; here `rga` writes: a fill
// before the slot is shared, and blits that need its lease by `&mut`.
unsafe impl Sync for DmaBuf {}

impl DmaBuf {
    /// Owned by this buffer: valid while it lives, not to be closed. Whoever
    /// hands it to a device for writing keeps every `read` out until the
    /// write is done.
    pub fn fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    /// `read` over the whole buffer between a sync start and end. The sync
    /// start waits on a write the kernel has fenced, and RGA's sync blits
    /// leave none behind. The end runs even if `read` panics; a failed end
    /// is only noted, since the bytes were read.
    pub fn read<R>(&self, read: impl FnOnce(&[u8]) -> R) -> Result<R> {
        struct End(RawFd);
        impl Drop for End {
            fn drop(&mut self) {
                if let Err(err) = sync(self.0, SYNC_END) {
                    cairn_detect::note!("dma: DMA_BUF_IOCTL_SYNC end: {err}");
                }
            }
        }
        let fd = self.fd.as_raw_fd();
        sync(fd, SYNC_START).context("DMA_BUF_IOCTL_SYNC start")?;
        let _end = End(fd);
        // SAFETY: `map` is a live mapping of `len` bytes until drop.
        let bytes = unsafe { std::slice::from_raw_parts(self.map.as_ptr(), self.len) };
        Ok(read(bytes))
    }
}

impl Drop for DmaBuf {
    fn drop(&mut self) {
        // SAFETY: the mapping `alloc` made, unmapped once; no slice of it
        // outlives a `read` call.
        unsafe { libc::munmap(self.map.as_ptr().cast(), self.len) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_heap_is_named() {
        let msg = match DmaHeap::open(Path::new("/nonexistent/dma_heap/system")) {
            Ok(_) => panic!("opened"),
            Err(err) => format!("{err:#}"),
        };
        assert!(msg.contains("/nonexistent/dma_heap/system"), "{msg}");
    }

    #[test]
    fn a_heap_that_is_not_one_refuses_the_alloc_ioctl_with_the_path() {
        let heap = DmaHeap::open(Path::new("/dev/null")).unwrap();
        let msg = format!("{:#}", heap.alloc(4096).err().unwrap());
        assert!(msg.contains("4096 bytes from /dev/null"), "{msg}");
        assert!(format!("{:#}", heap.alloc(0).err().unwrap()).contains("0 bytes"));
    }
}
