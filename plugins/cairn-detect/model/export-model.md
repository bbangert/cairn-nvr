# yolov10n ONNX export + INT8 quantization (reproducible steps)

This documents how to reproduce both `yolov10n.onnx` (FP32) and
`yolov10n-int8.onnx` (statically quantized INT8) from scratch, plus the
calibration/verification data used to validate the quantized model against
the cairn-detect plugin's exact preprocessing.

## 1. Environment

```bash
python3 -m venv yolo-export-venv
source yolo-export-venv/bin/activate
pip install ultralytics onnx onnxruntime torch --index-url https://download.pytorch.org/whl/cpu
pip install pillow opencv-python-headless
```

Versions used for this export (from `pip freeze`):

```
numpy==2.4.6
onnx==1.22.0
onnxruntime==1.28.0
onnxslim==0.1.94
opencv-python==5.0.0.93
pillow==12.3.0
torch==2.13.0+cpu
torchvision==0.28.0+cpu
ultralytics==8.4.105
ultralytics-thop==2.0.20
```

Python 3.11.2. System `ffmpeg` (5.1.9) and `ffprobe` used for frame
extraction — no Python video decoding dependency needed.

## 2. FP32 export

```bash
# yolov10n.pt is auto-downloaded by ultralytics on first use if not present
yolo export model=yolov10n.pt format=onnx imgsz=640 batch=1 dynamic=False simplify=True nms=False
```

This produces `yolov10n.onnx` with:
- input `images`: float32 `[1, 3, 640, 640]`
- output `output0`: float32 `[1, 300, 6]` — NMS-free (YOLOv10 "one2one" /
  end-to-end head), rows are `[x1, y1, x2, y2, score, class_id]` in
  640-pixel space, pre-sorted by score descending, top-300 kept internally
  by the graph itself (TopK nodes) — no external NMS step needed.
- opset 20, producer `pytorch 2.13.0`.

The export's embedded ONNX metadata (`onnx.load(...).metadata_props`)
records the exact ultralytics export args used:
`{'dynamic': False, 'simplify': True, 'opset': None, 'nms': False}`,
`end2end: True`, `head: v10Detect`. Re-running the command above against the
same `yolov10n.pt` weights reproduces an equivalent graph.

## 3. Calibration + held-out frame extraction

Preprocessing must match the plugin exactly (verified by reading
`plugins/cairn-detect/src/decode.rs`): **plain stretch resize to 640x640
(no letterbox), RGB, bilinear interpolation (`SWS_BILINEAR`), float32,
divide by 255, CHW, NCHW batch of 1**.

200 calibration frames are sampled from **20 of the 28** fixture clips
under `data/events/reolink_main/` (10 frames each, every 20th decoded
frame), reserving the other **8** clips entirely for a disjoint 10-frame
held-out evaluation set (different videos, not just different timestamps,
so there is no leakage). All clips are 2560x1920 H.264 @ 20fps.

```bash
SRC=/workspaces/cairn-nvr/data/events/reolink_main
ls "$SRC"/*.mp4 | xargs -n1 basename | sort > all_videos.txt
head -20 all_videos.txt > calib_videos.txt   # 20 clips -> calibration
tail -8  all_videos.txt > heldout_videos.txt  # 8 clips  -> held-out (disjoint)

# Calibration: 10 evenly-spaced frames per clip -> 200 total
mkdir -p calib_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='not(mod(n\,20))',scale=640:640:flags=bilinear" \
    -vsync 0 -frames:v 10 -f image2 "calib_frames/${base}_%02d.png" </dev/null
done 3< calib_videos.txt

# Held-out: 2 frames per clip at a different phase offset -> 16 candidates,
# subsampled down to 10 for evaluation (heldout_selected.txt / heldout10/)
mkdir -p heldout_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='eq(mod(n\,90)\,7)',scale=640:640:flags=bilinear" \
    -vsync 0 -frames:v 2 -f image2 "heldout_frames/${base}_%02d.png" </dev/null
done 3< heldout_videos.txt
```

Note: pass `-nostdin` and redirect ffmpeg's stdin from `/dev/null` inside a
`while read` loop — otherwise ffmpeg's interactive keyboard-command reader
competes with the shell loop for stdin and silently corrupts both the
frame extraction and the loop variable.

## 4. Quantization

Run the calibration + `quantize_static` pipeline:

```bash
yolo-export-venv/bin/python3 quantize_yolov10n.py \
    --model yolo-export-venv/yolov10n.onnx \
    --calib-dir calib_frames \
    --out yolov10n-int8.onnx \
    --preprocessed yolov10n-preproc.onnx
```

See `quantize_yolov10n.py` in this directory for the full, documented,
runnable script. Key points, in order:

1. **`quant_pre_process` (shape inference)**: onnxruntime's
   `SymbolicShapeInference` throws `TypeError: object of type 'NoneType'
   has no len()` inside `_infer_TopK` on this graph — a known op-coverage
   gap in symbolic shape inference for YOLOv10's NMS-free postprocessing
   tail (TopK -> GatherElements chain with a rank it can't resolve). The
   script catches this and retries `quant_pre_process(..., skip_symbolic_shape=True)`,
   which falls back to plain ONNX shape inference + the ORT graph
   optimizer only. This is sufficient for `quantize_static`'s own internal
   shape lookups on the Conv/MatMul backbone and succeeds cleanly.
2. **`quantize_static`**: QDQ format, per-channel weight quantization,
   `QInt8` weights / `QUInt8` activations, calibration via the 200-frame
   `CalibrationDataReader` (MinMax, default calibration method), restricted
   to `op_types_to_quantize=["Conv", "MatMul"]` (the postprocessing tail's
   Split/TopK/GatherElements/Mod/Cast ops operate on indices and
   already-decoded values — quantizing them is unnecessary and risks
   op-support issues, so they're left untouched and only wrapped by
   DQ nodes fed from the quantized backbone).
3. **Classification-head exclusion (accuracy fix, found empirically)**:
   the three per-scale classification-head convs
   (`/model.23/one2one_cv3.{0,1,2}.2/Conv`) feed directly into the
   `Sigmoid` that produces detection *scores*. A first pass that quantized
   all Conv/MatMul nodes (including these three) caused **every**
   confident detection's INT8 score to collapse to exactly `0.500`
   (`sigmoid(0)`) — traced to MinMax activation calibration on these
   specific tensors under-ranging on a 200-frame calibration set drawn from
   mostly-static surveillance footage (confident detections are rare in
   the calibration sample, so the true high-activation tail isn't
   captured, and it gets clipped). Excluding just these 3 nodes from
   quantization (`nodes_to_exclude=[...]`) fixed the collapse while still
   quantizing 80 of 83 Conv nodes in the backbone/neck. **If you extend
   calibration to a much larger/more diverse frame set with more confident
   detections, it's worth re-testing whether this exclusion is still
   necessary** — but with a fixture-sized calibration set it is required.

No op actually failed inside `quantize_static` itself in this run (i.e. no
"unsupported op" exception), so no dynamic-quantization fallback was
needed — the two real issues encountered were (a) the shape-inference
op-coverage bug in the *preprocessing* step, worked around as described,
and (b) a silent accuracy bug (score saturation) from over-eager
quantization scope, fixed by excluding 3 specific nodes.

## 5. Verification

```bash
yolo-export-venv/bin/python3 verify_models.py
```

See `verify_models.py` for the full script. It:
- asserts input/output names + shapes are identical between FP32 and INT8
  (`images` `[1,3,640,640]` -> `output0` `[1,300,6]`, both models)
- runs both models on the same 10 held-out frames (disjoint clips from
  calibration), decodes detections with score >= 0.5, greedy-matches FP32
  vs INT8 detections by same class + IoU > 0.5, and reports per-frame
  labels/scores side by side plus an aggregate match rate and mean
  absolute score delta on matched detections
- benchmarks single-frame CPU latency for both models: 3 warmup +
  20 timed `session.run()` calls each, `onnxruntime` default
  `SessionOptions` / `CPUExecutionProvider`

## 6. Results (this run)

| | FP32 | INT8 |
|---|---|---|
| File size | 9,475,454 B (9.48 MB) | 2,953,025 B (2.95 MB), **-68.8%** |
| Latency, mean of 5 trials of (3 warmup + 20 runs) | ~26.9 ms | ~27.2 ms |
| Latency, min observed | ~23.2 ms | ~21.9 ms |

Detection agreement on 10 held-out frames (score >= 0.5 threshold):
- FP32 total detections: 8; INT8 total detections: 6
- Matched (same class, IoU > 0.5): 5/8 (62.5%)
- Mean |score delta| on matched detections: 0.035 (max 0.072)
- All 5 matches had IoU > 0.94 (box localization essentially unaffected)
- Divergences were all near the 0.5 confidence threshold: two `car`
  detections at fp32 scores 0.555/0.561 dropped below 0.5 in INT8; one
  spurious low-confidence (`potted plant`, 0.503) false positive appeared
  in INT8 on a frame where FP32 said `car` (0.561) — a different, unrelated
  box, not a relabeling of the same detection.

## 7. Files in this directory

- `quantize_yolov10n.py` — the quantization script (documented, runnable)
- `verify_models.py` — the verification/benchmark script
- `yolov10n-int8.onnx` — final INT8 QDQ model
- `yolov10n-preproc.onnx` — intermediate shape-inferred model (quant_pre_process output, not needed after quantization)
- `calib_frames/` — 200 calibration PNGs (640x640 RGB)
- `heldout_frames/` / `heldout10/` — held-out PNGs, `heldout10/` is the exact 10-frame evaluation set
- `all_videos.txt`, `calib_videos.txt`, `heldout_videos.txt`, `heldout_selected.txt` — bookkeeping for which source clips went where
