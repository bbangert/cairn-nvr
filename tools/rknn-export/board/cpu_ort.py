#!/usr/bin/env python3
"""CPU ONNX Runtime latency for the NPU-vs-CPU delta. usage: cpu_ort.py MODEL.onnx N [threads]"""
import sys, time, json, numpy as np, onnxruntime as ort
p, n = sys.argv[1], int(sys.argv[2])
so = ort.SessionOptions()
if len(sys.argv) > 3: so.intra_op_num_threads = int(sys.argv[3])
s = ort.InferenceSession(p, so, providers=["CPUExecutionProvider"])
i = s.get_inputs()[0]
shape = [d if isinstance(d, int) else 1 for d in i.shape]
x = np.random.rand(*shape).astype(np.float32) * 255
s.run(None, {i.name: x})
v = []
for _ in range(n):
    a = time.perf_counter(); s.run(None, {i.name: x}); v.append((time.perf_counter() - a) * 1e3)
print("JSON:" + json.dumps({"model": p, "ort": ort.__version__, "providers": s.get_providers(), "n": n,
                            "p50": round(float(np.percentile(v, 50)), 1), "p95": round(float(np.percentile(v, 95)), 1)}))
