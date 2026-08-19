# syntax=docker/dockerfile:1
# The in-VM detection stack as a vagus add-on image (tier1-container plan).
# Two arch targets:
#   linux/arm64 — the shipped add-on (QCS6490; QNN/HTP via the dsp: true bind)
#   linux/amd64 — the x86 smoke build (sw decode, ORT CPU; qnn refuses loudly)
# Rust artifacts cross-compile on the build host (D-C3); only the BEAM release
# stage runs under emulation, because BEAM bytecode is arch-neutral and ERTS
# comes from the arm64 hexpm image.
#
# The QAIRT libraries ship under Qualcomm's AI Stack License, which permits
# object-code redistribution incorporated in an application but not standalone
# — the wheel is the licensed channel, its notice files must stay beside the
# libs, and the Qualcomm .so files must not be stripped. Verdict + obligations:
# .claude/plans/tier1-container/research/qairt-licensing.md.

ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_TAG=trixie-20260713

# ---------------------------------------------------------------------------
# Rust artifacts: the two NIFs and the cairn-detect canary, plus (arm64) the
# fastrpc userspace. Runs on the build platform, links for the target.
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
  # board build so both arches dlopen the pinned base ORT; the per-crate
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
case "$TARGETARCH" in
arm64)
  ORT_TGZ=onnxruntime-linux-aarch64-1.26.0.tgz
  ORT_SHA=34ff1c2d0f12e2cf3d33a0c5f82e39792e1d581fbd6968fd7c30d173654be01a
  ;;
amd64)
  ORT_TGZ=onnxruntime-linux-x64-1.26.0.tgz
  ORT_SHA=1254da24fb389cf39dc0ff3451ab48301740ffbfcbaf646849df92f80ee92c57
  ;;
esac
curl -fsSL -o /tmp/ort.tgz \
  "https://github.com/microsoft/onnxruntime/releases/download/v1.26.0/$ORT_TGZ"
echo "$ORT_SHA /tmp/ort.tgz" | sha256sum -c -
tar -xzf /tmp/ort.tgz -C /tmp
ORT_DIR="/tmp/${ORT_TGZ%.tgz}"
cp -a "$ORT_DIR"/lib/libonnxruntime.so* \
  "$ORT_DIR"/lib/libonnxruntime_providers_shared.so /opt/ort/
cp "$ORT_DIR"/LICENSE "$ORT_DIR"/ThirdPartyNotices.txt /opt/ort/

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
# The Elixir release, built on the target platform (qemu under buildx for
# arm64 — BEAM-only work, the NIFs arrive prebuilt from native-build).
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_TAG} AS release-build

# pkg-config + libssl-dev: ex_dtls's bundlex native resolves openssl through
# pkg-config. GitHub's ubuntu runners preinstall both, which is why ci.yml
# compiles the same deps with only ffmpeg — this image starts bare.
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential git pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
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

# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}-slim AS runtime

# Distro FFmpeg 7.1 — the same major.minor the NIFs' rsmpeg feature binds and
# the same sonames the native-build stage cross-linked against.
# libyaml-0-2 + libbsd0: fastrpc's libcdsprpc.so links both (YAML_LIBS /
# BSD_LIBS in its Makefile.am) — without them the QNN stub's dlopen chain
# fails on arm64 before FastRPC reaches the DSP. procps: four modules
# (FFmpegPort stall-kill, canary teardown, probe, clip_remux) signal OS
# processes via `System.cmd("kill", …)`, and slim ships no kill binary —
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
# Node-level QNN facts (runtime.exs → Cairn.Native.Config): the EP plugin
# location in THIS image and the QCS6490 identity (soc 35, HTP v68 — platform
# detection fails without them). Inert unless a profile says backend: qnn; on
# amd64 the missing library file makes qnn a stated refusal, never silent CPU.
ENV CAIRN_QNN_LIBRARY=/opt/qnn/libonnxruntime_providers_qnn.so \
  CAIRN_QNN_SOC_MODEL=35 \
  CAIRN_QNN_HTP_ARCH=68

COPY --from=ort-libs /opt/ort /opt/ort
COPY --from=ort-libs /opt/qnn /opt/qnn
COPY --from=native-build /dist/fastrpc/ /opt/qnn/
RUN echo /opt/ort > /etc/ld.so.conf.d/cairn.conf \
  && echo /opt/qnn >> /etc/ld.so.conf.d/cairn.conf \
  && ldconfig

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

# No USER: the QNN-touching process must run as root to pass the fastrpc
# nodes' root:root 0600 DAC — the host never chmods them (no udev on Nerves),
# and vagus add-on containers run as root by design.
CMD ["bin/cairn", "start"]
