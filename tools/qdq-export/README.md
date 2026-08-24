# qdq-export — HTP (QNN) artifact pipeline

Reproducible quantized artifacts for the QCS6490 tier candidates.
Full-op-coverage QDQ is what the HTP accepts — the CPU-tuned conv-island
flow in `model/quantize-model.md` produces artifacts that do NOT run on
it (fragmented FP32 gaps, then an ORT NHWC MaxPool abort; phase-0 spike).
Keep the two flows' outputs apart: `-qdq.onnx` here (HTP, profile key
`model.qnn:`) vs `-int8.onnx` there (CPU EP, `model.onnx:`).

## The two defect classes this pipeline exists to not reproduce

Every artifact built before 2026-08-20 carried both, and the whole
verification suite passed them.

1. **Baked score ceilings.** Calibration averaged per-frame extremes
   instead of taking them, so a class-score Sigmoid — range (0, 1) by
   construction — was quantized to a representable maximum of 0.13 at
   stride 32. Every detection at that scale was capped at 0.093 on every
   EP. Label histograms could not see it: the labels were all still
   there.
2. **A graph that disagreed with the hardware.** The QNN EP rewrites
   16-bit Sigmoid output qparams to `1/65536` inside the EP at
   graph-build time, logging at VERBOSE only, while the graph's own
   DequantizeLinear kept the calibrated scale. Every score came out
   multiplied by the calibrated maximum — on the HTP, and only on the
   HTP, which is why CPU-EP verification never saw it.

Both are fixed by `get_qnn_qdq_config` + plain MinMax (see
`qdq_quantize.py`'s docstring for what the hand-rolled `quantize_static`
call omitted), and `qparam_gate.py` fails the export rather than let
either ship again.

## Environments

Three venvs, deliberately separate:

- `model/quant-venv`: `pip install -r tools/qdq-export/requirements.txt`.
  Runs everything here except the Ultralytics export and the AI Hub
  client. Pinned, because the emitted graph depends on the ORT version
  and the idempotency claim is meaningless without one.
- `aihub-venv` (operator-created, here, gitignored): `pip install
  qai-hub==0.55.0`. Runs `aihub_quantize.py` only — the vendor
  cross-check needs Qualcomm's client and an API token (`qualcomm.env`,
  also gitignored), neither of which belongs in the pinned quant env.
- `export-venv` (operator-created, here): `pip install ultralytics
  --extra-index-url https://download.pytorch.org/whl/cpu`. Runs
  `export_ultralytics.py` only. This is the AGPL boundary: nothing in
  the repo fetches Ultralytics code or weights; you install and run it,
  and the results never enter git or a container image.

## Per-family recipe

| family | FP32 source | license | HTP notes |
|---|---|---|---|
| yolox (nano/tiny/s/m) | release-asset download, `model/quantize-model.md` §2 | Apache-2.0 | quantizes as-is; Focus-layer Slices stay FP32 harmlessly (2 islands, reported by the gate) |
| yolo26 (n/s/m), yolov10 | `export_ultralytics.py yolo26n yolo26s` | **AGPL-3.0**/Enterprise (code AND weights — HF model card) | export uses `end2end=False`: the default NMS-free tail segfaults QNN 2.4.0 quantized; the raw `[1, 4+nc, A]` head IS the yolov8 tensor contract, so the plugin decodes it under `--model-profile yolov8` with host-side NMS |
| yolov8 (n) | `export_ultralytics.py yolov8n` | AGPL-3.0 | no tail; exports raw head natively |

One checkpoint at two geometries needs `--suffix`, or the second export
overwrites the first: `export_ultralytics.py yolo26n --imgsz 416
--suffix -416`.

Then quantize (any family), at both widths:

```bash
SRC=out/sources OUT=out/artifacts CALIB=out/calib \
  tools/qdq-export/run_quantize_candidates.sh
```

or one at a time:

```bash
plugins/cairn-detect/model/quant-venv/bin/python3 tools/qdq-export/qdq_quantize.py \
  out/sources/yolo26s.onnx out/artifacts/yolo26s-qdq-a16.onnx \
  --calib-dir out/calib --activation uint16
```

**Both activation widths are first-class outputs.** The measurement that
once made w8a16 the mandatory default — "full-coverage w8a8 crushed
yolox_nano to 0.20–0.49" — was taken under the broken recipe and does
not survive it. Which width a rung ships at is decided by the board's
latency and accuracy legs, on artifacts that exist.

## Calibration frames

`capture_frames.sh <out_dir> <clips-or-rtsp...>` samples full-resolution
frames off real footage. Full-res matters: `load_image_chw` applies each
family's own resize policy at load, so one full-res set serves letterbox
(yolox) and stretch (yolo26/yolov8) families alike. The pre-letterboxed
416 set (`model/calib_frames`) is a fixed point for yolox only — do not
calibrate a stretch family on it.

Sampling spreads `FRAMES_PER_SOURCE` frames across each clip's whole
duration. It used to take every 20th frame, which with a 10-frame budget
never left the first nine seconds — and with a 5 s pre-trigger window,
half of that is the scene before the subject arrives.

What the set must span, because calibration hygiene is what the recipe
fix rests on: **both cameras**, the **substream** (640×480 — what the
detector actually consumes; a 2560 px frame downscaled to 640 is sharper
and lower-noise than a substream frame stretched to it), **frames that
contain people**, and more than one time of day. A set that is one
camera, one 110-minute night window and 13% person frames decides the
dynamic range of a detector deployed against none of those things.

Record the set's composition next to the artifacts. Under true MinMax
the set's *spread* is what the artifact inherits, so "196 frames" is not
a description of it.

## Verification

Three checks, and only the third can see everything.

- `run_verify_all.sh` — FP32-vs-QDQ **score distributions** per FPN
  level on the CPU EP (`score_parity.py`), over held-out frames and over
  the board clips. This is the accuracy oracle the pipeline lacked.
- `verify_artifact.sh <model.onnx>` — the plugin's real decode path on a
  loopback RTP feed, with a label histogram. It answers "does the decode
  still work end to end", never "are the scores right".
- **The board leg.** Same clips, `--backend qnn`, distributions compared
  against the CPU run. Defect 2 above is invisible to every local check
  by construction, so an artifact that has not run on an HTP has not
  been verified. Log the QNN partition count (`log_severity_level=1`,
  "Number of partitions supported by QNN EP: N") or bring up with
  `session.disable_cpu_ep_fallback=1` — per-node fallback is logged
  below ORT's default severity, and a mostly-HTP graph with CPU islands
  passes a latency-ratio check easily.

  The leg is automated: `run_htp_campaign.sh` pushes the artifacts,
  gates the bench env on a nano-parity check against the phase-0 spike
  numbers, runs `htp_content_test.sh` per rung × clip (plugin first,
  feed once — a looped feed wraps pts and the clip-time mapping that
  window analysis rests on is garbage), re-measures latency with the
  governor pinned, and fetches the evidence; `htp_report.py` renders
  verdicts, classifying failures by defect signature (plateau = baked
  ceiling, uniform depression = EP qparam rewrite). It stops the cairn
  container for the duration — the app holds the NPU — and restarts it
  on exit. Two built-in controls: a board CPU-EP run (ties board decode
  to the local reference) and the shipped defective nano, which must
  FAIL or the test has lost its sensitivity.

## Alternatives considered

Qualcomm AI Hub publishes quantized detectors for this SoC. Two things
that a previous version of this section had wrong: **no detection model
on AI Hub ships a precompiled QNN context binary** (tflite / onnx /
qnn_dlc universal assets only), and their **primary published precision
for QCS6490 detectors is w8a8**, with w8a16 as the expensive alternative
and mixed-int16 as the accuracy remedy — so "their precision choice
agrees with ours" was agreement with the wrong row.

Their AGPL artifacts are download-blocked (`restrict_model_sharing`;
`yolov8_det-*` release assets 403), so there is no AI Hub route to a
yolo26/yolov8 rung. YOLOX-S is fetchable anonymously and is worth having
as an **external reference point** — a second implementation of the same
architecture on the same board, with a published mAP (36.1 w8a8 vs 38.4
torch, 8.881 ms on RB3 Gen 2, qnn_dlc). Their recipe is server-side PTQ:
calibration plus deliberate range selection, no AdaRound, no Seq-MSE, no
CLE, no QAT. The gap between this pipeline and theirs was never a
missing algorithm.

## Tests

`export-venv/bin/python -m pytest` (from this directory). The suite pins
the #138 review-round classes as regressions: meta suspect/stale/legacy
grading and the `current` retry guard (campaign_meta.py — also run under
the system python3, whose stdlib is all it may use), analyzer verdict
paths including miss-as-zero pairing and non-finite refusal
(htp_report.py), and the qparam gate's failure classes on hand-built QDQ
graphs (per-axis, NaN, baked ceiling, Q/DQ disagreement, unpinned scale).
