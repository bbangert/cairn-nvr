# syntax=docker/dockerfile:1
# The in-VM detection stack as a vagus add-on image (tier1-container plan).
# CAIRN_BOARD picks the vendor layer:
#   generic  — linux/arm64 is the QCS6490 add-on (QNN/HTP via the dsp: true
#              bind); linux/amd64 is the x86 smoke build (sw decode, ORT CPU;
#              qnn refuses loudly)
#   rockchip — linux/arm64 only, the RK3566 add-on: sw or MPP decode, ORT
#              CPU or the RKNN engine NIF (librknnrt is not in the image:
#              the release downloads it at first start, pinned by sha256);
#              the MPP and librga userspace that `decoder: rkmpp` and the
#              probe binary's `--rk-probe` load is carried
# Both are `FROM core`, the release built with no board. The Rockchip board
# is not compiled into it: `board-build` builds boards/cairn_rockchip alone
# as a board directory, which the image attaches at boot through
# CAIRN_BOARD_DIR.
# Rust artifacts and the Rockchip libraries cross-compile on the build host
# (D-C3). What compiles under emulation is the release and the board
# directory: BEAM code, which is arch-neutral, and the Hex dependencies' own
# C NIFs. ERTS comes from the arm64 hexpm image.
#
# The QAIRT libraries (generic arm64) ship under Qualcomm's AI Stack License,
# which permits object-code redistribution incorporated in an application but
# not standalone — the wheel is the licensed channel, its notice files must
# stay beside the libs, and the Qualcomm .so files must not be stripped.
# Verdict + obligations: .claude/plans/tier1-container/research/qairt-licensing.md.

# mise.toml pins the same pair for CI and local work; a move changes both,
# and tools/ci/check-toolchain.sh fails CI when they differ.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_TAG=trixie-20260713
# generic | rockchip. The switch is `FROM vendor-${CAIRN_BOARD}`: any other
# value names no stage, so BuildKit fails trying to pull vendor-<value> as an
# image.
ARG CAIRN_BOARD=generic
# `core`'s labels. The contract is `Cairn.Stage.contract/0`'s, which
# release-build checks it against; the revision is the workflow's commit.
ARG CAIRN_CONTRACT=1
ARG CAIRN_REVISION=

# ---------------------------------------------------------------------------
# Rust artifacts: the two NIFs and the cairn-detect canary, plus (arm64) the
# fastrpc userspace.
# Runs on the build platform, links for the target.
FROM --platform=$BUILDPLATFORM rust:1.97-trixie AS native-build
ARG TARGETARCH

RUN <<'EOS'
set -eux
if [ "$TARGETARCH" = "arm64" ]; then
  dpkg --add-architecture arm64
  apt-get update
  apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu libc6-dev-arm64-cross pkg-config clang \
    libavcodec-dev:arm64 libavformat-dev:arm64 libavutil-dev:arm64 \
    libswscale-dev:arm64 libswresample-dev:arm64 libavfilter-dev:arm64 \
    libavdevice-dev:arm64 \
    autoconf automake libtool libyaml-dev:arm64 libbsd-dev:arm64
  rustup target add aarch64-unknown-linux-gnu
else
  apt-get update
  apt-get install -y --no-install-recommends \
    pkg-config clang \
    libavcodec-dev libavformat-dev libavutil-dev \
    libswscale-dev libswresample-dev libavfilter-dev libavdevice-dev
fi
rm -rf /var/lib/apt/lists/*
EOS

WORKDIR /src
COPY plugins plugins
COPY tools/container/build-rust-aarch64.sh tools/container/

RUN <<'EOS'
set -eux
if [ "$TARGETARCH" = "arm64" ]; then
  tools/container/build-rust-aarch64.sh /dist
else
  # Native build for the smoke image. Same ort-load-dynamic linkage as the
  # arm64 build so both arches dlopen the pinned base ORT; the per-crate
  # cargo configs point at a dev-container /opt/ffmpeg7 that doesn't exist
  # here, so steer rusty_ffmpeg at the distro tree and drop the rpath.
  export FFMPEG_PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
  export RUSTFLAGS=""
  for crate in cairn-detect cairn-native cairn-ort; do
    (cd "plugins/$crate" && cargo build --release --features ort-load-dynamic)
  done
  mkdir -p /dist
  cp plugins/cairn-detect/target/release/cairn-detect \
    plugins/cairn-native/target/release/libcairn_native.so \
    plugins/cairn-ort/target/release/libcairn_ort.so /dist/
fi
EOS

# fastrpc userspace (arm64 only): libcdsprpc.so, which libQnnHtpV68Stub.so
# NEEDs by its unsuffixed name (device-gate trap — a missing unsuffixed name
# fails device creation with no DSP-level error). Built from the same
# BSD-3-Clause source at the same pin as nerves_system_vagus's fastrpc
# package, including its DEFAULT_DSP_SEARCH_PATHS patch: the search list is a
# compile-time constant and the host's shells arrive at /usr/lib/dsp/{cdsp,adsp}
# via the dsp: true bind, which the stock list does not cover.
RUN <<'EOS'
set -eux
# Always present so the runtime COPY of /dist/fastrpc has a source on amd64.
mkdir -p /dist/fastrpc
[ "$TARGETARCH" = "arm64" ] || exit 0
git clone --depth 1 --branch v1.0.4 https://github.com/qualcomm/fastrpc /tmp/fastrpc
cd /tmp/fastrpc
git rev-parse HEAD | grep -q 8572ae1c45d38a4dc8853b1b9b6738207ab1ce94
sed -i 's|DEFAULT_DSP_SEARCH_PATHS='\''";/usr/lib/rfsa/adsp;/usr/lib/dsp;"'\''|DEFAULT_DSP_SEARCH_PATHS='\''";/usr/lib/dsp/cdsp;/usr/lib/dsp/adsp;/usr/lib/rfsa/adsp;/usr/lib/dsp;"'\''|' src/Makefile.am
grep -q '/usr/lib/dsp/cdsp' src/Makefile.am
autoreconf -fi
PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig \
  ./configure --host=aarch64-linux-gnu --prefix=/usr
make -j"$(nproc)"
make install DESTDIR=/tmp/fastrpc-out
mkdir -p /dist/fastrpc
cp -a /tmp/fastrpc-out/usr/lib/libcdsprpc.so* /dist/fastrpc/
cp LICENSE.txt /dist/fastrpc/LICENSE.fastrpc
EOS

# ---------------------------------------------------------------------------
# The Rockchip board's NIF and probe binary, on native-build's toolchain. A
# stage of its own so that a board edit leaves the core image's layers
# alone. On arm64 the script's core builds find native-build's targets
# fresh; the board crate compiles the core crates it links again, into its
# own target directory.
FROM native-build AS board-native
ARG TARGETARCH
COPY boards/cairn_rockchip/native boards/cairn_rockchip/native
RUN <<'EOS'
set -eux
if [ "$TARGETARCH" = "arm64" ]; then
  CAIRN_BOARD=rockchip tools/container/build-rust-aarch64.sh /dist
else
  # For the smoke's x86 board directory, built as native-build builds amd64.
  export FFMPEG_PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
  export RUSTFLAGS=""
  (cd boards/cairn_rockchip/native/cairn_rockchip && cargo build --release --features ort-load-dynamic)
  out=boards/cairn_rockchip/native/cairn_rockchip/target/release
  mkdir -p /dist/rockchip /dist/rockchip-nif
  cp "$out/cairn-rockchip-probe" /dist/rockchip/
  cp "$out/libcairn_rockchip.so" /dist/rockchip-nif/
fi
EOS

# ---------------------------------------------------------------------------
# Runtime inference libraries, fetched pinned. Base ORT (MIT) for both arches;
# the QNN EP plugin + QAIRT host libs (arm64 only) from the licensed wheel —
# the exact spike-proven triple: ORT 1.26.0 × onnxruntime-qnn 2.4.0 × QAIRT
# 2.48.40 (the wheel's libQnnHtp.so carries AISW_VERSION 2.48.40).
FROM --platform=$BUILDPLATFORM debian:${DEBIAN_TAG}-slim AS ort-libs
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*

RUN <<'EOS'
set -eux
mkdir -p /opt/ort /opt/qnn
# microsoft/onnxruntime went 404 on 2026-11-17; the sha256 checks make the
# hosts irrelevant.
case "$TARGETARCH" in
arm64)
  # Our byte-identical mirror first, Microsoft's release second.
  ORT_TGZ=onnxruntime-linux-aarch64-1.26.0.tgz
  curl -fsSL -o /tmp/ort.tgz \
    "https://github.com/bbangert/cairn-nvr/releases/download/ort-1.26.0/$ORT_TGZ" ||
    curl -fsSL -o /tmp/ort.tgz \
      "https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/$ORT_TGZ"
  echo "34ff1c2d0f12e2cf3d33a0c5f82e39792e1d581fbd6968fd7c30d173654be01a /tmp/ort.tgz" | sha256sum -c -
  tar -xzf /tmp/ort.tgz -C /tmp
  ORT_DIR="/tmp/${ORT_TGZ%.tgz}"
  cp -a "$ORT_DIR"/lib/libonnxruntime.so* \
    "$ORT_DIR"/lib/libonnxruntime_providers_shared.so /opt/ort/
  cp "$ORT_DIR"/LICENSE "$ORT_DIR"/ThirdPartyNotices.txt /opt/ort/
  ;;
amd64)
  # No copy of the x64 tarball survived. Microsoft's NuGet package is the
  # same build (its arm64 libs are byte-identical to the tarball's) but ships
  # only the unversioned file, so the tarball's links are recreated.
  curl -fsSL -o /tmp/ort.nupkg \
    https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.26.0/microsoft.ml.onnxruntime.1.26.0.nupkg
  echo "50cc3772668f04b8373ad65a36793f94699bc4e818f6e691fc68f1578c38ce42 /tmp/ort.nupkg" | sha256sum -c -
  unzip -j /tmp/ort.nupkg -d /tmp/ort \
    runtimes/linux-x64/native/libonnxruntime.so \
    runtimes/linux-x64/native/libonnxruntime_providers_shared.so \
    LICENSE ThirdPartyNotices.txt
  cp /tmp/ort/libonnxruntime.so /opt/ort/libonnxruntime.so.1.26.0
  ln -s libonnxruntime.so.1.26.0 /opt/ort/libonnxruntime.so.1
  ln -s libonnxruntime.so.1 /opt/ort/libonnxruntime.so
  cp /tmp/ort/libonnxruntime_providers_shared.so /tmp/ort/LICENSE \
    /tmp/ort/ThirdPartyNotices.txt /opt/ort/
  ;;
esac

if [ "$TARGETARCH" = "arm64" ]; then
  WHL=onnxruntime_qnn-2.4.0-cp312-cp312-manylinux_2_34_aarch64.whl
  curl -fsSL -o /tmp/qnn.whl \
    "https://files.pythonhosted.org/packages/09/9f/13af655e9f76f8f571c3cf59e7befad3129ba80218df3eb5d75a264ae66d/$WHL"
  echo "3b09af275e4b1cc0f7010b57d08c3070e3ad7cf95a3ad816201c9cafc6c6e3f7 /tmp/qnn.whl" | sha256sum -c -
  # Minimal HTP set for QCS6490 (v68) + the plugin EP the config's
  # qnn.library key names; backend libs must sit beside the EP library.
  # No skel: operator-uploaded via POST /dsp, bound at /usr/lib/rfsa/adsp.
  unzip -j /tmp/qnn.whl \
    onnxruntime_qnn/libonnxruntime_providers_qnn.so \
    onnxruntime_qnn/libQnnHtp.so \
    onnxruntime_qnn/libQnnHtpV68Stub.so \
    onnxruntime_qnn/libQnnSystem.so \
    onnxruntime_qnn/libQnnHtpPrepare.so \
    onnxruntime_qnn/LICENSE \
    onnxruntime_qnn/Qualcomm_LICENSE.pdf \
    onnxruntime_qnn/ThirdPartyNotices.txt \
    onnxruntime_qnn/Privacy.md \
    -d /opt/qnn
fi
EOS

# ---------------------------------------------------------------------------
# Rockchip vendor userspace (CAIRN_BOARD=rockchip), cross-built from pinned
# source: MPP (hardware video codec API; Apache-2.0 + MIT) and librga (RGA 2D
# engine API; Apache-2.0). librknnrt is not built, fetched or copied here:
# its licence does not permit redistribution, so `Cairn.Artifacts` downloads
# it on the board at run time.
FROM --platform=$BUILDPLATFORM debian:${DEBIAN_TAG}-slim AS rockchip-libs
ARG TARGETARCH

# g++ for MPP too, although the library is C: its CMakeLists adds -fPIC and
# -march only once it has identified the C++ compiler as GNU, and the link
# fails on non-PIC objects without it. librga carries its own copy of the
# DRM uapi headers and issues the ioctls itself, so no libdrm is needed.
RUN <<'EOS'
set -eux
[ "$TARGETARCH" = "arm64" ] || exit 0
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl cmake meson ninja-build \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross
rm -rf /var/lib/apt/lists/*
EOS

RUN <<'EOS'
set -eux
# Off arm64 the stage is these empty directories: vendor-rockchip refuses
# that platform before it copies from here.
mkdir -p /opt/rockchip/lib /opt/rockchip/licenses /dist/models
[ "$TARGETARCH" = "arm64" ] || exit 0
mpp_rev=c08762ebfadeb4e986d2fed993bc7a54862d3ebe
curl -fsSL -o /tmp/mpp.tar.gz \
  https://github.com/rockchip-linux/mpp/archive/${mpp_rev}.tar.gz
echo "82da3d7ea5926021d48fcaf56cde2e6cb39c3eaad11e06f3cf2a9bfbb3133852 /tmp/mpp.tar.gz" | sha256sum -c -
curl -fsSL -o /tmp/librga.tar.gz \
  https://github.com/JeffyCN/mirrors/archive/57a1067a246c71fa6c9a355d1668884fda155dd5.tar.gz
echo "c539db8a4059d13975e12f596fbe6fd0ba818288cc067300c5e00f3a9f0442e0 /tmp/librga.tar.gz" | sha256sum -c -
mkdir /tmp/mpp /tmp/librga
tar -xzf /tmp/mpp.tar.gz -C /tmp/mpp --strip-components=1
tar -xzf /tmp/librga.tar.gz -C /tmp/librga --strip-components=1

# MPP's ION allocator compiles in Android's ion.h, which carries plain GPLv2
# text. The add-on grants no /dev/ion, so that allocator could never be
# chosen here. The files go too, so a pin bump that brings a reference back
# fails the build.
sed -i '/allocator\/allocator_ion\.c/d' /tmp/mpp/osal/CMakeLists.txt
sed -i '/MPP_BUFFER_TYPE_ION) != 0) ? allocator_ion :/d' /tmp/mpp/osal/mpp_allocator.c
rm /tmp/mpp/osal/allocator/allocator_ion.c /tmp/mpp/osal/allocator/ion.h

# The root path keeps MPP's find_library(mvec) probe in the arm64 sysroot
# instead of the build host's.
cat > /tmp/aarch64.cmake <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_FIND_ROOT_PATH /usr/aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
cmake -S /tmp/mpp -B /tmp/mpp-out -G Ninja -DCMAKE_TOOLCHAIN_FILE=/tmp/aarch64.cmake \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF
# librockchip_mpp alone: not the legacy librockchip_vpu, the static archive
# or the test utils.
cmake --build /tmp/mpp-out --target rockchip_mpp -j"$(nproc)"
cp -a /tmp/mpp-out/mpp/librockchip_mpp.so* /opt/rockchip/lib/
# A shared object links with undefined symbols, so a leftover reference to the
# removed allocator would only fail at load time on the board.
aarch64-linux-gnu-nm -D /opt/rockchip/lib/librockchip_mpp.so.1 > /tmp/mpp.syms
if grep -q allocator_ion /tmp/mpp.syms; then
  echo "librockchip_mpp still references allocator_ion" >&2
  exit 1
fi

cat > /tmp/aarch64.meson <<'EOF'
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
meson setup /tmp/librga-out /tmp/librga --cross-file /tmp/aarch64.meson \
  --buildtype=release --prefix=/opt/rockchip --libdir=lib
meson compile -C /tmp/librga-out
DESTDIR=/tmp/librga-stage meson install -C /tmp/librga-out
cp -a /tmp/librga-stage/opt/rockchip/lib/librga.so* /opt/rockchip/lib/

cp /tmp/mpp/LICENSES/Apache-2.0 /opt/rockchip/licenses/mpp-Apache-2.0
cp /tmp/mpp/LICENSES/MIT /opt/rockchip/licenses/mpp-MIT
cp /tmp/librga/COPYING /opt/rockchip/licenses/librga-COPYING
printf '%s\n' \
  'librockchip_mpp is built from rockchip-linux/mpp at commit' \
  "$mpp_rev with the ION allocator removed:" \
  'osal/allocator/allocator_ion.c and osal/allocator/ion.h are deleted, and' \
  'their references dropped from osal/CMakeLists.txt and osal/mpp_allocator.c.' \
  > /opt/rockchip/licenses/mpp-CHANGES
# Both libraries compile in their own copies of MIT DRM uapi headers, each
# with its own copyright holders, and MIT's notice has to travel with the
# object code. drm.h opens with an author comment, so the cut is the end of
# the comment holding the permission text, not of the first comment.
for f in mpp/osal/linux/drm.h mpp/osal/linux/drm_mode.h \
  librga/core/3rdparty/libdrm/include/drm/drm.h \
  librga/core/3rdparty/libdrm/include/drm/drm_mode.h \
  librga/core/3rdparty/libdrm/include/drm/drm_fourcc.h; do
  echo "$f:"
  awk '{print} /Permission is hereby granted/{f=1} f&&/\*\//{exit}' "/tmp/$f"
  echo
done > /opt/rockchip/licenses/drm-uapi-headers-NOTICE
# A pin bump that reshapes a header must not quietly drop its notice.
[ "$(grep -c 'Permission is hereby granted' /opt/rockchip/licenses/drm-uapi-headers-NOTICE)" = 5 ]

# The board crate binds these exact names — every symbol that
# boards/cairn_rockchip/native/cairn_rockchip/src/mpp/sys.rs and
# src/rga/sys.rs load. Names C callers write, such as wrapbuffer_handle or
# mpp_buffer_get_fd, are macros, and importbuffer_fd and improcess have
# C++-mangled overloads beside the extern "C" one, so only an exact
# unmangled match counts.
need() {
  lib=$1
  shift
  for sym in "$@"; do
    aarch64-linux-gnu-nm -D --defined-only "$lib" | awk '{print $NF}' | grep -qxF "$sym" \
      || { echo "$lib does not export $sym" >&2; exit 1; }
  done
}
need /opt/rockchip/lib/librga.so.2 \
  importbuffer_fd releasebuffer_handle wrapbuffer_handle_t \
  improcess imfill_t imStrError_t querystring
need /opt/rockchip/lib/librockchip_mpp.so.1 \
  mpp_create mpp_init mpp_destroy \
  mpp_packet_init mpp_packet_set_pts mpp_packet_set_eos mpp_packet_deinit \
  mpp_frame_get_width mpp_frame_get_height mpp_frame_get_hor_stride \
  mpp_frame_get_ver_stride mpp_frame_get_errinfo mpp_frame_get_discard \
  mpp_frame_get_eos mpp_frame_get_info_change mpp_frame_get_fmt \
  mpp_frame_get_color_range \
  mpp_frame_get_pts mpp_frame_get_buf_size mpp_frame_get_buffer mpp_frame_deinit \
  mpp_buffer_get_fd_with_caller mpp_buffer_group_get mpp_buffer_group_put \
  mpp_buffer_group_clear mpp_buffer_group_limit_config
EOS

# FP32 YOLOX exports (Apache-2.0). The two Megvii published are the CPU
# twins of rk3566-tier1's rungs, whose `.rknn` files the release fetches at
# first start; the third is derived from the tiny file (below).
RUN <<'EOS'
set -eux
[ "$TARGETARCH" = "arm64" ] || exit 0
base=https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0
curl -fsSL -o /dist/models/yolox_tiny.onnx "$base/yolox_tiny.onnx"
echo "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7 /dist/models/yolox_tiny.onnx" | sha256sum -c -
curl -fsSL -o /dist/models/yolox_s.onnx "$base/yolox_s.onnx"
echo "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063 /dist/models/yolox_s.onnx" | sha256sum -c -
# The twin of tiny at 640: the tiny release file with its input size
# rewritten (tools/rknn-export), published beside the rungs. No shipped
# rung names it: one context holds as many cameras on yolox_s
# (docs/evidence/rk3566-capacity-20261118.md). It stays baked because a
# second context may bring the rung back.
curl -fsSL -o /dist/models/yolox_tiny_640.onnx \
  https://github.com/bbangert/cairn-nvr/releases/download/models-rk3566-1/yolox_tiny_640.onnx
echo "6066fa79efe783a554a6f7e13792e0ee9246bc0c7b27d6eddad3f43bdd000a61 /dist/models/yolox_tiny_640.onnx" | sha256sum -c -
EOS

# ---------------------------------------------------------------------------
# The Elixir release, built on the target platform (qemu under buildx for
# arm64 — BEAM code and the Hex dependencies' C NIFs; Cairn's own NIFs arrive
# prebuilt from native-build).
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_TAG} AS release-build

# pkg-config + libssl-dev: ex_dtls's bundlex native resolves openssl through
# pkg-config. GitHub's ubuntu runners preinstall both, which is why ci.yml
# compiles the same deps with only ffmpeg — this image starts bare.
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential git pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Path dependencies (`libs/`) resolve at deps.get, so they come in with
# mix.exs. No `boards/`: this release carries no board, and CAIRN_BOARD is
# not declared in this stage, so mix.exs and config/config.exs read generic.
COPY mix.exs mix.lock ./
COPY libs libs
RUN mix deps.get --only prod
COPY config config
RUN mix deps.compile
COPY priv priv
COPY lib lib
COPY assets assets
# Compile before the asset build: app.css imports the colocated CSS that
# `mix compile` extracts into the build dir (NODE_PATH points there).
RUN mix compile
RUN mix assets.setup && mix assets.deploy
COPY --from=native-build /dist/libcairn_native.so /dist/libcairn_ort.so priv/native/
RUN mix release
# The label a board build reads must be the number the release checks
# boards against.
ARG CAIRN_CONTRACT
RUN grep -qxF "  def contract, do: $CAIRN_CONTRACT" libs/cairn_stage/lib/cairn/stage.ex

# ---------------------------------------------------------------------------
# What every image's runtime shares; `core` adds the release.
FROM debian:${DEBIAN_TAG}-slim AS runtime-base

# Distro FFmpeg 7.1 — the same major.minor the NIFs' rsmpeg feature binds and
# the same sonames the native-build stage cross-linked against.
# libyaml-0-2 + libbsd0: fastrpc's libcdsprpc.so (generic) links both
# (YAML_LIBS / BSD_LIBS in its Makefile.am) — without them the QNN stub's
# dlopen chain fails on arm64 before FastRPC reaches the DSP. procps: four
# modules (FFmpegPort stall-kill, canary teardown, probe, clip_remux) signal
# OS processes via `System.cmd("kill", …)`, and slim ships no kill binary —
# device-proven: the canary LOADED the model on the HTP, then its teardown
# raised :enoent.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ffmpeg libstdc++6 openssl libncurses6 locales ca-certificates \
    libyaml-0-2 libbsd0 procps \
  && apt-get clean && rm -f /var/lib/apt/lists/*_* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true CAIRN_DATA_DIR=/data CAIRN_CONFIG=/config/config.yml
# ort-load-dynamic builds dlopen the pinned base ORT here at startup.
ENV ORT_DYLIB_PATH=/opt/ort/libonnxruntime.so.1

COPY --from=ort-libs /opt/ort /opt/ort

# ---------------------------------------------------------------------------
# The base every board image is `FROM`: the release with no board. A board
# image adds its vendor userspace and its board directory and sets
# CAIRN_BOARD_DIR. A board built elsewhere must be built on the toolchain the
# labels name: the loader refuses another contract and the board directory
# task another ERTS.
FROM runtime-base AS core
ARG ELIXIR_VERSION
ARG OTP_VERSION
ARG CAIRN_CONTRACT
ARG CAIRN_REVISION
LABEL org.opencontainers.image.revision=$CAIRN_REVISION \
  cairn.elixir.version=$ELIXIR_VERSION \
  cairn.otp.version=$OTP_VERSION \
  cairn.contract=$CAIRN_CONTRACT

WORKDIR /app
COPY --from=release-build /app/_build/prod/rel/cairn ./
COPY --from=native-build /dist/cairn-detect /usr/local/bin/cairn-detect
# The Apache ladder rungs (D-C2: yolo26/AGPL never ships here). Profile model
# paths resolve against the node's working directory, so models/ lives in
# /app. The pack rungs stay skip-with-warning until a cairn-models pack is
# installed under /data.
COPY models models
# Pack rungs name `data/models/…`, resolved against this workdir — host-side
# that coincided with the data dir; here it must reach the /data mount or an
# installed pack would land on ephemeral container filesystem.
RUN ln -s /data /app/data

VOLUME ["/data", "/config"]
EXPOSE 4000

# No USER: on the generic board the QNN-touching process must run as root to
# pass the fastrpc nodes' root:root 0600 DAC — the host never chmods them (no
# udev on Nerves), and vagus add-on containers run as root by design.
CMD ["bin/cairn", "start"]

# ---------------------------------------------------------------------------
FROM core AS vendor-generic

# Node-level QNN facts (runtime.exs → Cairn.Native.Config): the EP plugin
# location in THIS image and the QCS6490 identity (soc 35, HTP v68 — platform
# detection fails without them). Inert unless a profile says backend: qnn; on
# amd64 the missing library file makes qnn a stated refusal, never silent CPU.
ENV CAIRN_QNN_LIBRARY=/opt/qnn/libonnxruntime_providers_qnn.so \
  CAIRN_QNN_SOC_MODEL=35 \
  CAIRN_QNN_HTP_ARCH=68

COPY --from=ort-libs /opt/qnn /opt/qnn
COPY --from=native-build /dist/fastrpc/ /opt/qnn/
RUN echo /opt/ort > /etc/ld.so.conf.d/cairn.conf \
  && echo /opt/qnn >> /etc/ld.so.conf.d/cairn.conf \
  && ldconfig

# ---------------------------------------------------------------------------
# The Rockchip board directory: boards/cairn_rockchip compiled alone, in its
# own Mix project, on release-build's image (the task refuses an ERTS other
# than the release's), then written by `mix cairn_stage.board` against the
# core release's .rel, which also refuses a release that ships the board.
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_TAG} AS board-build

WORKDIR /src/boards/cairn_rockchip
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Where the project's `../../libs/cairn_stage` path dependency points.
COPY libs/cairn_stage /src/libs/cairn_stage
COPY boards/cairn_rockchip/mix.exs boards/cairn_rockchip/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY boards/cairn_rockchip/lib lib
COPY boards/cairn_rockchip/priv/profiles priv/profiles
# Into the `priv` the task ships and `Cairn.Rockchip.Native` loads from.
COPY --from=board-native /dist/rockchip-nif/ priv/native/
RUN mix compile --warnings-as-errors
COPY --from=release-build /app/_build/prod/rel/cairn/releases /core/releases
# A NIF or profile missing from the directory would show only on the board,
# as rknn refused at preflight or an unknown-profile config error.
RUN <<'EOS'
set -eux
vsn=$(cut -d' ' -f2 /core/releases/start_erl.data)
mix cairn_stage.board --core-rel "/core/releases/$vsn/cairn.rel" --out /board
grep -qxF "{board, 'Elixir.Cairn.Rockchip.Board'}." /board/board.manifest
test -f /board/lib/cairn_rockchip-*/priv/native/libcairn_rockchip.so
test -f /board/lib/cairn_rockchip-*/priv/profiles/rk3566-tier1.yml
EOS

# The directory alone, which `--output type=local` exports for the x86 smoke.
FROM scratch AS board-dir
COPY --from=board-build /board /

# ---------------------------------------------------------------------------
# No CAIRN_QNN_* and no /opt/qnn: this board has no HTP, and runtime.exs
# merges no node qnn facts when the variables are unset.
FROM core AS vendor-rockchip
ARG TARGETARCH

RUN [ "$TARGETARCH" = "arm64" ] \
  || { echo "CAIRN_BOARD=rockchip is arm64 only (TARGETARCH=$TARGETARCH)" >&2; exit 1; }

# No extra packages: the libraries need only glibc, libstdc++ and libgcc_s,
# which the base image has. The ldd check proves it here, on the
# target platform, rather than at the first dlopen on the board.
COPY --from=rockchip-libs /opt/rockchip /opt/rockchip
RUN <<'EOS'
set -eux
echo /opt/ort > /etc/ld.so.conf.d/cairn.conf
echo /opt/rockchip/lib >> /etc/ld.so.conf.d/cairn.conf
ldconfig
for lib in /opt/rockchip/lib/librga.so.2 /opt/rockchip/lib/librockchip_mpp.so.1; do
  ldd "$lib"
  if ldd "$lib" | grep -q 'not found'; then exit 1; fi
done
EOS

COPY --from=rockchip-libs /dist/models/ /app/models/
COPY --from=board-native /dist/rockchip/ /usr/local/bin/
COPY --from=board-dir / /opt/cairn/board
ENV CAIRN_BOARD_DIR=/opt/cairn/board
# The host runs the probe as rknn's canary and CPU baseline and the loader
# loads the NIF at boot, both only on the board, so an unresolved library is
# caught here on the target platform instead.
RUN <<'EOS'
set -eux
for bin in /usr/local/bin/cairn-rockchip-probe /opt/cairn/board/lib/cairn_rockchip-*/priv/native/libcairn_rockchip.so; do
  ldd "$bin"
  if ldd "$bin" | grep -q 'not found'; then exit 1; fi
done
EOS

# ---------------------------------------------------------------------------
FROM vendor-${CAIRN_BOARD} AS runtime
