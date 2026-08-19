#!/usr/bin/env bash
# Cross-build the three Rust artifacts for the aarch64 container image:
#
#   plugins/cairn-native  -> libcairn_native.so   (decode NIF, links FFmpeg)
#   plugins/cairn-ort     -> libcairn_ort.so      (inference NIF)
#   plugins/cairn-detect  -> cairn-detect         (canary / parity binary)
#
# Cross, never qemu (D-C3): NIFs and the canary are the only arch-native
# artifacts; BEAM bytecode is arch-neutral and ERTS comes from the arm64
# release build. Runs on any amd64 Debian trixie with:
#
#   dpkg --add-architecture arm64 && apt-get update
#   apt-get install gcc-aarch64-linux-gnu pkg-config clang \
#     libavcodec-dev:arm64 libavformat-dev:arm64 libavutil-dev:arm64 \
#     libswscale-dev:arm64 libswresample-dev:arm64 libavfilter-dev:arm64 \
#     libavdevice-dev:arm64
#   rustup target add aarch64-unknown-linux-gnu   # rust >= 1.88
#
# Trixie's distro FFmpeg is 7.1.x — the same major.minor the crates' pinned
# rsmpeg feature (ffmpeg7_1) binds and the same sonames (libavcodec.so.61 …)
# the trixie arm64 runtime stage provides, so the qcs6490 custom FFmpeg
# cross-build is not needed. `ort-load-dynamic` means no ORT link input
# either: the NIF dlopens the runtime's libonnxruntime.so.1 (base ORT
# 1.26.0, the spike-proven triple with onnxruntime-qnn 2.4.0 / QAIRT
# 2.48.40 — see research/qairt-licensing.md in the tier1-container plan).
#
# Usage: build-rust-aarch64.sh [DIST_DIR]   (default: dist/aarch64)
set -euo pipefail

cd "$(dirname "$0")/../.."
DIST="${1:-dist/aarch64}"
TARGET=aarch64-unknown-linux-gnu

# Target-specific rustflags override each crate's `[build] rustflags`, which
# bake an x86 /opt/ffmpeg7 DT_RPATH the target link must not inherit. The
# distro arm64 libs live on the default search path, so no replacement rpath.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS=""
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
# Same story for the crates' `[env] FFMPEG_PKG_CONFIG_PATH` (x86 tree):
# the environment wins over cargo [env], steering rusty_ffmpeg at the arm64
# .pc files. openssl-sys is a host-only build-dep (ort-sys) — never crosses.
export FFMPEG_PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig
export PKG_CONFIG_ALLOW_CROSS=1

# `gles` stays off: tier-1 decodes on CPU (Venus/GL never bound at substream
# res — tier1-container plan, risks ¶3).
for crate in cairn-detect cairn-native cairn-ort; do
  (cd "plugins/$crate" &&
    cargo build --release --target "$TARGET" --features ort-load-dynamic)
done

mkdir -p "$DIST"
cp plugins/cairn-detect/target/$TARGET/release/cairn-detect \
  plugins/cairn-native/target/$TARGET/release/libcairn_native.so \
  plugins/cairn-ort/target/$TARGET/release/libcairn_ort.so \
  "$DIST/"

for f in cairn-detect libcairn_native.so libcairn_ort.so; do
  file "$DIST/$f" | grep -q aarch64 || {
    echo "ERROR: $f is not aarch64" >&2
    exit 1
  }
done
echo "aarch64 artifacts in $DIST:"
ls -la "$DIST"
