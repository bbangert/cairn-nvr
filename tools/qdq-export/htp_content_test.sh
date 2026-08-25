#!/bin/sh
# On-board content test: one plugin run = one model x backend x clip,
# with the corrected methodology the 2026-08-20 board day paid for:
#
#   1. plugin FIRST — the RTP listener is up before any frame plays, so
#      the clip's head cannot pour into a dead port during model load
#      (the feed-first race that invalidated a day of bench analysis);
#   2. the feed plays ONCE — no -stream_loop, so pts stay monotonic and
#      stream-anchored: pts/90000 IS clip time as-is (looped pts wrap
#      and the mapping is garbage). The analyzer never p0-normalizes —
#      an empty clip head emits no line to anchor a p0 on;
#   3. raw evidence only — the ndjson and stderr are the deliverable;
#      analysis happens off-board (htp_report.py), because this busybox
#      has no python and CR-heavy logs render blank over ssh anyway.
#
#   sh htp_content_test.sh <backend> <model> <clip> <tag> [extra flags...]
#
# Env: PROFILE (default yolox; use yolov8 for yolo26/yolov8 raw heads),
# INSIZE (default 416), SAMPLE_FPS (default 10), MIN_SCORE (default 0.05
# — low so the score DISTRIBUTION is visible; a depressed band below a
# 0.5 floor is exactly the defect signature this test exists to see),
# LOAD_SECS (default 120, ceiling on model load / HTP graph prepare).
#
# Runs under the standard bench env (/data/cairn-bench + /data/qnn-spike
# libs). Trust in that env comes from the nano-parity gate the campaign
# runner performs first — not from this script.
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

export LD_LIBRARY_PATH=$BASE/lib:/data/qnn-spike/lib
export ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1
export ADSP_LIBRARY_PATH="/data/qnn-spike/dsp;"
export DSP_LIBRARY_PATH="/data/qnn-spike/dsp;"

# Orphan sweep before, not after: a dead ssh session cannot run traps,
# and a stale feed spraying RTP poisons the next run's pts mapping.
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
  # The methodology digest: the campaign's retry guard and the analyzer
  # match this script's own sha and the run's extra flags, so a changed
  # methodology regenerates evidence instead of re-labeling old runs.
  sha256sum "$0" 2>/dev/null
  echo "extra_args: $*"
} > "$RUN/meta"

FEED=""
PLUGIN=""
cleanup() {
  # The done-file first: it releases the control writer's poll loop on
  # every exit path, so an aborted run cannot leave a sleeping writer
  # holding the pipe.
  : > "$RUN/done"
  [ -n "$FEED" ] && kill "$FEED" 2>/dev/null
  [ -n "$PLUGIN" ] && kill "$PLUGIN" 2>/dev/null
}
# Signals must be TERMINAL: a trapped INT/TERM otherwise resumes the
# script, which would drain, finalize, and write the completion marker
# for a run that was interrupted mid-feed. EXIT keeps cleanup-only.
trap 'cleanup; trap - EXIT; exit 130' INT TERM
trap cleanup EXIT

# The control channel is a pipe from a background writer loop: the
# writer prints the epoch, then polls for $RUN/done; teardown touches
# that file, the writer exits, the write end closes, and the plugin gets
# the stdin EOF that ends it (exit 3, "control channel gone"). This
# replaced a fifo held on fd 3 after the 0.1.8 board image's busybox
# dropped `mkfifo`: the failed mkfifo let `exec 3>` create a REGULAR
# file, and every run died in ~2s reading one line then EOF, looking
# exactly like a clean host-initiated shutdown
# (.claude/solutions/board-image-dropped-mkfifo-*.md). Still not a piped
# `sleep` timer — its shutdown was `killall sleep`, a host-wide hammer
# no bench script gets to swing; the run's ceiling stays the campaign
# driver's ssh timeout.
rm -f "$RUN/done"
# $! after a background pipeline is the pipeline's LAST process — the
# plugin, which is what the up-wait and the final wait need.
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

# Model load / HTP graph prepare gates the feed. Poll granularity 1s;
# these sleeps finish before the killall below can ever run.
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

# One pass, real-time pacing. mp4 sources need the annexb filter for the
# RTP muxer (the .ts bench feeds never did).
"$BASE/lib/ffmpeg" -nostdin -nostats -loglevel error -re -i "$CLIP" \
  -map 0:v -c copy -bsf:v h264_mp4toannexb -f rtp -payload_type 96 \
  rtp://127.0.0.1:5600 2> "$RUN/feed.err"
feed_rc=$?
FEED=""
if [ "$feed_rc" -eq 0 ]; then
  echo "feed exited 0" >> "$RUN/meta"
else
  # In the meta's own suspect vocabulary: the campaign's retry guard and
  # the analyzer both key on this phrase, and a truncated feed must not
  # read as a completed run anywhere downstream.
  echo "feed exited $feed_rc — run suspect" >> "$RUN/meta"
fi

# Drain, then release the control writer — the plugin's stdin EOF, and
# nothing else's.
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
# This line doubles as the run's completion marker: it is only reached
# after the feed exit and plugin shutdown statuses above, so the guard
# and analyzer require it — a truncated meta must not read as complete.
echo "frame.objects lines: $frames" >> "$RUN/meta"
echo "== $TAG: $frames object frames, plugin rc=$rc, feed rc=$feed_rc =="
grep "infer latency" "$RUN/err" | tail -3
