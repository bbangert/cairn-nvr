#!/usr/bin/env python3
"""K concurrent mpi_dec_test decodes of one clip, CmaFree/MemAvailable sampled at 20 Hz.
usage: dec.py CLIP FRAMES K [bufmode]   bufmode: hi (default) | i | e"""
import json, os, subprocess, sys, threading, time, re
clip, frames, k = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
bufmode = sys.argv[4] if len(sys.argv) > 4 else None
def mi():
    d = {}
    for l in open("/proc/meminfo"):
        a, b = l.split(":")
        if a in ("CmaFree", "MemAvailable"):
            d[a] = int(b.split()[0]) // 1024
    return d
samples, stop = [], [False]
def samp():
    while not stop[0]:
        samples.append(mi()); time.sleep(0.05)
base = mi()
th = threading.Thread(target=samp, daemon=True); th.start()
env = dict(os.environ, dma_heap_debug="0x3", mpp_buffer_debug="0")
cmd = ["mpi_dec_test", "-t", "7", "-i", clip, "-n", str(frames), "-v", "f"] + (["-bufmode", bufmode] if bufmode else [])
t0 = time.time()
ps = [subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env) for _ in range(k)]
outs = [p.communicate()[0] for p in ps]
el = time.time() - t0
stop[0] = True; th.join()
after = mi()
heaps = sorted({m for o in outs for m in re.findall(r"open dma_heap (\S+)", o)})
fps = [re.findall(r"frame (\d+) .*?fps ([\d.]+)|decode (\d+) frames.*?fps ([\d.]+)", o) for o in outs]
tail = [[l for l in o.splitlines() if "fps" in l or "error" in l.lower() or "failed" in l.lower()][-3:] for o in outs]
print("JSON:" + json.dumps({"clip": os.path.basename(clip), "k": k, "frames_each": frames, "bufmode": bufmode or "hi",
    "wall_s": round(el, 2), "agg_fps_wall": round(k * frames / el, 1), "rc": [p.returncode for p in ps],
    "cma_free_base_mb": base["CmaFree"], "cma_free_min_mb": min(s["CmaFree"] for s in samples),
    "cma_free_after_mb": after["CmaFree"], "mem_avail_base_mb": base["MemAvailable"],
    "mem_avail_min_mb": min(s["MemAvailable"] for s in samples), "heaps_opened": heaps, "tail": tail}))
