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
import queue
import sys
import tempfile
import threading
import time

import av  # PyAV: decodes RTP via a generated SDP
import cv2
import numpy as np
import onnxruntime as ort

SAMPLE_FPS = 5
INPUT_SIZE = 640
NMS_IOU = 0.45
MAX_DETS = 32
OPEN_RETRY_S = 5
MAX_OPEN_ATTEMPTS = 12

STREAM_OPTIONS = {
    "protocol_whitelist": "file,udp,rtp",
    "fflags": "nobuffer",
    # Cairn's ffmpeg puts SPS/PPS in-band next to keyframes, and a plugin
    # starting mid-stream lands between them with nothing to probe. The
    # defaults give up in milliseconds ("Invalid data found"); these let the
    # probe wait out a GOP instead.
    "analyzeduration": "10000000",  # µs
    "probesize": "5000000",
    # A 2560x1920 camera pushes ~34 Mbps, and one keyframe is a burst of
    # several hundred loopback packets back to back. The 208 KB default
    # receive buffer overflows mid-burst, which shows up as a corrupt probe
    # ("Invalid data found") or torn frames later. 4 MB is net.core.rmem_max
    # on a stock kernel; raise that first if you still see RcvbufErrors climb
    # in /proc/net/snmp.
    "buffer_size": "4194304",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def emit(camera_id: str, pts: int, dets: list) -> None:
    print(json.dumps({"camera_id": camera_id, "pts": pts, "dets": dets}), flush=True)


def sdp_for(port: int) -> str:
    """Raw RTP has no session negotiation; feed the decoder a static SDP.

    Note the demuxer will also bind port+1 for RTCP even though Cairn never
    sends any — that port is reserved for us (see Cairn.UDPPorts). ffmpeg
    ignores an `a=rtcp:` override here, so the reservation has to hold.
    """
    return (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=cairn\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        f"m=video {port} RTP/AVP 96\r\n"
        "a=rtpmap:96 H264/90000\r\n"
    )


def open_stream(sdp_path: str) -> "av.container.InputContainer":
    """Open the RTP feed, waiting out the gap to the next keyframe.

    Joining between keyframes is routine (Cairn starts us alongside ffmpeg, and
    importing onnxruntime takes long enough to miss the opening parameter
    sets). Retrying in-process beats exiting: a restart would just land in the
    same gap, one backoff later. We do still give up eventually so a genuinely
    dead port surfaces as a plugin crash in Cairn's log rather than a silent
    spin.
    """
    for attempt in range(1, MAX_OPEN_ATTEMPTS + 1):
        try:
            return av.open(sdp_path, format="sdp", options=STREAM_OPTIONS, timeout=30)
        except av.FFmpegError as e:
            log(f"stream open attempt {attempt}/{MAX_OPEN_ATTEMPTS} failed ({e}); waiting for a keyframe")
            time.sleep(OPEN_RETRY_S)
    raise RuntimeError(f"no decodable stream after {MAX_OPEN_ATTEMPTS} attempts")


def load_labels(path: str | None) -> list[str]:
    if not path:
        return [str(i) for i in range(1000)]
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def preprocess(frame: "av.VideoFrame") -> tuple[np.ndarray, float, float]:
    img = frame.to_ndarray(format="rgb24")
    h, w = img.shape[:2]
    # letterbox-free resize; bboxes are normalized so only ratios matter
    resized = cv2.resize(img, (INPUT_SIZE, INPUT_SIZE))
    tensor = resized.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
    return tensor, w, h


def label_for(labels: list[str], cls: int) -> str:
    return labels[cls] if cls < len(labels) else str(cls)


def score_gate(labels: list[str], num_classes: int, min_scores: dict) -> np.ndarray:
    """Per-class score floor, as a vector indexable by class id."""
    default_min = float(min_scores.get("default", 0.5))
    return np.array(
        [float(min_scores.get(label_for(labels, c), default_min)) for c in range(num_classes)],
        dtype=np.float32,
    )


def postprocess(output: np.ndarray, labels: list[str], min_scores: dict) -> list:
    """YOLOv8 layout: (1, 4 + num_classes, 8400) -> contract dets.

    The raw export has no NMS baked in, so all 8400 anchors survive and the
    same object shows up dozens of times; we gate on score then run per-class
    NMS. Without it a single person emits ~20 near-identical boxes and the
    MAX_DETS cut drops genuinely distinct objects.
    """
    preds = output[0]
    boxes_xywh, scores_all = preds[:4].T, preds[4:].T
    class_ids = scores_all.argmax(axis=1)
    scores = scores_all.max(axis=1)

    # vectorized gate first: 8400 anchors down to a handful before any Python loop
    keep = scores >= score_gate(labels, scores_all.shape[1], min_scores)[class_ids]
    boxes_xywh, class_ids, scores = boxes_xywh[keep], class_ids[keep], scores[keep]
    if len(scores) == 0:
        return []

    # cx,cy,w,h -> x,y,w,h (top-left origin), still in input-pixel space
    xywh = boxes_xywh.copy()
    xywh[:, 0] -= xywh[:, 2] / 2
    xywh[:, 1] -= xywh[:, 3] / 2

    # cv2's NMS is class-agnostic; offsetting each class into its own coordinate
    # band keeps a person and an overlapping car from suppressing each other.
    offset = class_ids[:, None] * np.float32(INPUT_SIZE * 2)
    nms_boxes = xywh + np.hstack([offset, offset, np.zeros_like(offset), np.zeros_like(offset)])
    idxs = cv2.dnn.NMSBoxes(nms_boxes.tolist(), scores.tolist(), 0.0, NMS_IOU)
    if len(idxs) == 0:
        return []
    idxs = np.array(idxs).flatten()
    idxs = idxs[np.argsort(-scores[idxs])][:MAX_DETS]

    dets = []
    for i in idxs:
        x, y, w, h = (float(v) / INPUT_SIZE for v in xywh[i])
        # contract: bbox normalized 0..1 — boxes can run past the frame edge
        x0, y0 = max(0.0, x), max(0.0, y)
        x1, y1 = min(1.0, x + w), min(1.0, y + h)
        dets.append(
            {
                "label": label_for(labels, int(class_ids[i])),
                "score": round(float(scores[i]), 3),
                "bbox": [round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)],
            }
        )
    return dets


def infer_loop(slot, session, input_name, labels, min_scores, camera_id) -> None:
    """Consume sampled frames and print contract ndjson, one line per sample."""
    while True:
        pts_90k, frame = slot.get()
        tensor, _w, _h = preprocess(frame)
        output = session.run(None, {input_name: tensor})[0]
        emit(camera_id, pts_90k, postprocess(output, labels, min_scores))


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

    container = open_stream(sdp_path)

    last_sample = 0.0
    interval = 1.0 / SAMPLE_FPS

    # Inference runs off the decode thread. Held inline, a ~100ms model pass
    # stalls the socket read, and at this bitrate the kernel receive buffer
    # overflows inside that window — which corrupts the stream rather than
    # merely dropping a sample. The decode loop must never block.
    slot: queue.Queue = queue.Queue(maxsize=1)
    worker = threading.Thread(
        target=infer_loop,
        args=(slot, session, input_name, labels, min_scores, args.camera_id),
        daemon=True,
    )
    worker.start()

    dropped = 0
    for frame in container.decode(video=0):
        now = time.monotonic()
        if now - last_sample < interval:
            continue
        last_sample = now

        pts_90k = int(frame.pts * frame.time_base * 90_000) if frame.pts is not None else 0
        try:
            slot.put_nowait((pts_90k, frame))
        except queue.Full:
            # still busy with the previous sample; skip rather than queue up
            dropped += 1
            if dropped % 50 == 0:
                log(f"inference behind: {dropped} samples skipped so far")
        if not worker.is_alive():
            raise RuntimeError("inference thread died")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as e:  # exit loudly; Cairn restarts us with backoff
        log(f"fatal: {e}")
        sys.exit(1)
