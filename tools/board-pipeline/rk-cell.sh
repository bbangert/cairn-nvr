#!/bin/sh
# One capacity cell on the HA Green (busybox ash): `podman run --rm` of a cairn
# Rockchip image, Cairn.BoardPipeline in its release's `bin/cairn eval` VM.
#
#   sh rk-cell.sh <tag> <streams>
#
# Required env: IMAGE, MODEL and RKNN_LIBRARY (container paths), INPUT_SIZE.
# Optional: CPU_TWIN (measured only with CANARY=1, which runs the release's
# probe binary first), CELL_SECONDS or SECONDS_ (300), SAMPLE_FPS (2), ENGINES
# (1), DECODER (rkmpp), LABELS, MODEL_PROFILE (yolox), CLIP, BASE. Writes
# $BASE/runs/<tag>-<n>cam-<epoch>/; reads /sys and /proc and never writes them.
# The last stdout line is always `cell <tag> streams=<n> rc=<rc> run=<dir>`;
# the exit status is podman's, 2 when the cell refused to start, 255 when
# podman's was never recorded.
set -u

TAG=${1:-}
STREAMS=${2:-}
NAME=cairn-bench-cell
BASE=${BASE:-/root/cairn-bench-rk}
CELL_SECONDS=${CELL_SECONDS:-${SECONDS_:-300}}
SAMPLE_FPS=${SAMPLE_FPS:-2}
ENGINES=${ENGINES:-1}
DECODER=${DECODER:-rkmpp}
LABELS=${LABELS:-/app/models/coco.names}
MODEL_PROFILE=${MODEL_PROFILE:-yolox}
CLIP=${CLIP:-/h/tier1-sub.aus}
CPU_TWIN=${CPU_TWIN:-}
CANARY=${CANARY:-0}

refuse() {
  echo "rk-cell: $1" >&2
  echo "cell ${TAG:--} streams=${STREAMS:--} rc=- run=-"
  exit 2
}

[ -n "$TAG" ] || refuse "usage: sh rk-cell.sh <tag> <streams>"
for var in IMAGE MODEL INPUT_SIZE RKNN_LIBRARY; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || refuse "$var is required"
done
# Refused here, before a container start is spent on it.
for var in STREAMS ENGINES CELL_SECONDS SAMPLE_FPS INPUT_SIZE; do
  eval "val=\${$var:-}"
  case $val in '' | *[!0-9]*) refuse "$var must be a number, got '$val'" ;; esac
done
# Only ever this one name: other containers on the board are not ours.
if podman container exists "$NAME" 2>/dev/null; then
  refuse "a container named $NAME exists; remove it by hand if it is stale"
fi

RUN="$BASE/runs/$TAG-${STREAMS}cam-$(date +%s)"
mkdir -p "$RUN" || refuse "cannot create $RUN"

# kB figures on one line, under the names given (/proc/meminfo's by default).
# Three expressions: `\|` in a basic regex is a GNU extension.
meminfo() {
  echo $(sed -n \
    -e "s/^MemAvailable: *\\([0-9]*\\) kB\$/${1:-MemAvailable}=\\1/p" \
    -e "s/^CmaFree: *\\([0-9]*\\) kB\$/${2:-CmaFree}=\\1/p" \
    -e "s/^SwapFree: *\\([0-9]*\\) kB\$/${3:-SwapFree}=\\1/p" /proc/meminfo)
}

read_or_dash() {
  v=$(cat "$1" 2>/dev/null)
  echo "${v:--}"
}

# 1 Hz; every 5th line adds memory and the container's main process, whose pid
# is cached once seen: each `podman inspect` is load on the board.
sample() {
  i=0
  pid=
  # $$ is still the cell's pid here: a cell killed without its EXIT trap
  # (SIGKILL) must not leave a sampler appending forever.
  while kill -0 $$ 2>/dev/null; do
    temp=$(read_or_dash /sys/class/thermal/thermal_zone0/temp)
    npu=$(sed -n 's/^NPU load: *\([0-9]*\)%.*/\1/p' /proc/rknpu/load 2>/dev/null)
    freq=$(read_or_dash /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    nfreq=$(read_or_dash /sys/class/devfreq/fde40000.npu/cur_freq)
    line="$(date +%s) temp=$temp npu=${npu:--} freq=$freq nfreq=$nfreq"
    if [ $((i % 5)) -eq 0 ]; then
      if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
        pid=$(podman inspect --format '{{.State.Pid}}' "$NAME" 2>/dev/null)
        [ "$pid" = 0 ] && pid=
      fi
      rss=- cpu=-
      if [ -n "$pid" ] && stat=$(cat "/proc/$pid/stat" 2>/dev/null); then
        rss=$(sed -n 's/^VmRSS:[^0-9]*\([0-9]*\) kB$/\1/p' "/proc/$pid/status" 2>/dev/null)
        # Past the parenthesised comm, which may hold spaces: fields 14 and
        # 15 are then the 12th and 13th.
        rest=${stat##*") "}
        set -- $rest
        shift 11
        cpu="$1,$2"
      fi
      line="$line $(meminfo memavail cmafree swapfree) rss=${rss:--} cpu=$cpu"
    fi
    echo "$line" >>"$RUN/samples.log"
    i=$((i + 1))
    sleep 1
  done
}

SAMPLER=
INTERRUPTED=0
stop_sampler() {
  [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
  SAMPLER=
}
on_signal() {
  INTERRUPTED=1
  podman stop -t 10 "$NAME" >/dev/null 2>&1
}
trap stop_sampler EXIT
trap on_signal INT TERM HUP

MEM_BEFORE=$(meminfo)
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
: >"$RUN/samples.log"
sample &
SAMPLER=$!

EXPR='Code.require_file("/h/board_pipeline.ex"); Cairn.BoardPipeline.main()'

# In the background so a TERM reaches on_signal now, not after the cell.
# librknnrt and MPP log to stderr: every byte outside printable ASCII becomes
# `?` and lines stop at 600, so out.log's lines are safe to `tail` or `grep`
# over ssh; its size is not bounded.
{
  podman run --rm --name "$NAME" --network host \
    --security-opt unmask=/sys/firmware \
    --device /dev/mpp_service --device /dev/rga \
    --device /dev/dri/card1 --device /dev/dri/renderD129 \
    --device /dev/dma_heap/system --device /dev/dma_heap/system-uncached \
    -v "$BASE/h:/h:ro" -v "$BASE/artifacts:/artifacts:ro" \
    -e SECRET_KEY_BASE=board-pipeline-eval-vm-serves-no-endpoint-so-this-signs-nothing-at-all \
    -e CAIRN_RKNN_LIBRARY="$RKNN_LIBRARY" -e BOARD_PIPELINE_BACKEND=rknn \
    -e BOARD_PIPELINE_MODEL="$MODEL" -e BOARD_PIPELINE_LABELS="$LABELS" \
    -e BOARD_PIPELINE_MODEL_PROFILE="$MODEL_PROFILE" -e BOARD_PIPELINE_INPUT_SIZE="$INPUT_SIZE" \
    -e BOARD_PIPELINE_CPU_TWIN="$CPU_TWIN" -e BOARD_PIPELINE_CANARY="$CANARY" \
    -e BOARD_PIPELINE_DECODER="$DECODER" -e BOARD_PIPELINE_CLIP="$CLIP" \
    -e BOARD_PIPELINE_STREAMS="$STREAMS" -e BOARD_PIPELINE_ENGINES="$ENGINES" \
    -e BOARD_PIPELINE_SECONDS="$CELL_SECONDS" -e BOARD_PIPELINE_SAMPLE_FPS="$SAMPLE_FPS" \
    "$IMAGE" /app/bin/cairn eval "$EXPR"
  echo $? >"$RUN/.rc"
} 2>&1 | LC_ALL=C sed 's/[^ -~]/?/g' | cut -c1-600 >"$RUN/out.log" &
PIPE=$!
# A signal before podman has created the container finds nothing to stop, so
# once interrupted the stop repeats until `podman run` has returned.
until [ -e "$RUN/.rc" ] || ! kill -0 "$PIPE" 2>/dev/null; do
  if [ "$INTERRUPTED" = 1 ]; then
    podman stop -t 10 "$NAME" >/dev/null 2>&1
    sleep 1
  else
    wait "$PIPE"
  fi
done
wait "$PIPE"

stop_sampler
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RC=$(cat "$RUN/.rc" 2>/dev/null)
RC=${RC:-255}
rm -f "$RUN/.rc"

cat >"$RUN/meta" <<EOF
tag=$TAG streams=$STREAMS engines=$ENGINES seconds=$CELL_SECONDS sample_fps=$SAMPLE_FPS
image=$IMAGE
harness=$(sha256sum "$BASE/h/board_pipeline.ex" 2>/dev/null | cut -c1-64)
model=$MODEL input_size=$INPUT_SIZE
start=$START end=$END rc=$RC interrupted=$INTERRUPTED
cpu_governor=$(read_or_dash /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) npu_governor=$(read_or_dash /sys/class/devfreq/fde40000.npu/governor)
before $MEM_BEFORE
after $(meminfo)
EOF

(cd "$RUN" && sha256sum out.log samples.log meta >SHA256SUMS)

grep -e '^board-pipeline: engine n=' -e '^board-pipeline: result ' "$RUN/out.log" | tail -n $((ENGINES + 1)) | cut -c1-300
echo "cell $TAG streams=$STREAMS rc=$RC run=$RUN"
exit "$RC"
