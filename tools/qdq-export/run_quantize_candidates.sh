#!/bin/sh
# Quantize every candidate rung at BOTH activation widths.
#
# Both widths, always: the w8a8 measurement that once justified a blanket
# w8a16 default ("crushed yolox_nano to 0.20-0.49") was taken under the
# broken recipe and does not survive it. Which width a rung ships at is a
# question for the board's latency and accuracy legs, and it cannot be
# answered for artifacts that were never built. `-a8` / `-a16` suffixes
# keep both on disk at once.
#
# Env: SRC (fp32 exports), OUT (artifacts), CALIB (frame dir), PY,
# MODELS (space-separated stems under SRC, without .onnx).
#
# A gate failure is not fatal to the run: the matrix is the point, and
# stopping at the first bad rung hides how many others are fine. Failures
# are counted and re-listed at the end, and qdq_quantize.py has already
# deleted each rejected artifact.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${PY:-$ROOT/plugins/cairn-detect/model/quant-venv/bin/python3}
SRC=${SRC:-$HERE/out/sources}
OUT=${OUT:-$HERE/out/artifacts}
CALIB=${CALIB:?set CALIB to the calibration frame directory}
MODELS=${MODELS:-yolox_nano yolox_tiny yolox_s yolox_m yolo26n yolo26n-416 yolo26s yolo26m yolov8n}
mkdir -p "$OUT"
failed=""
for m in $MODELS; do
  for a in uint16 uint8; do
    case $a in uint16) sfx=a16 ;; *) sfx=a8 ;; esac
    echo "=== $m w8$sfx ==="
    # The destination is cleared before AND after a failed attempt: an
    # error ahead of the gate (missing source, ORT failure) deletes
    # nothing itself, and a stale predecessor left at this path would be
    # consumed downstream as if this run had produced it.
    rm -f "$OUT/$m-qdq-$sfx.onnx"
    if "$PY" "$HERE/qdq_quantize.py" "$SRC/$m.onnx" "$OUT/$m-qdq-$sfx.onnx" \
        --calib-dir "$CALIB" --activation "$a"; then
      :
    else
      echo "GATE FAILED: $m-$sfx"
      failed="$failed $m-$sfx"
      rm -f "$OUT/$m-qdq-$sfx.onnx"
    fi
  done
done
echo "=== artifacts ==="
ls -la "$OUT"
if [ -n "$failed" ]; then
  echo "=== gate failures:$failed ==="
  exit 1
fi
exit 0
