# NPU backend workflows: QNN (QCS6490)

The research record behind the generic board's backend-capability table
(`backends/0` in `Cairn.Board.Generic`) and the Rust descriptors it mirrors
(`ORT` and `QNN` in the stage library). A board in its own repository keeps
its own record: RKNN, MPP and RGA on rk3566/rk3576 are cairn-rockchip's
[docs/npu-rknn.md](https://github.com/bbangert/cairn-rockchip/blob/main/docs/npu-rknn.md).

It began as second-cycle research (2026-08-05, 11 sources), and what a board
has since measured replaced the research in place and says so. Figures
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
| RK3566 | vendor BSP 6.1 | MPP, `/dev/mpp_service` | only in the `ffmpeg-rockchip` fork (`h264_rkmpp`) | `rkmpp`, cairn-rockchip's own MPP binding, not ffmpeg |

A board profile that names a decoder gets it or refuses (see
`docs/profile-authoring.md`); the QCS6490 ladder names `v4l2`. What the
Rockchip rows cost beyond the decoder — the shared RKNN runtime, the device
nodes, MPP's need for the device tree — is in cairn-rockchip's
[docs/npu-rknn.md](https://github.com/bbangert/cairn-rockchip/blob/main/docs/npu-rknn.md).

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

## Known-broken combinations → profile validation rules

1. QNN backend + model export containing a fused NMS op → reject at
   profile validation (require NMS-free head or host-side-NMS decode).

A board's own backends bring their own rules; cairn-rockchip's RKNN ones are
in its [docs/npu-rknn.md](https://github.com/bbangert/cairn-rockchip/blob/main/docs/npu-rknn.md#known-broken-combinations--profile-validation-rules).

## Impact on the backend-trait seam

The `Detector::open`/`detect` seam survived both QNN and a board's own
backend. QNN is an ort EP (same crate, new registration path + EP options on
the session builder). A board's backend is a second backend behind the seam,
registered from the board's crate (cairn-rockchip's RKNN is one; see
`docs/architecture.md` § Adding a board). What the research asked of the
seam, as built:

- **Per-backend session options.** None are profile keys. QNN's
  (`soc_model`, `htp_arch`, performance mode, VTCM) are facts about the node,
  read from its environment (`config/runtime.exs`).
- **A capability report profile validation consumes.**
  Each backend's `Descriptor`, mirrored by each board's `backends/0`: the
  artifact (its extension in Rust, the `model:` key in Elixir), fused NMS,
  dynamic shapes, and on the Elixir side whether the CPU baseline needs an
  FP32 twin, whether the backend is experimental, and its conversion
  verdicts.
- **The artifact format.** A profile's `model:` is keyed per backend
  (`onnx:`, `qnn:`, and a board's own, such as cairn-rockchip's `rknn:`).

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
  `Cairn.Native.Host` measures the CPU pass once per engine load (and again
  when a fetched twin lands), in a subprocess (`--cpu-baseline` on the same
  model, or on the profile's FP32 ONNX twin where the CPU cannot run the
  artifact — cairn-rockchip's
  `rknn`), and `Cairn.Native.Health` reads the live pass latency against it. A backend
  it cannot measure is left unjudged rather than guessed at. Both sides of
  that ratio rise with load: the latency `Health` reads includes the wait
  for a free slot of the engine's model, and a baseline taken while streams are starting
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
- https://docs.ultralytics.com/integrations/qnn
- https://mysupport.qualcomm.com/supportforums/s/question/0D5dK000007AWh8SAG/ (QCS6490 yolov5 QNN benchmark)
