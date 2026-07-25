#!/usr/bin/env python3
"""
Static INT8 quantization of the yolov10n ONNX export for cairn-nvr.

Produces yolov10n-int8.onnx from yolov10n.onnx using onnxruntime's
quantize_static (QDQ format) with a calibration data reader built from
real camera frames extracted from fixture clips.

Preprocessing MUST match the inference plugin exactly:
  - plain resize to 640x640 (no letterbox / no aspect-ratio padding)
  - RGB channel order
  - float32, scaled to [0, 1] by dividing by 255
  - CHW layout, batch dim of 1

Usage:
    yolo-export-venv/bin/python3 quantize_yolov10n.py \
        --model yolo-export-venv/yolov10n.onnx \
        --calib-dir calib_frames \
        --out yolov10n-int8.onnx

Requires: onnx, onnxruntime (with onnxruntime.quantization), numpy, Pillow.
All already installed in yolo-export-venv.
"""
import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image

from onnxruntime.quantization import (
    CalibrationDataReader,
    QuantFormat,
    QuantType,
    quantize_static,
)
from onnxruntime.quantization.shape_inference import quant_pre_process


def load_image_chw(path: str) -> np.ndarray:
    """Load a pre-resized 640x640 PNG and convert to the model's input layout.

    The calibration/held-out PNGs were already produced at exactly 640x640 via
    a plain ffmpeg `scale=640:640` (no letterboxing), matching the plugin's
    preprocessing. This function only handles the RGB -> CHW -> f32/255 step.
    """
    im = Image.open(path).convert("RGB")
    if im.size != (640, 640):
        # Defensive: force a plain (non-letterboxed) resize if a caller passes
        # a differently-sized image. Calibration/held-out sets should already
        # be 640x640 from extraction, so this path should not normally trigger.
        im = im.resize((640, 640), Image.BILINEAR)  # matches plugin's SWS_BILINEAR
    arr = np.asarray(im, dtype=np.float32) / 255.0  # HWC, RGB, [0,1]
    arr = arr.transpose(2, 0, 1)  # CHW
    arr = np.expand_dims(arr, 0)  # NCHW
    return np.ascontiguousarray(arr, dtype=np.float32)


class FolderCalibrationDataReader(CalibrationDataReader):
    """Feeds every image in a folder to the model once, in filename order."""

    def __init__(self, calib_dir: str, input_name: str):
        self.input_name = input_name
        self.paths = sorted(glob.glob(os.path.join(calib_dir, "*.png")))
        if not self.paths:
            raise RuntimeError(f"No calibration PNGs found in {calib_dir}")
        self._iter = iter(self.paths)

    def get_next(self):
        path = next(self._iter, None)
        if path is None:
            return None
        return {self.input_name: load_image_chw(path)}


def get_input_name(model_path: str) -> str:
    import onnx

    m = onnx.load(model_path)
    return m.graph.input[0].name


def main():
    ap = argparse.ArgumentParser()
    # Model artifacts live in the plugin root (one level up) — that is where
    # the plugin's --model flag and .gitignore expect them.
    ap.add_argument("--model", default="../yolov10n.onnx")
    ap.add_argument("--calib-dir", default="calib_frames")
    ap.add_argument("--out", default="../yolov10n-int8.onnx")
    ap.add_argument(
        "--preprocessed",
        default="yolov10n-preproc.onnx",
        help="Intermediate shape-inferred model (quant_pre_process output).",
    )
    ap.add_argument(
        "--per-channel",
        action="store_true",
        default=True,
        help="Use per-channel weight quantization (recommended for CNNs).",
    )
    ap.add_argument(
        "--no-per-channel",
        dest="per_channel",
        action="store_false",
    )
    args = ap.parse_args()

    print(f"[1/3] quant_pre_process (shape inference + node simplification): "
          f"{args.model} -> {args.preprocessed}")
    try:
        quant_pre_process(
            input_model=args.model,
            output_model_path=args.preprocessed,
            skip_optimization=False,
        )
    except Exception as e:
        # yolov10's NMS-free postprocessing tail (TopK feeding GatherElements
        # on a dim whose rank the symbolic shape inferencer cannot resolve)
        # crashes onnxruntime's SymbolicShapeInference with a bare
        # `TypeError: object of type 'NoneType' has no len()` inside
        # _infer_TopK. This is a known op-coverage gap, not a bug in this
        # model. Fall back to skipping symbolic shape inference and rely on
        # plain ONNX shape inference + the optimizer only -- sufficient for
        # quantize_static's own shape lookups on the Conv/MatMul backbone.
        print(f"      quant_pre_process with symbolic shape inference failed "
              f"({e!r}); retrying with skip_symbolic_shape=True", file=sys.stderr)
        quant_pre_process(
            input_model=args.model,
            output_model_path=args.preprocessed,
            skip_optimization=False,
            skip_symbolic_shape=True,
        )

    input_name = get_input_name(args.preprocessed)
    print(f"      model input tensor name: {input_name!r}")

    print(f"[2/3] building calibration reader from {args.calib_dir} "
          f"({len(glob.glob(os.path.join(args.calib_dir, '*.png')))} frames)")
    reader = FolderCalibrationDataReader(args.calib_dir, input_name)

    print(f"[3/3] quantize_static -> {args.out} "
          f"(QDQ, per_channel={args.per_channel}, ops=Conv+MatMul only)")
    quantize_static(
        model_input=args.preprocessed,
        model_output=args.out,
        calibration_data_reader=reader,
        quant_format=QuantFormat.QDQ,
        per_channel=args.per_channel,
        weight_type=QuantType.QInt8,
        activation_type=QuantType.QUInt8,
        # Restrict quantization to the compute-heavy conv/matmul backbone.
        # The NMS-free postprocessing tail of yolov10 (Split / TopK /
        # GatherElements / Mod / Cast that produce the [1,300,6] output rows)
        # operates on indices and already-decoded box/score values; quantizing
        # those ops is unnecessary and risks numerical/op-support issues, so
        # they are left in FP32 and only wrapped by DQ nodes feeding from the
        # quantized backbone.
        op_types_to_quantize=["Conv", "MatMul"],
        # The three per-scale classification-head convs feed directly into
        # the Sigmoid that produces detection scores (see
        # /model.23/one2one_cv3.{0,1,2}.2/Conv -> Reshape_{3,4,5} -> Concat_1
        # -> Sigmoid). With only 200 mostly-static surveillance calibration
        # frames, MinMax activation calibration on these tensors
        # underestimates the true dynamic range (high-confidence detections
        # are rare in the calibration set), so quantizing them clips high
        # logits and collapses every confident detection's score to
        # sigmoid(0)==0.5 post-quantization -- verified empirically by
        # comparing raw pre-threshold scores between FP32 and a first-pass
        # INT8 build. Excluding just these 3 nodes (leaving them FP32) fixes
        # the collapse while still quantizing 80/83 Conv nodes in the
        # backbone/neck.
        nodes_to_exclude=[
            "/model.23/one2one_cv3.0/one2one_cv3.0.2/Conv",
            "/model.23/one2one_cv3.1/one2one_cv3.1.2/Conv",
            "/model.23/one2one_cv3.2/one2one_cv3.2.2/Conv",
        ],
        extra_options={
            "CalibMovingAverage": True,
        },
    )
    print("Done.")


if __name__ == "__main__":
    main()
