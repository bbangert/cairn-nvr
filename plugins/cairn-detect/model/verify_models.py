#!/usr/bin/env python3
"""
Verify an INT8-quantized cairn-detect model against its FP32 original:
  - input/output name + shape parity
  - detection agreement on held-out frames (not used for calibration)
  - single-frame CPU latency and file size for both models

Model-agnostic across the single-tensor families: geometry and layout are
read off the model by `quantize_model.describe`, the preprocessing (encoding
*and* resize policy) comes from `quantize_model.preprocessing`, and the decode
mirrors src/infer.rs for the three single-tensor layouts (yolox, yolov10
end-to-end, yolov8 raw head). Frames go through the same `load_image_chw` the
calibration uses, so a letterboxing family is verified letterboxed. The
two-tensor RF-DETR layout is not covered here -- quantizing it has not been
evaluated, and the plugin's own end-to-end harness in verify/ is what
exercises that path. Defaults target yolox_nano.onnx, which is Apache-2.0
like this project.

Usage:
    python3 -m venv quant-venv && . quant-venv/bin/activate
    pip install onnx onnxruntime pillow numpy sympy

    python3 verify_models.py \
        --fp32 ../yolox_nano.onnx --int8 ../yolox_nano-int8.onnx
"""
import argparse
import glob
import os
import time

import numpy as np
import onnx
import onnxruntime as ort

from quantize_model import (
    YOLOX_STRIDES,
    describe,
    load_image_chw,
    preprocessing,
)

SP = os.path.dirname(os.path.abspath(__file__))
# Defaults follow the repo layout: model artifacts live in the plugin root
# (one level up, where the plugin's --model flag and .gitignore expect them);
# held-out frames are produced by the extraction steps in quantize-model.md.
FP32_PATH = os.path.join(SP, "..", "yolox_nano.onnx")
INT8_PATH = os.path.join(SP, "..", "yolox_nano-int8.onnx")
HELDOUT_DIR = os.path.join(SP, "heldout_frames")

# Same IoU the plugin's NMS uses (NMS_IOU in src/infer.rs).
NMS_IOU = 0.45

# COCO-80 class names, which every model documented here is trained on.
COCO = [
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
    "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
    "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
    "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
    "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
    "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
    "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair",
    "couch","potted plant","bed","dining table","toilet","tv","laptop","mouse",
    "remote","keyboard","cell phone","microwave","oven","toaster","sink",
    "refrigerator","book","clock","vase","scissors","teddy bear","hair drier",
    "toothbrush",
]


def label(class_id: int) -> str:
    return COCO[class_id] if 0 <= class_id < len(COCO) else str(class_id)


def iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - inter
    if union <= 0:
        return 0.0
    return inter / union


def nms(dets):
    """Class-aware greedy NMS, matching the plugin: only a stronger box of the
    *same* class suppresses one. `dets` must be sorted by descending score."""
    kept = []
    for cls, score, box in dets:
        if any(k[0] == cls and iou(k[2], box) >= NMS_IOU for k in kept):
            continue
        kept.append((cls, score, box))
    return kept


def yolox_grid(width: int, height: int):
    """(gx, gy, stride) per anchor, in the order the model concatenates them:
    all of stride 8's cells row-major, then 16, then 32."""
    cells = []
    for stride in YOLOX_STRIDES:
        cols, rows = width // stride, height // stride
        for gy in range(rows):
            for gx in range(cols):
                cells.append((gx, gy, stride))
    return np.array(cells, dtype=np.float32)


def decode_detections(out: np.ndarray, layout: str, width: int, height: int,
                      score_thresh: float = 0.5):
    """-> [(class_id, score, (x1, y1, x2, y2))] in input pixels, score-sorted.

    Mirrors decode_output/postprocess* in src/infer.rs.
    """
    if layout == "yolov10":
        # [1, 300, 6] rows of [x1, y1, x2, y2, score, class_id], already NMS'd
        rows = out[0]
        dets = [
            (int(round(float(r[5]))), float(r[4]),
             (float(r[0]), float(r[1]), float(r[2]), float(r[3])))
            for r in rows if float(r[4]) >= score_thresh
        ]
        dets.sort(key=lambda d: -d[1])
        return dets

    if layout == "yolov8":
        # [1, 4 + nc, A] channels-first, cx/cy/w/h in pixels, no objectness
        chan = out[0]
        boxes = chan[:4].T
        scores = chan[4:].T
    elif layout == "yolox":
        # [1, A, 5 + nc] anchor-major, grid-relative boxes, objectness column
        rows = out[0]
        grid = yolox_grid(width, height)
        gx, gy, stride = grid[:, 0], grid[:, 1], grid[:, 2]
        cx = (rows[:, 0] + gx) * stride
        cy = (rows[:, 1] + gy) * stride
        w = np.exp(rows[:, 2]) * stride
        h = np.exp(rows[:, 3]) * stride
        boxes = np.stack([cx, cy, w, h], axis=1)
        # the whole difference from yolov8: objectness folds into every class
        scores = rows[:, 5:] * rows[:, 4:5]
    else:
        raise SystemExit(f"cannot decode an unrecognized layout ({layout!r})")

    classes = scores.argmax(axis=1)
    best = scores[np.arange(scores.shape[0]), classes]
    keep = best >= score_thresh
    dets = []
    for cls, score, (bcx, bcy, bw, bh) in zip(
        classes[keep], best[keep], boxes[keep]
    ):
        dets.append((
            int(cls), float(score),
            (float(bcx - bw / 2), float(bcy - bh / 2),
             float(bcx + bw / 2), float(bcy + bh / 2)),
        ))
    dets.sort(key=lambda d: -d[1])
    return nms(dets)


def check_io_parity(fp32_path: str, int8_path: str):
    def io_sig(m):
        def shp(t):
            return [d.dim_value if d.dim_value else d.dim_param
                    for d in t.type.tensor_type.shape.dim]
        return (
            [(i.name, shp(i)) for i in m.graph.input],
            [(o.name, shp(o)) for o in m.graph.output],
        )

    fp32_sig = io_sig(onnx.load(fp32_path))
    int8_sig = io_sig(onnx.load(int8_path))
    print("FP32 IO:", fp32_sig)
    print("INT8 IO:", int8_sig)
    assert fp32_sig == int8_sig, "Input/output name+shape MISMATCH between FP32 and INT8!"
    print("OK: input/output names and shapes are identical.\n")


def make_session(path: str) -> ort.InferenceSession:
    so = ort.SessionOptions()  # onnxruntime defaults
    return ort.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])


def run(sess: ort.InferenceSession, x: np.ndarray):
    input_name = sess.get_inputs()[0].name
    output_name = sess.get_outputs()[0].name
    return sess.run([output_name], {input_name: x})[0]


def greedy_match(dets_a, dets_b, iou_thresh=0.5):
    """Greedy match dets_a (FP32) to dets_b (INT8) by same class + IoU>thresh,
    preferring highest IoU first. Returns list of (i,j,iou) matches, plus
    unmatched indices for each side."""
    candidates = []
    for i, (ca, _sa, ba) in enumerate(dets_a):
        for j, (cb, _sb, bb) in enumerate(dets_b):
            if ca != cb:
                continue
            v = iou(ba, bb)
            if v > iou_thresh:
                candidates.append((v, i, j))
    candidates.sort(reverse=True)
    used_a, used_b = set(), set()
    matches = []
    for v, i, j in candidates:
        if i in used_a or j in used_b:
            continue
        used_a.add(i)
        used_b.add(j)
        matches.append((i, j, v))
    unmatched_a = [i for i in range(len(dets_a)) if i not in used_a]
    unmatched_b = [j for j in range(len(dets_b)) if j not in used_b]
    return matches, unmatched_a, unmatched_b


def bench_latency(sess: ort.InferenceSession, x: np.ndarray, warmup=3, runs=20):
    input_name = sess.get_inputs()[0].name
    output_name = sess.get_outputs()[0].name
    for _ in range(warmup):
        sess.run([output_name], {input_name: x})
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        sess.run([output_name], {input_name: x})
        times.append(time.perf_counter() - t0)
    times = np.array(times)
    return times.mean(), times.std(), times.min(), times.max()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fp32", default=FP32_PATH)
    ap.add_argument("--int8", default=INT8_PATH)
    ap.add_argument("--frames-dir", default=HELDOUT_DIR,
                    help="dir of held-out PNGs; any size, they go through the "
                         "profile's own resize (see quantize-model.md)")
    ap.add_argument("--input-encoding", choices=("raw-bgr", "unit-rgb"), default=None,
                    help="override the channel order/scale inferred from the "
                         "layout; the resize policy still follows the profile")
    ap.add_argument("--score-thresh", type=float, default=0.5)
    args = ap.parse_args()

    for path in (args.fp32, args.int8):
        if not os.path.isfile(path):
            raise SystemExit(
                f"model not found: {path} — fetch/quantize first (quantize-model.md)")
    if not os.path.isdir(args.frames_dir):
        raise SystemExit(
            f"frames dir not found: {args.frames_dir} — extract held-out frames "
            "per quantize-model.md, or pass --frames-dir")

    info = describe(args.fp32)
    width, height, layout = info["width"], info["height"], info["layout"]
    if not width or not height:
        raise SystemExit(f"{args.fp32} leaves its spatial dims dynamic")
    profile = preprocessing(layout, args.input_encoding)
    resize = profile["resize"]
    if resize == "letterbox":
        resize += f" (pad {profile['pad']})"
    print(f"=== 0. Model ===\n{width}x{height}, output {info['output_dims']}, "
          f"layout {layout or 'unrecognized'}, feeding {profile['encoding']} "
          f"/ {resize}\n")

    print("=== 1. I/O parity check ===")
    check_io_parity(args.fp32, args.int8)

    print("=== 2. Loading sessions (onnxruntime defaults) ===")
    sess_fp32 = make_session(args.fp32)
    sess_int8 = make_session(args.int8)

    print("=== 3. File sizes ===")
    fp32_size = os.path.getsize(args.fp32)
    int8_size = os.path.getsize(args.int8)
    print(f"FP32: {fp32_size/1e6:.2f} MB")
    print(f"INT8: {int8_size/1e6:.2f} MB")
    print(f"Reduction: {(1 - int8_size/fp32_size)*100:.1f}%\n")

    print(f"=== 4. Held-out frame detections (score >= {args.score_thresh}) ===")
    paths = sorted(glob.glob(os.path.join(args.frames_dir, "*.png")))
    if not paths:
        raise SystemExit(f"no .png frames in {args.frames_dir}")
    print(f"({len(paths)} frames from {args.frames_dir})")

    total_matches = 0
    total_fp32_dets = 0
    total_int8_dets = 0
    all_score_deltas = []

    for p in paths:
        x = load_image_chw(p, width, height, profile["encoding"],
                           profile["resize"], profile["pad"])
        dets_fp32 = decode_detections(
            run(sess_fp32, x), layout, width, height, args.score_thresh)
        dets_int8 = decode_detections(
            run(sess_int8, x), layout, width, height, args.score_thresh)
        matches, unmatched_a, unmatched_b = greedy_match(dets_fp32, dets_int8, 0.5)

        total_matches += len(matches)
        total_fp32_dets += len(dets_fp32)
        total_int8_dets += len(dets_int8)

        print(f"\n--- {os.path.basename(p)} ---")
        print(f"  FP32 ({len(dets_fp32)}): " + (", ".join(
            f"{label(c)}:{s:.3f}" for c, s, _ in dets_fp32) or "(none)"))
        print(f"  INT8 ({len(dets_int8)}): " + (", ".join(
            f"{label(c)}:{s:.3f}" for c, s, _ in dets_int8) or "(none)"))
        print(f"  matched={len(matches)} unmatched_fp32={len(unmatched_a)} "
              f"unmatched_int8={len(unmatched_b)}")
        for i, j, v in matches:
            sa = dets_fp32[i][1]
            sb = dets_int8[j][1]
            all_score_deltas.append(abs(sa - sb))
            print(f"    match class={label(dets_fp32[i][0])} iou={v:.3f} "
                  f"score_fp32={sa:.3f} score_int8={sb:.3f} delta={abs(sa-sb):.4f}")

    print("\n=== 5. Agreement summary ===")
    denom = max(total_fp32_dets, total_int8_dets, 1)
    print(f"Total FP32 detections (score>={args.score_thresh}): {total_fp32_dets}")
    print(f"Total INT8 detections (score>={args.score_thresh}): {total_int8_dets}")
    print(f"Matched detections (same class, IoU>0.5): {total_matches}")
    print(f"Match rate (matches / max(fp32,int8) dets): {total_matches/denom*100:.1f}%")
    if all_score_deltas:
        d = np.array(all_score_deltas)
        print(f"Mean absolute score delta on matches: {d.mean():.4f}")
        print(f"Max absolute score delta on matches: {d.max():.4f}")
    else:
        print("No matched detections to compute score delta.")

    print("\n=== 6. Latency (CPU, onnxruntime defaults, 3 warmup + 20 runs) ===")
    x = load_image_chw(paths[0], width, height, profile["encoding"],
                       profile["resize"], profile["pad"])
    mean_f, std_f, min_f, max_f = bench_latency(sess_fp32, x)
    mean_i, std_i, min_i, max_i = bench_latency(sess_int8, x)
    print(f"FP32: mean={mean_f*1000:.2f}ms std={std_f*1000:.2f}ms "
          f"min={min_f*1000:.2f}ms max={max_f*1000:.2f}ms")
    print(f"INT8: mean={mean_i*1000:.2f}ms std={std_i*1000:.2f}ms "
          f"min={min_i*1000:.2f}ms max={max_i*1000:.2f}ms")
    print(f"Speedup (fp32_mean/int8_mean): {mean_f/mean_i:.2f}x")


if __name__ == "__main__":
    main()
