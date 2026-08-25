#!/usr/bin/env bash
# HTP fast-state probe: the u8 spike (research/u8-spike-board-20260825.md)
# caught a discrete ~17.0ms p50 state on yolox_s-a8 — 35% under the
# 26.2ms sustained number — in the FLOAT graph's first 100-pass window
# and in ~30% of the u8out legs' windows. This session asks what turns
# it on, with zero code change: `--qnn-performance-mode` already exists
# and bench.sh forwards extra flags.
#
#   tools/qdq-export/run_fast_state_probe.sh [run|fetch|all]
#
# Five 60s bench legs, float artifact only, one boot session (governor
# pinned, container stopped, restore on trap):
#   ctrl30    SAMPLE_FPS=30, no perf flag — reproduce 26ms + first-window 17
#   burst     SAMPLE_FPS=30, --qnn-performance-mode burst
#   shp       SAMPLE_FPS=30, --qnn-performance-mode sustained_high_performance
#   sparse5   SAMPLE_FPS=5, no perf flag — idle-heavy cadence; if 17ms
#             windows appear, the state correlates with DSP idle/boost,
#             not with load
#   ctrl30b   leg 1 again — within-session drift bound
#
# Read: per-leg p50 window distributions. If burst/shp pin 17ms, the
# fast state is DCVS and the fix is one profile knob; if sparse5 shows
# it and burst does not, it is an idle-boost artifact and NOT usable
# sustained; if nothing reproduces it, it was a session transient.
set -u
BOARD=${BOARD:-192.168.2.87}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out-20260820}
SPIKE=$OUT/htp/fast-state
CONTAINER=addon_c2da371c_cairn
QNN_FLAGS="--qnn-library /data/qnn-spike/lib/libonnxruntime_providers_qnn.so --qnn-soc-model 35 --qnn-htp-arch 68"
BENCH=/data/cairn-bench
MODEL=$BENCH/artifacts-fixed/yolox_s-qdq-a8.onnx
STAGE=${1:-all}
mkdir -p "$SPIKE"
LOG=$SPIKE/probe.log

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

# Board helpers, copied from run_u8_spike.sh (throwaway probe, same
# rationale as there).
remote() {
  local t=$1; shift
  timeout "$t" ssh -n -o BatchMode=yes "$BOARD" ":os.cmd(~c|$*|)" > /dev/null 2>&1
}
fetch() {
  timeout 300 scp -q -r -o BatchMode=yes "$BOARD:$1" "$2" < /dev/null 2>/dev/null
  case $2 in
  */) [ -e "$2$(basename "$1")" ] ;;
  *) [ -e "$2" ] ;;
  esac
}
remote_verified() {
  local t=$1 tag=$2 dest=$3 nonce="RV-$$-$RANDOM-$RANDOM"
  shift 3
  rm -f "$dest" "$dest.ok"
  remote "$t" "rm -f /data/tmp-$tag.ok; { $*; } > /data/tmp-$tag.txt 2>&1 && { sha256sum /data/tmp-$tag.txt; echo $nonce; } > /data/tmp-$tag.ok" || return 1
  fetch "/data/tmp-$tag.txt" "$dest" || return 1
  fetch "/data/tmp-$tag.ok" "$dest.ok" || return 1
  grep -qxF "$nonce" "$dest.ok" || return 1
  [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$(head -1 "$dest.ok" | cut -d' ' -f1)" ] || return 1
  rm -f "$dest.ok"
}
do_reboot() {
  log "== reboot"
  remote_verified 30 fs-bootid "$SPIKE/.bootid-before" "cat /proc/sys/kernel/random/boot_id" \
    || { log "FATAL: cannot read boot id"; exit 1; }
  remote 20 reboot
  sleep 20
  local waited=20
  while :; do
    if remote_verified 15 fs-bootid "$SPIKE/.bootid-after" "cat /proc/sys/kernel/random/boot_id" \
       && [ -s "$SPIKE/.bootid-after" ] \
       && ! cmp -s "$SPIKE/.bootid-before" "$SPIKE/.bootid-after"; then
      break
    fi
    sleep 10
    waited=$((waited + 10))
    [ "$waited" -ge 300 ] && { log "FATAL: no new boot id after ${waited}s"; exit 1; }
  done
  log "board back after ~${waited}s"
  sleep 30
}
engine_state() { remote_verified 30 fs-ps "$1" "balena-engine ps --format {{.Names}}"; }
ensure_engine_stopped() {
  local f=$SPIKE/.ps-check
  engine_state "$f" || { log "FATAL: cannot read engine state"; exit 1; }
  if grep -q cairn "$f"; then
    remote 90 "balena-engine stop $CONTAINER"
    engine_state "$f" || { log "FATAL: cannot re-read engine state"; exit 1; }
    grep -q cairn "$f" && { log "FATAL: container did not stop"; exit 1; }
    log "container stopped"
  fi
}
pin_governor() {
  remote_verified 30 fs-gov-save "$SPIKE/.gov-saved" \
    "if test ! -s /data/faststate-gov.saved; then cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /data/faststate-gov.saved; fi; cat /data/faststate-gov.saved" \
    || { log "FATAL: cannot verify saved governor"; exit 1; }
  remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$c/cpufreq/scaling_governor; done"
  remote_verified 30 fs-gov "$SPIKE/.gov-check" "cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor" \
    || { log "FATAL: cannot read back governors"; exit 1; }
  grep -qv '^performance$' "$SPIKE/.gov-check" && { log "FATAL: pin did not take"; exit 1; }
  cp "$SPIKE/.gov-saved" "$SPIKE/.gov-pinned"
  log "governor pinned (saved: $(cat "$SPIKE/.gov-saved"))"
}
do_finish() {
  log "== finish"
  if [ -f "$SPIKE/.gov-pinned" ]; then
    local gov
    gov=$(cat "$SPIKE/.gov-pinned")
    remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo $gov > \$c/cpufreq/scaling_governor; done; rm -f /data/faststate-gov.saved"
    log "governor restored to $gov"
  fi
  remote 90 "balena-engine start $CONTAINER"
  log "container start requested"
}

leg() { # <tag> <sample_fps> [extra flags...]
  local tag=$1 fps=$2
  shift 2
  ensure_engine_stopped
  log "leg $tag (fps $fps${1:+, $*})"
  remote 200 "MODEL=$MODEL SAMPLE_FPS=$fps PIN_GOVERNOR=1 sh $BENCH/bench.sh qnn 60 1 --model-profile yolox --input-size 640 $QNN_FLAGS $*" \
    || log "WARN: leg $tag rc nonzero"
}

do_run() {
  trap do_finish EXIT INT TERM
  do_reboot
  ensure_engine_stopped
  pin_governor
  remote_verified 30 fs-runs-before "$SPIKE/.runs-before" "ls $BENCH/runs" || : > "$SPIKE/.runs-before"
  leg ctrl30 30
  leg burst 30 --qnn-performance-mode burst
  leg shp 30 --qnn-performance-mode sustained_high_performance
  leg sparse5 5
  leg ctrl30b 30
}

do_fetch() {
  log "== fetch"
  mkdir -p "$SPIKE/runs"
  if remote_verified 30 fs-runs-after "$SPIKE/.runs-after" "ls $BENCH/runs"; then
    while read -r d; do
      [ -z "$d" ] && continue
      grep -qxF "$d" "$SPIKE/.runs-before" 2>/dev/null && continue
      fetch "$BENCH/runs/$d" "$SPIKE/runs/" || log "WARN: run $d fetch incomplete"
    done < "$SPIKE/.runs-after"
  fi
  log "fetched: $(ls "$SPIKE/runs" 2>/dev/null | wc -l) run dirs"
}

case $STAGE in
run) do_run ;;
fetch) do_fetch ;;
all) do_run; do_fetch ;;
*) echo "usage: $0 [all|run|fetch]" >&2; exit 2 ;;
esac
