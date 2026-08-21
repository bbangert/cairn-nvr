#!/usr/bin/env python3
"""FP32-vs-QDQ score-distribution parity on the CPU EP.

The accuracy oracle the pipeline never had. `verify_artifact.sh` asks
"does this artifact detect the same things" and reads a label histogram,
which cannot see a score ceiling: the labels are all still there, just
capped. A quantized head clipped to 0.093 at stride 32 passes a label
histogram and detects nothing on a board running a 0.6 floor.

So compare the numbers instead. Both models run over the same frames on
the CPU EP, and the comparison is per FPN level, because that is where
the defect lives — a mean-of-extremes calibration hit the coarsest level
hardest every time, and a whole-tensor maximum hides it behind the finest
level's healthier scores.

Per-level maxima are a max over frames, not mAP. They answer "can this
artifact still produce a confident score at this scale", which is the
question a baked ceiling gets wrong, and they say nothing about
localization or ranking. Treat a pass as "the ceiling defect is absent",
never as "this rung is accurate".

  score_parity.py --fp32 yolox_s.onnx --qdq yolox_s-qdq-a16.onnx \
                  --frames calib/ [--tolerance 0.9] [--limit 40]
"""
import argparse
import glob
import os
import sys

import numpy as np

REPO_MODEL_DIR = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "..", "plugins", "cairn-detect", "model",
    )
)
sys.path.insert(0, REPO_MODEL_DIR)

import onnxruntime as ort
from quantize_model import YOLOX_STRIDES, describe, load_image_chw, preprocessing

# COCO dense index of "person" in both head orders this tool handles.
PERSON = 0

# The score at or above which a detection is actually reported. Both the
# per-level gate and the person window use it, for the same reason: below
# it there is no event to lose, so there is no parity to measure. It
# matches the plugin's own default floor rather than being chosen here.
REPORTABLE = 0.5


def level_bounds(width, height):
    """Anchor index ranges per FPN level, in head order (stride 8/16/32).

    Both families concatenate their levels along the anchor axis in this
    order, so one split serves the yolox `[1, A, 85]` layout and the
    yolov8/yolo26 `[1, 4+nc, A]` layout alike.
    """
    bounds, start = [], 0
    for s in YOLOX_STRIDES:
        n = (width // s) * (height // s)
        bounds.append((s, start, start + n))
        start += n
    return bounds, start


def scores(out, layout):
    """(per-anchor best score, per-anchor person score) from a raw head.

    yolox multiplies objectness by the class score — the plugin's decode
    does the same, so a comparison that skipped it would grade a tensor
    nobody consumes. yolov8/yolo26 raw heads have no objectness channel.
    """
    if layout == "yolox":
        a = out[0]                      # [A, 85]
        obj = a[:, 4]
        cls = a[:, 5:]
        return obj * cls.max(axis=1), obj * cls[:, PERSON]
    a = out[0]                          # [4 + nc, A]
    cls = a[4:, :]
    return cls.max(axis=0), cls[PERSON, :]


def run(model_path, frames, layout):
    sess = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    best, person = [], []
    for tensor in frames:
        out = sess.run(None, {name: tensor})[0]
        b, p = scores(out, layout)
        best.append(b)
        person.append(p)
    return np.stack(best), np.stack(person)


def compare(fp32_path, qdq_path, frame_dir, tolerance=0.9, limit=None, out=sys.stdout):
    info = describe(fp32_path)
    layout = info["layout"]
    if layout not in ("yolox", "yolov8"):
        raise SystemExit(f"{fp32_path}: unhandled layout {layout!r}")
    width, height = info["width"], info["height"]
    profile = preprocessing(layout)

    paths = sorted(glob.glob(os.path.join(frame_dir, "*.png")))
    if limit:
        # Stride rather than truncate: the first N files of a set built
        # clip by clip are all one clip, and a parity number measured on
        # one scene is not a parity number.
        step = max(1, len(paths) // limit)
        paths = paths[::step][:limit]
    if not paths:
        raise SystemExit(f"no PNG frames in {frame_dir}")
    tensors = [
        load_image_chw(
            p, width, height, profile["encoding"], profile["resize"], profile["pad"]
        )
        for p in paths
    ]

    f_best, f_person = run(fp32_path, tensors, layout)
    q_best, q_person = run(qdq_path, tensors, layout)

    bounds, total = level_bounds(width, height)
    if f_best.shape[1] != total:
        raise SystemExit(
            f"{fp32_path}: {f_best.shape[1]} anchors, expected {total} for "
            f"{width}x{height} — level split would be wrong"
        )

    print(f"  parity over {len(paths)} frames from {frame_dir}", file=out)
    rows, failures = [], []
    for stride, lo, hi in bounds:
        fmax = float(f_best[:, lo:hi].max())
        qmax = float(q_best[:, lo:hi].max())
        ratio = qmax / fmax if fmax > 0 else float("nan")
        rows.append((stride, fmax, qmax, ratio))
        flag = ""
        if fmax >= REPORTABLE and ratio < tolerance:
            # A level FP32 itself never drives past the reporting floor
            # carries nothing to compare: neither number would become a
            # detection, so their ratio grades noise against noise. Such
            # levels are printed and not failed. Measured, so this is not
            # a threshold picked to make things pass: every stride-32
            # ratio that wobbled to ~0.86 had an FP32 max of 0.33-0.40,
            # while the one frame where stride 32 held a real person read
            # FP32 0.836 / QDQ 0.831.
            failures.append(f"s{stride}: qdq {qmax:.4f} vs fp32 {fmax:.4f} ({ratio:.2f}x)")
            flag = "  <-- FAIL"
        print(
            f"    s{stride:<2} max score  fp32={fmax:.4f}  qdq={qmax:.4f}  "
            f"ratio={ratio:.3f}{flag}",
            file=out,
        )

    # The person leg, and the reason it is a gate and not a footnote: the
    # per-level numbers above are maxima over frames, so ONE good frame
    # carries a level. An artifact that reproduces FP32's best frame and
    # loses the subject on half the others passes every ratio above while
    # being useless on a board — measured on yolox_nano w8a8, per-level
    # ratios 0.96/0.94 with individual person frames falling 0.73 -> 0.007.
    # So compare frame by frame, on the frames where FP32 is confident.
    # That window is also what a board score floor is set against.
    fp = f_person.max(axis=1)
    qp = q_person.max(axis=1)
    window = fp >= REPORTABLE
    print(
        f"    person per-frame max: fp32 p50={np.median(fp):.4f} "
        f"max={fp.max():.4f} | qdq p50={np.median(qp):.4f} max={qp.max():.4f}",
        file=out,
    )
    if window.any():
        ratios = qp[window] / fp[window]
        median_ratio = float(np.median(ratios))
        print(
            f"    person window ({int(window.sum())} frames with "
            f"fp32>={REPORTABLE}): "
            f"fp32 {fp[window].min():.3f}-{fp[window].max():.3f} | "
            f"qdq {qp[window].min():.3f}-{qp[window].max():.3f}",
            file=out,
        )
        flag = ""
        if median_ratio < tolerance:
            failures.append(
                f"person window: median per-frame ratio {median_ratio:.2f}"
            )
            flag = "  <-- FAIL"
        print(
            f"    person window per-frame ratio: median={median_ratio:.3f} "
            f"min={float(ratios.min()):.3f} "
            f"frames below 0.5x={int((ratios < 0.5).sum())}/{int(window.sum())}"
            f"{flag}",
            file=out,
        )
    else:
        # A frame set fp32 never finds a person in cannot certify the person
        # leg, and falling through to PASS here would let an empty or
        # unsuitable set green-light an artifact. The comparison the caller
        # asked for did not happen — say so as a failure.
        failures.append("person window: fp32 never reaches 0.5 — set unsuitable for the person leg")
        print(
            "    person window: no frame reaches fp32 person >= 0.5  <-- FAIL",
            file=out,
        )

    if failures:
        print("  parity FAIL: " + "; ".join(failures), file=out)
        return False, rows
    print(
        f"  parity PASS (per-level maxima and person-window median all >= "
        f"{tolerance:.2f}x fp32)",
        file=out,
    )
    return True, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--fp32", required=True)
    ap.add_argument("--qdq", required=True)
    ap.add_argument("--frames", required=True, help="directory of PNG frames")
    ap.add_argument("--tolerance", type=float, default=0.9)
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()
    ok, _ = compare(args.fp32, args.qdq, args.frames, args.tolerance, args.limit)
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
