# Cairn NVR (Rockchip)

Presence-detection NVR for RK3566 vagus boards (Home Assistant Green): RTSP
cameras in, events and a live UI out.

**Not released.** Decode is software unless a profile says `decoder: rkmpp`.
Detection runs on the CPU. The image carries the RKNN engine, but `backend: rknn` needs Rockchip's `librknnrt.so`,
which is not in the image (it must be on the loader's path or named by
`CAIRN_RKNN_LIBRARY`), and this add-on has no way to supply either yet — so
`backend: rknn` runs only in a hand-run container for now. The image also
carries Rockchip's MPP and librga libraries and the add-on grants their device
nodes: `decoder: rkmpp` decodes through MPP and scales through the RGA, and
`decoder: auto` never picks it.

## Install

1. Add the repository that carries this add-on in the vagus store.
2. Install "Cairn NVR (Rockchip)" and place your `config.yml` in the add-on's
   config directory (mounted read-only at `/config`). vagus creates that
   directory on the first start, which therefore runs with no cameras:
   restart once the file is there. No shipped profile runs on this board
   yet — `rk3566-lowfps` names a placeholder `.rknn` and no CPU twin. Copy
   `priv/profiles/generic-ort.yml` under a name of your own into a directory
   beside your config (`/config/profiles`, say), list that directory under
   `profile_dirs:`, and point the copy's `model.onnx` at one of the baked
   FP32 models, `models/yolox_tiny.onnx` (`input_size: 416`) or
   `models/yolox_s.onnx` (`input_size: 640`) — see
   `docs/profile-authoring.md`. All state lives in `/data`.
3. The UI is on the host directly at port 4000 (`host_network`).

## Licenses

The image bundles: ONNX Runtime (MIT); Rockchip MPP (Apache-2.0, nearly
half its files alternatively MIT; built without its ION allocator, whose
header is GPLv2) and librga (Apache-2.0), each built with its own copies of MIT DRM
headers — texts at `/opt/rockchip/licenses`; and YOLOX models (Apache-2.0).
Rockchip's RKNN runtime is not redistributable and is not in the image.
