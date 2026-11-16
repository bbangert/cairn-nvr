#!/usr/bin/env python3
"""One rknn-toolkit2 conversion (x86 host, no board).

usage: convert.py NAME ONNX {i8|fp16} [--mean 0,0,0] [--std 1,1,1] [--calib DIR]
         [--size WxH] [--input-name images] [--outputs a,b] [--analysis N]
         [--algo normal] [--disable-rules r1,r2]
         [--out DIR] [--kind yolox|split --parity DIR [--dump N]]
Writes OUT/NAME.rknn and OUT/NAME.json (steps ok/err, timings, toolkit and
quantization settings, calibration/parity set ids, sha256 of the source ONNX
and of the .rknn, output tensors seen on the simulator). With --parity (a
prep_calib.py set of held-out frames) also OUT/NAME.parity.json: pooled
simulator-vs-FP32 metrics per source geometry; no tensors kept beyond the
first --dump frames. Without it, 5 calibration frames are dumped as
NAME.parity.npz for parity.py.
The simulator only runs in the session that built the graph, so parity
cannot be a separate step. Run under `venv/bin/python -I`; the caller
redirects stdout to OUT/NAME.out, which carries the toolkit's operator table.
"""
import argparse, hashlib, json, os, sys, time, traceback
from importlib.metadata import version
import numpy as np
from rknn.api import RKNN

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parity

ap = argparse.ArgumentParser()
ap.add_argument("name"); ap.add_argument("onnx"); ap.add_argument("mode", choices=["i8", "fp16"])
ap.add_argument("--mean", default="0,0,0"); ap.add_argument("--std", default="1,1,1")
ap.add_argument("--calib"); ap.add_argument("--size")
ap.add_argument("--outputs"); ap.add_argument("--analysis", type=int, default=0)
ap.add_argument("--algo", default="normal"); ap.add_argument("--disable-rules"); ap.add_argument("--input-name", default="images")
ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "rknn")); ap.add_argument("--kind", choices=["yolox", "split"])
ap.add_argument("--parity"); ap.add_argument("--dump", type=int, default=0)
a = ap.parse_args()
for k in ("onnx", "calib", "parity", "out"):
    if getattr(a, k): setattr(a, k, os.path.abspath(getattr(a, k)))
if a.parity:
    assert a.kind and a.calib, "--parity needs --kind and --calib"
    cf, pf = (json.load(open(d + "/set.json"))["frames"] for d in (a.calib, a.parity))
    if not (cf and pf): sys.exit("calibration and parity sets must both have frames")
    # frames of a calibration source would score the quantizer on its own training data
    shared = parity.shared_sources(cf, pf)
    if shared: sys.exit(f"calibration and parity share sources: {shared}")

out = a.out; os.makedirs(out, exist_ok=True)
os.chdir(out)  # the toolkit drops check*_*.onnx (20-40 MB each) into the cwd on every build
for ext in ("json", "rknn", "parity.json", "parity.npz"):
    if os.path.exists(f"{a.name}.{ext}"): os.remove(f"{a.name}.{ext}")
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
setid = lambda d: json.load(open(d + "/set.json"))["id"] if d and os.path.exists(d + "/set.json") else None
res = {"name": a.name, "mode": a.mode, "kind": a.kind, "steps": {}, "secs": {},
       "toolkit": version("rknn-toolkit2"), "target_platform": "rk3566", "quantized_algorithm": a.algo,
       "calib_set_id": setid(a.calib), "calib_policy": a.calib and os.path.basename(a.calib), "parity_set_id": setid(a.parity),
       "source_sha256": sha(a.onnx)}
def vec(s): return [[float(x) for x in s.split(",")]]
def save(): json.dump(res, open(os.path.join(out, a.name + ".json"), "w"), indent=1, default=str)

r = RKNN(verbose=True, verbose_file=os.path.join(out, a.name + ".build.log"))
r.config(mean_values=vec(a.mean), std_values=vec(a.std), target_platform="rk3566",
         quantized_algorithm=a.algo, float_dtype="float16",
         **({"disable_rules": a.disable_rules.split(",")} if a.disable_rules else {}))
kw = {}
if a.size:
    w, h = map(int, a.size.split("x")); kw = dict(inputs=[a.input_name], input_size_list=[[1, 3, h, w]])
if a.outputs: kw["outputs"] = a.outputs.split(",")
def step(k, fn):
    t = time.time()
    try:
        v = fn(); res["steps"][k] = "ok" if v in (0, None) else f"ret={v}"
        return v in (0, None)
    except Exception as e:
        res["steps"][k] = "ERR " + repr(e)[:300]; traceback.print_exc(); return False
    finally:
        res["secs"][k] = round(time.time() - t, 1)
ok = step("load", lambda: r.load_onnx(model=a.onnx, **kw))
ok = ok and step("build", lambda: r.build(do_quantization=(a.mode == "i8"),
                                          dataset=a.calib + "/dataset.txt" if a.calib else None))
ok = ok and step("export", lambda: r.export_rknn(os.path.join(out, a.name + ".rknn")))
if ok: res["rknn_sha256"] = sha(os.path.join(out, a.name + ".rknn"))
ok = ok and step("load_rknn", lambda: RKNN().load_rknn(os.path.join(out, a.name + ".rknn")))  # the file itself, not the live graph
if ok:
    res["size_mb"] = round(os.path.getsize(os.path.join(out, a.name + ".rknn")) / 1e6, 2)
    # simulator run: shapes of what the model emits
    if step("sim_init", lambda: r.init_runtime()):
        if a.calib:
            import onnxruntime as ort
            mean = np.array(vec(a.mean)[0], np.float32).reshape(1, 3, 1, 1)
            std = np.array(vec(a.std)[0], np.float32).reshape(1, 3, 1, 1)
            sess = ort.InferenceSession(a.onnx, providers=["CPUExecutionProvider"])
            iname = sess.get_inputs()[0].name
            if a.parity:
                meta = json.load(open(a.parity + "/set.json"))
                frames = [(f"{a.parity}/{f['npy']}", f"{f['w']}x{f['h']}") for f in meta["frames"]]
                dump = a.dump
            else:
                files = open(a.calib + "/dataset.txt").read().split()
                files = files[:: max(1, len(files) // 5)][:5]
                frames, dump = [(f, "all") for f in files], 5
            acc = parity.Acc(a.kind) if a.parity else None
            sim, ref = [], []
            t0 = time.time()
            try:
                for n, (f, grp) in enumerate(frames):
                    x = np.load(f)
                    o = r.inference(inputs=[x], data_format="nchw")
                    rf = sess.run(None, {iname: (x.astype(np.float32) - mean) / std})
                    if n == 0: res["sim_outputs"] = [[list(t.shape), str(t.dtype)] for t in o]
                    if n < dump: sim.append(o); ref.append(rf)
                    if acc: acc.add(grp, o, rf)
                if sim:
                    np.savez(os.path.join(out, a.name + ".parity.npz"),
                             **{f"sim{i}_{j}": t for i, o in enumerate(sim) for j, t in enumerate(o)},
                             **{f"ref{i}_{j}": t for i, o in enumerate(ref) for j, t in enumerate(o)})
                if acc:
                    json.dump({"set_id": meta["id"], "n_frames": len(frames), "groups": acc.result()},
                              open(os.path.join(out, a.name + ".parity.json"), "w"), indent=1)
            except Exception as e:
                res["sim_outputs"] = "ERR " + repr(e)[:300]; traceback.print_exc()
            res["secs"]["parity"] = round(time.time() - t0, 1)
    if a.analysis and a.mode == "i8":
        files = open(a.calib + "/dataset.txt").read().split()
        files = files[:: max(1, len(files) // a.analysis)][: a.analysis]
        res["analysis_inputs"] = files
        try:
            r.accuracy_analysis(inputs=files, output_dir=os.path.join(out, a.name + ".snap"),
                                target=None)
            res["steps"]["analysis"] = "ok"
        except Exception as e:
            res["steps"]["analysis"] = "ERR " + repr(e)[:300]; traceback.print_exc()
save()
print(json.dumps(res, indent=1, default=str))
sys.exit(int(any(v != "ok" for v in res["steps"].values()) or isinstance(res.get("sim_outputs"), str)))
