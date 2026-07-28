# Model acquisition + INT8 quantization (reproducible steps)

How to get `yolox_nano.onnx` (FP32) and produce `yolox_nano-int8.onnx`
(statically quantized INT8) from scratch, plus the calibration/verification
data used to validate a quantized model against the cairn-detect plugin's
exact preprocessing.

Everything here is model-agnostic **across the single-tensor families** —
`quantize_model.py` and `verify_models.py` read geometry and layout off the
model and take the preprocessing from the profile that layout resolves to
(yolox, yolov10, yolov8). **RF-DETR is not covered**: its two-tensor layout is
not one they decode and its ImageNet-normalized encoding is not one they
build, so quantizing it has not been evaluated. The documented path is YOLOX,
which is **Apache-2.0**, the same license as Cairn. YOLOv8/v10/v11 weights and
the `ultralytics` CLI are AGPL-3.0; the scripts will happily process such a
model if you bring one, and nothing in this repository fetches or installs
them. See the plugin README's *Model* section.

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
  graph. The plugin does the decode (`grid_objectness` in `src/infer.rs`);
  `verify_models.py` mirrors it.
- **opset 11** (the 0.1.1rc0 release export). This decides whether per-channel
  weight quantization is available: it emits a `DequantizeLinear` carrying an
  `axis` attribute, which only exists from opset 13, and below that
  onnxruntime loads the quantized model and then refuses it with
  "Unrecognized attribute: axis for operator DequantizeLinear".
  `quantize_model.py` reads the opset and turns per-channel off by itself,
  saying so on stdout. §6 is where that costs something.

To confirm any of that for a model you did not download from here:

```bash
python3 -c "import sys; sys.path.insert(0,'.'); \
  from quantize_model import describe; print(describe('../yolox_nano.onnx'))"
```

## 3. Calibration + held-out frame extraction

Preprocessing must match the plugin exactly, and **it is per family, resize
policy included**. The plugin composes it from the resolved profile —
`InputSpec { size, encoding, resize }` in `plugins/cairn-detect/src/infer.rs`,
applied by `ResizePolicy::fit` and `pack_chw` in `src/decode.rs`, with the
per-family channel order and scale in `TensorEncoding::packing`. The scripts
mirror that table in `quantize_model.PROFILES`:

| layout | channel order | scale | resize |
|---|---|---|---|
| yolox | BGR | none (0..255) | **letterbox**, aspect preserved, pad 114 |
| yolov10, yolov8 | RGB | ÷255 (0..1) | stretch to the model's own HxW |
| rfdetr | RGB | ImageNet mean/std | stretch — **not supported by these scripts** |

Common to all: bilinear interpolation (`SWS_BILINEAR`), float32, CHW, NCHW
batch of 1. Under letterbox the content sits at the **top-left** with the
padding bottom-right (what YOLOX's own `preproc` does), each side is rounded
down to an even number of pixels, and the pad goes in as a *pixel value*
before the encoding — so a `raw-bgr` model sees 114 and a `unit-rgb` model
would see 114/255.

The resize policy is not cosmetic for calibration: it decides the pixel
distribution MinMax activation ranges are measured over. Calibrating YOLOX on
stretched frames measures ranges for a model nobody is running.

`load_image_chw` applies the resolved profile's policy to **whatever size PNG
it is handed**, reproducing what the plugin would build from a camera frame of
that size. A frame set already at the model's geometry is a fixed point of
both policies, so the extraction below — which bakes the letterbox in with
ffmpeg — passes through untouched, and so would a set of full-resolution
frames.

200 calibration frames are sampled from **20 of the 28** fixture clips under
`data/events/reolink_main/` (10 frames each, every 20th decoded frame),
reserving the other **8** clips entirely for a disjoint held-out evaluation
set (different videos, not just different timestamps, so there is no leakage):
2 frames per clip at another phase offset, 16 candidates subsampled to the 10
that §5 and §6 evaluate. All clips are 2560x1920 H.264 @ 20fps, which
letterboxes into 416x416 as 416x312 of picture over 104 rows of pad.

```bash
SRC=/workspaces/cairn-nvr/data/events/reolink_main
SIZE=416   # the model's input size; 640 for yolox_s / a yolov10 export

# The plugin's letterbox, as an ffmpeg filter: scale down preserving aspect,
# even sides, then pad to square from the top-left with 114 (0x72). For a
# stretch-policy family (yolov10 / yolov8) this is just `scale=$SIZE:$SIZE`.
LB="scale=$SIZE:$SIZE:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bilinear"
LB="$LB,pad=$SIZE:$SIZE:0:0:color=0x727272"

ls "$SRC"/*.mp4 | xargs -n1 basename | sort > all_videos.txt
head -20 all_videos.txt > calib_videos.txt   # 20 clips -> calibration
tail -8  all_videos.txt > heldout_videos.txt  # 8 clips  -> held-out (disjoint)

# Calibration: 10 evenly-spaced frames per clip -> 200 total
mkdir -p calib_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='not(mod(n\,20))',$LB" \
    -vsync 0 -frames:v 10 -f image2 "calib_frames/${base}_%02d.png" </dev/null
done 3< calib_videos.txt

# Held-out: 2 frames per clip at a different phase offset -> 16 candidates,
# subsampled down to 10 for evaluation (heldout_selected.txt / heldout10/)
mkdir -p heldout_frames
while read -r f <&3; do
  base=$(basename "$f" .mp4)
  ffmpeg -nostdin -y -v error -i "$SRC/$f" \
    -vf "select='eq(mod(n\,90)\,7)',$LB" \
    -vsync 0 -frames:v 2 -f image2 "heldout_frames/${base}_%02d.png" </dev/null
done 3< heldout_videos.txt
```

To check the letterbox landed where the plugin puts it, the bottom-right
pixel of any extracted frame should be exactly `114, 114, 114` and row 312 the
first padded one.

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
them explicitly only to deviate. `--input-encoding` overrides the *encoding*
the script infers from the layout, which it only gets wrong for an export
whose output shape is dynamic; the resize policy follows the profile and has
no flag, because a wrong one is silent and there is nothing to override it
with for a layout the script did not recognize in the first place. The run
prints what it resolved:

```
      model: input 'images' 416x416, opset 11, output [1, 3549, 85],
      layout yolox, calibrating with raw-bgr / letterbox (pad 114)
```

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
   # historical — the YOLOv10 run, and the only command line here naming an
   # AGPL-3.0 model. Kept as the evidence for the trap; the same flags apply
   # to any head, including yolox_nano.onnx.
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

- reports the geometry and layout it read off the FP32 model, and the
  encoding *and resize policy* of the profile that layout resolves to — the
  same `load_image_chw` the calibration used, so a letterboxing family is
  verified letterboxed
- asserts input/output names + shapes are identical between FP32 and INT8
- runs both models on the same 10 held-out frames (disjoint clips from
  calibration; `--frames-dir heldout10`), decodes detections with score >= 0.5 through the layout's
  own decode path (mirroring `src/infer.rs`, including the yolox grid/stride
  decode and `objectness × class_score`), greedy-matches FP32 vs INT8
  detections by same class + IoU > 0.5, and reports per-frame labels/scores
  side by side plus an aggregate match rate and mean absolute score delta on
  matched detections
- benchmarks single-frame CPU latency for both models: 3 warmup + 20 timed
  `session.run()` calls each, `onnxruntime` default `SessionOptions` /
  `CPUExecutionProvider`

## 6. Results

### YOLOX-Nano: INT8 is not worth it (re-measured 2026-07-28, letterboxed)

The full §3 protocol — 200 calibration frames from 20 clips, 10 held-out
frames from the 8 disjoint clips, all letterboxed with pad 114 and fed
`raw-bgr`, which is what the plugin does. Both models measured in the same
run on the same dev container, score threshold 0.5:

| | FP32 | INT8 |
|---|---|---|
| File size | 3,659,407 B (3.66 MB) | 1,082,662 B (1.08 MB), **-70.4%** |
| Latency, mean of 20 runs | 7.56 ms (std 1.15) | 11.83 ms (std 1.88), **1.6x slower** |
| Latency, min observed | 6.92 ms | 10.57 ms |
| Detections on 10 held-out frames | 6 | 1 |
| Match rate (same class, IoU > 0.5) | — | **0%** |

INT8 loses almost every detection rather than shifting them: FP32's `car`
0.601, `person` 0.836, `chair` 0.550 and three `potted plant`s (0.610–0.674)
all fall under the threshold, and the one detection INT8 does emit is a
spurious `banana` 0.536 on a frame where FP32 says `potted plant` 0.646.
Nothing matches. It is also slower, because per-channel quantization had to
be disabled (§2 — the export is opset 11) and the per-tensor QDQ nodes cost
more than the INT8 kernels save at this size.

An earlier scouting run (24 calibration frames, 6 held-out, and — before the
plugin letterboxed — stretched frames) failed differently and more visibly:
the INT8 model emitted the *same* detection, `zebra` at 0.393, on 3 of the 6
frames while missing every real one, which is the classification-score
collapse of §4 item 3 arriving as a constant rather than as `0.500`. The
verdict did not change when the preprocessing was corrected; the symptom did.

Two things could be tuned — a larger and more varied calibration set, and an
opset upgrade to re-enable per-channel — but the ceiling is low: **YOLOX-Nano
is already 3.6 MB**, so the entire prize is a couple of megabytes on disk.
Ship FP32. This section exists mostly to show the verification catching a bad
quantization, which is what it is for.

### YOLOv10 (historical)

These numbers are from the earlier `yolov10n.onnx` (640x640, 9.48 MB) run,
kept because they are the measured evidence for "INT8 is a size win, not a
speed win" on a model large enough for the question to arise. yolov10 is a
**stretch** family, so unlike the YOLOX numbers above these were never
measured under the wrong resize policy and did not need re-running.

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
- `calib_frames/` — 200 calibration PNGs at the model's input geometry,
  under the profile's own resize policy (letterboxed with pad 114 for yolox)
- `heldout_frames/` / `heldout10/` — held-out PNGs, same treatment;
  `heldout10/` is the exact 10-frame evaluation set
- `all_videos.txt`, `calib_videos.txt`, `heldout_videos.txt`,
  `heldout_selected.txt` — bookkeeping for which source clips went where

`*.onnx` in and above this directory is gitignored: the FP32 model is a
download and the INT8 model is a build product. So are `quant-venv/`, the
frame sets and the bookkeeping `.txt` files — every one of them is
reproducible from §1 and §3, and the calibration set alone is tens of
megabytes.
