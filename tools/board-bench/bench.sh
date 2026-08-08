#!/bin/sh
# On-board bench runner (busybox ash). One run = one plugin group process
# serving N cameras for a fixed duration, with per-run latency, achieved
# rate, CPU and RSS recorded.
#
#   sh bench.sh <backend> <secs> <ncams> [extra plugin flags...]
#
# Env:
#   MODEL       artifact to run (default /data/cairn-bench/model.onnx)
#   SAMPLE_FPS  sample gate ceiling per camera (default 30)
#   CAM_URLS    file of rtsp:// URLs, one per line — real cameras. Absent,
#               every camera is a looping local clip feed (CLIP env), which
#               exercises identical decode+inference load minus network
#               jitter.
#   CLIP        fixture (default /data/cairn-bench/bench-feed.ts)
#   PIN_GOVERNOR=1  pin cpufreq to performance for the run, restore after.
#               Either way the governor in force is RECORDED: an unpinned
#               idle board reads ~2x slow on QNN (docs/npu-backends.md).
#
# Backend env (qnn): pass --qnn-library etc. as extra flags; ORT_DYLIB_PATH
# and ADSP_LIBRARY_PATH are set below from the standard bundle layout.
set -u
BACKEND=$1
SECS=$2
NCAMS=$3
shift 3
BASE=/data/cairn-bench
MODEL=${MODEL:-$BASE/model.onnx}
SAMPLE_FPS=${SAMPLE_FPS:-30}
CLIP=${CLIP:-$BASE/bench-feed.ts}
# Param expansion, not basename/awk: this busybox ships neither.
case ${SECS} in
'' | *[!0-9]* | 0) echo "secs must be a positive integer" >&2; exit 1 ;;
esac
case ${NCAMS} in
'' | *[!0-9]* | 0) echo "ncams must be a positive integer" >&2; exit 1 ;;
esac
if [ -n "${CAM_URLS:-}" ] && [ ! -r "$CAM_URLS" ]; then
  # Refused, not fallen back from: a missing URL file silently becoming
  # clip feeds would mislabel every number the run produces.
  echo "CAM_URLS=$CAM_URLS is not readable" >&2
  exit 1
fi
MB=${MODEL##*/}
MB=${MB%.onnx}
# Timestamped so a repeat run never overwrites its predecessor's raw
# evidence — repeatability pairs need both run dirs to survive.
TAG="$BACKEND-$MB-${NCAMS}cam"
RUN="$BASE/runs/$TAG-$(date +%s)"
mkdir -p "$RUN"

export LD_LIBRARY_PATH=$BASE/lib:/data/qnn-spike/lib
export ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1
export ADSP_LIBRARY_PATH="/data/qnn-spike/dsp;"
export DSP_LIBRARY_PATH="/data/qnn-spike/dsp;"

# Stale-run sweep: the cleanup trap below cannot fire when the
# controlling ssh dies mid-run, and orphaned feeds accumulate (eleven
# were found spraying RTP after one day of runs — they also wedge
# :os.cmd captures). A bench board runs no other ffmpeg/cairn-detect;
# if this board ever hosts production containers, scope this kill.
killall ffmpeg 2>/dev/null
killall cairn-detect 2>/dev/null

GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
FEEDS=""
PLUGIN=""
# The trap owns every side effect: an aborted run must not leak feeds
# or the plugin, and above all must not leave the governor pinned —
# that would silently distort every later unpinned run on this board.
cleanup() {
  for f in $FEEDS; do kill "$f" 2>/dev/null; done
  [ -n "$PLUGIN" ] && kill "$PLUGIN" 2>/dev/null
  if [ "${PIN_GOVERNOR:-0}" = "1" ]; then
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      echo "$GOV" > "$c/cpufreq/scaling_governor"
    done
  fi
}
trap cleanup EXIT INT TERM
if [ "${PIN_GOVERNOR:-0}" = "1" ]; then
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance > "$c/cpufreq/scaling_governor"
  done
fi
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) (was $GOV)" > "$RUN/meta"
echo "model: $MODEL backend: $BACKEND ncams: $NCAMS secs: $SECS sample_fps: $SAMPLE_FPS" >> "$RUN/meta"

# Feeds + cameras-json. Ports 5600, 5602, ... (RTP; +1 is RTCP's).
JSON="["
i=0
while [ "$i" -lt "$NCAMS" ]; do
  port=$((5600 + i * 2))
  # Line i+1 of CAM_URLS, pure shell (no sed on this busybox).
  url=""
  if [ -n "${CAM_URLS:-}" ]; then
    n=0
    while read -r cam_line; do
      n=$((n + 1))
      [ "$n" -eq $((i + 1)) ] && url=$cam_line && break
    done < "$CAM_URLS"
  fi
  if [ -n "$url" ]; then
    "$BASE/lib/ffmpeg" -nostdin -nostats -loglevel error -rtsp_transport tcp \
      -i "$url" -map 0:v -c copy -bsf:v h264_mp4toannexb \
      -f rtp -payload_type 96 "rtp://127.0.0.1:$port" 2>> "$RUN/feeds.err" &
  else
    "$BASE/lib/ffmpeg" -nostdin -nostats -loglevel error -re -stream_loop -1 \
      -i "$CLIP" -c copy -f rtp -payload_type 96 \
      "rtp://127.0.0.1:$port" 2>> "$RUN/feeds.err" &
  fi
  FEEDS="$FEEDS $!"
  [ "$i" -gt 0 ] && JSON="$JSON,"
  JSON="$JSON{\"id\":\"bench$i\",\"udp_port\":$port}"
  i=$((i + 1))
done
JSON="$JSON]"
sleep 2

# The plugin: one multiplexed group. stdin held open for the duration
# (EOF exits it); resource sampling reads /proc while it runs.
sleep "$SECS" | "$BASE/cairn-detect" --cameras-json "$JSON" \
  --model "$MODEL" --labels "$BASE/coco.names" --decoder sw \
  --sample-fps "$SAMPLE_FPS" --backend "$BACKEND" "$@" \
  > "$RUN/out.ndjson" 2> "$RUN/err" &
PLUGIN=$!
CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)
: > "$RUN/proc"
# Field extraction via `set --`, not cut (absent on this busybox). The
# comm field "(cairn-detect)" is one token, so utime/stime are $14/$15.
while kill -0 "$PLUGIN" 2>/dev/null; do
  if [ -r "/proc/$PLUGIN/stat" ]; then
    stat_line=$(cat "/proc/$PLUGIN/stat" 2>/dev/null) || stat_line=""
    statm_line=$(cat "/proc/$PLUGIN/statm" 2>/dev/null) || statm_line=""
    if [ -n "$stat_line" ] && [ -n "$statm_line" ]; then
      set -- $stat_line
      ut=${14}
      st=${15}
      set -- $statm_line
      echo "$(date +%s) $ut $st $2" >> "$RUN/proc"
    fi
  fi
  sleep 5
done
wait "$PLUGIN" 2>/dev/null
rc=$?
PLUGIN=""
for f in $FEEDS; do kill "$f" 2>/dev/null; done
FEEDS=""
# The one legitimate end is the timer-driven stdin EOF, which the
# plugin answers with _exit(3) ("control channel gone"). Anything else
# — a startup refusal, a bad model, a mid-run fault — must invalidate
# the run loudly instead of summarizing whatever partial output exists.
if [ "$rc" -ne 3 ]; then
  echo "plugin exited $rc (expected 3, the timer-driven stdin EOF) — run invalid" >&2
  tail -5 "$RUN/err" >&2
  exit 1
fi
# Governor restore is the trap's job, at exit — after the summary.

# Summary: latency lines verbatim; achieved rate from run count over
# wall time; CPU% from utime+stime delta over the sampled span; RSS
# peak. Pure-shell parsing throughout: this busybox has grep and tail
# but no sed, awk, cut, or basename.
grep "infer latency" "$RUN/err" > "$RUN/latency" || true
runs=0
while read -r line; do
  case $line in
  *"(total "*)
    t=${line##*"(total "}
    runs=${t%)*}
    ;;
  esac
done < "$RUN/latency"
echo "== $TAG =="
cat "$RUN/meta"
tail -3 "$RUN/latency"
rt=$((runs * 10 / SECS))
echo "inference runs: $runs over $SECS s = $((rt / 10)).$((rt % 10))/s ($NCAMS cams x sample_fps $SAMPLE_FPS)"
first=""
last=""
peak=0
while read -r ts ut st r; do
  [ -z "$first" ] && first="$ts $ut $st"
  last="$ts $ut $st"
  [ "$r" -gt "$peak" ] 2>/dev/null && peak=$r
done < "$RUN/proc"
if [ -n "$first" ] && [ "$first" != "$last" ]; then
  # Trailing zeros pad a torn final sample (the plugin can die between
  # the fields of its last /proc read) so set -u never trips here.
  set -- $first 0 0
  t0=$1 u0=$(($2 + $3))
  set -- $last 0 0
  t1=$1 u1=$(($2 + $3))
  [ "$t1" -gt "$t0" ] &&
    echo "cpu: $(((u1 - u0) * 100 / CLK / (t1 - t0)))% of one core; rss peak: $((peak * 4096 / 1048576)) MB"
fi
echo "run dir: $RUN"
