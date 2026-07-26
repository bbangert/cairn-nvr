# Multiplexed Plugin Research: Web Sources

**Date:** 2026-07-25  
**Focus:** Single detector process serving N camera streams (Coral Edge TPU exclusive-access pattern)

---

## 1. Frigate Architecture: Single Detector Process & Shared Queue

**Source:** Frigate Official Docs [T1]
- URL: https://docs.frigate.video/configuration/object_detectors/

### Shared Detection Queue Pattern
Frigate implements a **unified detection architecture** where multiple detector processes pull from a common queue of detection requests across all cameras. This is the key scaling pattern: detectors are decoupled from camera pipelines and compete for shared work.

### Device Selection & Multi-TPU
- **USB single:** `device: usb`
- **USB multiple:** `device: usb:0`, `usb:1`, etc.
- **PCIe single:** `device: pci`
- **PCIe multiple:** `device: pci:0`, `pci:1`, etc.
- **Constraint:** Only one detector type allowed for object detection (cannot mix EdgeTPU + OpenVINO simultaneously)

### Detector Scaling
When a single detector cannot keep up with queue rate, add more detector instances of the same type (assuming hardware supports concurrent access). Each detector process independently pulls from the shared queue.

### Crash Recovery
No explicit mechanism documented; relies on Erlang supervision. When a detector crashes, presumably the queue persists and a supervisor restarts the detector process.

---

## 2. Coral libedgetpu: Maintenance Status & Constraints

**Source:** Google Coral libedgetpu Repository [T1]
- URL: https://github.com/google-coral/libedgetpu
- **Status:** ARCHIVED October 14, 2025 — no longer maintained

### Key Points
- Runtime driver for all Coral.ai devices (USB, PCIe, M.2)
- Two performance variants: `libedgetpu1-std` (standard) and `libedgetpu1-max` (high-performance)
- **Exclusive Access:** Not documented in libedgetpu README, but implied by Coral hardware design (single-threaded ASIC)
- **Multi-TPU:** No explicit multi-TPU coordination in libedgetpu; device selection strings allow multiple devices, but application must serialize or use separate processes

### Installation Implications
Original Coral runtime builds no longer work with current TensorFlow Lite runtime versions (as of 2025). Community alternatives exist for active maintenance.

---

## 3. Viseron + DeepStack: HTTP API to Separate Service

**Source:** Viseron DeepStack Component Docs [T2]
- URL: https://viseron.netlify.app/components-explorer/components/deepstack

### Architecture Pattern
DeepStack is a **separate HTTP service** (remote or localhost). Viseron sends detection requests over HTTP to a single shared service.

### Per-Camera Configuration
- **FPS:** Configurable per camera (default: 1)
- **Timeout:** HTTP request timeout (default: 10 seconds)
- **Motion-triggered:** `scan_on_motion_only` conserves resources
- **Image resizing:** `image_width`, `image_height` for inference speedup

### Queue Abstraction
HTTP protocol handles implicit queueing; client (camera pipeline) blocks on HTTP request until response arrives. No explicit multi-stream multiplexing; each camera makes independent requests.

### Failure Handling
Timeout-based; if DeepStack service hangs, Viseron request eventually times out and can be retried or skipped.

---

## 4. Scrypted: Plugin Architecture with Hardware Routing

**Source:** Scrypted Object Detection Docs [T2]
- URL: https://docs.scrypted.app/detection/object-detection.html

### Plugin Types
- **CoreML:** Apple Silicon Neural Engine
- **OpenVINO:** Intel CPU/GPU/NPU
- **ONNX:** NVIDIA GPU (CUDA/cuDNN)
- **TensorFlow Lite:** Cross-platform, Coral TPU support

### Multi-Camera Handling
Per-camera integration: each camera stream routes to the selected plugin. Coral TPU support configured via device pass-through (e.g., Docker device mapping).

### Stream Isolation
Plugin architecture abstracts per-device routing. Scrypted NVR selects one plugin globally for all cameras (unlike Frigate's per-detector-type constraint).

### Limitation
No explicit queue/buffering documentation; plugin abstraction hides implementation details.

---

## 5. Elixir/OTP: Port-Based Multiplexing Patterns

### Port Communication [T1]
**Source:** Elixir Port Documentation
- URL: https://elixir.hexdocs.pm/Port.html

#### Port.open/2 Options
- `:binary` — receive as binary, not byte list
- `:line` — split input on newlines (automatic line-framing)
- `:exit_status` — receive `{port, {:exit_status, status}}` on crash

#### Message Format (handle_info callbacks)
- `{port, {:data, data}}` — stdout data from external process
- `{port, {:exit_status, status}}` — process termination (0 = success, non-zero = error)
- `{port, :closed}` — port closed

#### Backpressure Control
`Port.command/3` options: `:force` (ignore backpressure, buffer internally) or `:nosuspend` (return error if buffer full). Use `:nosuspend` for explicit flow control in high-rate scenarios.

### GenServer Port Ownership [T3]
**Source:** Managing External Commands with Ports
- URL: https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/

#### Patterns
- Open port in GenServer `init/1`
- Receive data in `handle_info/2` via `{port, {:data, text}}`
- Graceful shutdown: `Process.flag(:trap_exit, true)` and `terminate/2`
- **Critical:** Flush external process stdout for timely line delivery

#### Demultiplexing Strategy
GenServer can decode ndjson or other framing from `{:data, text}` messages and dispatch to per-stream handlers via routing table. At 100 lines/sec (20 cameras × 5 lines/sec), inline routing in `handle_info` is feasible; no need for separate demux processes unless blocking work dominates.

---

## 6. Coral Models: Realistic Choices & Constraints

**Source:** Coral Model Zoo & Community Reports [T2-T3]
- URL: https://www.coral.ai/models/object-detection/
- URL: https://github.com/blakeblackshear/frigate/discussions/7650
- URL: https://www.researchgate.net/publication/373507345_Efficient_Edge_Deployment_Demonstrated_on_YOLOv5_and_Coral_Edge_TPU

### Production-Ready Models
- **EfficientDet-Lite0:** Officially supported, good accuracy/speed tradeoff
- **SSD MobileNetv2:** Official models available, proven in Frigate
- **YOLO:** Challenging; many operations don't compile to EdgeTPU (fallback to CPU)

### Compilation Reality
Edge TPU compiler maps operations until incompatibility. Problem ops: LeakyReLU, Hardswish.
- YOLOv5: better compatibility than v8, still has CPU fallback (24+ ops)
- YOLOv8: 233 ops on TPU, 24 on CPU (unacceptable for single-device exclusivity)

### Single-Model Constraint
No explicit constraint documented, but practical: one model per detector instance. To swap models, restart detector (queue drains/replays).

---

## 7. Architectural Synthesis for Cairn

### Recommended Pattern
1. **Shared Request Queue** (Frigate-inspired)
   - GenServer holds one Port to external detector process
   - Camera pipelines enqueue `{frame_id, frame_bytes, callback_pid}` tuples
   - Detector reads frames, runs inference, sends results ndjson to stdout

2. **Port Communication**
   - Use `:line` mode on Port.open to auto-split on newlines
   - Each line is one JSON detection result
   - Frame ID in JSON links result back to camera + callback

3. **Backpressure**
   - Use `:nosuspend` in Port.command to avoid filling internal buffer
   - If buffer full, drop or queue in Elixir-side queue (not in external process queue)

4. **Crash Recovery**
   - Supervise detector Port process with Supervisor
   - On crash, supervisor restarts; queue requests wait for restart
   - Consider per-camera request timeout to fail fast if detector wedged >N seconds

5. **Device Exclusivity** (Coral-specific)
   - Pass device string (e.g., `--device=usb:0`) via argv to external process
   - External process owns libedgetpu handle exclusively
   - Multiple TPUs = multiple detector instances, each with own Port

### Model Loading
- EfficientDet-Lite0 or SSD MobileNetv2 recommended (proven on Frigate)
- Load model path via argv; single model per detector instance
- If multi-model needed, spin separate detector processes with different models

---

## 8. Known Pitfalls & Workarounds

| Issue | Source | Mitigation |
|-------|--------|-----------|
| libedgetpu archived, no future maintenance | [T1] | Pin libedgetpu version; consider ONNX/OpenVINO fallback |
| Frame batching can wedge detector | [T3] | Timeout per-frame request; don't batch (1 frame per request) |
| Port stdout buffering delays lines | [T3] | Flush external process stdout; use `:line` mode |
| Coral driver install fails (Debian 13) | [T2] | Try `gasket-builder`; verify secure boot off; fallback to OpenVINO |
| YOLO ops don't compile to TPU | [T3] | Use EfficientDet or SSD MobileNet; accept YOLOv5 partial CPU fallback if needed |

---

## Sources Fetched

| Tier | Source | URL |
|------|--------|-----|
| T1 | Frigate Object Detectors | https://docs.frigate.video/configuration/object_detectors/ |
| T1 | Coral libedgetpu Repo (archived) | https://github.com/google-coral/libedgetpu |
| T1 | Elixir Port Docs | https://elixir.hexdocs.pm/Port.html |
| T2 | Viseron DeepStack Component | https://viseron.netlify.app/components-explorer/components/deepstack |
| T2 | Scrypted Object Detection | https://docs.scrypted.app/detection/object-detection.html |
| T2 | Frigate Coral Discussion | https://github.com/blakeblackshear/frigate/discussions/21566 |
| T3 | Managing External Commands in Elixir with Ports | https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/ |
| T3 | Coral Model Zoo | https://www.coral.ai/models/object-detection/ |
| T3 | YOLOv5 on Coral Research | https://www.researchgate.net/publication/373507345_Efficient_Edge_Deployment_Demonstrated_on_YOLOv5_and_Coral_Edge_TPU |

