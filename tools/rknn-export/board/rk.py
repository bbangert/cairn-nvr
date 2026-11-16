#!/usr/bin/env python3
"""ctypes harness against librknnrt (2.3.2 header layout), no rknnlite.

Timing is per C call, so Python pre/post work is outside every number.

  rk.py info   MODEL
  rk.py bench  MODEL [--warm 200] [--sustain 60] [--want-float 0] [--input zero|frame.npy]
  rk.py input  MODEL FRAME.npy          pass_through 0 vs 1 and zero-copy create_mem, timed
  rk.py acc    MODEL OUT.npz FRAME.npy...   float outputs for host-side parity
  rk.py worker MODEL START_EPOCH SECONDS    concurrency child: one JSON line

FRAME.npy is the trial's NCHW uint8 calibration tensor; it is fed as NHWC uint8.
"""
import ctypes as C, json, os, sys, threading, time
import numpy as np

LIB = os.environ.get("RKNN_LIB", "/usr/lib/librknnrt.so")
rk = C.CDLL(LIB)

MAX_DIMS, NAME_LEN = 16, 256
FLOAT32, FLOAT16, INT8, UINT8 = 0, 1, 2, 3
NCHW, NHWC = 0, 1
Q_IN_OUT, Q_IN, Q_OUT, Q_PERF_RUN, Q_SDK, Q_MEM, Q_NATIVE_IN, Q_NATIVE_OUT, Q_NHWC_IN = 0, 1, 2, 4, 5, 6, 8, 9, 10


class IONum(C.Structure):
    _fields_ = [("n_input", C.c_uint32), ("n_output", C.c_uint32)]


class Attr(C.Structure):
    _fields_ = [("index", C.c_uint32), ("n_dims", C.c_uint32), ("dims", C.c_uint32 * MAX_DIMS),
                ("name", C.c_char * NAME_LEN), ("n_elems", C.c_uint32), ("size", C.c_uint32),
                ("fmt", C.c_int), ("type", C.c_int), ("qnt_type", C.c_int), ("fl", C.c_int8),
                ("zp", C.c_int32), ("scale", C.c_float), ("w_stride", C.c_uint32),
                ("size_with_stride", C.c_uint32), ("pass_through", C.c_uint8), ("h_stride", C.c_uint32)]

    def d(self):
        return {"name": self.name.decode(), "dims": list(self.dims[: self.n_dims]), "fmt": self.fmt,
                "type": self.type, "zp": self.zp, "scale": self.scale, "size": self.size,
                "size_with_stride": self.size_with_stride, "w_stride": self.w_stride}


class Input(C.Structure):
    _fields_ = [("index", C.c_uint32), ("buf", C.c_void_p), ("size", C.c_uint32),
                ("pass_through", C.c_uint8), ("type", C.c_int), ("fmt", C.c_int)]


class Output(C.Structure):
    _fields_ = [("want_float", C.c_uint8), ("is_prealloc", C.c_uint8), ("index", C.c_uint32),
                ("buf", C.c_void_p), ("size", C.c_uint32)]


class Mem(C.Structure):
    _fields_ = [("virt_addr", C.c_void_p), ("phys_addr", C.c_uint64), ("fd", C.c_int32),
                ("offset", C.c_int32), ("size", C.c_uint32), ("flags", C.c_uint32), ("priv_data", C.c_void_p)]


class SDK(C.Structure):
    _fields_ = [("api", C.c_char * 256), ("drv", C.c_char * 256)]


class MemSize(C.Structure):
    _fields_ = [("weight", C.c_uint32), ("internal", C.c_uint32), ("dma", C.c_uint64),
                ("sram_total", C.c_uint32), ("sram_free", C.c_uint32), ("res", C.c_uint32 * 10)]


ctx_t = C.c_uint64
rk.rknn_init.argtypes = [C.POINTER(ctx_t), C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p]
rk.rknn_query.argtypes = [ctx_t, C.c_int, C.c_void_p, C.c_uint32]
rk.rknn_inputs_set.argtypes = [ctx_t, C.c_uint32, C.c_void_p]
rk.rknn_run.argtypes = [ctx_t, C.c_void_p]
rk.rknn_outputs_get.argtypes = [ctx_t, C.c_uint32, C.c_void_p, C.c_void_p]
rk.rknn_outputs_release.argtypes = [ctx_t, C.c_uint32, C.c_void_p]
rk.rknn_destroy.argtypes = [ctx_t]
rk.rknn_create_mem.argtypes = [ctx_t, C.c_uint32]
rk.rknn_create_mem.restype = C.POINTER(Mem)
rk.rknn_set_io_mem.argtypes = [ctx_t, C.POINTER(Mem), C.POINTER(Attr)]
rk.rknn_destroy_mem.argtypes = [ctx_t, C.POINTER(Mem)]


def ck(r, what):
    if r != 0:
        raise RuntimeError(f"{what} -> {r}")


class Model:
    def __init__(self, path):
        self.blob = open(path, "rb").read()
        self.buf = C.create_string_buffer(self.blob, len(self.blob))
        self.ctx = ctx_t(0)
        t = time.perf_counter()
        ck(rk.rknn_init(C.byref(self.ctx), self.buf, len(self.blob), 0, None), "rknn_init")
        self.init_ms = (time.perf_counter() - t) * 1e3
        io = IONum()
        ck(rk.rknn_query(self.ctx, Q_IN_OUT, C.byref(io), C.sizeof(io)), "query io")
        self.n_in, self.n_out = io.n_input, io.n_output
        self.ins = [self.attr(Q_IN, i) for i in range(self.n_in)]
        self.outs = [self.attr(Q_OUT, i) for i in range(self.n_out)]
        a = self.ins[0]
        d = list(a.dims[: a.n_dims])
        # attr dims follow attr.fmt; NHWC models report [1,H,W,C].
        self.h, self.w = (d[1], d[2]) if a.fmt == NHWC else (d[2], d[3])
        self.outarr = (Output * self.n_out)()

    def attr(self, cmd, i):
        a = Attr()
        a.index = i
        ck(rk.rknn_query(self.ctx, cmd, C.byref(a), C.sizeof(a)), f"query {cmd}/{i}")
        return a

    def info(self):
        sdk, ms = SDK(), MemSize()
        rk.rknn_query(self.ctx, Q_SDK, C.byref(sdk), C.sizeof(sdk))
        rk.rknn_query(self.ctx, Q_MEM, C.byref(ms), C.sizeof(ms))
        return {"api": sdk.api.decode(), "drv": sdk.drv.decode(), "init_ms": round(self.init_ms, 1),
                "weight_mb": round(ms.weight / 1e6, 2), "internal_mb": round(ms.internal / 1e6, 2),
                "dma_mb": round(ms.dma / 1e6, 2),
                "inputs": [a.d() for a in self.ins], "native_in": [self.attr(Q_NATIVE_IN, 0).d()],
                "outputs": [a.d() for a in self.outs]}

    def set_input(self, arr, pass_through=0, typ=UINT8, fmt=NHWC):
        inp = Input(0, arr.ctypes.data, arr.nbytes, pass_through, typ, fmt)
        ck(rk.rknn_inputs_set(self.ctx, 1, C.byref(inp)), "inputs_set")

    def run(self):
        ck(rk.rknn_run(self.ctx, None), "run")

    def get(self, want_float=0):
        for i in range(self.n_out):
            self.outarr[i] = Output(want_float, 0, i, None, 0)
        ck(rk.rknn_outputs_get(self.ctx, self.n_out, self.outarr, None), "outputs_get")

    def fetch_float(self):
        """Copies of the float outputs, shaped as queried."""
        self.get(1)
        res = []
        for i, a in enumerate(self.outs):
            o = self.outarr[i]
            res.append(np.ctypeslib.as_array(C.cast(o.buf, C.POINTER(C.c_float)), (o.size // 4,))
                       .copy().reshape(list(a.dims[: a.n_dims])))
        self.release()
        return res

    def release(self):
        ck(rk.rknn_outputs_release(self.ctx, self.n_out, self.outarr), "outputs_release")

    def close(self):
        rk.rknn_destroy(self.ctx)


def nhwc(path, m):
    x = np.load(path)
    if x.ndim == 4 and x.shape[1] == 3:
        x = x.transpose(0, 2, 3, 1)
    return np.ascontiguousarray(x, np.uint8)


def pct(v, p):
    return round(float(np.percentile(v, p)), 2)


def stats(ms):
    return {"n": len(ms), "p50": pct(ms, 50), "p95": pct(ms, 95), "mean": round(float(np.mean(ms)), 2)}


def read(p):
    try:
        return open(p).read().strip()
    except OSError:
        return None


def temps():
    out = []
    for i in range(10):
        t = read(f"/sys/class/thermal/thermal_zone{i}/temp")
        if t is None:
            break
        out.append(int(t) / 1000)
    return out


def meminfo():
    d = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":")
        if k in ("MemAvailable", "CmaFree", "MemFree"):
            d[k] = int(v.split()[0]) // 1024
    return d


class Sampler(threading.Thread):
    """1 Hz /proc/rknpu/load, temps and meminfo while a sustained run is going."""

    def __init__(self):
        super().__init__(daemon=True)
        self.loads, self.t, self.mem, self.stop = [], [], [], False

    def run(self):
        while not self.stop:
            l = read("/proc/rknpu/load") or ""
            try:
                self.loads.append(int(l.split(":")[-1].strip().rstrip("%").split("%")[0]))
            except ValueError:
                pass
            self.t.append(max(temps() or [0]))
            self.mem.append(meminfo())
            time.sleep(1)

    def summary(self):
        cma = [m.get("CmaFree") for m in self.mem if "CmaFree" in m]
        av = [m.get("MemAvailable") for m in self.mem]
        return {"npu_load_mean": round(float(np.mean(self.loads)), 1) if self.loads else None,
                "npu_load_max": max(self.loads) if self.loads else None,
                "temp_max": max(self.t) if self.t else None,
                "cma_free_min_mb": min(cma) if cma else None, "mem_avail_min_mb": min(av) if av else None}


def bench(path, warm=200, sustain=60, want_float=0, frame=None):
    t0, m0 = temps(), meminfo()
    m = Model(path)
    x = nhwc(frame, m) if frame else np.zeros((1, m.h, m.w, 3), np.uint8)
    for _ in range(5):
        m.set_input(x); m.run(); m.get(want_float); m.release()
    ts, tr, tg = [], [], []
    for _ in range(warm):
        a = time.perf_counter(); m.set_input(x)
        b = time.perf_counter(); m.run()
        c = time.perf_counter(); m.get(want_float)
        d = time.perf_counter(); m.release()
        ts.append((b - a) * 1e3); tr.append((c - b) * 1e3); tg.append((d - c) * 1e3)
    res = {"model": os.path.basename(path), "info": {k: v for k, v in m.info().items()
                                                       if k in ("api", "drv", "init_ms", "weight_mb", "internal_mb", "dma_mb")},
           "inputs_set": stats(ts), "run": stats(tr), "outputs_get": stats(tg),
           "temp_before": max(t0), "mem_before": m0}
    if sustain:
        s = Sampler(); s.start()
        n, end = 0, time.perf_counter() + sustain
        start = time.perf_counter()
        while time.perf_counter() < end:
            m.set_input(x); m.run(); m.get(want_float); m.release(); n += 1
        el = time.perf_counter() - start
        s.stop = True; s.join()
        res["sustained"] = {"seconds": round(el, 1), "n": n, "ips": round(n / el, 2), **s.summary()}
    res["temp_after"] = max(temps())
    m.close()
    return res


def input_paths(path, frame):
    m = Model(path)
    x = nhwc(frame, m)
    na = m.attr(Q_NATIVE_IN, 0)
    res = {"model": os.path.basename(path), "native_in": na.d(), "in": m.ins[0].d()}

    def timed(fn, n=100):
        v = []
        for _ in range(n):
            a = time.perf_counter(); fn(); v.append((time.perf_counter() - a) * 1e3)
        return stats(v)

    m.set_input(x); m.run(); ref = m.fetch_float()
    res["pt0_nhwc_u8"] = {"inputs_set": timed(lambda: m.set_input(x))}
    xc = np.ascontiguousarray(x.transpose(0, 3, 1, 2))
    try:
        m.set_input(xc, fmt=NCHW); m.run(); o = m.fetch_float()
        res["pt0_nchw_u8"] = {"inputs_set": timed(lambda: m.set_input(xc, fmt=NCHW)),
                              "cos_vs_nhwc": [cosine(a, b) for a, b in zip(o, ref)]}
    except RuntimeError as e:
        res["pt0_nchw_u8"] = {"error": str(e)}

    # pass_through=1: buffer must already be in the model's native input type/layout.
    if na.type == INT8:
        q = np.clip(np.round(x.astype(np.float32) / na.scale) + na.zp, -128, 127).astype(np.int8)
    elif na.type == FLOAT16:
        q = x.astype(np.float16)
    else:
        q = x
    q = np.ascontiguousarray(q)
    try:
        m.set_input(q, pass_through=1, typ=na.type, fmt=na.fmt); m.run(); o = m.fetch_float()
        res["pt1_native"] = {"buf_dtype": str(q.dtype), "inputs_set": timed(lambda: m.set_input(q, pass_through=1, typ=na.type, fmt=na.fmt)),
                             "cos_vs_pt0": [cosine(a, b) for a, b in zip(o, ref)]}
        # pass_through=1 with raw uint8: shows whether the driver silently accepts the wrong type.
        m.set_input(x, pass_through=1, typ=UINT8, fmt=NHWC); m.run(); o = m.fetch_float()
        res["pt1_raw_u8"] = {"cos_vs_pt0": [cosine(a, b) for a, b in zip(o, ref)]}
    except RuntimeError as e:
        res["pt1_native"] = {"error": str(e)}
    res["run_after_inputs_set"] = timed(m.run, 50)
    m.close()

    # Zero-copy: rknn_create_mem input as NHWC uint8 (what RGA would write), set_io_mem.
    m = Model(path)
    try:
        a = m.attr(Q_NATIVE_IN, 0)
        a.type, a.fmt, a.pass_through = UINT8, NHWC, 0
        mem = rk.rknn_create_mem(m.ctx, a.size_with_stride)
        ck(0 if mem else -1, "create_mem in")
        mi = mem.contents
        wst = a.w_stride or m.w
        dst = np.ctypeslib.as_array(C.cast(mi.virt_addr, C.POINTER(C.c_uint8)), (a.size_with_stride,))
        img = dst[: m.h * wst * 3].reshape(m.h, wst, 3)
        img[:, : m.w] = x[0]
        ck(rk.rknn_set_io_mem(m.ctx, mem, C.byref(a)), "set_io_mem in")
        oms = []
        for i in range(m.n_out):
            oa = m.attr(Q_NATIVE_OUT, i)
            om = rk.rknn_create_mem(m.ctx, oa.size_with_stride)
            ck(rk.rknn_set_io_mem(m.ctx, om, C.byref(oa)), f"set_io_mem out{i}")
            oms.append((om, oa))
        m.run()
        res["zero_copy"] = {"in_attr": a.d(), "in_fd": mi.fd, "in_phys": hex(mi.phys_addr),
                            "run": timed(m.run, 50),
                            "out_native": [oa.d() for _, oa in oms]}
        # parity of output 0 against inputs_set path, when the native out layout equals the normal one
        o0, oa0 = oms[0]
        if oa0.type in (INT8, FLOAT16) and list(oa0.dims[: oa0.n_dims]) == list(m.outs[0].dims[: m.outs[0].n_dims]):
            dt = np.int8 if oa0.type == INT8 else np.float16
            raw = np.ctypeslib.as_array(C.cast(o0.contents.virt_addr, C.POINTER(C.c_uint8)), (oa0.size,)).view(dt)
            f = (raw.astype(np.float32) - oa0.zp) * oa0.scale if oa0.type == INT8 else raw.astype(np.float32)
            res["zero_copy"]["cos_out0_vs_inputs_set"] = cosine(f, ref[0])
        for om, _ in oms:
            rk.rknn_destroy_mem(m.ctx, om)
        rk.rknn_destroy_mem(m.ctx, mem)
    except RuntimeError as e:
        res["zero_copy"] = {"error": str(e)}
    m.close()
    return res


def cosine(a, b):
    a, b = np.ravel(a).astype(np.float64), np.ravel(b).astype(np.float64)
    if a.size != b.size:
        return f"size {a.size} vs {b.size}"
    return round(float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)), 5)


def acc(path, out, frames):
    m = Model(path)
    d = {}
    for i, f in enumerate(frames):
        m.set_input(nhwc(f, m)); m.run()
        for j, t in enumerate(m.fetch_float()):
            d[f"npu{i}_{j}"] = t
    np.savez(out, **d)
    m.close()
    return {"model": os.path.basename(path), "saved": out, "n": len(frames)}


def worker(path, start, seconds):
    m = Model(path)
    x = np.zeros((1, m.h, m.w, 3), np.uint8)
    m.set_input(x); m.run(); m.get(); m.release()
    while time.time() < start:
        time.sleep(0.005)
    n, err, lat = 0, None, []
    end = start + seconds
    try:
        while time.time() < end:
            a = time.perf_counter()
            m.set_input(x); m.run(); m.get(); m.release()
            lat.append((time.perf_counter() - a) * 1e3); n += 1
    except RuntimeError as e:
        err = str(e)
    m.close()
    return {"model": os.path.basename(path), "pid": os.getpid(), "n": n, "ips": round(n / seconds, 2),
            "lat": stats(lat) if lat else None, "error": err}


if __name__ == "__main__":
    cmd, model = sys.argv[1], sys.argv[2]
    rest = sys.argv[3:]
    opt = {}
    pos = []
    i = 0
    while i < len(rest):
        if rest[i].startswith("--"):
            opt[rest[i][2:]] = rest[i + 1]; i += 2
        else:
            pos.append(rest[i]); i += 1
    try:
        if cmd == "info":
            r = Model(model).info()
        elif cmd == "bench":
            r = bench(model, int(opt.get("warm", 200)), float(opt.get("sustain", 60)),
                      int(opt.get("want-float", 0)), opt.get("input"))
        elif cmd == "input":
            r = input_paths(model, pos[0])
        elif cmd == "acc":
            r = acc(model, pos[0], pos[1:])
        elif cmd == "worker":
            r = worker(model, float(pos[0]), float(pos[1]))
        else:
            raise SystemExit(__doc__)
    except Exception as e:
        r = {"model": os.path.basename(model), "error": f"{type(e).__name__}: {e}"}
    print("JSON:" + json.dumps(r), flush=True)
