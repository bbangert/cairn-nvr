#!/usr/bin/env python3
"""
Verify the INT8-quantized yolov10n ONNX model against the FP32 original:
  - input/output name + shape parity
  - detection agreement on held-out frames (not used for calibration)
  - single-frame CPU latency and file size for both models

Usage:
    yolo-export-venv/bin/python3 verify_models.py
"""
import glob
import os
import time

import numpy as np
import onnx
import onnxruntime as ort
from PIL import Image

SP = os.path.dirname(os.path.abspath(__file__))
FP32_PATH = os.path.join(SP, "yolo-export-venv", "yolov10n.onnx")
INT8_PATH = os.path.join(SP, "yolov10n-int8.onnx")
HELDOUT_DIR = os.path.join(SP, "heldout10")

# COCO class names (yolov10n is trained on COCO-80)
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


def load_image_chw(path: str) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    assert im.size == (640, 640), f"expected 640x640, got {im.size} for {path}"
    arr = np.asarray(im, dtype=np.float32) / 255.0
    arr = arr.transpose(2, 0, 1)
    return np.ascontiguousarray(np.expand_dims(arr, 0), dtype=np.float32)


def check_io_parity():
    m_fp32 = onnx.load(FP32_PATH)
    m_int8 = onnx.load(INT8_PATH)

    def io_sig(m):
        def shp(t):
            return [d.dim_value if d.dim_value else d.dim_param
                    for d in t.type.tensor_type.shape.dim]
        return (
            [(i.name, shp(i)) for i in m.graph.input],
            [(o.name, shp(o)) for o in m.graph.output],
        )

    fp32_sig = io_sig(m_fp32)
    int8_sig = io_sig(m_int8)
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
    out = sess.run([output_name], {input_name: x})[0]
    return out  # [1, 300, 6]


def decode_detections(out: np.ndarray, score_thresh: float = 0.5):
    """out: [1,300,6] rows = [x1,y1,x2,y2,score,class_id], sorted by score desc.
    Returns list of (class_id:int, score:float, box:(x1,y1,x2,y2)) with score>=thresh.
    """
    rows = out[0]
    dets = []
    for r in rows:
        x1, y1, x2, y2, score, cls = r
        if score >= score_thresh:
            dets.append((int(round(cls)), float(score), (float(x1), float(y1), float(x2), float(y2))))
    return dets


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


def greedy_match(dets_a, dets_b, iou_thresh=0.5):
    """Greedy match dets_a (FP32) to dets_b (INT8) by same class + IoU>thresh,
    preferring highest IoU first. Returns list of (i,j,iou) matches, plus
    unmatched indices for each side."""
    candidates = []
    for i, (ca, sa, ba) in enumerate(dets_a):
        for j, (cb, sb, bb) in enumerate(dets_b):
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
    print("=== 1. I/O parity check ===")
    check_io_parity()

    print("=== 2. Loading sessions (onnxruntime defaults) ===")
    sess_fp32 = make_session(FP32_PATH)
    sess_int8 = make_session(INT8_PATH)

    print("=== 3. File sizes ===")
    fp32_size = os.path.getsize(FP32_PATH)
    int8_size = os.path.getsize(INT8_PATH)
    print(f"FP32: {fp32_size/1e6:.2f} MB")
    print(f"INT8: {int8_size/1e6:.2f} MB")
    print(f"Reduction: {(1 - int8_size/fp32_size)*100:.1f}%\n")

    print("=== 4. Held-out frame detections (score >= 0.5) ===")
    paths = sorted(glob.glob(os.path.join(HELDOUT_DIR, "*.png")))
    assert len(paths) == 10, f"expected 10 held-out frames, found {len(paths)}"

    total_matches = 0
    total_fp32_dets = 0
    total_int8_dets = 0
    all_score_deltas = []

    for p in paths:
        x = load_image_chw(p)
        out_fp32 = run(sess_fp32, x)
        out_int8 = run(sess_int8, x)
        dets_fp32 = decode_detections(out_fp32, 0.5)
        dets_int8 = decode_detections(out_int8, 0.5)
        matches, unmatched_a, unmatched_b = greedy_match(dets_fp32, dets_int8, 0.5)

        total_matches += len(matches)
        total_fp32_dets += len(dets_fp32)
        total_int8_dets += len(dets_int8)

        fname = os.path.basename(p)
        print(f"\n--- {fname} ---")
        print(f"  FP32 ({len(dets_fp32)}): " + ", ".join(
            f"{COCO[c] if 0<=c<80 else c}:{s:.3f}" for c, s, _ in dets_fp32) or "  FP32: (none)")
        print(f"  INT8 ({len(dets_int8)}): " + ", ".join(
            f"{COCO[c] if 0<=c<80 else c}:{s:.3f}" for c, s, _ in dets_int8) or "  INT8: (none)")
        print(f"  matched={len(matches)} unmatched_fp32={len(unmatched_a)} unmatched_int8={len(unmatched_b)}")
        for i, j, v in matches:
            sa = dets_fp32[i][1]
            sb = dets_int8[j][1]
            all_score_deltas.append(abs(sa - sb))
            print(f"    match class={COCO[dets_fp32[i][0]]} iou={v:.3f} "
                  f"score_fp32={sa:.3f} score_int8={sb:.3f} delta={abs(sa-sb):.4f}")

    print("\n=== 5. Agreement summary ===")
    denom = max(total_fp32_dets, total_int8_dets, 1)
    match_rate = total_matches / denom
    print(f"Total FP32 detections (score>=0.5): {total_fp32_dets}")
    print(f"Total INT8 detections (score>=0.5): {total_int8_dets}")
    print(f"Matched detections (same class, IoU>0.5): {total_matches}")
    print(f"Match rate (matches / max(fp32,int8) dets): {match_rate*100:.1f}%")
    if all_score_deltas:
        d = np.array(all_score_deltas)
        print(f"Mean absolute score delta on matches: {d.mean():.4f}")
        print(f"Max absolute score delta on matches: {d.max():.4f}")
    else:
        print("No matched detections to compute score delta.")

    print("\n=== 6. Latency (CPU, onnxruntime defaults, 3 warmup + 20 runs) ===")
    x = load_image_chw(paths[0])
    mean_f, std_f, min_f, max_f = bench_latency(sess_fp32, x)
    mean_i, std_i, min_i, max_i = bench_latency(sess_int8, x)
    print(f"FP32: mean={mean_f*1000:.2f}ms std={std_f*1000:.2f}ms "
          f"min={min_f*1000:.2f}ms max={max_f*1000:.2f}ms")
    print(f"INT8: mean={mean_i*1000:.2f}ms std={std_i*1000:.2f}ms "
          f"min={min_i*1000:.2f}ms max={max_i*1000:.2f}ms")
    print(f"Speedup (fp32_mean/int8_mean): {mean_f/mean_i:.2f}x")


if __name__ == "__main__":
    main()
