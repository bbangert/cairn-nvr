#!/usr/bin/env bash
# Compile and run Cairn.BoardPipeline on this (x86) machine, against the
# repo's own dev-built deps and NIF .so files: the generic board, onnxruntime
# on the CPU and the software decoder. The Green runs the same source inside
# its release instead (rk-cell.sh).
#
# The clip is BOARD_PIPELINE_CLIP, a board-soak packed AU file
# (<<pts90::signed-64, size::unsigned-32, au::binary>>). Regenerate one from
# any H.264 video:
#   mix run --no-start tools/board-pipeline/pack_clip.exs <video> <out.aus>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Refused up front with the remedy, not after a full compile as the
# pipeline's opaque {:error, :no_clip_configured} (or :clip_empty — `-s`
# covers the empty-file case too).
if [ -z "${BOARD_PIPELINE_CLIP:-}" ] || [ ! -s "${BOARD_PIPELINE_CLIP:-}" ]; then
  echo "run-local.sh: BOARD_PIPELINE_CLIP must point at a non-empty packed .aus clip" >&2
  echo "  (make one: mix run --no-start tools/board-pipeline/pack_clip.exs <video> <out.aus>)" >&2
  exit 1
fi
BUILD="$ROOT/_build/dev/lib"
OUT="${BOARD_PIPELINE_BUILD:-$(mktemp -d)}/ebin"
mkdir -p "$OUT"

# membrane_core's runtime closure is pure BEAM; the h26x parser and the two
# format apps sit on top of it. jason is only the canary's (disabled here),
# and nx/complex only the motion gate's, which a gate-open chain never
# builds — on the path they keep those modules' compile warning-free.
DEPS=(qex telemetry bunch ratio numbers coerce decimal jason complex nx
  membrane_core membrane_raw_video_format membrane_h264_format
  membrane_h265_format membrane_h26x_plugin)

PA=()
for dep in "${DEPS[@]}"; do
  PA+=(-pa "$BUILD/$dep/ebin")
done

# The minimal cairn slice: the detect chain and its board, the host stack it
# calls into, and the value modules those carry. config_stub.ex stands in for
# Cairn.Config. Expected warnings: Cairn.Config's functions,
# Cairn.Config.Server and Phoenix.PubSub are undefined here — remote calls
# this path never takes.
elixirc "${PA[@]}" -o "$OUT" \
  "$ROOT/tools/board-pipeline/config_stub.ex" \
  "$ROOT/lib/cairn/ulid.ex" \
  "$ROOT/lib/cairn/observation.ex" \
  "$ROOT/lib/cairn/observation_clock.ex" \
  "$ROOT/lib/cairn/native/observations.ex" \
  "$ROOT/lib/cairn/stream_epochs.ex" \
  "$ROOT/lib/cairn_ort.ex" \
  "$ROOT/lib/cairn/native.ex" \
  "$ROOT/lib/cairn/native/config.ex" \
  "$ROOT/lib/cairn/native/health.ex" \
  "$ROOT/lib/cairn/native/canary.ex" \
  "$ROOT/lib/cairn/native/host.ex" \
  "$ROOT"/libs/cairn_stage/lib/cairn/stage.ex \
  "$ROOT"/libs/cairn_stage/lib/cairn/stage/*.ex \
  "$ROOT/lib/cairn/board.ex" \
  "$ROOT/lib/cairn/board/generic.ex" \
  "$ROOT/lib/cairn/motion.ex" \
  "$ROOT/lib/cairn/motion/config.ex" \
  "$ROOT/lib/cairn/motion/thumbnail.ex" \
  "$ROOT/lib/cairn/pipeline/motion_gate.ex" \
  "$ROOT/lib/cairn/pipeline/picker.ex" \
  "$ROOT/lib/cairn/pipeline/decoder.ex" \
  "$ROOT/lib/cairn/pipeline/inference.ex" \
  "$ROOT/lib/cairn/pipeline/detect_chain.ex" \
  "$ROOT/tools/board-pipeline/board_pipeline.ex"

BOARD_PIPELINE_MODEL="${BOARD_PIPELINE_MODEL:-$ROOT/plugins/cairn-detect/yolox_nano.onnx}" \
  BOARD_PIPELINE_LABELS="${BOARD_PIPELINE_LABELS:-$ROOT/plugins/cairn-detect/coco.names}" \
  BOARD_PIPELINE_BACKEND="${BOARD_PIPELINE_BACKEND:-ort}" \
  BOARD_PIPELINE_QNN_LIBRARY="${BOARD_PIPELINE_QNN_LIBRARY:-}" \
  BOARD_PIPELINE_DECODER="${BOARD_PIPELINE_DECODER:-sw}" \
  BOARD_PIPELINE_SECONDS="${BOARD_PIPELINE_SECONDS:-20}" \
  BOARD_PIPELINE_NATIVE_LIB="${BOARD_PIPELINE_NATIVE_LIB:-$ROOT/priv/native/libcairn_native.so}" \
  BOARD_PIPELINE_ORT_LIB="${BOARD_PIPELINE_ORT_LIB:-$ROOT/priv/native/libcairn_ort.so}" \
  exec elixir "${PA[@]}" -pa "$OUT" -e 'Cairn.BoardPipeline.main()'
