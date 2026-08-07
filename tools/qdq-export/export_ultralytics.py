#!/usr/bin/env python3
"""Operator-run ONNX export for Ultralytics families (yolo26/yolov10/yolov8).

AGPL boundary (same stance as model/quantize-model.md): Ultralytics code
and weights — YOLO26 included, per its Hugging Face model card — are
AGPL-3.0/Enterprise. Nothing in this repository fetches, installs, or
redistributes them; this script is cairn's own code and it drives an
`ultralytics` package the OPERATOR installed (README: export-venv). The
exported .onnx and quantized artifacts stay out of git and out of
container images.

The one flag that matters for HTP: `end2end=False`. yolov10/YOLO26
exports default to the NMS-free selection tail (TopK/Gather ->
[1, 300, 6]); that tail SEGFAULTS QNN 2.4.0 at first inference once
quantized (phase-0 spike; Ultralytics' own NPU exporters strip it for
the same reason). Without it the export emits the raw one-to-one head
[1, 4+nc, A] — byte-for-byte the yolov8 RawClasses contract, so the
plugin decodes it under the `yolov8` profile with its host-side NMS
(harmless on a one-to-one head: duplicates are already rare by
training). yolov8 itself has no tail; the flag is accepted and inert.

Usage:
  export_ultralytics.py yolo26n [--imgsz 640] [--out DIR]
  export_ultralytics.py yolo26s yolov8n          # several at once
"""
import argparse
import os
import shutil


def export(name, imgsz, out_dir):
    from ultralytics import YOLO

    # Weights download relative to the CWD; pin it here so the .pt always
    # lands next to this script, where this directory's .gitignore covers
    # it — run from the repo root it would otherwise land unignored.
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    model = YOLO(f"{name}.pt")
    path = model.export(format="onnx", imgsz=imgsz, end2end=False, opset=13)
    dest = os.path.join(out_dir, f"{name}.onnx")
    if os.path.abspath(path) != os.path.abspath(dest):
        shutil.move(path, dest)
    print(f"{name}: {dest}")
    return dest


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("models", nargs="+", help="e.g. yolo26n yolo26s yolov8n")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument(
        "--out",
        default=os.path.normpath(
            os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "..", "..", "plugins", "cairn-detect",
            )
        ),
        help="Destination dir (default: the plugin root, where --model and "
        ".gitignore expect artifacts)",
    )
    args = ap.parse_args()
    for name in args.models:
        export(name, args.imgsz, args.out)


if __name__ == "__main__":
    main()
