# Model acquisition + INT8 quantization (reproducible steps)

How to get `yolox_nano.onnx` (FP32) and produce `yolox_nano-int8.onnx`
(statically quantized INT8) from scratch, plus the calibration/verification
data used to validate a quantized model against the cairn-detect plugin's
exact preprocessing.

Everything here is model-agnostic — `quantize_model.py` and
`verify_models.py` read geometry, layout and preprocessing off the model —
but the documented path is YOLOX, which is **Apache-2.0**, the same license
as Cairn. YOLOv8/v10/v11 weights and the `ultralytics` CLI are AGPL-3.0; the
scripts will happily process such a model if you bring one, and nothing in
this repository fetches or installs them. See the plugin README's *Model*
section.

## 1. Environment

```bash
python3 -m venv quant-venv
source quant-venv/bin/activate
pip install onnx onnxruntime pillow numpy sympy
```

`sympy` is optional: without it, onnxruntime's symbolic shape inference is
unavailable and `quantize_model.py` falls back to plain ONNX shape inference
(see §4.1), which is sufficient. No `torch`, no `ultralytics`, no model
vendor package of any kind.

Versions used for the most recent run: `onnx==1.22.0`, `onnxruntime==1.28.0`,
`pillow==12.3.0`, Python 3.11.2. System `ffmpeg`/`ffprobe` are used for frame
extraction — no Python video decoding dependency needed.

## 2. Getting the FP32 model

YOLOX publishes prebuilt ONNX exports as release assets, so there is nothing
to export:

```bash
cd plugins/cairn-detect
curl -L -o yolox_nano.onnx \
  https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx
```

Its canonical home is the plugin root, where the plugin's `--model` flag and
`.gitignore` expect it. `yolox_tiny.onnx` and `yolox_s.onnx` are in the same
release.

`yolox_nano.onnx` (3,659,407 B, sha256
`c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d`) has:

- input `images`: float32 `[1, 3, 416, 416]`, **BGR in 0..255** — YOLOX's
  `preproc` does no scaling and reads images through OpenCV. This is not
  declared anywhere in the graph; it is the training transform's convention
  and the plugin infers it from the output layout.
- output `output`: float32 `[1, 3549, 85]` — anchor-major over
  `52² + 26² + 13² = 3549` anchors (strides 8/16/32 over 416), each row
  `[x, y, w, h, objectness, 80 class scores]`.
- The **grid/stride decode is not folded in**: `x, y` are offsets inside the
  anchor's own grid cell and `w, h` are log extents, both relative to the
  cell's stride. Objectness and the class scores *are* sigmoided in the
  graph. The plugin does the decode (`postprocess_yolox` in
  `src/infer.rs`); `verify_models.py` mirrors it.

To confirm any of that for a model you did not download from here:

```bash
python3 -c "import sys; sys.path.insert(0,'.'); \
  from quantize_model import describe; print(describe('../yolox_nano.onnx'))"
```

## 3. Calibration + held-out frame extraction

Preprocessing must match the plugin exactly (see `rgb_to_chw` in
`plugins/cairn-detect/src/decode.rs`): **plain stretch resize to the model's
own HxW (no letterbox), bilinear interpolation (`SWS_BILINEAR`), float32,
CHW, NCHW batch of 1**, and then per family:

| layout | channel order | scale |
|---|---|---|
| yolox | BGR | none (0..255) |
| yolov10, yolov8 | RGB | ÷255 (0..1) |

The extracted PNGs are always plain RGB at the model's size; the BGR swap and
the scaling happen in `load_image_chw`, so the same frame set serves either
family. **Extract at the model's input size**: 416 for yolox_nano, 640 for
yolox_s or a yolov10 export.

200 calibration frames are sampled from **20 of the 28** fixture clips under
`data/events/reolink_main/` (10 frames each, every 20th decoded frame),
reserving the other **8** clips entirely for a disjoint 10-frame held-out
evaluation set (different videos, not just different timestamps, so there is
no leakage). All clips are 2560x1920 H.264 @ 20fps.

```bash
SRC=/workspaces/cairn-nvr/data/events/reolink_main
SIZE=416   # the model's input size; 640 for yolox_s / a yolov10 export
ls "$SRC"/*.mp4 | xargs -n1 basename | sort > all_videos.txt
head -20 all_videos.txt > calib_videos.txt   # 20 clips -> calibration
tail -8  all_videos.txt > heldout_videos.txt  # 8 clips  -> held-out (disjoint)

# Calibration: 10 evenly-spaced frames per clip -> 200 total
mkdir -p calib_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='not(mod(n\,20))',scale=$SIZE:$SIZE:flags=bilinear" \
    -vsync 0 -frames:v 10 -f image2 "calib_frames/${base}_%02d.png" </dev/null
done 3< calib_videos.txt

# Held-out: 2 frames per clip at a different phase offset -> 16 candidates,
# subsampled down to 10 for evaluation (heldout_selected.txt / heldout10/)
mkdir -p heldout_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='eq(mod(n\,90)\,7)',scale=$SIZE:$SIZE:flags=bilinear" \
    -vsync 0 -frames:v 2 -f image2 "heldout_frames/${base}_%02d.png" </dev/null
done 3< heldout_videos.txt
```

Note: pass `-nostdin` and redirect ffmpeg's stdin from `/dev/null` inside a
`while read` loop — otherwise ffmpeg's interactive keyboard-command reader
competes with the shell loop for stdin and silently corrupts both the
frame extraction and the loop variable.

## 4. Quantization

```bash
# see what the script sees, and list the Conv/MatMul nodes it can exclude
python3 quantize_model.py --model ../yolox_nano.onnx --preprocess-only

python3 quantize_model.py
```

The defaults match the repo layout: `--model ../yolox_nano.onnx` (plugin
root), `--calib-dir calib_frames`, `--out ../yolox_nano-int8.onnx` — pass
them explicitly only to deviate. `--input-encoding` overrides what the script
infers from the layout, which it only gets wrong for an export whose output
shape is dynamic.

See `quantize_model.py` for the full, documented, runnable script. Key points,
in order:

1. **`quant_pre_process` (shape inference)**: on some graphs onnxruntime's
   `SymbolicShapeInference` throws `TypeError: object of type 'NoneType' has
   no len()` inside `_infer_TopK` — a known op-coverage gap for a NMS-free
   postprocessing tail (TopK -> GatherElements chain with a rank it can't
   resolve), observed on YOLOv10. Without `sympy` installed it raises an
   `ImportError` instead. Either way the script catches it and retries
   `quant_pre_process(..., skip_symbolic_shape=True)`, falling back to plain
   ONNX shape inference + the ORT graph optimizer. That is sufficient for
   `quantize_static`'s own internal shape lookups on the Conv/MatMul backbone
   and succeeds cleanly.
2. **`quantize_static`**: QDQ format, per-channel weight quantization,
   `QInt8` weights / `QUInt8` activations, calibration via the 200-frame
   `CalibrationDataReader` (MinMax, default calibration method), restricted
   to `op_types_to_quantize=["Conv", "MatMul"]`. A detect head's
   postprocessing tail — Split/TopK/GatherElements/Mod/Cast, or a yolox
   head's grid arithmetic — operates on indices and already-decoded values;
   quantizing those is unnecessary and risks op-support issues, so they are
   left untouched and only wrapped by DQ nodes fed from the quantized
   backbone.
3. **Classification-head exclusion (accuracy trap, found empirically)**:
   classification-head convs feed directly into the `Sigmoid` that produces
   detection *scores*. On YOLOv10, a first pass that quantized all
   Conv/MatMul nodes (including the three
   `/model.23/one2one_cv3.{0,1,2}.2/Conv`) caused **every** confident
   detection's INT8 score to collapse to exactly `0.500` (`sigmoid(0)`) —
   traced to MinMax activation calibration on those specific tensors
   under-ranging on a 200-frame calibration set drawn from mostly-static
   surveillance footage (confident detections are rare in the sample, so the
   true high-activation tail isn't captured, and it gets clipped). Excluding
   just those 3 nodes fixed the collapse while still quantizing 80 of 83
   Conv nodes:

   ```bash
   python3 quantize_model.py --model ../yolov10n.onnx \
     --exclude-suffix one2one_cv3.0.2/Conv \
     --exclude-suffix one2one_cv3.1.2/Conv \
     --exclude-suffix one2one_cv3.2.2/Conv
   ```

   The same failure mode is possible on any head. Run §5 and check for a
   pile of identical scores before trusting a quantized model. If you extend
   calibration to a much larger/more diverse frame set with more confident
   detections, re-test whether the exclusion is still needed.

No op actually failed inside `quantize_static` itself (i.e. no "unsupported
op" exception), so no dynamic-quantization fallback was needed — the two real
issues encountered were (a) the shape-inference op-coverage gap in the
*preprocessing* step, worked around as described, and (b) a silent accuracy
bug (score saturation) from over-eager quantization scope.

## 5. Verification

```bash
python3 verify_models.py --fp32 ../yolox_nano.onnx --int8 ../yolox_nano-int8.onnx
```

See `verify_models.py` for the full script. It:

- reports the geometry, layout and preprocessing it read off the FP32 model
- asserts input/output names + shapes are identical between FP32 and INT8
- runs both models on the same 10 held-out frames (disjoint clips from
  calibration), decodes detections with score >= 0.5 through the layout's
  own decode path (mirroring `src/infer.rs`, including the yolox grid/stride
  decode and `objectness × class_score`), greedy-matches FP32 vs INT8
  detections by same class + IoU > 0.5, and reports per-frame labels/scores
  side by side plus an aggregate match rate and mean absolute score delta on
  matched detections
- benchmarks single-frame CPU latency for both models: 3 warmup + 20 timed
  `session.run()` calls each, `onnxruntime` default `SessionOptions` /
  `CPUExecutionProvider`

## 6. Results

### YOLOX-Nano: INT8 is not worth it (measured 2026-07-28)

A quantization run on `yolox_nano.onnx` with 24 calibration frames and 6
held-out frames, on the same dev container:

| | FP32 | INT8 |
|---|---|---|
| Latency, mean of 20 runs | 20.3 ms | 47.6 ms (**2.3x slower**) |
| Detections on held-out frames (score >= 0.3) | 4 | 4, none matching |
| Match rate (same class, IoU > 0.5) | — | **0%** |

The INT8 model emitted the *same* detection — `zebra`, score `0.393` — on
three different frames while missing every real one: the classification-score
collapse described in §4.3, arriving here as a constant rather than as
`0.500`. It is also slower, because per-channel quantization had to be
disabled (§2: opset 11) and the per-tensor QDQ nodes cost more than the INT8
kernels save at this size.

Two things could be tuned — many more calibration frames, and an opset
upgrade to re-enable per-channel — but the ceiling is low: **YOLOX-Nano is
already 3.6 MB**, so the entire prize is a couple of megabytes on disk. Ship
FP32. This section exists mostly to show the verification catching a bad
quantization, which is what it is for.

### YOLOv10 (historical)

These numbers are from the earlier `yolov10n.onnx` (640x640, 9.48 MB) run,
kept because they are the measured evidence for "INT8 is a size win, not a
speed win" on a model large enough for the question to arise.

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

- `quantize_model.py` — the quantization script (documented, runnable)
- `verify_models.py` — the verification/benchmark script; also the reference
  Python implementation of all three decode paths
- `calib_frames/` — 200 calibration PNGs at the model's input size
- `heldout_frames/` / `heldout10/` — held-out PNGs, `heldout10/` is the exact
  10-frame evaluation set
- `all_videos.txt`, `calib_videos.txt`, `heldout_videos.txt`,
  `heldout_selected.txt` — bookkeeping for which source clips went where

`*.onnx` in and above this directory is gitignored: the FP32 model is a
download and the INT8 model is a build product.
