# CPU reference plugin

> Deploying rather than reading? Use `plugins/cairn-detect/` — a single Rust
> binary with hardware decode and ~7x lower CPU on the same clip. This plugin
> stays as the short, readable example of what the contract asks for.

Real CPU inference for Cairn on x86 dev machines: PyAV decodes the H.264
RTP feed, frames are sampled at ~5 fps, and a YOLOv8-style ONNX model runs
via onnxruntime. It exists to (a) exercise the full pipeline without
special hardware and (b) document how to write a plugin — read
`docs/plugin-contract.md` alongside `main.py`.

## Setup

```bash
cd plugins/cpu-reference
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

Then drop a YOLOv8-format ONNX export next to `main.py`. `coco.names` is
already in-tree; export the weights with ultralytics in a *throwaway* venv so
torch stays out of the plugin's own environment:

```bash
python3 -m venv /tmp/export && /tmp/export/bin/pip install ultralytics onnx
/tmp/export/bin/python -c "from ultralytics import YOLO; \
  YOLO('yolov8n.pt').export(format='onnx', imgsz=640, opset=12)"
mv yolov8n.onnx plugins/cpu-reference/
```

The export must report output shape `(1, 84, 8400)` — that is the layout
`postprocess` expects. `.venv/` and `*.onnx` are gitignored.

## Wire into config.yml

```yaml
cameras:
  - id: front_door
    rtsp_url: rtsp://...
    plugin:
      - plugins/cpu-reference/.venv/bin/python3
      - plugins/cpu-reference/main.py
      - --model
      - plugins/cpu-reference/yolov8n.onnx
      - --labels
      - plugins/cpu-reference/coco.names
```

Cairn appends `--camera-id`, `--udp-port`, and `--min-score-json` per the
contract. Logs land in `{data_dir}/log/plugin-front_door.log`.

## Notes

- Joining mid-stream is normal: PyAV resyncs on the next keyframe. The probe
  is given a generous `analyzeduration` so it waits for one rather than
  failing with "Invalid data found".
- The demuxer also binds `udp-port + 1` for RTCP even though Cairn sends
  none. Cairn reserves it (`Cairn.UDPPorts` allocates four ports per camera);
  if something else takes that port the stream will not open at all.
- Inference runs on its own thread. Held inline it stalls the socket read
  long enough to overflow the receive buffer at multi-megabit bitrates, which
  corrupts the stream rather than just dropping a sample.
- The raw YOLOv8 export has no NMS, so `postprocess` runs its own; without it
  one object emits dozens of near-identical boxes.
- The model contract is YOLOv8 output `(1, 84, 8400)`; other layouts need
  a tweak in `postprocess`.
- This plugin is intentionally not part of the Elixir release.
