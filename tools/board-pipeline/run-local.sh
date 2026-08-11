#!/usr/bin/env bash
# Compile and run Cairn.BoardPipeline on this (x86) machine, against the
# repo's own dev-built deps and NIF .so files — the same module set an
# aarch64 board runs, so a pass here validates everything but the hardware.
#
# The clip is BOARD_PIPELINE_CLIP, a board-soak packed AU file
# (<<pts90::signed-64, size::unsigned-32, au::binary>>). Regenerate one from
# any H.264 video with the packer used for the board soak:
#   mix run <scratchpad>/pack_clip.exs <video> <out.aus>
# (pack_clip.exs wraps Cairn.Native.Parity.read_clip and rescales pts to 90 kHz.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/_build/dev/lib"
OUT="${BOARD_PIPELINE_BUILD:-$(mktemp -d)}/ebin"
mkdir -p "$OUT"

# membrane_core's runtime closure is pure BEAM; the h26x parser and the two
# format apps sit on top of it. jason is only the canary's (disabled here),
# but on the path it compiles canary.ex without undefined-module warnings.
# Everything else cairn's detect branch needs is compiled below from source.
DEPS=(qex telemetry bunch ratio numbers coerce decimal jason
  membrane_core membrane_raw_video_format membrane_h264_format
  membrane_h265_format membrane_h26x_plugin)

PA=()
for dep in "${DEPS[@]}"; do
  PA+=(-pa "$BUILD/$dep/ebin")
done

# The minimal cairn slice: the detect-branch elements, the host stack they
# call into, and the value modules those carry. board_pipeline.ex supplies
# the Cairn.CameraTracker stub, so the real tracker (and everything behind
# it) stays out. Expected warnings: Cairn.Config/Cairn.Config.Server and
# Phoenix.PubSub are undefined here — remote calls this path never takes.
elixirc "${PA[@]}" -o "$OUT" \
  "$ROOT/lib/cairn/ulid.ex" \
  "$ROOT/lib/cairn/observation.ex" \
  "$ROOT/lib/cairn/observation_clock.ex" \
  "$ROOT/lib/cairn/native/observations.ex" \
  "$ROOT/lib/cairn/config/camera.ex" \
  "$ROOT/lib/cairn/stream_epochs.ex" \
  "$ROOT/lib/cairn_ort.ex" \
  "$ROOT/lib/cairn/native.ex" \
  "$ROOT/lib/cairn/native/config.ex" \
  "$ROOT/lib/cairn/native/health.ex" \
  "$ROOT/lib/cairn/native/canary.ex" \
  "$ROOT/lib/cairn/native/host.ex" \
  "$ROOT/lib/cairn/pipeline/sample_gate.ex" \
  "$ROOT/lib/cairn/pipeline/picker.ex" \
  "$ROOT/lib/cairn/pipeline/decoder.ex" \
  "$ROOT/lib/cairn/pipeline/inference.ex" \
  "$ROOT/lib/cairn/detect/dispatch.ex" \
  "$ROOT/lib/cairn/pipeline/detect_sink.ex" \
  "$ROOT/tools/board-pipeline/board_pipeline.ex"

BOARD_PIPELINE_MODEL="${BOARD_PIPELINE_MODEL:-$ROOT/plugins/cairn-detect/yolox_nano.onnx}" \
  BOARD_PIPELINE_LABELS="${BOARD_PIPELINE_LABELS:-$ROOT/plugins/cairn-detect/coco.names}" \
  BOARD_PIPELINE_BACKEND="${BOARD_PIPELINE_BACKEND:-ort}" \
  BOARD_PIPELINE_QNN_LIBRARY="${BOARD_PIPELINE_QNN_LIBRARY:-}" \
  BOARD_PIPELINE_DECODER="${BOARD_PIPELINE_DECODER:-sw}" \
  BOARD_PIPELINE_SECONDS="${BOARD_PIPELINE_SECONDS:-20}" \
  BOARD_PIPELINE_NATIVE_LIB="${BOARD_PIPELINE_NATIVE_LIB:-$ROOT/priv/native/libcairn_native.so}" \
  BOARD_PIPELINE_ORT_LIB="${BOARD_PIPELINE_ORT_LIB:-$ROOT/priv/native/libcairn_ort.so}" \
  exec elixir "${PA[@]}" -pa "$OUT" \
  -e 'case Cairn.BoardPipeline.run() do :ok -> System.halt(0); other -> IO.puts("board-pipeline: #{inspect(other)}"); System.halt(1) end'
