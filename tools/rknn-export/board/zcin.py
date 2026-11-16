#!/usr/bin/env python3
"""Zero-copy input only: UINT8 NHWC into rknn_create_mem + set_io_mem, outputs via outputs_get.
Also zeroes the input mem and reports whether the outputs change, proving that mem is what the NPU reads.
usage: zcin.py MODEL FRAME.npy"""
import ctypes as C, json, sys, time, numpy as np
import rk
path, frame = sys.argv[1:3]
m = rk.Model(path); x = rk.nhwc(frame, m)
m.set_input(x); m.run(); ref = m.fetch_float()
m.close()
m = rk.Model(path)
sync = rk.rk.rknn_mem_sync; sync.argtypes = [rk.ctx_t, C.POINTER(rk.Mem), C.c_int]
a = m.attr(rk.Q_NATIVE_IN, 0); a.type, a.fmt, a.pass_through = rk.UINT8, rk.NHWC, 0
mem = rk.rk.rknn_create_mem(m.ctx, a.size_with_stride)
dst = np.ctypeslib.as_array(C.cast(mem.contents.virt_addr, C.POINTER(C.c_uint8)), (a.size_with_stride,))
wst = a.w_stride or m.w; dst[: m.h * wst * 3].reshape(m.h, wst, 3)[:, : m.w] = x[0]
sync(m.ctx, mem, 1)
r = {"model": path}
try:
    rk.ck(rk.rk.rknn_set_io_mem(m.ctx, mem, C.byref(a)), "set_io_mem in")
    m.run(); o = m.fetch_float()
    r["cos_zc_input_vs_inputs_set"] = [rk.cosine(p, q) for p, q in zip(o, ref)]
    v = []
    for _ in range(30):
        t = time.perf_counter(); sync(m.ctx, mem, 1); m.run(); v.append((time.perf_counter() - t) * 1e3)
    r["zc_input_run_ms_p50"] = round(float(np.median(v)), 2)
except RuntimeError as e:
    r["error"] = str(e)
# a frame of zeros must change the outputs; proves the mem is the one being read
dst[:] = 0; sync(m.ctx, mem, 1); m.run(); z = m.fetch_float()
r["cos_zero_frame_vs_real"] = [rk.cosine(p, q) for p, q in zip(z, ref)][:3]
print("JSON:" + json.dumps(r))
