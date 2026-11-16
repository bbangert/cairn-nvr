#!/usr/bin/env python3
"""Zero-copy correctness: UINT8 NHWC input written into rknn_create_mem, native outputs read
back with their padded row stride, compared with the inputs_set path. Also times numpy u8->fp16.
usage: zc.py MODEL FRAME.npy"""
import ctypes as C, json, sys, time, numpy as np
import rk
path, frame = sys.argv[1:3]
m = rk.Model(path); x = rk.nhwc(frame, m)
m.set_input(x); m.run(); ref = m.fetch_float()[0]
a = m.attr(rk.Q_NATIVE_IN, 0); a.type, a.fmt, a.pass_through = rk.UINT8, rk.NHWC, 0
mem = rk.rk.rknn_create_mem(m.ctx, a.size_with_stride)
dst = np.ctypeslib.as_array(C.cast(mem.contents.virt_addr, C.POINTER(C.c_uint8)), (a.size_with_stride,))
dst[: x.nbytes] = x.ravel()
rk.ck(rk.rk.rknn_set_io_mem(m.ctx, mem, C.byref(a)), "set_io_mem in")
oa = m.attr(rk.Q_NATIVE_OUT, 0)
om = rk.rk.rknn_create_mem(m.ctx, oa.size_with_stride)
rk.ck(rk.rk.rknn_set_io_mem(m.ctx, om, C.byref(oa)), "set_io_mem out")
sync = rk.rk.rknn_mem_sync; sync.argtypes = [rk.ctx_t, C.POINTER(rk.Mem), C.c_int]
sync(m.ctx, mem, 1)
m.run()
sync(m.ctx, om, 2)
dt = {rk.INT8: np.int8, rk.FLOAT16: np.float16}[oa.type]
raw = np.ctypeslib.as_array(C.cast(om.contents.virt_addr, C.POINTER(C.c_uint8)), (oa.size_with_stride,)).view(dt)
rows, cols = ref.shape[1], ref.shape[2]; row = raw.size // rows
q = raw.astype(np.float32)
if oa.type == rk.INT8:
    q = (q - oa.zp) * oa.scale
# candidate native layouts for a padded [1,rows,cols] tensor
cands = {"rows_x_padcols": q.reshape(rows, row)[:, :cols],
         "padcols_x_rows_T": q.reshape(row, rows)[:cols].T,
         "c1_rows_c2(8)": q.reshape(row // 8, rows, 8).transpose(1, 0, 2).reshape(rows, row)[:, :cols],
         "c1_rows_c2(16)": q.reshape(row // 16 if row % 16 == 0 else 1, -1, 16).transpose(1, 0, 2).reshape(rows, -1)[:, :cols] if row % 16 == 0 else None}
scores = {k: rk.cosine(v, ref) for k, v in cands.items() if v is not None}
best = max(scores, key=lambda k: scores[k]); f = cands[best]
v = []
for _ in range(50):
    t = time.perf_counter(); x.astype(np.float16); v.append((time.perf_counter() - t) * 1e3)
zrun = []
for _ in range(30):
    t = time.perf_counter(); sync(m.ctx, mem, 1); m.run(); sync(m.ctx, om, 2); zrun.append((time.perf_counter() - t) * 1e3)
print("JSON:" + json.dumps({"model": path, "zero_copy_sync_run_ms_p50": round(float(np.median(zrun)), 2), "out_native": oa.d(), "row_stride_elems": row,
                            "layout_cos": scores, "best": best, "cos_zero_copy_vs_inputs_set": rk.cosine(f, ref), "max_abs": float(np.abs(f - ref[0]).max()),
                            "numpy_u8_to_fp16_ms_p50": round(float(np.median(v)), 2)}))
