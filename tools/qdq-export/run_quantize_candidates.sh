#!/bin/sh
# Quantize the phase-3 candidate set (w8a16, full-res calibration).
# Prereqs: the FP32 exports in the plugin root (export_ultralytics.py)
# and a calib_frames_fullres set (run_capture_calib.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PY=${PY:-$ROOT/plugins/cairn-detect/model/quant-venv/bin/python3}
PLUGIN=$ROOT/plugins/cairn-detect
CALIB=${CALIB:-$PLUGIN/model/calib_frames_fullres}
for m in yolo26n yolo26s yolov8n; do
  echo "=== $m ==="
  "$PY" "$(dirname "$0")/qdq_quantize.py" \
    "$PLUGIN/$m.onnx" "$PLUGIN/$m-qdq.onnx" --calib-dir "$CALIB"
done
ls -la "$PLUGIN"/*-qdq.onnx
