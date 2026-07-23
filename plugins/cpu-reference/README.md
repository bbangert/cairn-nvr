# CPU reference plugin

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
# any YOLOv8-format ONNX export works, e.g.:
#   yolo export model=yolov8n.pt format=onnx  (ultralytics)
# plus a labels file (coco.names)
```

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

- Joining mid-stream is normal: PyAV resyncs on the next keyframe.
- The model contract is YOLOv8 output `(1, 84, 8400)`; other layouts need
  a tweak in `postprocess`.
- This plugin is intentionally not part of the Elixir release.
