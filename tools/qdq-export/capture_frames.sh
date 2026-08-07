#!/bin/sh
# Sample full-resolution calibration frames off real camera footage.
#
# Full-res on purpose: quantize_model.py's load_image_chw applies the
# resolved profile's own resize policy (yolox letterbox-114, yolov10/
# yolov8 stretch) to whatever size PNG it is handed, so ONE full-res
# frame set calibrates every family correctly. A pre-letterboxed set
# (model/calib_frames, 416) is a fixed point for yolox only — feeding
# it to a stretch-family calibration would bake yolox padding into the
# activation ranges.
#
# Sources are recorded event clips (the default) or any RTSP URL:
#   capture_frames.sh out_dir /path/to/clips/*.mp4
#   capture_frames.sh out_dir "rtsp://cam/stream"
#
# Sampling: every 20th decoded frame, up to FRAMES_PER_SOURCE (default
# 10) per source — the same cadence model/quantize-model.md documents
# for the yolox set, so set sizes stay comparable.
set -eu
OUT=$1
shift
FRAMES_PER_SOURCE=${FRAMES_PER_SOURCE:-10}
mkdir -p "$OUT"
for src in "$@"; do
  base=$(basename "$src" | tr -c 'A-Za-z0-9._-' '_')
  ffmpeg -nostdin -nostats -loglevel error -i "$src" \
    -vf "select=not(mod(n\,20))" -vsync vfr \
    -frames:v "$FRAMES_PER_SOURCE" \
    "$OUT/${base%.*}_%02d.png"
done
count=$(ls "$OUT" | wc -l)
echo "$OUT: $count frames"
