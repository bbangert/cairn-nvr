# qdq-export — HTP (QNN) artifact pipeline

Reproducible quantized artifacts for the QCS6490 tier candidates
(qcs6490-profiles plan, phase 3). Full-op-coverage QDQ is what the HTP
accepts — the CPU-tuned conv-island flow in `model/quantize-model.md`
produces artifacts that do NOT run on it (fragmented FP32 gaps, then an
ORT NHWC MaxPool abort; phase-0 spike). Keep the two flows' outputs
apart: `-qdq.onnx` here (HTP, profile key `model.qnn:`) vs `-int8.onnx`
there (CPU EP, `model.onnx:`).

## Environments

Two venvs, deliberately separate:

- `model/quant-venv` (see `model/quantize-model.md` §1): onnx +
  onnxruntime + pillow. Runs `qdq_quantize.py`. No vendor packages.
- `export-venv` (operator-created, here): `pip install ultralytics
  --extra-index-url https://download.pytorch.org/whl/cpu`. Runs
  `export_ultralytics.py` only. This is the AGPL boundary: nothing in
  the repo fetches Ultralytics code or weights; you install and run it,
  and the results never enter git or a container image.

## Per-family recipe

| family | FP32 source | license | HTP notes |
|---|---|---|---|
| yolox (nano/tiny/s) | release-asset download, `model/quantize-model.md` §2 | Apache-2.0 | quantizes as-is; Focus-layer Slices fall back to CPU harmlessly |
| yolo26 (n/s), yolov10 | `export_ultralytics.py yolo26n yolo26s` | **AGPL-3.0**/Enterprise (code AND weights — HF model card) | export uses `end2end=False`: the default NMS-free tail segfaults QNN 2.4.0 quantized; the raw `[1, 4+nc, A]` head IS the yolov8 tensor contract, so the plugin decodes it under `--model-profile yolov8` with host-side NMS |
| yolov8 (n) | `export_ultralytics.py yolov8n` | AGPL-3.0 | no tail; exports raw head natively |

Then quantize (any family):

```bash
model/quant-venv/bin/python3 tools/qdq-export/qdq_quantize.py \
  plugins/cairn-detect/yolo26s.onnx plugins/cairn-detect/yolo26s-qdq.onnx \
  --calib-dir plugins/cairn-detect/model/calib_frames_fullres
```

## Calibration frames

`capture_frames.sh <out_dir> <clips-or-rtsp...>` samples full-resolution
frames off real camera footage (every 20th frame, 10/source — the
cadence `model/quantize-model.md` §3 documents). Full-res matters:
`load_image_chw` applies each family's own resize policy at load, so one
full-res set serves letterbox (yolox) and stretch (yolo26/yolov8)
families alike. The pre-letterboxed 416 set (`model/calib_frames`) is a
fixed point for yolox only — do not calibrate a stretch family on it.

```bash
tools/qdq-export/capture_frames.sh \
  plugins/cairn-detect/model/calib_frames_fullres \
  data/events/reolink_main/*.mp4
```

## Decode verification (CPU EP)

`verify_artifact.sh <model.onnx> [plugin flags...]` collapses the
`verify/` two-terminal flow into one run: plugin on loopback RTP,
fixture feed, `validate_ndjson.py`, label histogram. It answers "does
this artifact detect the same things", never byte-identity
(`verify/README.md` on the wall-clock sample gate). Check each artifact
here before any on-board run.

## Alternatives considered

Ultralytics ships a first-party `format="qnn"` export (w8a16 QDQ + a
pre-compiled ORT QNN context binary). Not used: the context binary pins
a QAIRT version, its calibration is not our cameras', and our w8a8
per-channel flow is the one the phase-0 spike proved on this exact
board stack. Revisit if per-model accuracy demands w8a16 activations.

## On-board reality checks

A QDQ artifact that runs here can still fall back per-node on the HTP.
The only accepted proof of HTP execution is the plugin's
`infer latency:` stderr line beating the `--backend ort` number by ≥3×
(D-P5) — and pin the cpufreq governor while measuring, or the number
lies (docs/npu-backends.md, "QNN wiring as landed").
