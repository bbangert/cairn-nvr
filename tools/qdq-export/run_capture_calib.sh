#!/bin/sh
# Full-res calibration set off the camera's newest 20 recordings.
#
# model/calib_videos.txt's documented 20-clip list predates event
# retention — recordings rotate — so this samples whatever is newest.
# Calibration wants a representative distribution off the real camera,
# not specific files; the yolox 416 set (model/calib_frames) stays the
# documented fixed point for the CPU-int8 flow.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${SRC:-$ROOT/data/events/reolink_main}
OUT=${OUT:-$ROOT/plugins/cairn-detect/model/calib_frames_fullres}
clips=$(ls -t "$SRC"/*.mp4 | sed -n 1,20p)
sh "$(dirname "$0")/capture_frames.sh" "$OUT" $clips
