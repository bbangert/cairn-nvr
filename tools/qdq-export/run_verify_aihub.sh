#!/bin/sh
# Local gates for the AI Hub-returned artifacts (plan 5.2) — the exact
# checks our own exports face, because provenance buys nothing here: a
# baked ceiling from their calibrator would ship just as silently as
# one from ours. Per artifact: qparam gate, then FP32-vs-QDQ score
# parity on heldout + board frames. Decode verify (verify_artifact.sh)
# is separate — it needs the release binary and a fixture clip.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
O=$HERE/out-20260820
A=$O/aihub-ours/artifacts
R=$O/aihub-ours/records
PY=$ROOT/plugins/cairn-detect/model/quant-venv/bin/python3
mkdir -p "$R"

: > "$R/qparam-summaries.txt"
: > "$R/parity.txt"
rc=0
checked=0
for art in "$A"/*/model.onnx; do
  [ -f "$art" ] || continue
  checked=$((checked + 1))
  base=$(basename "$(dirname "$art")")
  case "$base" in
  *-416-*) size=416 ;;
  yolox_nano* | yolox_tiny*) size=416 ;;
  *) size=640 ;;
  esac
  # stem = source name: strip "-aihub-a8/-aihub-a16".
  stem=${base%-aihub-*}
  # The gate CLI only reports (deletion is qdq_quantize.py's job on its
  # own writes) — safe on artifacts we paid job quota for.
  echo "=== $base (input $size) ===" | tee -a "$R/qparam-summaries.txt"
  "$PY" "$HERE/qparam_gate.py" "$art" --input-size "$size" \
    >> "$R/qparam-summaries.txt" 2>&1 || { echo "  GATE FAIL" >> "$R/qparam-summaries.txt"; rc=1; }

  echo "=== $base ===" >> "$R/parity.txt"
  echo "--- heldout" >> "$R/parity.txt"
  "$PY" "$HERE/score_parity.py" --fp32 "$O/sources/$stem.onnx" --qdq "$art" \
    --frames "$ROOT/plugins/cairn-detect/model/heldout_frames" --limit 16 \
    >> "$R/parity.txt" 2>&1 || rc=1
  echo "--- board" >> "$R/parity.txt"
  "$PY" "$HERE/score_parity.py" --fp32 "$O/sources/$stem.onnx" --qdq "$art" \
    --frames "$O/parity-board" --limit 60 >> "$R/parity.txt" 2>&1 || rc=1
done

echo "== gate results =="
grep -E "^===|ceiling|GATE FAIL|islands" "$R/qparam-summaries.txt" | tail -60
echo "== parity verdicts =="
grep -E "^===|parity (PASS|FAIL)" "$R/parity.txt"
# Same posture as run_verify_all.sh: a run that gated nothing, or one where
# any advertised gate failed, must not exit green — these are the artifacts
# a ladder decision reads.
if [ "$checked" -eq 0 ]; then
  echo "verify-aihub: no artifacts matched under $A — nothing was verified" >&2
  exit 1
fi
echo "verify-aihub: $checked artifact(s) checked"
exit $rc
