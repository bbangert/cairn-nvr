#!/usr/bin/env python3
"""Cairn CPU reference plugin.

Receives H.264 RTP from Cairn (see docs/plugin-contract.md), decodes with
PyAV, samples frames at ~SAMPLE_FPS, runs a small ONNX detection model via
onnxruntime, and prints contract ndjson on stdout.

Runs the full Cairn pipeline on plain x86 dev machines and doubles as the
plugin-author documentation. Not part of the Elixir release.

Usage (Cairn appends the contract args):

    python3 main.py --model yolov8n.onnx --labels coco.names \
        --camera-id front_door --udp-port 17000 --min-score-json '{...}'

The model must take a 640x640 RGB image and produce YOLOv8-style output
(1, 84, 8400); anything else needs a postprocess tweak below.
"""

import argparse
import json
import sys
import tempfile
import time

import av  # PyAV: decodes RTP via a generated SDP
import numpy as np
import onnxruntime as ort

SAMPLE_FPS = 5
INPUT_SIZE = 640


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def emit(camera_id: str, pts: int, dets: list) -> None:
    print(json.dumps({"camera_id": camera_id, "pts": pts, "dets": dets}), flush=True)


def sdp_for(port: int) -> str:
    """Raw RTP has no session negotiation; feed the decoder a static SDP."""
    return (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=cairn\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        f"m=video {port} RTP/AVP 96\r\n"
        "a=rtpmap:96 H264/90000\r\n"
    )


def load_labels(path: str | None) -> list[str]:
    if not path:
        return [str(i) for i in range(1000)]
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def preprocess(frame: "av.VideoFrame") -> tuple[np.ndarray, float, float]:
    img = frame.to_ndarray(format="rgb24")
    h, w = img.shape[:2]
    # letterbox-free resize; bboxes are normalized so only ratios matter
    import cv2  # noqa: PLC0415 (optional dep, imported lazily)

    resized = cv2.resize(img, (INPUT_SIZE, INPUT_SIZE))
    tensor = resized.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
    return tensor, w, h


def postprocess(output: np.ndarray, labels: list[str], min_scores: dict) -> list:
    """YOLOv8 layout: (1, 4 + num_classes, 8400)."""
    preds = output[0]
    boxes, scores_all = preds[:4].T, preds[4:].T
    dets = []
    class_ids = scores_all.argmax(axis=1)
    scores = scores_all.max(axis=1)
    default_min = float(min_scores.get("default", 0.5))

    for (cx, cy, w, h), cls, score in zip(boxes, class_ids, scores):
        label = labels[cls] if cls < len(labels) else str(cls)
        threshold = float(min_scores.get(label, default_min))
        if score < threshold:
            continue
        dets.append(
            {
                "label": label,
                "score": round(float(score), 3),
                "bbox": [
                    round(float(cx - w / 2) / INPUT_SIZE, 4),
                    round(float(cy - h / 2) / INPUT_SIZE, 4),
                    round(float(w) / INPUT_SIZE, 4),
                    round(float(h) / INPUT_SIZE, 4),
                ],
            }
        )
    return dets[:32]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--camera-id", required=True)
    parser.add_argument("--udp-port", type=int, required=True)
    parser.add_argument("--min-score-json", default="{}")
    parser.add_argument("--model", required=True, help="path to an ONNX detection model")
    parser.add_argument("--labels", help="newline-separated label names")
    args = parser.parse_args()

    min_scores = json.loads(args.min_score_json)
    labels = load_labels(args.labels)
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    log(f"cpu-reference up: camera={args.camera_id} udp={args.udp_port} model={args.model}")

    with tempfile.NamedTemporaryFile("w", suffix=".sdp", delete=False) as f:
        f.write(sdp_for(args.udp_port))
        sdp_path = f.name

    container = av.open(
        sdp_path,
        format="sdp",
        options={
            "protocol_whitelist": "file,udp,rtp",
            "fflags": "nobuffer",
        },
        timeout=30,
    )

    last_sample = 0.0
    interval = 1.0 / SAMPLE_FPS

    for frame in container.decode(video=0):
        now = time.monotonic()
        if now - last_sample < interval:
            continue
        last_sample = now

        pts_90k = int(frame.pts * frame.time_base * 90_000) if frame.pts is not None else 0
        tensor, _w, _h = preprocess(frame)
        output = session.run(None, {input_name: tensor})[0]
        emit(args.camera_id, pts_90k, postprocess(output, labels, min_scores))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as e:  # exit loudly; Cairn restarts us with backoff
        log(f"fatal: {e}")
        sys.exit(1)
