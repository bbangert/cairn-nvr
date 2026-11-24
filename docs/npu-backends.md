# NPU backend workflows: QNN (QCS6490) and RKNN (rk3566/rk3576)

The research record behind the boards' backend-capability tables
(`backends/0` in `Cairn.Board.Generic` and `Cairn.Rockchip.Board`) and the
Rust descriptors they mirror (`ORT` and `QNN` in the stage library, `RKNN` in
the Rockchip board's crate).

It began as second-cycle research (2026-08-05, 11 sources), and what a board
has since measured replaced the research in place and says so. The RKNN
section is measured on a Home Assistant Green (RK3566), 2026-11-15 to
2026-11-18; the raw logs behind it are kept outside this repository. Figures
still marked as claims are third parties' and are in no profile.

## The other axis: kernel/stack flavor, and which decoder it leaves reachable

A board is not just an NPU. Which *video decoder* cairn can open on it depends
on the kernel flavor its image runs and, separately, on which ffmpeg that image
ships — and the two Rockchip boards answer differently enough that findings do
not transfer between them (D-M6, confirmed by spike 0.4).

| board | kernel flavor | decode driver | reachable from our ffmpeg as | `decoder:` value |
|---|---|---|---|---|
| QCS6490 | mainline | Venus, V4L2 stateful M2M | `h264_v4l2m2m` | `v4l2` — **measured**, spike 0.3 |
| RK3576 | mainline 7.0+ | `rkvdec` VDPU383, V4L2 **stateless** (request API) | not by `h264_v4l2m2m`; unsettled | none: no profile, not measured |
| RK3566 | vendor BSP 6.1 | MPP, `/dev/mpp_service` | only in the `ffmpeg-rockchip` fork (`h264_rkmpp`) | `rkmpp`, the Rockchip release's own MPP binding, not ffmpeg |

The NPU half forks less than the decode half does: RK3566 and RK3576 share one
runtime (`librknnrt`), one converter (rknn-toolkit2, only `--target` differs)
and one artifact format — so a second Rockchip SoC should fork on decode
driver, kernel flavor and model budget, and reuse the RKNN backend. That is
an expectation: the backend has run on RK3566 only. (RK3566's 1 TOPS NPU is
RKNPU2-family, *not* the older rknpu1/`librknn_api` line — an earlier plan
label said otherwise.)

Two consequences worth carrying. A board profile that names a decoder gets it
or refuses (see `docs/profile-authoring.md`), and both shipped board profiles
name theirs: `v4l2` on QCS6490, `rkmpp` on RK3566, which that board's `auto`
never picks. And on RK3566 the surrounding work was plumbing rather than
silicon.
The add-on's six device nodes all open (`/dev/mpp_service`, `/dev/rga`,
`/dev/dri/card1` and `renderD129` — the NPU is a DRM device on this kernel,
not `/dev/rknpu` — and two dma-heaps), but MPP also needs the device tree:
with `/sys/firmware` masked, as a container has it by default, MPP matches no
SoC and every decoder open fails, while RKNN opens in the same container and
hides the cause. The add-on sets `devicetree: true` for it.

## QNN EP on QCS6490 (via ort)

- Path exists through the ort Rust crate: register the QNN EP with
  `backend_path` pointing at the HTP shared library. Per-SoC tuning:
  `htp_arch` (68 for QCS6490), `htp_performance_mode`, `vtcm_mb`.
  *(Superseded by measurement: the wiring that landed uses the ORT ≥1.22
  plugin-EP registration instead of `backend_path` — see "QNN wiring as
  landed" below.)*
- Models must be quantized to QDQ format (uint16 activations / uint8
  weights) via the onnxruntime quantization API or Qualcomm AIMET. No
  dynamic shapes on HTP. Context binary caching (`ep.context_enable`) cuts
  init cost.
- **Critical gap: the NMS operator is not in QNN's supported op list.**
  Standard YOLO exports with a fused NMS op fail. Two options: NMS-free
  heads (yolov10-class — already in cairn's catalog), or run the head on
  HTP and do NMS host-side in Rust. Note cairn's decode already does its
  own NMS host-side for GridObjectness-style heads (DEFAULT_NMS in
  catalog.rs), so this maps onto the existing decode split rather than
  forcing a new architecture — but it must become a profile validation
  rule: QNN profiles may not select fused-NMS model exports.
- Reported perf: YOLOv5s @480 INT8 ~527 µs raw inference; realistic full
  pipeline 100-300 fps claims for nano/small at 640. **Treat as optimistic
  until measured** — either way the QCS6490 comfortably exceeds the 15-30
  fps profile band.

## RKNN on rk3566 / rk3576

- Compilation is host-side Python only: rknn-toolkit2 (x86) converts
  ONNX→.rknn, INT8 (calibration dataset required) or FP16; INT4 on rk3576
  only. No dynamic shapes. YOLOv5-v11 officially covered by the model zoo (v8/v11
  as exports with the head cut before its box decode — the nine-tensor
  layout `tools/rknn-export`'s split export emits). **Trialed with
  rknn-toolkit2 and librknnrt 2.3.2:** in INT8 on the RK3566, yolox_s,
  yolox_tiny and both split heads (`yolov8split`, `yolo26split`) run and
  detect. In INT8 in the toolkit's simulator, the stock Ultralytics whole
  heads and the end-to-end head detect nothing (one output scale zeroes the
  scores) and rfdetr's scores are unusable. In FP16 on the board, the
  end-to-end head's boxes are wrong and rfdetr crashes the runtime (no
  GridSample op); Cairn's backend opens INT8 artifacts only —
  `tools/rknn-export/README.md`.
- Runtime from Rust: the board crate opens librknnrt itself with `dlopen`
  (`rknn/sys.rs`, written against the 2.3.2 API); rknpu2-rs is not used. No
  async and no batching — one inference at a time per context. Contexts of
  one model do overlap (measured, below); Cairn's engine holds one. No
  perf-mode API equivalent to QNN's, and none was needed: every budget was
  taken under the governors as found (`schedutil`, `rknpu_ondemand`).
  `rknn_set_core_mask` is not bound: nothing would set it.
- Frames in and out are copies. Input goes through `rknn_inputs_set`.
  Importing the scaler's dma-buf instead (`rknn_set_io_mem`) gave
  bit-identical outputs over 200 frames and needed no sync, but saved about
  1 ms a sample, some 2 %, so the shipped chain does not use it. Output comes
  back as floats from `rknn_outputs_get`: a native output buffer read back at
  cosine 0.05 under every layout tried (`tools/rknn-export/README.md`).
- Per-board reality:
  - rk3566 (~1 TOPS): on the HA Green, in the pipeline with one context,
    INT8 yolox_tiny@416 holds nine cameras at 2 fps (16.57 passes/s carried,
    46.8 ms a pass) and yolox_s@640 four (7.36, 120.0 ms) —
    `rk3566-tier1`'s budgets are those camera counts at the loader's
    1.875/s floor rate, 16.875 and 7.5. A third to just over half
    of each pass is CPU time in the calling thread; one context leaves the
    NPU 40-51 % busy at saturation, and a second context of the same model
    adds 57 % (tiny@416) or 34 % (s@640):
    `docs/evidence/rk3566-capacity-20261118.md`.
  - rk3576 (6 TOPS, INT4-capable): not measured. No profile ships for it.
- **Preprocessing: no Rust crate for RGA** (Rockchip's 2D accelerator for
  resize/color-convert, librga C API, dma_fd zero-copy), so the board crate
  binds librga by hand (`rga.rs`); `rkmpp` scales there. On the Green
  (librga 1.10.5, RGA2) a 1080p picture scales to 416² or 640² in 4.4-4.9 ms. librga
  converts with BT.601 and takes full or limited range from the destination
  buffer's format, not from the stream, so the binding picks it per picture
  from `mpp_frame_get_color_range`; the first build did not, and expanded
  full-range video as if it were limited.

## Known-broken combinations → profile validation rules

1. QNN backend + model export containing a fused NMS op → reject at
   profile validation (require NMS-free head or host-side-NMS decode).
2. RKNN backend + a family whose conversion was not measured to detect
   (stock whole heads, the end-to-end head, rfdetr) → reject unless the
   profile declares `experimental: true`, and warn with the reason when it
   does.
3. RKNN backend + an artifact whose input is not NHWC INT8 (an FP16 build)
   → refused by the backend when it opens the model. Config load cannot see
   inside the file.

That RKNN runs one inference at a time per context is not a rule: no profile
field can ask for async or batching, so it is a sizing fact
(`docs/profile-authoring.md`).

## Impact on the backend-trait seam

The `Detector::open`/`detect` seam survived both. QNN is an ort EP (same
crate, new registration path + EP options on the session builder). RKNN is a
second backend behind the seam, in `boards/cairn_rockchip`'s crate. What the
research asked of the seam, as built:

- **Per-backend session options.** Neither backend's are profile keys. QNN's
  (`soc_model`, `htp_arch`, performance mode, VTCM) are facts about the node,
  read from its environment (`config/runtime.exs`). RKNN takes none through
  the seam: its one setting, the runtime's path, is a NIF argument or
  `CAIRN_RKNN_LIBRARY`.
- **A capability report profile validation consumes.**
  Each backend's `Descriptor`, mirrored by each board's `backends/0`: the
  artifact (its extension in Rust, the `model:` key in Elixir), fused NMS,
  dynamic shapes, and on the Elixir side whether the CPU baseline needs an
  FP32 twin.
- **The artifact format.** A profile's `model:` is keyed per backend
  (`onnx:`, `qnn:`, `rknn:`).

## QNN wiring as landed (phase 2, 2026-08-07)

What `--backend qnn` actually does, per the phase-0 spike's proven recipe
(`tools/qnn-spike/README.md` — the version triple, traps, and D-P5
criterion live there and in
`.claude/plans/qcs6490-profiles/research/spike-results.md`):

- **Plugin EP, not a custom ORT build.** Stock ONNX Runtime (base 1.26.0
  on the board) plus the `onnxruntime-qnn` distribution's
  `libonnxruntime_providers_qnn.so`, registered at open via the ORT ≥1.22
  plugin-EP API — in ort 2.0.0-rc.12: `Environment::register_ep_library`,
  then `SessionBuilder::with_devices` over the devices the plugin exposes
  (`AppendExecutionProvider_V2` underneath). The `qnn` cargo feature /
  `system` build strategy researched earlier was never needed.
- **Flags** (the `cairn-detect` binary's, which the canary and the bench
  harnesses pass; the in-VM engine takes the same node facts from
  `CAIRN_QNN_LIBRARY`, `CAIRN_QNN_SOC_MODEL`, `CAIRN_QNN_HTP_ARCH`,
  `CAIRN_QNN_PERFORMANCE_MODE` and `CAIRN_QNN_VTCM_MB`): `--qnn-library`
  (the plugin EP .so, required), and
  `--qnn-soc-model 35 --qnn-htp-arch 68` (required in practice on
  QCS6490 — platform detection fails without them), plus optional
  `--qnn-performance-mode`, `--qnn-vtcm-mb`. `backend_type=htp` is always
  set. The QNN backend libraries must sit beside the plugin EP library;
  the DSP skel is delivered via `ADSP_LIBRARY_PATH`/`DSP_LIBRARY_PATH`.
- **Board binary linking**: the aarch64 build uses the crate's
  `ort-load-dynamic` feature (ort `load-dynamic`), dlopening the exact
  spike-proven `libonnxruntime.so` at runtime via `ORT_DYLIB_PATH` — no
  ORT libraries at cross-link time, no version skew against the plugin.
  Dev/CI x86 builds keep the default static link.
- **Fallback posture**: open fails loudly when the plugin registers but
  exposes no device (no NPU / wrong libs), and the embedder refuses
  `--backend qnn` outright until a QDQ embedder export exists. Per-node
  CPU fallback after a successful open is still possible and *invisible*
  in logs — the only accepted proof of HTP execution is a latency delta
  vs the `ort` backend (D-P5, ≥3×), which the board-bench harness
  enforces. The stage library's own surface for that check is the
  `infer latency: backend=… p50=… p95=…` stderr line `Detector::detect`
  emits every 100 runs. The in-VM host runs the same check unattended:
  `Cairn.Native.Host` measures the CPU pass once per engine load, in a
  subprocess (`--cpu-baseline` on the same model, or on the profile's FP32
  ONNX twin where the CPU cannot run the artifact — `rknn`), and
  `Cairn.Native.Health` reads the live pass latency against it. A backend
  it cannot measure is left unjudged rather than guessed at. Both sides of
  that ratio rise with load: the latency `Health` reads includes the wait
  for the shared model lock, and a baseline taken while streams are starting
  reads slower than one taken on an idle board.
- **Measured, phase-2 proof runs (2026-08-07, board .87, yolox_nano
  full-QDQ 416, real RTP feed + software decode)**: CPU EP p50 44.5 ms;
  QNN/HTP p50 8–12 ms with the `performance` cpufreq governor → 3.6–5.6×,
  D-P5 PASS. **Trap: the default `schedutil` governor makes QNN read
  ~19 ms p50** (2.3×, under the bar) at any real frame cadence — the DSP
  waits interleave with CPU-side EP work, the core never ramps, and the
  slowdown is flat and noiseless, so it looks exactly like a plausible
  HTP latency. It is not decode contention (unchanged at 640×480), not
  input-buffer churn (unchanged with a reused tensor), and not
  `htp_performance_mode` (inert — the spike's "Unable to set HTP power
  configurations" watch-item). The tight-loop spike driver never shows it
  because its own CPU work keeps the core ramped. Bench protocol (phase
  4) must pin or record the governor; loaded production boards (several
  cameras decoding) sit near the ramped number by construction.

## Quantized-export defect classes, and why CPU-EP verification cannot see them

Two defect classes shipped in every `*-qdq` artifact before 2026-08-20
(root-caused in `.claude/plans/presence-events/reviews/qdq-export-review.md`,
fixed by the qdq-reexport campaign). Both are structural, both survived a
CPU-EP-only verification pipeline, and each is why the other went unseen:

1. **Baked calibration ceiling.** `CalibMovingAverage` averaged per-frame
   maxima, so the score sigmoids' Q/DQ scales encoded a ceiling *below*
   the head's true range — per FPN level, hardest at the coarsest level.
   Close/large objects became structurally undetectable (a nano level-0
   ceiling of 0.1334), and every score above the ceiling clipped to it.
   Visible on any EP, but only if you compare score *distributions*
   against fp32 — a label histogram passes, and per-level maxima carried
   by one good frame pass. Killed by `qparam_gate.py`: any class-score
   sigmoid whose representable maximum `(qmax - zp) × scale` is below
   0.95 fails the export.

2. **EP qparam rewrite disagreeing with the graph.** The QNN EP pins
   16-bit sigmoid output scales to `1/65536` at graph-build time while
   the graph's DQ keeps the calibrated scale — so **on the HTP only**,
   every score is multiplied by the calibrated ceiling (measured live:
   CPU 0.799 × ceiling 0.810 = the recorded 0.613–0.685 band). The CPU
   EP executes the graph as written and *cannot* reproduce this; no
   local run sees it. The fixed recipe (`get_qnn_qdq_config` + MinMax,
   score sigmoids pinned to `1/65536` at a16 and `1/256` at a8) makes
   the file agree with the hardware instead.

Standing consequence: **no QDQ artifact is verified until it has an HTP
leg** — an on-board score-distribution comparison on real clip content,
with the CPU-EP numbers as the reference (acceptance: HTP ≈ CPU;
per-frame person-window median ratio ≥ 0.9, no plateau, no uniform
depression — each failure shape is one defect class's signature). The
campaign vehicle is the Elixir driver in `tools/qdq-export/driver/`
(`Driver.CLI` over `:erpc`; invocation in the qdq-export README) →
`htp_content_test.sh` (plugin-first, feed once — looped feeds wrap pts
and invalidate window analysis) → `htp_report.py`, gated by a
nano-parity check of the bench env against the phase-0 spike numbers.
Latency deltas prove *execution* on the HTP (D-P5); they say nothing
about *scores*, which is exactly where both defect classes live.

## Sources

- https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html
- https://github.com/onnxruntime/onnxruntime-qnn
- https://github.com/airockchip/rknn_model_zoo
- https://github.com/boundarybitlabs/rknpu2-rs
- https://docs.ultralytics.com/integrations/qnn
- https://docs.ultralytics.com/integrations/rockchip-rknn
- https://mysupport.qualcomm.com/supportforums/s/question/0D5dK000007AWh8SAG/ (QCS6490 yolov5 QNN benchmark)
- https://github.com/airockchip/librga
- https://bliiot.com/info-detail/rk3576-deep-dive-6-tops-npu-meets-unbeatable-cost-performance-in-aiot
- Frigate discussions (rk3566 real-world inference times)
