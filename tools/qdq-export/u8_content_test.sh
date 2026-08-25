#!/bin/sh
# Spike-local copy of htp_content_test.sh with one mechanical change: the
# control channel is a pipe from a background writer loop, not a fifo.
# The board image that shipped hardware decode (0.1.8) dropped `mkfifo`
# from busybox; on it the original script's mkfifo silently fails,
# `exec 3>` then creates a REGULAR file, and the plugin reads the epoch
# line, hits EOF, and exits inside two seconds — the campaign's content
# methodology is broken on that image until it gets the same treatment.
#
# The writer subshell prints the epoch, then polls for $RUN/done; the
# teardown touches that file, the writer exits, the pipe's write end
# closes, and the plugin gets the same stdin-EOF shutdown (exit 3) the
# fifo used to deliver.
#
#   sh u8_content_test.sh <backend> <model> <clip> <tag> [extra flags...]
#
# Env and evidence layout are htp_content_test.sh's (PROFILE, INSIZE,
# SAMPLE_FPS, MIN_SCORE, LOAD_SECS; meta/out.ndjson/err under
# $BASE/content/$TAG).
set -u
BACKEND=$1
MODEL=$2
CLIP=$3
TAG=$4
shift 4
BASE=/data/cairn-bench
PROFILE=${PROFILE:-yolox}
INSIZE=${INSIZE:-416}
SAMPLE_FPS=${SAMPLE_FPS:-10}
MIN_SCORE=${MIN_SCORE:-0.05}
LOAD_SECS=${LOAD_SECS:-120}
[ -f "$MODEL" ] || { echo "no model at $MODEL" >&2; exit 1; }
[ -f "$CLIP" ] || { echo "no clip at $CLIP" >&2; exit 1; }

RUN="$BASE/content/$TAG"
mkdir -p "$RUN"
rm -f "$RUN/done"

export LD_LIBRARY_PATH=$BASE/lib:/data/qnn-spike/lib
export ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1
export ADSP_LIBRARY_PATH="/data/qnn-spike/dsp;"
export DSP_LIBRARY_PATH="/data/qnn-spike/dsp;"

killall ffmpeg 2>/dev/null
killall cairn-detect 2>/dev/null
sleep 1

{
  echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  echo "backend: $BACKEND profile: $PROFILE insize: $INSIZE sample_fps: $SAMPLE_FPS min_score: $MIN_SCORE"
  echo "model: $MODEL"
  sha256sum "$MODEL" 2>/dev/null
  echo "clip: $CLIP"
  sha256sum "$CLIP" 2>/dev/null
  sha256sum "$0" 2>/dev/null
  echo "extra_args: $*"
} > "$RUN/meta"

FEED=""
PLUGIN=""
cleanup() {
  : > "$RUN/done"
  [ -n "$FEED" ] && kill "$FEED" 2>/dev/null
  [ -n "$PLUGIN" ] && kill "$PLUGIN" 2>/dev/null
}
trap cleanup EXIT INT TERM

# $! after a background pipeline is the pipeline's LAST process — the
# plugin, which is exactly what the up-wait and the final wait need.
{
  echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"content","stream_epoch":"01K0QDQCONTENT000000000000","rtp":{"clock_rate":90000}}'
  # Bounded: a trap-less death (ssh kill, SIGKILL) never touches the
  # done-file, and an unbounded loop would then hold the pipe open
  # forever - the plugin lingering with a live QNN session until the
  # next run's killall, which is CDSP session-budget pressure. The cap
  # restores the fifo design's eventual-EOF-on-every-death-mode.
  n=0
  while [ ! -f "$RUN/done" ] && [ "$n" -lt 900 ]; do sleep 1; n=$((n + 1)); done
} | "$BASE/cairn-detect" --camera-id content --udp-port 5600 \
  --model "$MODEL" --model-profile "$PROFILE" --input-size "$INSIZE" \
  --labels "$BASE/coco.names" --decoder sw --sample-fps "$SAMPLE_FPS" \
  --min-score-json "{\"default\":$MIN_SCORE}" \
  --backend "$BACKEND" "$@" \
  > "$RUN/out.ndjson" 2> "$RUN/err" &
PLUGIN=$!

waited=0
while [ "$waited" -lt "$LOAD_SECS" ]; do
  grep -q "cairn-detect up:" "$RUN/err" && break
  kill -0 "$PLUGIN" 2>/dev/null || break
  sleep 1
  waited=$((waited + 1))
done
if ! grep -q "cairn-detect up:" "$RUN/err"; then
  echo "plugin never came up in ${LOAD_SECS}s — run invalid" >&2
  tail -10 "$RUN/err" >&2
  exit 1
fi
echo "up after ~${waited}s" >> "$RUN/meta"

"$BASE/lib/ffmpeg" -nostdin -nostats -loglevel error -re -i "$CLIP" \
  -map 0:v -c copy -bsf:v h264_mp4toannexb -f rtp -payload_type 96 \
  rtp://127.0.0.1:5600 2> "$RUN/feed.err"
feed_rc=$?
FEED=""
if [ "$feed_rc" -eq 0 ]; then
  echo "feed exited 0" >> "$RUN/meta"
else
  echo "feed exited $feed_rc — run suspect" >> "$RUN/meta"
fi

# Drain, then release the writer loop — the plugin's stdin EOF.
sleep 3
: > "$RUN/done"
wait "$PLUGIN" 2>/dev/null
rc=$?
PLUGIN=""
if [ "$rc" -ne 3 ]; then
  echo "plugin exited $rc (expected 3, stdin EOF) — run suspect" >> "$RUN/meta"
fi

frames=$(grep -c '"frame.objects"' "$RUN/out.ndjson" 2>/dev/null)
frames=${frames:-0}
echo "frame.objects lines: $frames" >> "$RUN/meta"
echo "== $TAG: $frames object frames, plugin rc=$rc, feed rc=$feed_rc =="
grep "infer latency" "$RUN/err" | tail -3
