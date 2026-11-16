#!/bin/sh
# matrix.sh OUT MODEL... : rk.py bench per model, one JSON line each, appended to OUT.
# 20 s idle between rungs so each starts near idle temperature.
out=$1; shift
cd "$(dirname "$0")"
for m in "$@"; do
  python3 rk.py bench models/$m.rknn --warm 200 --sustain 60 >> "$out" 2>&1
  sleep 20
done
echo DONE >> "$out"
