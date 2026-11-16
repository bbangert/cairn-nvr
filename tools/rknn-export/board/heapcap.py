#!/usr/bin/env python3
"""Count 1920x1088 NV12 buffers the 32 MiB rk-dma-heap-cma pool yields (cap 14), then free all.
The default CMA ('reserved') is not drained: kernel drivers allocate from it."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from heaps import alloc, cma, SIZES
h = "/dev/rk_dma_heap/rk-dma-heap-cma"
fd = os.open(h, os.O_RDWR); held = []; c0 = cma(); err = None
while len(held) < 14:
    try:
        held.append(alloc(fd, SIZES["nv12_1088"], "R"))
    except OSError as e:
        err = str(e); break
c1 = cma()
for d in held: os.close(d)
os.close(fd)
print("JSON:" + json.dumps({"heap": h, "nv12_1088_buffers": len(held), "stopped_by": err, "cma_free_before_mb": c0 // 1024,
                            "cma_free_at_peak_mb": c1 // 1024, "cma_free_after_mb": cma() // 1024}))
