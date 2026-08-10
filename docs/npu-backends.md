# NPU backend workflows: QNN (QCS6490) and RKNN (rk3566/rk3576)

The research record behind `Cairn.Config.Profile`'s backend-capability
table and the plugin's `BackendKind::capabilities` — both cite this file.

Second-cycle research, 2026-08-05. 11 sources. Numbers below are
agent-reported and marked with confidence; fps claims should be re-verified
on hardware before being baked into profile fps bands.

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
  only. No dynamic shapes. YOLOv5-v11 officially covered by the model zoo;
  **yolov10 (NMS-free) and DETR-class (rfdetr) not documented — treat as
  unsupported until trialed.**
- Runtime from Rust: rknpu2-rs binds librknnrt (2.3.2 API), zero-copy
  in/out, but no async, no batching, no multi-core orchestration
  documented — assume sequential single-inference per model. No perf-mode
  API equivalent to QNN's.
- Per-board reality (inference-only vs pipeline):
  - rk3566 (~1 TOPS): model-zoo yolov8n@640 claimed 34 fps, but Frigate
    real-world reports 95-250 ms inference (~4-10 fps with overhead) —
    consistent with the profile's declared 2-4 fps band once decode +
    tracking overhead lands.
  - rk3576 (6 TOPS, INT4-capable): no official benchmarks found; ~6×
    rk3566 expected; Frigate discussions confirm multi-stream viability.
    Profile band likely 8-16 fps pending measurement.
- **Preprocessing: no Rust crate for RGA** (Rockchip's 2D accelerator for
  resize/color-convert, librga C API, dma_fd zero-copy). GPU/RGA
  preprocessing on rk35xx means writing an FFI wrapper — a real work item
  if CPU resize proves too costly at the target fps; not standard practice
  in Frigate either.

## Known-broken combinations → profile validation rules

1. QNN backend + model export containing a fused NMS op → reject at
   profile validation (require NMS-free head or host-side-NMS decode).
2. RKNN backend + yolov10/DETR-class families → unverified; reject or mark
   experimental until a conversion trial succeeds.
3. Any profile assuming async/batched inference on RKNN → invalid;
   runtime is sequential.

## Impact on the backend-trait seam

The `Detector::open`/`detect` trait seam survives. QNN is an ort EP (same
crate, new registration path + EP options on the session builder). RKNN is
a second trait impl over rknpu2-rs. The trait's contract should include:
(a) per-backend session options from the profile (htp_arch, perf mode,
core mask), (b) a capability report (supports fused NMS? dynamic shapes?)
that profile validation consumes, (c) model artifact format expected
(.onnx vs .rknn) — profiles reference backend-specific artifacts.

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
- **Flags**: `--qnn-library` (the plugin EP .so, required), and
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
  enforces. The plugin's own surface for that check is the
  `infer latency: backend=… p50=… p95=…` stderr line `Detector::detect`
  emits every 100 runs. The in-VM host runs the same check unattended:
  `Cairn.Native.Host` measures the CPU pass once at engine init
  (`cpu_baseline_ms`, a second ORT session on the same model) and
  `Cairn.Native.Health` reads the live pass latency against it. A backend
  it cannot measure is left unjudged rather than guessed at.
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
