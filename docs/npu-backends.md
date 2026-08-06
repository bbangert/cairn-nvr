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
