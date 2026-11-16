#!/usr/bin/env python3
"""Allocate 640x640x3 and 1920x1088 NV12 dma-bufs from each heap; CmaFree delta and,
where pagemap allows, the physical range. Buffers are freed before exit.
usage: heaps.py [N_NV12]   (N 1080p NV12 buffers per heap, default 4)"""
import ctypes as C, fcntl, json, mmap, os, struct, sys
SIZES = {"rgb640": 640 * 640 * 3, "nv12_1088": 1920 * 1088 * 3 // 2}
HEAPS = ["/dev/dma_heap/system", "/dev/dma_heap/system-uncached", "/dev/dma_heap/reserved", "/dev/rk_dma_heap/rk-dma-heap-cma"]
n_nv12 = int(sys.argv[1]) if len(sys.argv) > 1 else 4

def cma():
    for l in open("/proc/meminfo"):
        if l.startswith("CmaFree"):
            return int(l.split()[1])

def alloc(fd, size, magic):
    buf = bytearray(struct.pack("<QIIQ", size, 0, os.O_RDWR | os.O_CLOEXEC, 0))
    req = 0xC0000000 | (24 << 16) | (ord(magic) << 8)
    fcntl.ioctl(fd, req, buf)
    return struct.unpack("<QIIQ", buf)[1]

def phys(dfd, size):
    """First/last PFN of the mapped dma-buf via pagemap (0 means not permitted)."""
    try:
        m = mmap.mmap(dfd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    except OSError as e:
        return f"mmap: {e}"
    addr = C.addressof(C.c_char.from_buffer(m))
    pfns = []
    with open("/proc/self/pagemap", "rb") as pm:
        for off in range(0, size, 4096):
            m[off] = 1  # fault the page in
            pm.seek(((addr + off) // 4096) * 8)
            e, = struct.unpack("<Q", pm.read(8))
            pfns.append(e & ((1 << 55) - 1) if e >> 63 else None)
    del addr
    m.close()
    if not pfns or pfns[0] in (None, 0):
        return "pfn hidden (no CAP_SYS_ADMIN) or not present"
    contig = all(pfns[i] == pfns[0] + i for i in range(len(pfns)))
    return {"first": hex(pfns[0] * 4096), "last": hex(max(pfns) * 4096 + 4095), "contiguous": contig}

def main():
    res = {}
    for h in HEAPS:
        r = {}
        try:
            hfd = os.open(h, os.O_RDWR)
        except OSError as e:
            res[h] = {"open": str(e)}; continue
        magic = "R" if "rk_dma_heap" in h else "H"
        held, got = [], 0
        c0 = cma()
        for name, size in [("rgb640", SIZES["rgb640"])] + [(f"nv12_1088#{i}", SIZES["nv12_1088"]) for i in range(n_nv12)]:
            try:
                d = alloc(hfd, size, magic)
                held.append(d); got += size
                r[name] = {"ok": True, **({"phys": phys(d, size)} if name in ("rgb640", "nv12_1088#0") else {})}
            except OSError as e:
                r[name] = {"ok": False, "err": str(e)}
        r["cma_free_drop_kb"] = c0 - cma()
        r["alloc_kb"] = got // 1024
        for d in held:
            os.close(d)
        os.close(hfd)
        r["cma_free_after_close_drop_kb"] = c0 - cma()
        res[h] = r
    print("JSON:" + json.dumps(res))


if __name__ == "__main__":
    main()
