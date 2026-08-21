# Shipped models — the Apache rungs only

The tier-1 ladder's Apache-2.0 rungs, baked into the container image
(D-C2, tier1-container plan). AGPL models (the yolo26 family) are never
placed here — they distribute as cairn-models packs into the data dir,
and config skips their rungs with a load warning until a pack is
installed. The image must be complete on these rungs alone.

These are the fixed-quantization exports (qdq-reexport campaign,
2026-08-20/21): `get_qnn_qdq_config` + plain MinMax, score sigmoids
pinned, every artifact through the qparam gate, CPU score parity AND
the on-board HTP score leg (all rungs at HTP ≈ CPU on real clips —
the shipped audit record `docs/evidence/qdq-reexport-htp-20260821.md`).
Their predecessors carried two export defects (baked score ceilings +
an HTP-only score multiplication, `docs/npu-backends.md`) and must not
ship again; the width-suffixed names exist so a stale defective file
can never satisfy a ladder rung path.

| File | sha256 | Provenance |
|---|---|---|
| `yolox_m-qdq-a8.onnx` | `5c54525c31dd5c5743b55d7c596c384dca275e4acb9c34b1ba650fa329cefca6` | w8a8 QDQ of YOLOX-m 640; HTP leg PASS (person-window medians 0.999–1.025), bench p50 38.62 ms governor-pinned |
| `yolox_s-qdq-a8.onnx` | `3e30784983d01897db208a009ab6e99e089cff59b85a0a7f704d816bc6003ab8` | w8a8 QDQ of YOLOX-s 640; HTP leg PASS (medians 1.075), bench p50 17.17 ms — the a8 refund rung (2.49x vs its a16) |
| `yolox_tiny-qdq-a8.onnx` | `4c2a364b8f9375896381b981995d2bc98aa94bfc6f7f4f0d240fa0b38eb7b74a` | w8a8 QDQ of YOLOX-tiny 416; HTP leg PASS (medians 1.108–1.179), bench p50 8.55 ms |
| `yolox_nano-qdq-a16.onnx` | `b36cdc926423fa441ba6772c60501e794621fcca82d4e905d8a2c58436ed8050` | w8a16 QDQ of YOLOX-nano 416 (nano's a8 collapses per-frame); HTP leg PASS (medians 0.999–1.004), bench p50 10.38 ms; carries the ladder's one boundary-measured budget |
| `coco.names` | — | 80-class dense COCO list (yolox head order; copy of `plugins/cairn-detect/coco.names`) |

YOLOX is Apache-2.0 (Megvii, github.com/Megvii-BaseDetection/YOLOX);
`LICENSE` here is that license's text and ships with the models (the same
notice obligation the image honors for the QAIRT libs).
Quantization is byte-deterministic, so re-running tools/qdq-export on the
same fp32 export and calibration set reproduces these bytes — the
sha256s above are the identity check, and they match the full
manifest in `docs/evidence/qdq-reexport-htp-20260821.md`.

The a8 rungs read ~3–18% hot on the HTP relative to CPU (the EP's 8-bit
sigmoid qparam vs the graph's pinned 1/256): a floor tuned on an a16
rung is conservative on an a8 rung. See the ladder file's note.

Paths here are what `priv/profiles/qcs6490-tier1.yml` names
(`models/…` resolves against the node's working directory — `/app` in
the image, the repo root in dev).
