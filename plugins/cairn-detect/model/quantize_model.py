#!/usr/bin/env python3
"""
Static INT8 quantization of a cairn-detect ONNX model.

Model-agnostic on purpose: the geometry, the input tensor name and the
preprocessing convention are all read out of the model, the same way the
plugin reads them (see plugins/cairn-detect/src/infer.rs). Nothing here
installs or imports a model vendor's package — onnx, onnxruntime, numpy and
Pillow are the whole dependency list, all permissively licensed.

The default target is yolox_nano.onnx (Apache-2.0, Megvii). It works just as
well on a yolov10 / yolov8 export you have brought yourself; note those
weights are AGPL-3.0 and this repository does not ship or fetch them.

Preprocessing MUST match the inference plugin exactly, which means it depends
on the model family:

  - plain resize to the model's own HxW (no letterbox / no aspect padding)
  - yolox:            BGR channel order, float32 in 0..255
  - yolov10 / yolov8: RGB channel order, float32 scaled to 0..1
  - CHW layout, batch dim of 1

Usage:
    python3 -m venv quant-venv && . quant-venv/bin/activate
    pip install onnx onnxruntime pillow numpy sympy

    # list the graph's Conv nodes without quantizing anything
    python3 quantize_model.py --model ../yolox_nano.onnx --preprocess-only

    python3 quantize_model.py --model ../yolox_nano.onnx \
        --calib-dir calib_frames --out ../yolox_nano-int8.onnx
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

# The FPN strides a yolox head emits anchors for. Mirrors YOLOX_STRIDES in
# src/infer.rs; the anchor count they imply is what identifies the layout.
YOLOX_STRIDES = (8, 16, 32)


def yolox_anchors(width: int, height: int) -> int:
    return sum((width // s) * (height // s) for s in YOLOX_STRIDES)


def _dims(value_info) -> list:
    """Static dims of a graph input/output; None for a dynamic axis."""
    out = []
    for d in value_info.type.tensor_type.shape.dim:
        out.append(d.dim_value if d.HasField("dim_value") and d.dim_value > 0 else None)
    return out


def describe(model_path: str) -> dict:
    """Input name, geometry and layout, read off the model itself."""
    import onnx

    m = onnx.load(model_path)
    graph_input = m.graph.input[0]
    idims = _dims(graph_input)
    if len(idims) != 4 or idims[1] != 3:
        raise SystemExit(
            f"{model_path}: expected a [1, 3, H, W] first input, got {idims}"
        )
    height, width = idims[2], idims[3]

    odims = _dims(m.graph.output[0])
    layout = None
    if len(odims) == 3 and odims[0] == 1 and None not in odims:
        if odims[2] == 6:
            layout = "yolov10"
        elif odims[1] is not None and odims[2] > odims[1] * 4:
            layout = "yolov8"
        elif width and height and odims[1] == yolox_anchors(width, height):
            layout = "yolox"

    # Default (ai.onnx) opset. Per-channel quantization emits a
    # DequantizeLinear carrying an `axis` attribute, which only exists from
    # opset 13 — below that, onnxruntime loads the quantized model and then
    # refuses it with "Unrecognized attribute: axis for operator
    # DequantizeLinear". yolox_nano.onnx from the 0.1.1rc0 release is opset
    # 11, so this is the common case, not the exotic one.
    opset = next(
        (i.version for i in m.opset_import if i.domain in ("", "ai.onnx")), None
    )

    return {
        "input_name": graph_input.name,
        "width": width,
        "height": height,
        "opset": opset,
        "output_dims": odims,
        "layout": layout,
    }


def load_image_chw(path: str, width: int, height: int, encoding: str) -> np.ndarray:
    """A calibration PNG -> the model's exact input tensor.

    The calibration/held-out PNGs should already be at the model's size, from
    a plain ffmpeg `scale=W:H` (no letterboxing), matching the plugin. The
    resize below is only a guard for a caller that passes something else.
    """
    im = Image.open(path).convert("RGB")
    if im.size != (width, height):
        # matches the plugin's SWS_BILINEAR stretch
        im = im.resize((width, height), Image.BILINEAR)
    arr = np.asarray(im, dtype=np.float32)  # HWC, RGB, 0..255
    if encoding == "raw-bgr":
        arr = arr[:, :, ::-1]
    else:
        arr = arr / 255.0
    arr = arr.transpose(2, 0, 1)  # CHW
    arr = np.expand_dims(arr, 0)  # NCHW
    return np.ascontiguousarray(arr, dtype=np.float32)


class FolderCalibrationDataReader(CalibrationDataReader):
    """Feeds every image in a folder to the model once, in filename order."""

    def __init__(self, calib_dir, input_name, width, height, encoding):
        self.input_name = input_name
        self.width = width
        self.height = height
        self.encoding = encoding
        self.paths = sorted(glob.glob(os.path.join(calib_dir, "*.png")))
        if not self.paths:
            raise RuntimeError(f"No calibration PNGs found in {calib_dir}")
        self._iter = iter(self.paths)

    def get_next(self):
        path = next(self._iter, None)
        if path is None:
            return None
        return {
            self.input_name: load_image_chw(
                path, self.width, self.height, self.encoding
            )
        }


def conv_nodes(model_path: str) -> list:
    import onnx

    m = onnx.load(model_path)
    return [n.name for n in m.graph.node if n.op_type in ("Conv", "MatMul")]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Model artifacts live in the plugin root (one level up) — that is where
    # the plugin's --model flag and .gitignore expect them.
    ap.add_argument("--model", default="../yolox_nano.onnx")
    ap.add_argument("--calib-dir", default="calib_frames")
    ap.add_argument("--out", default="../yolox_nano-int8.onnx")
    ap.add_argument(
        "--preprocessed",
        default=None,
        help="Intermediate shape-inferred model (default: <out stem>-preproc.onnx).",
    )
    ap.add_argument(
        "--input-encoding",
        choices=("raw-bgr", "unit-rgb"),
        default=None,
        help="Override the preprocessing inferred from the detected layout.",
    )
    ap.add_argument(
        "--exclude-node",
        action="append",
        default=[],
        help="Leave this node in FP32. Repeatable. See the score-collapse note.",
    )
    ap.add_argument(
        "--exclude-suffix",
        action="append",
        default=[],
        help="Leave every node whose name ends with this in FP32. Repeatable.",
    )
    ap.add_argument(
        "--preprocess-only",
        action="store_true",
        help="Stop after shape inference and print the graph's Conv/MatMul "
        "nodes, so --exclude-node can be aimed at real names.",
    )
    ap.add_argument(
        "--per-channel",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Per-channel weight quantization (better for CNNs, needs opset "
        ">= 13). Default: on when the model's opset allows it.",
    )
    args = ap.parse_args()

    info = describe(args.model)
    width, height = info["width"], info["height"]
    if not width or not height:
        raise SystemExit(
            f"{args.model} leaves its spatial dims dynamic; this script needs a "
            f"pinned input size to build calibration tensors"
        )
    encoding = args.input_encoding or (
        "raw-bgr" if info["layout"] == "yolox" else "unit-rgb"
    )
    per_channel = args.per_channel
    if per_channel is None:
        per_channel = bool(info["opset"] and info["opset"] >= 13)
    print(
        f"      model: input {info['input_name']!r} {width}x{height}, opset "
        f"{info['opset']}, output {info['output_dims']}, layout "
        f"{info['layout'] or 'unrecognized'}, calibrating with {encoding}"
    )
    if args.per_channel is None and not per_channel:
        print(
            f"      per-channel quantization off: opset {info['opset']} predates "
            f"DequantizeLinear's `axis` attribute (opset 13), and onnxruntime "
            f"rejects the resulting model at load time"
        )
    if info["layout"] is None and args.input_encoding is None:
        print(
            "      warning: layout not recognized, defaulting to unit-rgb; pass "
            "--input-encoding if that is wrong",
            file=sys.stderr,
        )

    preprocessed = args.preprocessed or (
        os.path.splitext(os.path.basename(args.out))[0] + "-preproc.onnx"
    )

    print(
        f"[1/3] quant_pre_process (shape inference + node simplification): "
        f"{args.model} -> {preprocessed}"
    )
    try:
        quant_pre_process(
            input_model=args.model,
            output_model_path=preprocessed,
            skip_optimization=False,
        )
    except Exception as e:
        # An NMS-free postprocessing tail (yolov10's TopK feeding
        # GatherElements on a dim whose rank the symbolic shape inferencer
        # cannot resolve) crashes onnxruntime's SymbolicShapeInference with a
        # bare `TypeError: object of type 'NoneType' has no len()` inside
        # _infer_TopK. This is a known op-coverage gap, not a bug in the
        # model. Fall back to plain ONNX shape inference + the optimizer,
        # which is sufficient for quantize_static's own shape lookups on the
        # Conv/MatMul backbone.
        print(
            f"      quant_pre_process with symbolic shape inference failed "
            f"({e!r}); retrying with skip_symbolic_shape=True",
            file=sys.stderr,
        )
        quant_pre_process(
            input_model=args.model,
            output_model_path=preprocessed,
            skip_optimization=False,
            skip_symbolic_shape=True,
        )

    names = conv_nodes(preprocessed)
    if args.preprocess_only:
        print(f"      {len(names)} Conv/MatMul node(s):")
        for name in names:
            print(f"        {name}")
        return

    excluded = list(args.exclude_node)
    for suffix in args.exclude_suffix:
        excluded.extend(n for n in names if n.endswith(suffix))
    excluded = sorted(set(excluded))
    unknown = [n for n in args.exclude_node if n not in names]
    if unknown:
        # A typo'd node name silently excludes nothing, and the symptom is a
        # subtly worse model rather than an error — so say so here.
        raise SystemExit(
            f"--exclude-node named {unknown}, which are not Conv/MatMul nodes in "
            f"{preprocessed}; run with --preprocess-only to list them"
        )

    frames = len(glob.glob(os.path.join(args.calib_dir, "*.png")))
    print(f"[2/3] building calibration reader from {args.calib_dir} ({frames} frames)")
    reader = FolderCalibrationDataReader(
        args.calib_dir, info["input_name"], width, height, encoding
    )

    print(
        f"[3/3] quantize_static -> {args.out} (QDQ, per_channel={per_channel}, "
        f"ops=Conv+MatMul only, {len(excluded)} node(s) left FP32)"
    )
    quantize_static(
        model_input=preprocessed,
        model_output=args.out,
        calibration_data_reader=reader,
        quant_format=QuantFormat.QDQ,
        per_channel=per_channel,
        weight_type=QuantType.QInt8,
        activation_type=QuantType.QUInt8,
        # Restrict quantization to the compute-heavy conv/matmul backbone. A
        # detect head's postprocessing tail (Split / TopK / GatherElements /
        # Mod / Cast, or a yolox head's grid arithmetic) operates on indices
        # and already-decoded box/score values; quantizing those ops is
        # unnecessary and risks numerical/op-support issues, so they are left
        # in FP32 and only wrapped by DQ nodes feeding from the quantized
        # backbone.
        op_types_to_quantize=["Conv", "MatMul"],
        # Classification-head convs are the ones to watch. They feed directly
        # into the Sigmoid that produces detection scores, and with a couple
        # of hundred mostly-static surveillance calibration frames, MinMax
        # activation calibration underestimates their true dynamic range
        # (high-confidence detections are rare in such a set). Quantizing them
        # then clips high logits and collapses every confident detection's
        # score to sigmoid(0) == 0.5.
        #
        # Measured on yolov10n, where excluding exactly three nodes
        # (/model.23/one2one_cv3.{0,1,2}.2/Conv) fixed the collapse while
        # still quantizing 80 of 83 Convs:
        #
        #   --exclude-suffix one2one_cv3.0.2/Conv \
        #   --exclude-suffix one2one_cv3.1.2/Conv \
        #   --exclude-suffix one2one_cv3.2.2/Conv
        #
        # Compare raw pre-threshold scores between FP32 and a first-pass INT8
        # build (verify_models.py does this) before deciding you need it.
        nodes_to_exclude=excluded,
        extra_options={
            "CalibMovingAverage": True,
        },
    )
    print("Done.")


if __name__ == "__main__":
    main()
