#!/usr/bin/env python3
"""Full-op-coverage QDQ quantization for HTP spike/bench artifacts.

The repo's quantize_model.py restricts quantization to Conv/MatMul —
right for CPU accuracy, fatal on HTP: v68 rejects FP32 ops, so a
conv-island model fragments into unclaimable pieces and an ORT NHWC
MaxPool layout bug then aborts the session (see tools/qnn-spike/README.md).
This variant quantizes every op ORT supports (w8a8, per-channel,
opset upgraded to >= 13) while reusing quantize_model.py's calibration
reader and per-family preprocessing, so the tensors match what the
plugin feeds the model.

Usage: spike_quant.py <fp32-model.onnx> <out-qdq.onnx> [calib_dir]

Known trap (spike-verified): yolov10-family exports with the NMS-free
postprocessing tail segfault QNN 2.4.0 at first inference when
quantized this way — strip or FP32-exclude the tail first. yolox is
clean (its Focus-layer Slices fall back to CPU harmlessly).
"""
import os
import sys
import tempfile

REPO_MODEL_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "plugins", "cairn-detect", "model")
)
sys.path.insert(0, REPO_MODEL_DIR)

import onnx
from onnxruntime.quantization import QuantFormat, QuantType, quantize_static
from onnxruntime.quantization.shape_inference import quant_pre_process
from quantize_model import FolderCalibrationDataReader, describe, preprocessing


def build(model_path, out_path, calib_dir, min_opset=13):
    m = onnx.load(model_path)
    opset = next(i.version for i in m.opset_import if i.domain in ("", "ai.onnx"))
    with tempfile.TemporaryDirectory(prefix="spike_quant_") as work:
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
            # yolov10's TopK tail crashes symbolic shape inference (known
            # op-coverage gap); plain shape inference suffices for QDQ.
            print(f"symbolic shape inference failed ({e!r}); skipping it")
            quant_pre_process(
                input_model=src, output_model_path=pre, skip_symbolic_shape=True
            )

        _quantize(pre, out_path, calib_dir)


def _quantize(pre, out_path, calib_dir):
    info = describe(pre)
    profile = preprocessing(info["layout"])
    print(f"layout={info['layout']} {info['width']}x{info['height']} -> {out_path}")
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
        activation_type=QuantType.QUInt8,
        # no op_types_to_quantize: quantize everything supported (the point)
        extra_options={"CalibMovingAverage": True},
    )
    print(f"wrote {out_path}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(
            "usage: spike_quant.py <fp32-model.onnx> <out-qdq.onnx> [calib_dir]"
        )
    calib = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
        REPO_MODEL_DIR, "calib_frames"
    )
    build(sys.argv[1], sys.argv[2], calib)
