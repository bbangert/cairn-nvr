#!/usr/bin/env python3
"""Full-op-coverage QDQ quantization for HTP artifacts.

The repo's model/quantize_model.py restricts quantization to Conv/MatMul
islands — right for CPU-EP accuracy, fatal on HTP: v68 rejects FP32 ops,
a conv-island model fragments into unclaimable pieces, and an ORT NHWC
MaxPool layout bug then aborts session creation (phase-0 spike,
tools/qnn-spike/README.md). This tool quantizes for the QNN EP
specifically, reusing quantize_model.py's calibration reader and
per-family preprocessing so calibration tensors match what the plugin
feeds the model at runtime.

The recipe is `get_qnn_qdq_config` + plain MinMax, and both halves are
load-bearing:

- **`get_qnn_qdq_config`, not a hand-rolled `quantize_static`.** ORT
  publishes a config builder for this exact EP, and the hand-rolled call
  it replaces omitted four things that only matter on QNN. Chief among
  them: the EP rewrites 16-bit Sigmoid output qparams to
  `scale = 1/65536, zero_point = 0` *inside the EP at graph-build time*,
  logging at VERBOSE only, while the graph's own DequantizeLinear keeps
  the calibrated scale. Every score then comes out multiplied by the
  calibrated maximum — on the HTP, and only on the HTP, which is why
  CPU-EP verification passed artifacts that detected nothing on the
  board. The config writes those same numbers into the file, so the file
  and the hardware agree. It also forces MatMul per-tensor (QNN has no
  per-channel MatMul), fixes MatMul/LayerNorm initializer types under
  a16 (HTP MatMul has no uint16xuint16 form), and sets
  `MinimumRealRange` against near-zero scales.
- **Plain MinMax, never a moving average.** The call this replaces passed
  `CalibMovingAverage: True`, which makes ORT take activation ranges as
  the *mean* of per-frame min/max. For a bounded saturating tensor like a
  score sigmoid there is no outlier to suppress — the maximum IS the
  signal — so averaging bakes a hard ceiling into the graph. Measured on
  the shipped yolox_nano artifact: representable maxima of 0.50/0.65/0.13
  for FPN levels 0/1/2, against a true calibration-set max of 0.98. At
  stride 32 that capped any detection at 0.093, on any EP. qparam_gate.py
  now fails the export rather than let that ship.
- **Score sigmoids pinned to their analytic range at 8 bits.** ORT makes
  that correction at 16 bits only, because there QNN demands it; at 8
  bits it calibrates instead, and the graph then inherits whatever
  maximum the frames happened to contain. `_score_sigmoid_overrides`
  applies the same fix at a8 through `init_overrides`.

Op coverage — the part a comment here once got wrong. Omitting
`op_types_to_quantize` does NOT give full coverage; it falls back to
ORT's `QLinearOpsRegistry | QDQRegistry`, 34 op types, which excludes
`Sub`, `Div`, `Exp`, `ReduceMax`, `Min`, `Max`, `Sqrt`, `Pow`, `Tanh`
and `Gelu`. YOLOX survives that (its whole op census is in the registry);
a yolov8/yolo26 raw head does not — `dist2bbox` is `Sub`/`Add`/`Div`, so
`Sub` and `Div` stayed FP32 islands in the middle of the detection head,
forcing QNN partition boundaries with CPU requantization exactly where
scores are formed. `get_qnn_qdq_config` is what actually delivers full
coverage: it sets `op_types_to_quantize` to every op type present in the
model minus `Cast`. We take that default deliberately — Sub and Div
included — and qparam_gate.py reports the remaining FP32 island count per
artifact so the claim is checked rather than asserted.

Usage:
  qdq_quantize.py <fp32-model.onnx> <out-qdq.onnx> --calib-dir DIR
                  [--activation uint16|uint8]

Idempotent for a fixed toolchain: calibration is deterministic over a
fixed frame set and ORT's quantizer is single-threaded and ordered.
"Fixed toolchain" is not decoration — the emitted graph depends on the
ORT version, so requirements.txt pins one and the export record names it
next to each sha256.

Known traps (measured, see docs/npu-backends.md and the spike README):
- yolov10/YOLO26-family exports carrying the end-to-end selection tail
  (TopK/Gather) SEGFAULT QNN 2.4.0 at first inference once quantized.
  Export with `end2end=False` (export_ultralytics.py) and let the host
  decode the raw head.
- Do NOT hand this tool's output to the CPU-tuned int8 flow or vice
  versa: the artifacts are named differently on purpose (`-qdq` vs
  `-int8`), and the profile schema keys them separately (`model.qnn:`
  vs `model.onnx:`).
"""
import argparse
import os
import sys
import tempfile

REPO_MODEL_DIR = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "..", "plugins", "cairn-detect", "model",
    )
)
sys.path.insert(0, REPO_MODEL_DIR)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import onnx
from onnxruntime.quantization import CalibrationMethod, QuantType, quantize
from onnxruntime.quantization.execution_providers.qnn import get_qnn_qdq_config
from onnxruntime.quantization.shape_inference import quant_pre_process
from quantize_model import FolderCalibrationDataReader, describe, preprocessing

import qparam_gate

# What `qnn_preprocess_model` exists to fuse. We do not run it: it raises
# `TypeError: cannot convert dictionary update sequence element #0` in
# onnxruntime 1.28.0 (preprocess.py:194). Skipping it is harmless for the
# YOLO families — none of these ops appear in their graphs — but it would
# NOT be harmless for a transformer, so the skip is conditional and a
# model carrying any of these stops the export instead of quietly losing
# a fusion pass.
QNN_PREPROCESS_OPS = frozenset(
    {"Gelu", "LayerNormalization", "LpNormalization", "SpaceToDepth", "DepthToSpace"}
)


def build(
    model_path,
    out_path,
    calib_dir,
    activation="uint16",
    min_opset=13,
    min_ceiling=qparam_gate.DEFAULT_MIN_CEILING,
):
    m = onnx.load(model_path)
    opset = next(i.version for i in m.opset_import if i.domain in ("", "ai.onnx"))
    present = {n.op_type for n in m.graph.node} & QNN_PREPROCESS_OPS
    if present:
        raise SystemExit(
            f"{model_path}: contains {sorted(present)}, which qnn_preprocess_model "
            "is supposed to fuse before quantization — and that pass is broken in "
            "onnxruntime 1.28.0. Pin an ORT where it works before quantizing this "
            "model; do not quantize it unfused."
        )
    with tempfile.TemporaryDirectory(prefix="qdq_quantize_") as work:
        src = model_path
        if opset < min_opset:
            from onnx import version_converter

            m = version_converter.convert_version(m, min_opset)
            src = os.path.join(work, "upgraded.onnx")
            onnx.save(m, src)
            print(f"upgraded opset {opset} -> {min_opset}")

        pre = os.path.join(work, "preproc.onnx")
        try:
            quant_pre_process(input_model=src, output_model_path=pre)
        except Exception as e:
            # A leftover end-to-end tail crashes symbolic shape inference
            # (known op-coverage gap); plain shape inference suffices.
            print(f"symbolic shape inference failed ({e!r}); skipping it")
            quant_pre_process(
                input_model=src, output_model_path=pre, skip_symbolic_shape=True
            )

        info = _quantize(pre, out_path, calib_dir, activation)

    _gate(out_path, info, min_ceiling)


def _score_sigmoid_overrides(pre, activation):
    """Pin the class-score sigmoids to their analytic range at 8 bits.

    A sigmoid's output is (0, 1) by definition. There is nothing to
    measure, and measuring it anyway costs range: calibration can only
    ever return the largest score some frame happened to contain, so the
    graph inherits a ceiling from the calibration set — 0.918 at stride
    16 on the set built for this run — and clips anything more confident
    at inference. `scale = 1/256` spends the full uint8 code space on
    0..1 and lands within 8% of what calibration chose anyway, so the
    resolution given up is negligible against the clipping avoided.

    Not needed at 16 bits: `get_qnn_qdq_config` already forces every
    16-bit Sigmoid to `1/65536` because QNN *requires* it, and this
    returns None so that path stays exactly ORT's. The 8-bit case is the
    same correction made for the same reason, applied where the EP does
    not make it for us and only to the sigmoids whose values reach the
    output tensor — an internal SiLU's sigmoid is not a score and keeps
    its calibrated range.
    """
    if activation != "uint8":
        return None
    return {
        t: [
            {
                "quant_type": QuantType.QUInt8,
                "scale": np.array(1.0 / 256.0, dtype=np.float32),
                "zero_point": np.array(0, dtype=np.uint8),
            }
        ]
        for t in qparam_gate.score_sigmoid_tensors(pre)
    }


def _quantize(pre, out_path, calib_dir, activation):
    info = describe(pre)
    profile = preprocessing(info["layout"])
    print(
        f"layout={info['layout']} {info['width']}x{info['height']} "
        f"w8a{16 if activation == 'uint16' else 8} -> {out_path}"
    )
    reader = FolderCalibrationDataReader(
        calib_dir, info["input_name"], info["width"], info["height"], profile
    )
    config = get_qnn_qdq_config(
        pre,
        reader,
        init_overrides=_score_sigmoid_overrides(pre, activation),
        # MinMax over the frame set, with no averaging anywhere. See the
        # module docstring: the maximum is the signal for a score sigmoid.
        calibrate_method=CalibrationMethod.MinMax,
        activation_type=QuantType.QUInt16
        if activation == "uint16"
        else QuantType.QUInt8,
        weight_type=QuantType.QInt8,
        # Per-channel int8 Conv weights are the sanctioned QNN combination
        # (per-channel weights had to be a SIGNED type until ORT 1.24 /
        # QAIRT 2.36, and axis must be 0 for Conv). The config downgrades
        # MatMul to per-tensor on its own, which is why per_channel can be
        # global here without pushing MatMuls to CPU.
        per_channel=True,
    )
    quantize(pre, out_path, config)
    print(f"wrote {out_path}")
    return info


def _gate(out_path, info, min_ceiling):
    """Fail the export rather than ship a graph with a baked score ceiling.

    The artifact is removed on failure: a rejected .onnx left on disk is
    one `--model` flag away from being benchmarked as if it had passed,
    and the defect this gate catches is invisible to every other check in
    the pipeline.
    """
    try:
        qparam_gate.check(out_path, min_ceiling, input_size=info.get("width"))
    except qparam_gate.GateFailure as e:
        os.unlink(out_path)
        raise SystemExit(f"FAIL (artifact removed): {e}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("model", help="FP32 .onnx input")
    ap.add_argument("out", help="QDQ .onnx output (name it <model>-qdq.onnx)")
    ap.add_argument(
        "--calib-dir",
        required=True,
        help="Calibration frame directory (PNG only — the reader globs "
        "*.png and a mixed directory silently calibrates on the PNG "
        "subset). The profile's own resize/encoding is applied at load, so "
        "full-resolution frames (capture_frames.sh) work for every family. "
        "Required, no default: the tempting default — the 416 "
        "pre-letterboxed yolox set — silently miscalibrates every stretch "
        "family.",
    )
    ap.add_argument(
        "--activation",
        choices=("uint16", "uint8"),
        default="uint16",
        help="Activation quantization width (weights are always int8 "
        "per-channel). Both widths are supported outputs; w8a16 is the "
        "default only because it is the conservative one pending the "
        "board's own accuracy leg. The 'w8a8 collapses this model' result "
        "that once made a16 mandatory was an artifact of the broken "
        "recipe and does not survive it — measure, do not assume.",
    )
    ap.add_argument(
        "--min-ceiling",
        type=float,
        default=qparam_gate.DEFAULT_MIN_CEILING,
        help="Score-sigmoid representable-maximum floor for the qparam gate.",
    )
    args = ap.parse_args()
    build(
        args.model,
        args.out,
        args.calib_dir,
        args.activation,
        min_ceiling=args.min_ceiling,
    )


if __name__ == "__main__":
    main()
