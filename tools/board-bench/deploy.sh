#!/bin/sh
# Cross-build the plugin and assemble/push the /data/cairn-bench bundle.
#
#   sh deploy.sh [board-ip]     # default 192.168.2.87
#
# Prereqs (one-time, documented in docs/npu-backends.md "QNN wiring as
# landed"): rustup target aarch64-unknown-linux-gnu; an aarch64 FFmpeg
# tree at plugins/cairn-detect/target/board/ffmpeg-aarch64 built with
# --enable-cross-compile (run this script once and it prints the recipe
# if the tree is missing); the QNN/ORT runtime libs already on the board
# under /data/qnn-spike (phase-0 spike bundle — the wheel's libs and the
# DSP skel; this script does not re-push those).
#
# Board quirks (memory: qcs6490): ssh runs ELIXIR (nerves_ssh) — shell
# via :os.cmd; busybox has no chmod — File.chmod!; scp exits 1 even on
# success — verify by listing sizes.
set -eu
BOARD=${1:-192.168.2.87}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CRATE=$ROOT/plugins/cairn-detect
FF=$CRATE/target/board/ffmpeg-aarch64

if [ ! -d "$FF/lib/pkgconfig" ]; then
  cat >&2 <<'EOF'
missing aarch64 FFmpeg tree. One-time build (from plugins/cairn-detect/target/board):
  curl -LO https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz && tar xf ffmpeg-7.1.tar.xz
  cd ffmpeg-7.1 && ./configure --prefix=../ffmpeg-aarch64 \
    --enable-cross-compile --cross-prefix=aarch64-linux-gnu- \
    --arch=aarch64 --target-os=linux --enable-shared --disable-static \
    --disable-doc --disable-autodetect --disable-ffplay --disable-ffprobe
  make -j"$(nproc)" && make install
EOF
  exit 1
fi

cd "$CRATE"
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS= \
FFMPEG_PKG_CONFIG_PATH="$FF/lib/pkgconfig" PKG_CONFIG_ALLOW_CROSS=1 \
cargo build --release --target aarch64-unknown-linux-gnu --features ort-load-dynamic

ssh "$BOARD" 'File.mkdir_p!("/data/cairn-bench/lib"); File.mkdir_p!("/data/cairn-bench/runs")'
scp "$CRATE/target/aarch64-unknown-linux-gnu/release/cairn-detect" \
  "$CRATE/coco.names" "$ROOT/tools/board-bench/bench.sh" \
  "$BOARD:/data/cairn-bench/" || true
scp "$CRATE/target/board/ffmpeg-7.1/ffmpeg" \
  "$FF"/lib/libav*.so.* "$FF"/lib/libsw*.so.* \
  "$BOARD:/data/cairn-bench/lib/" || true
# Models: every QDQ artifact present locally rides along.
for m in "$CRATE"/*-qdq.onnx; do
  [ -f "$m" ] && scp "$m" "$BOARD:/data/cairn-bench/" || true
done
ssh "$BOARD" 'File.chmod!("/data/cairn-bench/cairn-detect", 0o755); File.chmod!("/data/cairn-bench/lib/ffmpeg", 0o755); :os.cmd(~c"ls -la /data/cairn-bench") |> IO.puts()'
