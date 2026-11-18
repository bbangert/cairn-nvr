# Cairn NVR (Rockchip)

Presence-detection NVR for RK3566 vagus boards (Home Assistant Green): RTSP
cameras in, events and a live UI out.

**Not released.** A group on the shipped `rk3566-tier1` profile decodes
through MPP, scales through the RGA and detects on the NPU. On a profile
of your own, decode is software unless it says `decoder: rkmpp` and
detection runs on the CPU unless it says `backend: rknn`; a YOLOX-tiny pass
at 416 takes about 650 ms there against 47 on the NPU. `backend: rknn` needs
Rockchip's `librknnrt.so`, whose licence does not permit
shipping it in the image: at first start Cairn downloads it from Rockchip's
own repository (`airockchip/rknn-toolkit2` at a pinned commit), keeps it only
if its sha256 matches the pin, and stores it as `/data/artifacts/<sha256>`;
later starts check it again and never re-download a verified file. Offline,
the UI comes up and the config error says the library is missing and why the
last download failed. While it is missing, a config with a camera on an
`rknn` profile is refused whole: **no** camera runs or records, the others
included, until a retry succeeds. A config with no camera on `rknn` at most
warns. In a hand-run container, `CAIRN_RKNN_LIBRARY` set to a file of your
own replaces the download. The image also
carries Rockchip's MPP and librga libraries and the add-on grants their device
nodes: `decoder: rkmpp` decodes through MPP and scales through the RGA, and
`decoder: auto` never picks it.

## What `rk3566-tier1` carries

Up to nine cameras with detection. Up to four run YOLOX-s at 640; five to
nine run YOLOX-tiny at 416, each measured at 1.84 detection passes a second
at nine; a tenth is refused at config load. Both limits were measured on a
Home Assistant Green: what runs out is the engine's one RKNN context, not
decode or memory (`docs/evidence/rk3566-capacity-20261118.md`).

## Prerequisites

- An RK3566 vagus board. Only the Home Assistant Green has run this.
- Network on the first start, for the runtime library and the profile's two
  models (about 24 MB). Nothing is uploaded by hand.

## Install

1. Add the repository that carries this add-on in the vagus store.
2. Install "Cairn NVR (Rockchip)" and place your `config.yml` in the add-on's
   config directory (mounted read-only at `/config`). vagus creates that
   directory on the first start, which therefore runs with no cameras:
   restart once the file is there. Name the shipped `rk3566-tier1` from a
   plugin group (with `allow_experimental: true`) to detect on the NPU: its
   `.rknn` models download at first start into `/data/artifacts`, and until
   they have, the config is refused with an error naming what is missing.
   See `docs/profile-authoring.md`. All state lives in `/data`.
3. The UI is on the host directly at port 4000 (`host_network`).

## Known open points

- `rk3566-tier1` is `experimental: true`, which is why a group must say
  `allow_experimental: true` to use it: `rknn` has not finished a soak.
- Every `rknn` run so far was a hand-started container. Installed through
  vagus, this add-on has only run on the CPU.

## Licenses

The image bundles: ONNX Runtime (MIT); Rockchip MPP (Apache-2.0, nearly
half its files alternatively MIT; built without its ION allocator, whose
header is GPLv2) and librga (Apache-2.0), each built with its own copies of MIT DRM
headers — texts at `/opt/rockchip/licenses`; and YOLOX models (Apache-2.0).
Rockchip's RKNN runtime is not redistributable and is not in the image.
