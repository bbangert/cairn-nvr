#!/bin/bash
# HTP verification campaign driver (phase 3 of the qdq-reexport plan).
# Runs from the dev container against the board; every on-board step is
# self-logging and every artifact of evidence is fetched back under
# $OUT/htp/. Nothing here interprets scores — that is htp_report.py's
# job, on the fetched files.
#
#   tools/qdq-export/run_htp_campaign.sh [all|push|envcheck|content|latency|fetch|finish]
#
# Stages (all = the lot, in order):
#   push      artifacts + htp_content_test.sh to the board, sha-verified
#   envcheck  nano-parity spike run — gates trust in the bench env
#             (bench ORT/QNN libs are NOT the container's; a run that
#             does not reproduce the phase-0 spike numbers means scores
#             from this env are evidence about nothing)
#   content   per-rung unlooped content runs on the board clips (QNN),
#             plus a nano CPU-EP control and the OLD defective nano as a
#             sensitivity control (the test must SEE the known defect)
#   latency   per-rung bench.sh runs, governor pinned (phase 3.3)
#   fetch     pull /data/cairn-bench/content + new bench run dirs
#   finish    restart the cairn container + restore the governor
#
# The cairn container is STOPPED for the duration (it holds the NPU —
# Ben's direction 2026-08-20); `finish` restarts it, and runs on a trap
# so an aborted campaign does not leave the NVR down.
set -u
BOARD=${BOARD:-192.168.2.87}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out-20260820}
HTP=$OUT/htp
ART=$OUT/artifacts
CONTAINER=addon_c2da371c_cairn
QNN_FLAGS="--qnn-library /data/qnn-spike/lib/libonnxruntime_providers_qnn.so --qnn-soc-model 35 --qnn-htp-arch 68"
CLIPS=${CLIPS:-"ac86 f58a aeb4"}
# The shipped defective nano, byte-for-byte: the sensitivity control is
# only a control if THESE bytes ran. Anything else at the board path —
# including someone "fixing" it — voids the CAP demonstration.
OLD_NANO_SHA=e4bb2552c6f3c810ae6fc40686f6b4cac5e21eab885b868e6469a2c87098627d
STAGE=${1:-all}
mkdir -p "$HTP/runs"
LOG=$HTP/campaign.log

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

# Remote exec: nerves_ssh evaluates ELIXIR; shell rides :os.cmd. The
# ~c|...| sigil means no literal `|` may appear in a remote command —
# board-side complexity lives in the pushed script, not here. Output
# through the channel is unreliable (CR-heavy logs render blank), so
# anything that matters is written to a file on /data and fetched.
remote() { # <timeout-secs> <shell command, no pipes>
  local t=$1; shift
  # -n: ssh must not drain stdin — several callers sit inside
  # while-read loops that it would otherwise eat.
  timeout "$t" ssh -n -o BatchMode=yes "$BOARD" ":os.cmd(~c|$*|)" > /dev/null 2>&1
}
fetch() { # <remote path> <local path>  (scp exits 1 on success — check artifact instead)
  timeout 300 scp -q -r -o BatchMode=yes "$BOARD:$1" "$2" < /dev/null 2>/dev/null
  # The artifact to check is what scp CREATES: into a directory destination
  # (trailing slash) that is dest/<remote basename>; a plain destination is
  # the file itself. Checking "$2" alone was vacuous for the directory
  # callers — $HTP/content/ always exists, fetched or not. A survivor from
  # an earlier run can still satisfy this; the campaign log's per-stage
  # counts are the cross-check.
  case $2 in
  */) [ -e "$2$(basename "$1")" ] ;;
  *) [ -e "$2" ] ;;
  esac
}

# The 12 board-worthy rungs (phase 2.3 verdicts): every a16 plus the
# three a8 survivors. name:profile:insize; raw yolo26/yolov8 heads
# decode under the yolov8 profile (the bundled binary's contract).
RUNGS="
yolox_nano-qdq-a16:yolox:416
yolox_tiny-qdq-a16:yolox:416
yolox_tiny-qdq-a8:yolox:416
yolox_s-qdq-a16:yolox:640
yolox_s-qdq-a8:yolox:640
yolox_m-qdq-a16:yolox:640
yolox_m-qdq-a8:yolox:640
yolo26n-qdq-a16:yolov8:640
yolo26n-416-qdq-a16:yolov8:416
yolo26s-qdq-a16:yolov8:640
yolo26m-qdq-a16:yolov8:640
yolov8n-qdq-a16:yolov8:640
"

engine_state() { # writes container names to $1 (local file)
  remote 30 "balena-engine ps --format {{.Names}} > /data/tmp-ps.txt 2>&1"
  fetch /data/tmp-ps.txt "$1"
}

ensure_engine_stopped() {
  local f=$HTP/.ps-check
  # Fatal, not a warning, both ways: the container holds the NPU, so a
  # state we cannot read or a stop that did not take means every number
  # measured afterwards is contention evidence wearing a campaign tag.
  engine_state "$f" || { log "FATAL: cannot read engine state — refusing to measure blind"; exit 1; }
  if grep -q cairn "$f"; then
    log "cairn container running — stopping (holds the NPU)"
    remote 90 "balena-engine stop $CONTAINER"
    engine_state "$f" || { log "FATAL: cannot re-read engine state after stop"; exit 1; }
    if grep -q cairn "$f"; then
      log "FATAL: container did not stop — refusing to measure under contention"
      exit 1
    fi
    log "container stopped"
  fi
}

# The DSP wedges under session churn: every QNN session leaks a graph
# handle on the CDSP (the teardown 6001s in every run's stderr), and
# after ~26 sessions fastrpc starts failing buffer maps — from then on
# EVERY execute returns 6001, indiscriminately (measured 2026-08-20: a
# clean break mid-campaign; the shipped nano that ran fine as session 1
# failed the same way as session 40). So the driver counts QNN sessions
# and reboots before crossing the budget (content_run below); any 6001
# wall that still appears means "reboot and rerun", never "the
# artifact is broken".
QNN_SESSION_BUDGET=18
QNN_SESSIONS=0
do_reboot() {
  log "== reboot: clearing CDSP session-leak state"
  # A reboot that never happened must not be reported as one: the ssh
  # command can fail before executing `reboot`, the board stays up, and
  # a liveness probe then "succeeds" immediately. The boot id is the
  # witness — wait for it to CHANGE, not for the board to answer.
  remote 30 "cat /proc/sys/kernel/random/boot_id > /data/tmp-bootid.txt"
  fetch /data/tmp-bootid.txt "$HTP/.bootid-before" || { log "FATAL: cannot read boot id"; exit 1; }
  remote 20 reboot
  sleep 20
  local waited=20
  while :; do
    rm -f "$HTP/.bootid-after"
    if remote 15 "cat /proc/sys/kernel/random/boot_id > /data/tmp-bootid.txt"; then
      fetch /data/tmp-bootid.txt "$HTP/.bootid-after" || true
      if [ -f "$HTP/.bootid-after" ] && ! cmp -s "$HTP/.bootid-before" "$HTP/.bootid-after"; then
        break
      fi
    fi
    sleep 10
    waited=$((waited + 10))
    [ "$waited" -ge 300 ] && { log "FATAL: boot id unchanged after ${waited}s — reboot did not happen"; exit 1; }
  done
  log "board back with a new boot id after ~${waited}s"
  # HA's supervisor autostarts the addon on boot; give it a moment so
  # ensure_engine_stopped sees (and stops) the running container rather
  # than racing its startup.
  sleep 30
}

do_push() {
  log "== push: content script + 12 artifacts"
  remote 30 "mkdir -p /data/cairn-bench/artifacts-fixed /data/cairn-bench/content"
  timeout 60 scp -q -o BatchMode=yes "$HERE/htp_content_test.sh" "$BOARD:/data/cairn-bench/" 2>/dev/null
  # The board script rides the same sha check as the artifacts below —
  # a silently-failed push here would run a STALE methodology and label
  # its output with today's date.
  remote 60 "sha256sum /data/cairn-bench/htp_content_test.sh > /data/tmp-script-sha.txt 2>&1"
  fetch /data/tmp-script-sha.txt "$HTP/.script-sha" || { log "FATAL: cannot verify script push"; exit 1; }
  if [ "$(cut -d' ' -f1 "$HTP/.script-sha")" != "$(sha256sum "$HERE/htp_content_test.sh" | cut -d' ' -f1)" ]; then
    log "FATAL: htp_content_test.sh push mismatch"
    exit 1
  fi
  local files=()
  while IFS=: read -r name _ _; do
    [ -n "$name" ] && files+=("$ART/$name.onnx")
  done <<< "$RUNGS"
  timeout 900 scp -q -o BatchMode=yes "${files[@]}" "$BOARD:/data/cairn-bench/artifacts-fixed/" 2>/dev/null
  # scp over nerves_ssh exits 1 even on success — verify by checksum.
  remote 300 "sha256sum /data/cairn-bench/artifacts-fixed/*.onnx > /data/tmp-sha.txt 2>&1"
  fetch /data/tmp-sha.txt "$HTP/pushed.sha256" || { log "FATAL: cannot verify push"; exit 1; }
  local bad=0
  while IFS=: read -r name _ _; do
    [ -z "$name" ] && continue
    local want have
    want=$(grep " $name.onnx\$" "$OUT/records/artifacts.sha256" | cut -d' ' -f1)
    have=$(grep "/$name.onnx\$" "$HTP/pushed.sha256" | cut -d' ' -f1)
    if [ "$want" != "$have" ] || [ -z "$want" ]; then
      log "PUSH MISMATCH: $name (local ${want:-?} board ${have:-missing})"
      bad=1
    fi
  done <<< "$RUNGS"
  [ "$bad" = 0 ] && log "push verified: 12/12 sha256 match" || { log "FATAL: push verification failed"; exit 1; }
}

do_envcheck() {
  log "== envcheck: nano-parity spike (N=20)"
  ensure_engine_stopped
  remote 240 "sh /data/qnn-spike/run_spike.sh 20 > /data/cairn-bench/content/spike-env.txt 2>&1"
  fetch /data/cairn-bench/content/spike-env.txt "$HTP/spike-env.txt" || { log "FATAL: no spike output"; exit 1; }
  python3 - "$HTP/spike-env.txt" <<'EOF' | tee -a "$LOG"
import json, sys
# Phase-0 recorded: CPU p50 34.98-40.63 ms, QNN p50 6.40-6.66 ms (6.1x).
# Bands are generous: the gate is "same regime", not "same run". The
# spike's JSON lines swim in EP/DSP log noise — key off the lines, not
# their position.
p50 = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('{"ep":'):
        blob = json.loads(line)
        p50[blob["ep"]] = blob["p50_ms"]
cpu, qnn = p50.get("cpu"), p50.get("qnn")
ok = cpu and qnn and 25 <= cpu <= 60 and 4 <= qnn <= 13 and cpu / qnn >= 3
print(f"envcheck: cpu p50={cpu} qnn p50={qnn} ratio={cpu/qnn:.1f}x"
      f" -> {'PASS (matches phase-0 spike regime)' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
EOF
  [ "${PIPESTATUS[0]}" = 0 ] || { log "FATAL: envcheck failed — bench env untrusted, do not read scores from it"; exit 1; }
}

fetched_run_current() { # <tag> <rung-label> <clip>
  local dir="$HTP/content/$1" local_art="$ART/$2.onnx" local_clip="$OUT/clips/clip-$3.mp4"
  grep -q '"frame.objects"' "$dir/out.ndjson" 2>/dev/null || return 1
  [ -f "$dir/meta" ] || return 1
  grep -q "run suspect" "$dir/meta" && return 1
  if [ -f "$local_art" ]; then
    grep -q "$(sha256sum "$local_art" | cut -d' ' -f1)" "$dir/meta" || return 1
  fi
  # The control has no local artifact under $ART; its bytes are pinned.
  if [ "$2" = control-old-nano-a16 ]; then
    grep -q "$OLD_NANO_SHA" "$dir/meta" || return 1
  fi
  # A changed clip under the same tag must retry too — otherwise the run
  # is skipped forever, the analyzer marks it STALE-EVIDENCE, and no
  # rerun can regenerate it without manual deletion.
  if [ -f "$local_clip" ]; then
    grep -q "$(sha256sum "$local_clip" | cut -d' ' -f1)" "$dir/meta" || return 1
  fi
  return 0
}

content_run() { # <backend> <model-path> <rung-label> <profile> <insize>
  local backend=$1 model=$2 label=$3 profile=$4 insize=$5 clip flags=""
  [ "$backend" = qnn ] && flags=$QNN_FLAGS
  for clip in $CLIPS; do
    local tag="$label-$backend-$clip"
    # Skip only on evidence of a SUCCESSFUL CURRENT run: emitted frames,
    # a meta with no suspect verdict, and — when the artifact exists
    # locally — the meta's recorded model sha matching today's bytes. A
    # truncated run can emit a frame before dying, and an old run under
    # the same tag can describe different model bytes; both must retry.
    if fetched_run_current "$tag" "$label" "$clip"; then
      log "content $tag: already fetched, skip"
      continue
    fi
    if [ "$backend" = qnn ]; then
      if [ "$QNN_SESSIONS" -ge "$QNN_SESSION_BUDGET" ]; then
        log "QNN session budget ($QNN_SESSION_BUDGET) reached — rebooting before $tag"
        do_reboot
        QNN_SESSIONS=0
      fi
      QNN_SESSIONS=$((QNN_SESSIONS + 1))
    fi
    ensure_engine_stopped
    log "content $tag: running"
    remote 420 "PROFILE=$profile INSIZE=$insize sh /data/cairn-bench/htp_content_test.sh $backend $model /data/clip-$clip.mp4 $tag $flags" \
      || log "WARN: $tag remote rc nonzero (checked on fetch)"
    # Fetch each run's evidence immediately: the retry-skip guard reads
    # the LOCAL copy, so without this a wedged run could only be retried
    # after a manual fetch stage.
    mkdir -p "$HTP/content"
    fetch "/data/cairn-bench/content/$tag" "$HTP/content/" || log "WARN: $tag evidence fetch failed"
  done
}

do_content() {
  log "== content runs: ${CLIPS} x (12 rungs qnn + nano ort control + old-nano defect control)"
  # Anchor the session counter to a clean CDSP: envcheck (and any prior
  # manual session this boot) has already leaked graph handles, and the
  # budget below counts only sessions THIS stage starts — without this
  # reboot the ~26-session wedge can land before the first budgeted one.
  do_reboot
  pin_governor
  while IFS=: read -r name profile insize; do
    [ -z "$name" ] && continue
    content_run qnn "/data/cairn-bench/artifacts-fixed/$name.onnx" "$name" "$profile" "$insize"
  done <<< "$RUNGS"
  # CPU-EP control: ties board decode+sampling to the local CPU reference.
  content_run ort /data/cairn-bench/artifacts-fixed/yolox_nano-qdq-a16.onnx yolox_nano-qdq-a16 yolox 416
  # Sensitivity control: the SHIPPED defective nano must show its baked
  # ceiling through this exact methodology, or the test cannot be
  # trusted to clear the fixed rungs. Authenticate the bytes first —
  # the label has no $ART artifact, so no other check sees them.
  remote 60 "sha256sum /data/cairn-bench/yolox_nano-qdq-a16.onnx > /data/tmp-ctl-sha.txt"
  fetch /data/tmp-ctl-sha.txt "$HTP/.ctl-sha" || { log "FATAL: cannot read control sha"; exit 1; }
  grep -q "$OLD_NANO_SHA" "$HTP/.ctl-sha" || {
    log "FATAL: board control bytes are not the shipped defective nano ($OLD_NANO_SHA)"
    exit 1
  }
  CLIPS="ac86" content_run qnn /data/cairn-bench/yolox_nano-qdq-a16.onnx control-old-nano-a16 yolox 416
}

pin_governor() {
  # Capture the pre-campaign governor ONCE — never on re-entry, or a
  # second pin would record "performance" and finish would then restore
  # the pin itself. What was actually there is what comes back.
  # Both checked: a failed save leaves do_finish nothing to restore (the
  # board stays pinned forever), and a failed pin would label unpinned
  # latency evidence as governor-pinned.
  remote 30 "test -f /data/campaign-gov.saved || cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /data/campaign-gov.saved" \
    || { log "FATAL: cannot capture pre-campaign governor"; exit 1; }
  remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$c/cpufreq/scaling_governor; done" \
    || { log "FATAL: governor pin failed"; exit 1; }
}

do_latency() {
  log "== latency runs: bench.sh per rung, governor pinned"
  pin_governor
  echo "$(date +%s)" > "$HTP/.latency-start"
  while IFS=: read -r name profile insize; do
    [ -z "$name" ] && continue
    ensure_engine_stopped
    log "latency $name qnn 60s"
    remote 200 "MODEL=/data/cairn-bench/artifacts-fixed/$name.onnx SAMPLE_FPS=30 PIN_GOVERNOR=1 sh /data/cairn-bench/bench.sh qnn 60 1 --model-profile $profile --input-size $insize $QNN_FLAGS" \
      || log "WARN: latency $name rc nonzero"
  done <<< "$RUNGS"
  # One CPU-EP anchor (nano is cheap); with the per-rung QNN numbers and
  # the model-menu HTP table it detects whole-session CPU fallback.
  log "latency yolox_nano-qdq-a16 ort 60s (CPU anchor)"
  remote 200 "MODEL=/data/cairn-bench/artifacts-fixed/yolox_nano-qdq-a16.onnx SAMPLE_FPS=30 PIN_GOVERNOR=1 sh /data/cairn-bench/bench.sh ort 60 1 --model-profile yolox --input-size 416"
}

do_fetch() {
  log "== fetch evidence"
  mkdir -p "$HTP/content"
  fetch /data/cairn-bench/content "$HTP/" || log "WARN: content fetch incomplete"
  remote 30 "ls /data/cairn-bench/runs > /data/tmp-runs.txt 2>&1"
  fetch /data/tmp-runs.txt "$HTP/.runs-list"
  # Without a latency-stage marker there are no new bench runs to pull —
  # and pulling unfiltered would drag in every historical run dir.
  [ -f "$HTP/.latency-start" ] || { log "no latency marker — skipping bench-run fetch"; return; }
  local start
  start=$(cat "$HTP/.latency-start")
  while read -r d; do
    local ts=${d##*-}
    case $ts in *[!0-9]*|'') continue ;; esac
    if [ "$ts" -ge "$start" ] && [ ! -d "$HTP/runs/$d" ]; then
      fetch "/data/cairn-bench/runs/$d" "$HTP/runs/" || log "WARN: run $d fetch failed"
    fi
  done < "$HTP/.runs-list"
  log "fetched: $(ls "$HTP/content" 2>/dev/null | wc -l) content dirs, $(ls "$HTP/runs" 2>/dev/null | wc -l) bench runs"
}

do_finish() {
  log "== finish: restore governor + restart container"
  # Restore ONLY what pin_governor captured: a finish reached without a
  # pin (standalone envcheck, an early failure) must not write any
  # governor at all — restore-only means exactly that.
  remote 30 "if test -f /data/campaign-gov.saved; then gov=\$(cat /data/campaign-gov.saved); for c in /sys/devices/system/cpu/cpu[0-9]*; do echo \$gov > \$c/cpufreq/scaling_governor; done; rm -f /data/campaign-gov.saved; fi"
  remote 120 "balena-engine start $CONTAINER"
  engine_state "$HTP/.ps-check"
  grep -q cairn "$HTP/.ps-check" && log "cairn container back up" || log "WARN: cairn container NOT running — start it: balena-engine start $CONTAINER"
}

case $STAGE in
push) do_push ;;
envcheck) trap do_finish EXIT; do_envcheck ;;
reboot) do_reboot ;;
content) trap do_finish EXIT; do_content ;;
latency) trap do_finish EXIT; do_reboot; do_latency ;;
fetch) do_fetch ;;
finish) do_finish ;;
all)
  trap do_finish EXIT
  do_push
  do_envcheck
  do_content
  do_reboot
  do_latency
  do_fetch
  ;;
*) echo "unknown stage $STAGE" >&2; exit 1 ;;
esac
log "stage $STAGE done"
