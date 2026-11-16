#!/usr/bin/env python3
"""Simulator-vs-FP32-ONNX parity.
usage: parity.py NAME KIND   (reads $RKNN_OUT or work/rknn, NAME.parity.npz)
KIND: split (airockchip triples) | yolox (N,85 obj*cls) | v8 (4+nc,A) | v8t (A,4+nc) | e2e (N,6) | generic
yolox/split are scored by Acc (also used in-process by convert.py); the rest
by the trial's per-frame loop below. Acc pools counts over frames, never
averaging per frame, so a frame with one positive weighs one positive. The
trial kinds (legacy: v8/v8t/e2e/generic) print per-frame means: n_ref is
averaged over frames that have a positive, n_sim over all frames, so those two
lines are not comparable.
Positive = FP32 best-class score >= THR; recall = share of those the sim also scores >= THR."""
import json, os, re, sys
import numpy as np

THR = 0.3
STRIDES = (8, 16, 32)


def cos(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def merge(into, src, pre=""):
    for k, v in src.items():
        k = pre + k
        f = k.rsplit(".", 1)[-1]
        if k not in into: into[k] = v
        elif f.startswith("max"): into[k] = max(into[k], v)
        elif f.startswith("min"): into[k] = min(into[k], v)
        else: into[k] += v


def _score(sb, rb, p):
    pos = rb >= THR
    return {p + "n_ref": int(pos.sum()), p + "hit": int((sb[pos] >= THR).sum()),
            p + "dsum": float(np.abs(sb[pos] - rb[pos]).sum()), p + "n_sim": int((sb >= THR).sum()),
            p + "max_ref": float(rb.max()), p + "max_sim": float(sb.max())}


def _scores(sbest, rbest, sper, rper):
    return {**_score(sbest, rbest, "score."), **_score(sper, rper, "person.")}


def _dfl(x):
    if x.shape[0] == 4:
        return x.astype(np.float64)
    z = x.reshape(4, -1, *x.shape[1:]).astype(np.float64)
    e = np.exp(z - z.max(1, keepdims=True))
    return (e / e.sum(1, keepdims=True) * np.arange(e.shape[1]).reshape(1, -1, 1, 1)).sum(1)


def _yolox(s, r):
    s, r = s[0].astype(np.float64), r[0].astype(np.float64)
    n = len(s)
    size = round((n * 1024 / 21) ** 0.5)
    stride = np.repeat(STRIDES, [(size // k) ** 2 for k in STRIDES])
    assert len(stride) == n, (n, size)
    ss, rs = s[:, 4:5] * s[:, 5:], r[:, 4:5] * r[:, 5:]
    d = _scores(ss.max(1), rs.max(1), ss[:, 0], rs[:, 0])
    pos = rs.max(1) >= THR
    st = stride[pos, None]
    err = np.concatenate([np.abs(s[pos, :2] - r[pos, :2]) * st,
                          np.abs(np.exp(s[pos, 2:4]) - np.exp(r[pos, 2:4])) * st], 1)
    d.update({"box.sum": float(err.sum()), "box.n": err.size})
    gaps = np.diff(np.unique(s[:, 4]))
    if (gaps > 0).any():
        d["step.min"] = float(gaps[gaps > 0].min())
    return d


def _split(sim, ref):
    d = {}
    for k, stride in enumerate(STRIDES):
        (sb, sc, _), (rb, rc, _) = sim[3 * k:3 * k + 3], ref[3 * k:3 * k + 3]
        sc, rc = sc[0].astype(np.float64), rc[0].astype(np.float64)
        part = _scores(sc.max(0).ravel(), rc.max(0).ravel(), sc[0].ravel(), rc[0].ravel())
        pos = rc.max(0) >= THR
        err = np.abs(_dfl(sb[0])[:, pos] - _dfl(rb[0])[:, pos]) * stride
        part.update({"box.sum": float(err.sum()), "box.n": err.size})
        merge(d, part, f"s{stride}/")
        merge(d, part)
    return d


def frame_stats(kind, sim, ref):
    shapes = [(s.shape, r.shape) for s, r in zip(sim, ref)]
    if len(sim) != len(ref) or any(a != b for a, b in shapes):
        raise ValueError(f"sim/ref outputs differ: {len(sim)} vs {len(ref)} tensors, shapes {shapes}")
    if not all(np.isfinite(t).all() for t in (*sim, *ref)):
        raise ValueError("non-finite values in sim/ref outputs")  # NaN scores compare False and vanish from every count
    d = {"frames": 1}
    for j, (s, r) in enumerate(zip(sim, ref)):
        d[f"cos.{j}"] = cos(s, r)
    merge(d, _yolox(sim[0], ref[0]) if kind == "yolox" else _split(sim, ref))
    return d


def _block(d, p):
    n = d[p + "n_ref"]
    return {"n_ref": n, "recall": d[p + "hit"] / n if n else None,
            "mean_abs_dscore": d[p + "dsum"] / n if n else None, "n_sim": d[p + "n_sim"],
            "max_ref": d[p + "max_ref"], "max_sim": d[p + "max_sim"]}


def _group(d, pre=""):
    return {"score": _block(d, pre + "score."), "person": _block(d, pre + "person."),
            "box_err_px": d[pre + "box.sum"] / d[pre + "box.n"] if d[pre + "box.n"] else None}


def finalize(d):
    out = {"n_frames": d["frames"],
           "cos": {f"out{k[4:]}": v / d["frames"] for k, v in d.items() if k.startswith("cos.")}, **_group(d)}
    if "step.min" in d:
        out["score_step"] = d["step.min"]
    strides = [k for k in STRIDES if f"s{k}/box.n" in d]
    if strides:
        out["strides"] = {str(k): _group(d, f"s{k}/") for k in strides}
    return out


class Acc:
    def __init__(self, kind):
        self.kind, self.g = kind, {}

    def add(self, group, sim, ref):
        st = frame_stats(self.kind, sim, ref)
        for g in {group, "all"}:
            merge(self.g.setdefault(g, {}), st)

    def result(self):
        if not self.g: raise ValueError("no frames scored")
        return {g: finalize(d) for g, d in sorted(self.g.items())}


def shared_sources(calib_frames, parity_frames):
    """Source stems (capture name minus its trailing _NN.ext) in both frame lists."""
    stem = lambda fr: {re.sub(r"_\d+\.[^.]+$", "", f["src"]) for f in fr}
    return sorted(stem(calib_frames) & stem(parity_frames))


def _f(x):
    return "-" if x is None else f"{x:.4f}"


def report(name, groups):
    for g, r in groups.items():
        for who in ("score", "person"):
            b = r[who]
            print(f"{name} [{g}] n={r['n_frames']} {who}: n_ref={b['n_ref']} recall={_f(b['recall'])} "
                  f"dscore={_f(b['mean_abs_dscore'])} n_sim={b['n_sim']} max_ref={b['max_ref']:.3f} max_sim={b['max_sim']:.3f}")
        print(f"{name} [{g}] cos=" + " ".join(f"{v:.4f}" for v in r["cos"].values()) +
              f" box_err_px={_f(r['box_err_px'])}" + (f" score_step={r['score_step']:.5f}" if "score_step" in r else ""))


def legacy(name, d, kind):
    frames = sorted({k.split("_")[0][3:] for k in d if k.startswith("sim")})
    outs = sorted({int(k.split("_")[1]) for k in d if k.startswith("sim")})
    for j in outs:
        acc = {}
        for i in frames:
            s, r = d[f"sim{i}_{j}"], d[f"ref{i}_{j}"]
            acc.setdefault("all", []).append(cos(s, r))
            if kind in ("v8", "v8t"):
                if kind == "v8": s, r = s[0].T, r[0].T
                else: s, r = s[0], r[0]
                acc.setdefault("box", []).append(cos(s[:, :4], r[:, :4]))
                acc.setdefault("cls", []).append(cos(s[:, 4:], r[:, 4:]))
                sb, rb = s[:, 4:].max(1), r[:, 4:].max(1)
                hit = rb >= 0.3
                if hit.any():
                    acc.setdefault("n_ref>=.3", []).append(int(hit.sum()))
                    acc.setdefault("recall@.3", []).append(float((sb[hit] >= 0.3).mean()))
                    acc.setdefault("mean|dscore|", []).append(float(np.abs(sb[hit] - rb[hit]).mean()))
                acc.setdefault("n_sim>=.3", []).append(int((sb >= 0.3).sum()))
            elif kind == "e2e":
                rr = r.reshape(-1, r.shape[-1]); ss_ = s.reshape(-1, s.shape[-1])
                acc.setdefault("n_ref>=.3", []).append(int((rr[:, 4] >= 0.3).sum()))
                acc.setdefault("n_sim>=.3", []).append(int((ss_[:, 4] >= 0.3).sum()))
        print(f"{name} out{j} shape={d[f'sim{frames[0]}_{j}'].shape}: " +
              "  ".join(f"{k}={np.mean(v):.4f}" if isinstance(v[0], float) else f"{k}={np.mean(v):.1f}" for k, v in acc.items()))


if __name__ == "__main__":
    name, kind = sys.argv[1:3]
    path = os.path.join(os.environ.get("RKNN_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "rknn"),
                        name + ".parity.npz")
    print("scoring", path)
    d = np.load(path)
    if kind in ("yolox", "split"):
        frames = sorted({k.split("_")[0][3:] for k in d if k.startswith("sim")}, key=int)
        outs = sorted({int(k.split("_")[1]) for k in d if k.startswith("sim")})
        acc = Acc(kind)
        for i in frames:
            acc.add("all", [d[f"sim{i}_{j}"] for j in outs], [d[f"ref{i}_{j}"] for j in outs])
        report(name, acc.result())
    else:
        legacy(name, d, kind)
