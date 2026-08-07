#!/usr/bin/env python3
"""Full-op-coverage QDQ quantization for HTP artifacts (phase 3).

The repo's model/quantize_model.py restricts quantization to Conv/MatMul
islands — right for CPU-EP accuracy, fatal on HTP: v68 rejects FP32 ops,
a conv-island model fragments into unclaimable pieces, and an ORT NHWC
MaxPool layout bug then aborts session creation (phase-0 spike,
tools/qnn-spike/README.md). This tool is the productionized form of the
spike's spike_quant.py: quantize every op ORT supports (weights int8
per-channel, activations uint16 by default — see `--activation` for the
measured why), reusing quantize_model.py's calibration reader and
per-family preprocessing so calibration tensors match what the plugin
feeds the model at runtime.

Usage:
  qdq_quantize.py <fp32-model.onnx> <out-qdq.onnx> --calib-dir DIR

Idempotent: same inputs -> same graph (calibration is deterministic over
a fixed frame set; ORT's quantizer is single-threaded and ordered).

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

import onnx
from onnxruntime.quantization import QuantFormat, QuantType, quantize_static
from onnxruntime.quantization.shape_inference import quant_pre_process
from quantize_model import FolderCalibrationDataReader, describe, preprocessing


def build(model_path, out_path, calib_dir, activation="uint16", min_opset=13):
    m = onnx.load(model_path)
    opset = next(i.version for i in m.opset_import if i.domain in ("", "ai.onnx"))
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

        _quantize(pre, out_path, calib_dir, activation)


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
    quantize_static(
        model_input=pre,
        model_output=out_path,
        calibration_data_reader=reader,
        quant_format=QuantFormat.QDQ,
        per_channel=True,
        weight_type=QuantType.QInt8,
        # uint16 activations are the default on purpose: w8a8 full-coverage
        # crushed yolox_nano's score distribution from 0.50-0.72 down to
        # 0.20-0.49 on the fixture clip — everything under the plugin's 0.5
        # floor. w8a16 is also what Ultralytics' first-party QNN export
        # ships. HTP v68 runs 16-bit activations (slower per-op; D-P5 on the
        # board is the judge of whether the margin survives).
        activation_type=QuantType.QUInt16
        if activation == "uint16"
        else QuantType.QUInt8,
        # no op_types_to_quantize: full coverage is the point (HTP)
        extra_options={"CalibMovingAverage": True},
    )
    print(f"wrote {out_path}")


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
        help="Calibration frame directory (PNG/JPEG). The profile's own "
        "resize/encoding is applied at load, so full-resolution frames "
        "(capture_frames.sh) work for every family. Required, no "
        "default: the tempting default — the 416 pre-letterboxed yolox "
        "set — silently miscalibrates every stretch family.",
    )
    ap.add_argument(
        "--activation",
        choices=("uint16", "uint8"),
        default="uint16",
        help="Activation quantization width (weights are always int8 "
        "per-channel). uint8 halves activation memory but measured a "
        "score collapse on yolox_nano — see the in-code note.",
    )
    args = ap.parse_args()
    build(args.model, args.out, args.calib_dir, args.activation)


if __name__ == "__main__":
    main()
