# Cairn NVR (Rockchip)

Presence-detection NVR for RK3566 vagus boards (Home Assistant Green): RTSP
cameras in, events and a live UI out.

**Not released.** Decode is software unless a profile says `decoder: rkmpp`.
Detection runs on the CPU unless a group names an `rknn` profile, such as the
shipped `rk3566-tier1`, to run it on the NPU. `backend: rknn` needs
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

## Licenses

The image bundles: ONNX Runtime (MIT); Rockchip MPP (Apache-2.0, nearly
half its files alternatively MIT; built without its ION allocator, whose
header is GPLv2) and librga (Apache-2.0), each built with its own copies of MIT DRM
headers — texts at `/opt/rockchip/licenses`; and YOLOX models (Apache-2.0).
Rockchip's RKNN runtime is not redistributable and is not in the image.
