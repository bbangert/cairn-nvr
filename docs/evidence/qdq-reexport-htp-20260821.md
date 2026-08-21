# Evidence: qdq-reexport HTP verification (2026-08-20/21, board .87)

The audit record for the artifacts shipped in `models/` and the ladder
in `priv/profiles/qcs6490-tier1.yml`. Produced by
`tools/qdq-export/run_htp_campaign.sh` (board leg) and
`tools/qdq-export/htp_report.py` (verdicts); methodology and defect
background in `docs/npu-backends.md` ("Quantized-export defect
classes"). Raw evidence (ndjson, bench runs, calibration census) is
gigabytes and reproducible; this file carries the verdicts and the
identities.

## Why these artifacts exist

Every previously shipped `*-qdq` artifact carried two export defects:
mean-of-maxima calibration baking per-FPN-level score ceilings into the
graph, and the QNN EP's 16-bit sigmoid qparam rewrite disagreeing with
the graph's calibrated DQ scale — on the HTP only, every score
multiplied by the calibrated ceiling (a measured hard 0.685 cap, missed
return walks, and a CPU-EP-only verification that could not see it).
The fixed recipe: `get_qnn_qdq_config` + plain MinMax, score sigmoids
pinned (1/65536 at a16, 1/256 at a8), a post-export qparam gate, CPU
score parity, and the on-board HTP score leg below — no artifact ships
without all of them.

## HTP score leg — all 12 board-worthy rungs PASS

Acceptance: HTP ≈ the artifact's own CPU-EP distribution on the same
clips (per-frame person-window median ratio ≥ 0.9, no cap plateau, no
uniform depression — each failure shape is one defect class's
signature). Three real clips, including the two whose return walks the
defective artifacts missed.

| rung | ac86 | aeb4 | f58a |
|---|---|---|---|
| yolox_nano-qdq-a16 | 0.999 | 1.000 | 1.000 |
| yolox_tiny-qdq-a16 | 1.000 | 0.999 | 1.001 |
| yolox_tiny-qdq-a8 | 1.108 | 1.108 | 1.179 |
| yolox_s-qdq-a16 | 0.999 | 0.998 | 0.999 |
| yolox_s-qdq-a8 | 1.075 | 1.075 | 1.077 |
| yolox_m-qdq-a16 | 1.000 | 1.000 | 1.000 |
| yolox_m-qdq-a8 | 1.025 | 1.025 | 1.000 |
| yolo26n-qdq-a16 | 1.000 | 1.000 | 1.000 |
| yolo26n-416-qdq-a16 | 1.000 | 1.000 | 1.000 |
| yolo26s-qdq-a16 | 1.000 | 1.000 | 1.000 |
| yolo26m-qdq-a16 | 1.000 | 1.000 | 1.000 |
| yolov8n-qdq-a16 | 0.999 | 0.989 | 1.000 |

(Values are the person-window median per-frame ratio, HTP vs the same
artifact on the CPU EP. a8 rungs read 3–18% hot on the HTP — the EP's
8-bit sigmoid qparam vs the graph's pinned 1/256; floors tuned on a16
are conservative on a8.)

Controls, both behaving: a board CPU-EP run PASSes against the local
reference (the methodology measures models, not plumbing), and the
previously shipped defective nano grades CAP with a plateau at 0.578 —
the test demonstrably sees the defect class it exists to block, and
0.578 matches the live band measured on the wall before the fix.

## Latency (bench.sh, 1 cam, governor pinned)

| rung | p50 ms | p95 ms |
|---|---|---|
| yolox_tiny-qdq-a8 | 8.55 | 12.20 |
| yolox_nano-qdq-a16 | 10.38 | 11.08 |
| yolo26n-416-qdq-a16 | 12.30 | 12.59 |
| yolox_tiny-qdq-a16 | 12.78 | 16.86 |
| yolox_s-qdq-a8 | 17.17 | 17.74 |
| yolov8n-qdq-a16 | 21.35 | 23.86 |
| yolo26n-qdq-a16 | 24.39 | 27.06 |
| yolo26s-qdq-a16 | 35.65 | 36.35 |
| yolox_m-qdq-a8 | 38.62 | 39.14 |
| yolox_s-qdq-a16 | 42.70 | 43.18 |
| yolo26m-qdq-a16 | 52.83 | 55.06 |
| yolox_m-qdq-a16 | 58.35 | 59.46 |

The w8a8 refund that reshaped the ladder: yolox_s-a8 2.49x its a16,
tiny and m ~1.5x. yolox_nano's a8 collapses per-frame and the
yolo26/yolov8 family cannot do a8 at all (the head Concat's scale
leaves the scores zero codes — confirmed independently by Qualcomm AI
Hub's own quantizer producing 0.0000 on the same head).

## Artifact identities (sha256)

Quantization is byte-deterministic: re-running `tools/qdq-export` on
the same fp32 export and calibration set reproduces these bytes.

| artifact | sha256 |
|---|---|
| `yolo26m-qdq-a16.onnx` | `49851f533f858b19b9e51929670c3fbb61096cee1fd11a6a4da571148bfa781d` |
| `yolo26m-qdq-a8.onnx` | `45a26254f30b015388585699ec4d33f704e216238c6b8f0820c72fbd65c7442b` |
| `yolo26n-416-qdq-a16.onnx` | `7ed46405443d4965f1aac4243e543e2a06870f5403bf3664f6cdf747ff8a7f44` |
| `yolo26n-416-qdq-a8.onnx` | `711209ef16fc6f8af0a31aae196b63c952b04691e9de5d941b69e24e37a38fae` |
| `yolo26n-qdq-a16.onnx` | `8d87b91dade03192c5e751bfe4105cb728b516774eeae068b300d30f0d5eb14a` |
| `yolo26n-qdq-a8.onnx` | `532a0a3fde24cfa7c1342269cfa1575e994500c70f3b64450ff4a88d8d52cc04` |
| `yolo26s-qdq-a16.onnx` | `04b2742293d2b9ecba2978470d2ef21039ab0e502a39545f772d4200eaaee929` |
| `yolo26s-qdq-a8.onnx` | `cb6858178d3685474deed68dcd6e729711822ac761c436208df7140fbf0f76f4` |
| `yolov8n-qdq-a16.onnx` | `2c9e13b26f4fc2ae920e579db9c0f85da3ea34bafefb3f3bdad3601542daa643` |
| `yolov8n-qdq-a8.onnx` | `39e04350bc0745a4439cee76549884c85255f84f8c8114f518515a89ca32f4a6` |
| `yolox_m-qdq-a16.onnx` | `99bec797d417eb5a707f07bb5e18f8bcc387c7c458fa1584b1dd67139af15b1f` |
| `yolox_m-qdq-a8.onnx` | `5c54525c31dd5c5743b55d7c596c384dca275e4acb9c34b1ba650fa329cefca6` |
| `yolox_nano-qdq-a16.onnx` | `b36cdc926423fa441ba6772c60501e794621fcca82d4e905d8a2c58436ed8050` |
| `yolox_nano-qdq-a8.onnx` | `f8161f9307806fe9c16c9e31cdf761627cc0d0c906db1c1a6d0241fcdb2328c0` |
| `yolox_s-qdq-a16.onnx` | `12395d01e745112274bb8a9529b5d69f11fa406dba34a0a306468a28397f0cbb` |
| `yolox_s-qdq-a8.onnx` | `3e30784983d01897db208a009ab6e99e089cff59b85a0a7f704d816bc6003ab8` |
| `yolox_tiny-qdq-a16.onnx` | `2b08c80314f1fa5e49d414d667b67b2ee1deab1f180d1a52f2db001880fced5f` |
| `yolox_tiny-qdq-a8.onnx` | `4c2a364b8f9375896381b981995d2bc98aa94bfc6f7f4f0d240fa0b38eb7b74a` |

The four Apache rungs shipped in `models/` are the subset above whose
names `priv/profiles/qcs6490-tier1.yml` bakes; `models/README.md`
carries their per-file provenance. AGPL-family artifacts never ship in
the image or packs built from this repo.

## End-to-end validation

The fixed yolo26m was swapped into the live NVR (2026-08-21): both
cameras recorded a full walk including the return leg, person peaks
0.93/0.94 where the defective artifact hard-capped at 0.578–0.685.
