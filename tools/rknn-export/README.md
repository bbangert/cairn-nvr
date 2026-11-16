# rknn-export — RK3566 (RKNN) rung pipeline

Builds the INT8 `.rknn` rungs for the HA Green's NPU (RK3566,
rknn-toolkit2 2.3.2), each beside the FP32 ONNX it was converted from, and
scores the toolkit's simulator against that ONNX on frames calibration never
saw. Host only. Nothing built here enters git: `work/` and `venv/` are
ignored, and so is any `.onnx`, `.rknn`, `.pt`, `.npy` or `.npz` wherever it
lands.

Simulator parity measures INT8 quantisation error, not the NPU's numerics.
The board is a separate measurement (`board/`).

## Why the rungs look the way they do

This toolkit gives an INT8 output tensor one scale. Everything else follows.

- **Stock Ultralytics heads detect nothing.** `[1, 4+nc, A]` (and yolo26's
  end-to-end `[1, 300, 6]`) carries pixel-range boxes and 0..1 scores in one
  tensor, so the scores quantise to zero: all six models convert, run, keep a
  box cosine of 0.998, and emit zero detections ≥ 0.3. FP16 of the same
  graphs is exact.
- **The split head is the fix.** `export_ultralytics_rknn.py … split` cuts
  the head before DFL/decode and emits nine tensors, `box{i}`, `cls{i}`,
  `sum{i}` for strides 8/16/32. `box` is `[1, 4*reg_max, H, W]` (64 channels
  of DFL logits for v8/v11; 4 ltrb distances in stride units for yolo26,
  taken from its one2one head), `cls` is the sigmoided scores, `sum` is
  airockchip's early-reject channel. The export sets those names and asserts
  names and shapes before the file reaches its destination; all nine survive
  into the `.rknn`.
- **YOLOX survives as one tensor** because its box columns are raw
  regressions, not pixels. The price is a coarse score: boxes and scores
  still share a scale, and the step is 0.025–0.028 (listed under the parity
  table).
- **yolox_nano does not survive INT8** (recall 0.00; the `mmse` quantiser
  does not rescue it). rfdetr_nano INT8 is unusable (score error 0.09–0.25)
  and RT-DETR-l fails at build.
- **FP16 is not a rung.** It is exact in parity and three times slower on
  the board end to end: yolox_s 640 takes 101 ms a frame INT8 and 310 ms
  FP16, 65 of them converting the input (`board/results/m1.log`).

## Environments

- `venv` (here, ignored): `python3.11 -m venv venv && venv/bin/pip install
  -r requirements.txt`. Runs every script in this directory except the
  Ultralytics export.
  `onnx` is pinned because pip's latest breaks `load_onnx`.
- `../qdq-export/export-venv`: runs `export_ultralytics_rknn.py` only. The
  AGPL boundary is the one `tools/qdq-export/README.md` describes: you
  install and run Ultralytics, and neither its weights nor anything exported
  from them enters git or an image.
- `plugins/cairn-detect/model/quant-venv`: runs the held-out census
  (`tools/qdq-export/calib_census.py`) and pytest.

Scripts run as `venv/bin/python -I`. `-I` keeps the script directory off
`sys.path`, which is why the ones that import a sibling insert it by hand.

## Input conventions

Mean and std are folded into the `.rknn`, so the model takes raw uint8.

| family | resize | channels | mean / std |
|---|---|---|---|
| yolox | letterbox, pad 114, content at the origin | BGR | 0 / 1 |
| yolov8, yolo11, yolo26 | stretch | RGB | 0 / 255 |
| rfdetr (trial only) | stretch | RGB | ImageNet |

`prep_calib.py` writes each set as NCHW uint8 `.npy` — the toolkit rejects
NHWC `.npy`, and image files would hide the channel order — with a
`set.json` recording every frame's source geometry and an id hashed over the
frame bytes. That id is the calibration set id in the manifest.

## Calibration and held-out frames

Both sets come from `tools/qdq-export/capture_frames.sh` (full resolution,
sampled across the whole clip) and both are operator-local.

**Calibration** is the 285-frame set the QNN pipeline already vetted,
`tools/qdq-export/out-20260820/calib`: 36 clips, 2560x1920 ×120, 1920x1080
×105, 640x480 ×60, a person in 24 % of frames. The conversion trial's own
set (135 frames) had no substream and one 2.5-hour window — the composition
`tools/qdq-export/README.md` warns against — so the rungs are not calibrated
on it.

**Held-out** is 90 frames from 20 clips, none of them a clip calibration
drew from (`convert.py` refuses to build a rung whose two sets share one):
2560x1920 ×40, 1920x1080 ×30, 1024x576 ×20. Parity is reported per geometry
because a single pooled number hides a geometry that fails. Three limits on
what it can say:

- Held out by clip, not by scene. The 15 event clips come from one of
  calibration's two event cameras, inside the same 2.5 hours; one ends 4 s
  before a calibration clip from that camera begins, and another overlaps
  in time a calibration clip from the other. This is parity on unseen
  frames of familiar scenes.
- A person scores ≥ 0.5 in 11 of the 90 frames, none of them in the
  substream group; the one held-out substream clip never shows one. The
  person columns count cells whose FP32 person score is ≥ 0.3, nearly all
  of them in those frames. Read them to ±0.1, and substream person parity
  as unmeasured.
- The any-class counts are mostly the same parked cars, frame after frame.

## Build

```sh
./build_rungs.sh apache   # the three YOLOX rungs; no Ultralytics needed
./build_rungs.sh pack     # the six split rungs; needs export-venv and work/src/weights/*.pt
./build_rungs.sh all
```

It needs ffmpeg, the event clips in `data/events/reolink_main/`,
`tools/qdq-export/out-20260820/` (the calibration frames and its clips) and
the YOLOX release files in `work/src/` (hashes in
`plugins/cairn-detect/README.md`).

Steps skip when their output exists, so a failed run resumes. The log is
`work/final/build.log`. Per rung, `work/final/build/` holds `NAME.out` (the
toolkit's stdout, operator table included), `NAME.build.log` (its debug
log), `NAME.json` and `NAME.parity.json`. A rung takes 30–115 s to build
and 18–42 s to score. `work/rungs/` ends up holding the `.rknn` files,
their twins, `MANIFEST.sha256` (`sha256sum -c` format) and `MANIFEST.json`
(bytes, license, twin, toolkit, target, calibration set id). `manifest.py`
lists a rung only if the hash its build recorded is the hash of the file.

The YOLOX twins are the 0.1.1rc0 release files, bytes unchanged
(`work/src/yolox_{tiny,s}.onnx`). `yolox_tiny_640.onnx` is the 416 release
file with its input size rewritten (`onnx_edit.py resize`); the 640 rung is
converted from that file, so it has a reference to be scored against.

**A manifest hash names one build, not a recipe.** Two builds of
`yolox_tiny_416_i8` from identical inputs differ in 105 bytes within the
first 2.6 kB and are identical after it; their parity results are
byte-identical. Publish the files the manifest hashed, not a rebuild.

## Parity

Simulator vs twin, pooled over the 90 held-out frames. A positive is a cell
whose FP32 score is ≥ 0.3; recall is the share of those the simulator also
scores ≥ 0.3. Person recall is given overall, then for 1920x1080 and
2560x1920. CPU ops excludes the input and output operators. Box error is
mean absolute error at positive cells, in input pixels. Max is the highest
score seen, FP32 → simulator: a ceiling baked in by calibration would show
as a gap.

| rung | MB | CPU ops | any: n, recall | person: n, recall | person 16:9 / 4:3 | person mean abs Δscore | box px | max |
|---|---|---|---|---|---|---|---|---|
| yolox_tiny_416_i8 | 6.3 | 3 | 1392, 0.93 | 93, 0.87 | 0.88 / 0.84 | 0.071 | 0.95 | .92 → .92 |
| yolox_tiny_640_i8 | 6.4 | 3 | 2020, 0.95 | 100, 0.94 | 0.99 / 0.82 | 0.066 | 0.84 | .93 → .92 |
| yolox_s_640_i8 | 10.4 | 3 | 1772, 0.94 | 96, 1.00 | 1.00 / 1.00 | 0.020 | 0.72 | .93 → .95 |
| yolov8n_split_640_i8 | 4.8 | 0 | 1550, 0.91 | 87, 0.83 | 0.80 / 0.89 | 0.110 | 0.51 | .88 → .87 |
| yolov8s_split_640_i8 | 13.2 | 0 | 2406, 0.93 | 122, 0.92 | 0.91 / 1.00 | 0.037 | 0.33 | .90 → .89 |
| yolo11n_split_640_i8 | 4.6 | 4 | 1328, 0.84 | 78, 0.92 | 0.89 / 1.00 | 0.072 | 0.78 | .90 → .92 |
| yolo11s_split_640_i8 | 11.9 | 4 | 2390, 0.86 | 100, 0.75 | 0.76 / 0.73 | 0.155 | 0.71 | .95 → .94 |
| yolo26n_split_640_i8 | 4.6 | 8 | 153, 0.63 | 8, 0.88 | 0.83 / 1.00 | 0.109 | 0.82 | .91 → .93 |
| yolo26s_split_640_i8 | 12.2 | 8 | 245, 0.73 | 13, 0.77 | 0.75 / 0.80 | 0.162 | 0.82 | .95 → .94 |

- No rung shows a score ceiling.
- YOLOX score steps: 0.0278 (tiny 416), 0.0256 (tiny 640), 0.0253 (s 640).
- **yolox_tiny at 640 is kept.** The bar was set before the run: person
  recall ≥ 0.85 overall and no more than 0.05 below the 416 rung. It scored
  0.94 against 0.87, with the same output cosine (0.969).
- yolo11n loses stride 32 for non-person classes (any-class recall 0.42
  there); yolo11s loses a quarter of person cells at every stride it has
  them.
- yolo26's one2one head fires once per object, hence the small counts. Its
  any-class recall (0.63, 0.73) is the worst of the set and its person
  sample is too thin to rescue it.

## Apache rungs

The rows a fetch manifest would pin (toolkit 2.3.2, target `rk3566`,
`quantized_algorithm=normal`):

| file | bytes | sha256 | calibration set |
|---|---|---|---|
| yolox_tiny_416_i8.rknn | 6273103 | `832df464bc84259d8d612bb7e9d4f6dd8573acb94f9847e051cce4c438c78304` | `5047ae0e6484f100` |
| yolox_tiny.onnx | 20219662 | `427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7` | |
| yolox_tiny_640_i8.rknn | 6402703 | `cd146e38777ea0c38e20c114c4166fb9b7553c379e20651a999167acb0bb044a` | `920782f4e1e36e81` |
| yolox_tiny_640.onnx | 20219702 | `6066fa79efe783a554a6f7e13792e0ee9246bc0c7b27d6eddad3f43bdd000a61` | |
| yolox_s_640_i8.rknn | 10414863 | `c61524bca75d6f5df3fd255c8f27b5eaca544c94cbd05d4ce835a82a48733282` | `920782f4e1e36e81` |
| yolox_s.onnx | 35858002 | `c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063` | |

## Toolkit traps

- The simulator only runs a graph built in the same process; a `.rknn`
  loaded with `load_rknn` cannot be simulated. So `convert.py` scores parity
  itself right after the build, and the check on the exported file is that
  `load_rknn` accepts it.
- Every build drops `check*_*.onnx` files (20–40 MB each) into the current
  directory. `convert.py` changes into its `--out` directory first.
- `accuracy_analysis` (`--analysis N`) writes about 1 GB per model. The rung
  build does not use it.
- CPU fallback is never a warning. It shows only as `CPU` rows in the
  operator table the toolkit prints to stdout (`NAME.out`, not
  `NAME.build.log`), which is what `summarize.py` counts.

## The conversion trial

`run.sh`, `batch_ultra.sh`, `parity_e2e.py`, `parity_detr.py` and the `v8`,
`v8t`, `e2e` kinds of `parity.py` reproduce the matrix behind the first
section, on five calibration frames per model. Those kinds print per-frame
means, not the pooled counts above.

```sh
venv/bin/python -I prep_calib.py work/frames work/calib/lb640_bgr 640 letterbox bgr   # also lb416_bgr, st640_rgb, st384_rgb
(cd work/src/weights && ../../../../qdq-export/export-venv/bin/python -I \
  ../../../export_ultralytics_rknn.py yolov8n stock 640 ../yolov8n_stock.onnx)        # stock | split | e2e
./run.sh yolox_s_640_i8 work/src/yolox_s.onnx i8 --calib work/calib/lb640_bgr
venv/bin/python -I parity.py yolox_s_640_i8 yolox
./batch_ultra.sh                                  # six models × stock, split × INT8, FP16
./run.sh rfdetr_nano_384_fp16 work/src/rfdetr_nano.onnx fp16 --mean 123.675,116.28,103.53 \
  --std 58.395,57.12,57.375 --calib work/calib/st384_rgb --size 384x384 --input-name pixel_values
```

## board/

Probes that ran on the Green during bring-up, with the board's `python3` and
numpy and nothing from the toolkit. Each prints `JSON:`-prefixed records, and
`results/` holds what they printed; the other lines there (`DONE`,
`[exit 0]`, `:ok`, a checksum) come from the commands around them. The models
were trial builds, not the pinned rungs.

- `rk.py` is a ctypes harness over librknnrt: `info`, `bench` (200 timed
  calls, then 60 s sustained with NPU load, temperature and free memory
  sampled), `input` (the ways to hand over a frame, timed and checked against
  each other), `acc` (float outputs for the host) and `worker` (the child
  `conc.py` starts). `matrix.sh` runs `bench` over `models/NAME.rknn` into
  `m1.log`, `m2.log` and `m3.log`; `tab.py` prints those a line per record.
- `zcin.py` and `zc.py` try zero-copy I/O through `rknn_create_mem` and
  `rknn_set_io_mem`. A zero-copy input gives the outputs `rknn_inputs_set`
  gives, at cosine 1.000 (`zcin.log`). A zero-copy output does not: `zc.py`
  read the native buffer back at cosine 0.05 under every layout it tried
  (`zc.log`), so nothing here shows how to read one.
- `conc.py` and `conc.sh` run one context per process, started on one epoch
  (`conc.log`).
- `heaps.py` and `heapcap.py` allocate from each dma-heap, report what that
  takes from CMA, and count the 1080p NV12 buffers the 32 MiB
  `rk-dma-heap-cma` pool yields (`heaps.log`, `heapcap.log`).
- `dec.py` runs K concurrent `mpi_dec_test` decodes with free CMA sampled
  (`dec.log`). That log was taken while `dec.py` still read the decoders'
  pipes one after another. Its 1080p rows at K = 2 and 4 show the decoders
  finishing in order, 2.2 s apart, so each waited on a full pipe: read those
  aggregate rates as a floor. The 2560x1920 pair finished together.
- `syms.py` checks the exported symbols of librknnrt, librga and
  librockchip_mpp against the calls a board library makes. No log is kept.
- `cpu_ort.py` times ONNX Runtime on the CPU, for the NPU's margin over it.
  It has not been run on the board.

`compare.py` runs on the host and answers whether the NPU agrees with the
simulator: it scores an `rk.py acc` dump against the simulator and FP32
tensors of the same build, `$RKNN_OUT/NAME.parity.npz` (default `work/rknn`).
A `run.sh` build writes that file for five calibration frames, and `acc` must
be given the same five in the same order. `build_rungs.sh` keeps no tensors,
so a rung from `work/rungs` cannot be scored this way.

## Tests

`python -m pytest tools/rknn-export` covers the parity arithmetic, the ONNX
edits and the letterbox size rule, the pieces whose errors would be silent,
and the manifest's refusals. CI runs it with neither the toolkit nor onnxruntime, so the one
check that runs a resized model is skipped there.
