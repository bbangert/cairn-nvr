# Shipped models — the Apache rungs only

The tier-1 ladder's Apache-2.0 rungs, baked into the container image
(D-C2, tier1-container plan). AGPL models (the yolo26 family) are never
placed here — they distribute as cairn-models packs into the data dir,
and config skips their rungs with a load warning until a pack is
installed. The image must be complete on these rungs alone.

| File | sha256 | Provenance |
|---|---|---|
| `yolox_m_qdq.onnx` | `6e77e4ff8a8e9eacb6b8e0eb9f62c56c16e14592222723077d23991b4376824a` | w8a16 QDQ export of YOLOX-m 640 (tools/qdq-export, model-menu-htp 2026-08-14); menu-benched on-board (`/data/cairn-bench/yolox_m-qdq.onnx`, p50 48.5 ms), boundary run owed |
| `yolox_nano_qdq.onnx` | `e4bb2552c6f3c810ae6fc40686f6b4cac5e21eab885b868e6469a2c87098627d` | w8a16 QDQ export of YOLOX-nano 416 (tools/qdq-export); the artifact the tier1-capacity ladder measured on-board 2026-08-14 (`/data/cairn-bench/yolox_nano-qdq-a16.onnx`) |
| `yolox_tiny_qdq.onnx` | `10dd2645b95a5a4e46092844f8c4f84ace8180fd3ae0afebdf5a233231ee6ab5` | w8a16 QDQ export of YOLOX-tiny 416 (tools/qdq-export, model-menu-htp 2026-08-14); the artifact the tier1-boundary ladder measured 2026-08-15 |
| `coco.names` | — | 80-class dense COCO list (yolox head order; copy of `plugins/cairn-detect/coco.names`) |

YOLOX is Apache-2.0 (Megvii, github.com/Megvii-BaseDetection/YOLOX);
`LICENSE` here is that license's text and ships with the models (the same
notice obligation the image honors for the QAIRT libs).
Quantization is byte-idempotent, so re-running tools/qdq-export on the
same fp32 export and calibration set reproduces these bytes — the
sha256s above are the identity check.

Paths here are what `priv/profiles/qcs6490-tier1.yml` names
(`models/…` resolves against the node's working directory — `/app` in
the image, the repo root in dev).
