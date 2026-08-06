#!/usr/bin/env bash
# Cross-compile qnn_spike and assemble the on-board bundle.
#
# Produces work/bundle/ ready to copy to /data/qnn-spike/ on the board.
# Run from tools/qnn-spike/. Requires: aarch64-linux-gnu-gcc, pip, curl.
#
# Version triple (see README.md): base ORT 1.26.0 x plugin EP 2.4.0 x
# QAIRT 2.48.40 (bundled inside the onnxruntime-qnn wheel).
set -euo pipefail

ORT_VERSION=1.26.0
PLUGIN_VERSION=2.4.0
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
PLUGIN_ROOT=$HERE/../../plugins/cairn-detect
# MODEL, if set, must be a FULL-op-coverage QDQ model (conv-island int8
# aborts QNN session creation — see README traps). Unset, we quantize
# SRC_MODEL ourselves with spike_quant.py, which is how the recorded
# PASS artifact was produced.
SRC_MODEL=${SRC_MODEL:-$PLUGIN_ROOT/yolox_nano.onnx}
QUANT_PY=${QUANT_PY:-$PLUGIN_ROOT/model/quant-venv/bin/python}

mkdir -p "$WORK"
cd "$WORK"

if [ ! -d "onnxruntime-linux-aarch64-$ORT_VERSION" ]; then
  curl -sLO "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-aarch64-$ORT_VERSION.tgz"
  tar xzf "onnxruntime-linux-aarch64-$ORT_VERSION.tgz"
fi

if [ ! -d wheel ]; then
  pip download "onnxruntime-qnn==$PLUGIN_VERSION" --no-deps \
    --platform manylinux_2_34_aarch64 --python-version 3.12 \
    --only-binary :all: -d .
  unzip -q "onnxruntime_qnn-$PLUGIN_VERSION"-cp312-*.whl -d wheel
fi

if [ -z "${MODEL:-}" ]; then
  if [ ! -f "$SRC_MODEL" ]; then
    echo >&2 "missing $SRC_MODEL — fetch it per plugins/cairn-detect/model/quantize-model.md"
    exit 1
  fi
  if [ ! -x "$QUANT_PY" ]; then
    echo >&2 "missing quant venv at $QUANT_PY — create it per plugins/cairn-detect/model/quantize-model.md"
    exit 1
  fi
  MODEL="$WORK/$(basename "${SRC_MODEL%.onnx}")_htp.onnx"
  [ -f "$MODEL" ] || "$QUANT_PY" "$HERE/spike_quant.py" "$SRC_MODEL" "$MODEL"
fi

ORT="$WORK/onnxruntime-linux-aarch64-$ORT_VERSION"
aarch64-linux-gnu-gcc -O2 -std=c11 -Wall -Wextra \
  -I "$ORT/include" "$HERE/qnn_spike.c" \
  -L "$ORT/lib" -lonnxruntime -Wl,-rpath,'$ORIGIN/lib' \
  -o qnn_spike

rm -rf bundle
mkdir -p bundle/lib bundle/dsp
cp qnn_spike "$HERE/run_spike.sh" bundle/
cp "$MODEL" bundle/model.onnx
# SONAME the driver links against:
cp "$ORT/lib/libonnxruntime.so.$ORT_VERSION" bundle/lib/libonnxruntime.so.1
# Host-side QNN stack + plugin EP (from the wheel):
for f in libonnxruntime_providers_qnn.so libQnnHtp.so libQnnHtpPrepare.so \
         libQnnHtpV68Stub.so libQnnSystem.so; do
  cp "$WORK/wheel/onnxruntime_qnn/$f" bundle/lib/
done
# DSP-side skeleton — delivered via ADSP_LIBRARY_PATH override (D-P1):
cp "$WORK/wheel/onnxruntime_qnn/libQnnHtpV68Skel.so" bundle/dsp/

echo "bundle ready: $WORK/bundle ($(du -sh bundle | cut -f1))"
