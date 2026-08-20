#!/bin/sh
# Score-distribution parity for every artifact, against its own FP32.
#
# This replaced a loop over verify_artifact.sh's label histogram. The
# histogram is still worth running (it exercises the real decode path
# end to end, which this does not), but it was never an accuracy oracle:
# a head clipped to 0.093 at stride 32 emits the same labels, and the
# artifacts that ran the fleet blind passed it.
#
# Two frame sets on purpose:
#   HELDOUT — frames never used for calibration. The honest oracle.
#   BOARD   — dense frames off the clips the failure was measured on, so
#             the person-window numbers here are comparable to what the
#             board reports. Its calibration frames are a subset, so read
#             it as the domain check, not as held-out evidence.
#
# CPU EP only. That is the point of the board leg, not a gap this script
# can close: the QNN EP rewrites qparams at graph-build time and nothing
# measured here can see it.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${PY:-$ROOT/plugins/cairn-detect/model/quant-venv/bin/python3}
SRC=${SRC:-$HERE/out/sources}
OUT=${OUT:-$HERE/out/artifacts}
HELDOUT=${HELDOUT:-$ROOT/plugins/cairn-detect/model/heldout_frames}
BOARD=${BOARD:-}
LIMIT=${LIMIT:-60}
TOLERANCE=${TOLERANCE:-0.9}
rc=0
for art in "$OUT"/*-qdq-a*.onnx; do
  [ -f "$art" ] || continue
  base=$(basename "$art" .onnx)
  stem=${base%-qdq-a16}
  stem=${stem%-qdq-a8}
  fp32="$SRC/$stem.onnx"
  [ -f "$fp32" ] || { echo "=== $base: no FP32 at $fp32 — SKIPPED"; rc=1; continue; }
  echo "=== $base ==="
  echo "--- heldout"
  "$PY" "$HERE/score_parity.py" --fp32 "$fp32" --qdq "$art" \
    --frames "$HELDOUT" --tolerance "$TOLERANCE" --limit "$LIMIT" || rc=1
  if [ -n "$BOARD" ]; then
    echo "--- board clips"
    "$PY" "$HERE/score_parity.py" --fp32 "$fp32" --qdq "$art" \
      --frames "$BOARD" --tolerance "$TOLERANCE" --limit "$LIMIT" || rc=1
  fi
done
exit $rc
