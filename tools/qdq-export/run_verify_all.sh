#!/bin/sh
# CPU-EP decode verification of every phase-3 artifact.
# Floor 0.35: sits under the measured w8a16 score depression so the
# histogram shows what each artifact finds, while staying above junk.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PLUGIN=$ROOT/plugins/cairn-detect
export MIN_SCORE_JSON=${MIN_SCORE_JSON:-'{"default": 0.35}'}
port=17310
for m in yolox_nano-qdq yolo26n-qdq yolo26s-qdq yolov8n-qdq; do
  echo "=== $m ==="
  PORT=$port sh "$(dirname "$0")/verify_artifact.sh" "$PLUGIN/$m.onnx" || echo "FAILED: $m"
  port=$((port + 2))
done
