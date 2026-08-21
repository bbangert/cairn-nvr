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
# Sampling is spread across the WHOLE clip: the stride is derived per
# source from its frame count, so the last frame sampled sits near the
# end. A fixed stride would not — at every-20th-frame the 10-frame budget
# lands entirely inside the first nine seconds, and with a 5 s
# pre-trigger window that is mostly the scene before the subject
# arrives. Calibration then measures an empty room and the subject's
# activations fall outside the range that was learned.
#
# Frame count is read from the container rather than counted: decoding
# every clip twice costs minutes across a 40-clip set, and the estimate
# only has to be close — an over-estimate samples slightly short of the
# end, an under-estimate is truncated by -frames:v.
set -eu
OUT=$1
shift
FRAMES_PER_SOURCE=${FRAMES_PER_SOURCE:-10}
mkdir -p "$OUT"
for src in "$@"; do
  base=$(basename "$src" | tr -c 'A-Za-z0-9._-' '_')
  total=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=nb_frames -of csv=p=0 "$src" 2>/dev/null | tr -d '\r')
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  if [ "$total" -le 0 ]; then
    # No frame count in the container (live RTSP, fragmented mp4): fall
    # back to a fixed stride, which is the pre-existing behaviour and
    # correct for a stream that has no end to spread across.
    step=20
  else
    # Interval between first and last REQUESTED sample, not total/N: with
    # 19 frames and a budget of 10, total/N truncates to 1 and the second
    # half of the clip is never calibrated. (N=1 is the total-step case.)
    if [ "$FRAMES_PER_SOURCE" -gt 1 ]; then
      step=$(((total - 1) / (FRAMES_PER_SOURCE - 1)))
    else
      step=$total
    fi
    [ "$step" -lt 1 ] && step=1
  fi
  ffmpeg -nostdin -nostats -loglevel error -i "$src" \
    -vf "select=not(mod(n\,$step))" -vsync vfr \
    -frames:v "$FRAMES_PER_SOURCE" \
    "$OUT/${base%.*}_%02d.png"
done
count=$(ls "$OUT" | wc -l)
echo "$OUT: $count frames"
