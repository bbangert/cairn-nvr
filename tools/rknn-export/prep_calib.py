#!/usr/bin/env python3
"""Build INT8 calibration .npy sets (NCHW uint8; toolkit rejects NHWC .npy).

Policies mirror plugins/cairn-detect catalog.rs: yolox = BGR letterbox
(pad 114, content at the origin, pad right/bottom); yolov8/yolo26 = RGB
stretch; rfdetr = RGB stretch. Stored as .npy so channel order is explicit
rather than depending on how rknn reads image files.
Also writes set.json (per-frame source geometry, and an id over the npy bytes
that manifests record as the calibration/parity set id).
usage: prep_calib.py FRAMES_DIR OUT_DIR SIZE {letterbox|stretch} {rgb|bgr}
"""
import glob, hashlib, json, os, sys
import cv2, numpy as np

frames, out, size, policy, order = sys.argv[1:6]
size = int(size)
paths = sorted(glob.glob(os.path.join(frames, "*.jpg")) + glob.glob(os.path.join(frames, "*.png")))
if not paths: sys.exit(f"no .jpg/.png frames in {frames}")
os.makedirs(out, exist_ok=True)
lines, meta, digest = [], [], hashlib.sha256()
for i, p in enumerate(paths):
    im = cv2.imread(p)  # BGR
    h, w = im.shape[:2]
    if policy == "letterbox":
        r = min(size / w, size / h)
        nw, nh = round(w * r), round(h * r)
        canvas = np.full((size, size, 3), 114, np.uint8)
        canvas[:nh, :nw] = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
    else:
        canvas = cv2.resize(im, (size, size), interpolation=cv2.INTER_LINEAR)
    if order == "rgb":
        canvas = canvas[:, :, ::-1]
    f = os.path.join(out, f"{i:03d}.npy")
    np.save(f, np.ascontiguousarray(canvas.transpose(2, 0, 1)[None]))  # NCHW: what the toolkit demands of .npy
    lines.append(os.path.abspath(f))
    meta.append({"npy": os.path.basename(f), "src": os.path.basename(p), "w": w, "h": h})
    digest.update(f"{hashlib.sha256(open(f, 'rb').read()).hexdigest()}  {os.path.basename(f)}\n".encode())
open(os.path.join(out, "dataset.txt"), "w").write("\n".join(lines) + "\n")
json.dump({"source": os.path.abspath(frames), "policy": policy, "order": order, "size": size, "n": len(lines),
           "id": digest.hexdigest()[:16], "frames": meta}, open(os.path.join(out, "set.json"), "w"), indent=1)
print(len(lines), "frames ->", out)
