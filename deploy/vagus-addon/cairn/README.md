# Cairn NVR

Presence-detection NVR for QCS6490 vagus boards: RTSP cameras in, events
and a live UI out, detection on the Hexagon HTP through the tier-1 model
ladder (YOLOX m/tiny/nano baked in, Apache-2.0; yolo26 packs install
separately into `/data` and take over the top rungs when present).

## Prerequisites

- vagus ≥ 0.7.3 on a DSP board (Dragon Q6A / Rubik Pi 3).
- **One manual step — upload the DSP skeleton library.** Qualcomm's HTP
  skel is delivered by the operator, never by an image. Get the exact
  matching version from the same wheel this image's QNN stack ships
  (QAIRT 2.48.40):

  ```
  pip download onnxruntime-qnn==2.4.0 --no-deps -d . \
    --platform manylinux_2_34_aarch64 --only-binary=:all: \
    --implementation cp --python-version 3.12 --abi cp312
  unzip -j onnxruntime_qnn-2.4.0-*.whl onnxruntime_qnn/libQnnHtpV68Skel.so
  ```

  then upload `libQnnHtpV68Skel.so` in the vagus admin panel (DSP section,
  `POST /dsp`). Once per board; survives add-on updates. Without it the
  add-on refuses to start with a message naming the panel.

## Install

1. Add this repository in the vagus store
   (`https://github.com/bbangert/cairn-addons`).
2. Install "Cairn NVR" and place your `config.yml` in the add-on's config
   directory (`addon_configs/cairn/config.yml` under the vagus data root,
   mounted read-only at `/config`). Cameras, detection groups and
   profiles: see the cairn docs. All state lives in `/data`.
3. The UI is on the host directly at port 4000 (`host_network`).

## Known open point

- CPU governor: QNN inference measures ~2.3× vs CPU under `schedutil`
  and 3.6–5.6× under `performance`. Who pins the governor at boot is a
  host decision, not this add-on's — until settled, benchmark claims
  assume `performance`.

## Licenses

The image bundles: ONNX Runtime (MIT), Qualcomm QAIRT runtime libraries
(Qualcomm AI Stack License — notices at `/opt/qnn`, redistributed as
incorporated in this application), fastrpc userspace (BSD-3-Clause),
YOLOX models (Apache-2.0). The DSP skel is operator-supplied and never
redistributed here.
