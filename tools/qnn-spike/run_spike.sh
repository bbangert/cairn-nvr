#!/bin/sh
# On-board spike runner (busybox ash — no bashisms, no uname/head/wc).
# Expects the bundle at /data/qnn-spike/ (see build.sh).
#
# ADSP_LIBRARY_PATH / DSP_LIBRARY_PATH steer the *skel* lookup to our
# /data copy (D-P1). The DSP shell (fastrpc_shell_0) is found via the
# compiled-in search list, whose first entry /usr/lib/dsp/cdsp already
# ships it — this bundle doesn't carry a shell, only the skel. Both env
# names are set because the fastrpc convention splits them by domain
# (ADSP_ vs DSP_) and CDSP reads either depending on version.
B=/data/qnn-spike
N=${1:-100}

# Prefix, don't clobber: keep any preconfigured paths after ours.
export LD_LIBRARY_PATH="$B/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ADSP_LIBRARY_PATH="$B/dsp;${ADSP_LIBRARY_PATH:-}"
export DSP_LIBRARY_PATH="$B/dsp;${DSP_LIBRARY_PATH:-}"

echo "--- cpu ---"
"$B/qnn_spike" "$B/model.onnx" cpu "$N"
echo "--- qnn ---"
# soc_model=35/htp_arch=68 (QCS6490/HTP v68): platform detection fails
# without them ("Failed to get HTP arch") — README trap #1.
"$B/qnn_spike" "$B/model.onnx" qnn "$N" "$B/lib/libonnxruntime_providers_qnn.so" \
  soc_model=35 htp_arch=68
