#!/usr/bin/env python3
"""What is actually in a calibration set.

Under true MinMax an artifact inherits its calibration set's *spread*,
which makes "196 frames" a description of nothing. The set that produced
the fleet's broken artifacts was one camera, one 110-minute night window,
the main stream rather than the detect substream, and 13% person frames —
none of which anyone had to lie about, because nobody had a way to look.

Run this before quantizing and paste the output next to the artifacts.

  calib_census.py <calib-dir> [--model fp32.onnx] [--limit N]

Without `--model` it reports provenance and geometry only, which needs no
inference and takes a second. With one it adds class presence, which is
the number that matters: the class the deployment exists to detect
deciding the dynamic range it is quantized against.
"""
import argparse
import collections
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

from PIL import Image
from quantize_model import describe, load_image_chw, preprocessing


def source_stem(path):
    """capture_frames.sh names frames `<clip-stem>_NN.png`; strip the
    index to recover which clip a frame came from."""
    stem = os.path.basename(path).rsplit(".", 1)[0]
    head, _, tail = stem.rpartition("_")
    return head if head and tail.isdigit() else stem


def census(calib_dir, model=None, limit=None, score_floor=0.5, out=sys.stdout):
    paths = sorted(glob.glob(os.path.join(calib_dir, "*.png")))
    if not paths:
        raise SystemExit(f"no PNG frames in {calib_dir}")
    print(f"{calib_dir}: {len(paths)} frames", file=out)

    sources = collections.Counter(source_stem(p) for p in paths)
    geometry = collections.Counter()
    for p in paths:
        with Image.open(p) as im:
            geometry[im.size] += 1
    print(f"  {len(sources)} source clips", file=out)
    print(
        "  geometry: "
        + ", ".join(f"{w}x{h} x{n}" for (w, h), n in geometry.most_common()),
        file=out,
    )

    if not model:
        return
    import onnxruntime as ort

    info = describe(model)
    profile = preprocessing(info["layout"])
    sess = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    sample = paths if not limit else paths[:: max(1, len(paths) // limit)][:limit]

    labels = _labels(model)
    present = collections.Counter()
    person_scores = []
    for p in sample:
        tensor = load_image_chw(
            p,
            info["width"],
            info["height"],
            profile["encoding"],
            profile["resize"],
            profile["pad"],
        )
        a = sess.run(None, {name: tensor})[0][0]
        if info["layout"] == "yolox":
            cls = a[:, 5:] * a[:, 4:5]
        else:
            cls = a[4:, :].T
        best = cls.max(axis=0)
        person_scores.append(float(best[0]))
        for idx in np.nonzero(best >= score_floor)[0]:
            present[labels[idx] if idx < len(labels) else str(idx)] += 1

    n = len(sample)
    print(f"  class presence over {n} frames (fp32 {os.path.basename(model)}, "
          f"score >= {score_floor}):", file=out)
    for label, count in present.most_common(10):
        print(f"    {label:<16} {count:>4} frames ({100 * count / n:.0f}%)", file=out)
    ps = np.array(person_scores)
    print(
        f"  person best-score per frame: p50={np.median(ps):.3f} "
        f"p90={np.percentile(ps, 90):.3f} max={ps.max():.3f}; "
        f"{int((ps >= score_floor).sum())}/{n} frames "
        f"({100 * (ps >= score_floor).mean():.0f}%) carry a confident person",
        file=out,
    )


def _labels(model):
    for candidate in (
        os.path.join(os.path.dirname(os.path.abspath(model)), "coco.names"),
        os.path.join(REPO_MODEL_DIR, "..", "coco.names"),
    ):
        if os.path.exists(candidate):
            with open(candidate) as fh:
                return [line.strip() for line in fh if line.strip()]
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("calib_dir")
    ap.add_argument("--model", help="FP32 .onnx for the class-presence pass")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--score-floor", type=float, default=0.5)
    args = ap.parse_args()
    census(args.calib_dir, args.model, args.limit, args.score_floor)


if __name__ == "__main__":
    main()
