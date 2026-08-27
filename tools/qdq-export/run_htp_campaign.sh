#!/bin/bash
# DEPRECATED: the campaign driver is now the Elixir/:erpc one in
# driver/ (`cd driver && mix run -e 'Driver.CLI.main(System.argv())' -- all`),
# which deletes this file's transport workarounds (remote_verified's
# nonce/digest protocol, fetch()'s existence checks, the ~c|...| no-pipes
# rule) by speaking Erlang distribution via Vagus.Dist. This script is
# kept as the behavior-parity reference (run_parity_slice.sh diffs the
# two) until the first FULL campaign has run on :erpc — then it can go.
#
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

# The one shape for "run a board command and read its result": remote()
# swallows the command's rc (:os.cmd) and forbids pipes (~c|...|), so
# every caller used to hand-roll write-file/fetch/verify slightly
# differently — the #138 churn class. The command group's output goes to
# one tmp file; a separate .ok file, written only if the group exited 0,
# carries a per-call NONCE plus the output's sha256. Success requires the
# fetched .ok to carry THIS call's nonce AND the fetched output to match
# the recorded digest. The nonce defeats stale state (/data persists,
# across reboots too, and tags are shared between call sites); the digest
# defeats partial transfer (fetch() cannot read scp's rc — this transport
# exits 1 even on success — so an interrupted copy leaves a shorter file
# that exists, and a complete .ok from its own later scp must not vouch
# for it). Keeping both out of the output file means no output shape can
# defeat or fake the verification.
remote_verified() { # <timeout-secs> <tag> <local-dest> <command..., no pipes>
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

# The 12 board-worthy rungs (phase 2.3 verdicts): every a16 plus the
# three a8 survivors. name:profile:insize; raw yolo26/yolov8 heads
# decode under the yolov8 profile (the bundled binary's contract).
# Env-overridable for parity slices (run_parity_slice.sh) only — a real
# campaign runs the full table.
RUNGS=${RUNGS:-"
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
"}

engine_state() { # writes container names to $1 (local file)
  # A failed ps would redirect its error into the file, contain no
  # "cairn", and read as "engine stopped" — remote_verified's sentinel is
  # what stands between those two states.
  remote_verified 30 ps "$1" "balena-engine ps --format {{.Names}}"
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
  # witness — wait for it to CHANGE, not for the board to answer. Stale
  # values on either side would fake a verified reboot; remote_verified's
  # per-call nonce is what rules them out (tmp files survive the reboot).
  remote_verified 30 bootid "$HTP/.bootid-before" "cat /proc/sys/kernel/random/boot_id" \
    || { log "FATAL: cannot read boot id"; exit 1; }
  [ -s "$HTP/.bootid-before" ] || { log "FATAL: boot id snapshot is empty"; exit 1; }
  remote 20 reboot
  sleep 20
  local waited=20
  while :; do
    if remote_verified 15 bootid "$HTP/.bootid-after" "cat /proc/sys/kernel/random/boot_id" \
       && [ -s "$HTP/.bootid-after" ] \
       && ! cmp -s "$HTP/.bootid-before" "$HTP/.bootid-after"; then
      break
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
  remote_verified 60 script-sha "$HTP/.script-sha" "sha256sum /data/cairn-bench/htp_content_test.sh" \
    || { log "FATAL: cannot verify script push"; exit 1; }
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
  remote_verified 300 push-sha "$HTP/pushed.sha256" "sha256sum /data/cairn-bench/artifacts-fixed/*.onnx" \
    || { log "FATAL: cannot verify push"; exit 1; }
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
  remote_verified 240 spike "$HTP/spike-env.txt" "sh /data/qnn-spike/run_spike.sh 20" \
    || { log "FATAL: spike run failed or its output is unverifiable"; exit 1; }
  python3 - "$HTP/spike-env.txt" <<'EOF' | tee -a "$LOG"
import json, math, sys
# Phase-0 recorded: CPU p50 34.98-40.63 ms, QNN p50 6.40-6.66 ms (6.1x).
# Bands are generous: the gate is "same regime", not "same run" — but
# only over real numbers: NaN answers False to every band check and must
# read FAIL, never slip through. The spike's JSON lines swim in EP/DSP
# log noise — key off the lines, not their position.
p50 = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('{"ep":'):
        blob = json.loads(line)
        p50[blob["ep"]] = blob["p50_ms"]
cpu, qnn = p50.get("cpu"), p50.get("qnn")
finite = all(isinstance(v, (int, float)) and math.isfinite(v) for v in (cpu, qnn))
ok = finite and 25 <= cpu <= 60 and 4 <= qnn <= 13 and cpu / qnn >= 3
ratio = f"{cpu / qnn:.1f}x" if finite and qnn > 0 else "?"
print(f"envcheck: cpu p50={cpu} qnn p50={qnn} ratio={ratio}"
      f" -> {'PASS (matches phase-0 spike regime)' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
EOF
  [ "${PIPESTATUS[0]}" = 0 ] || { log "FATAL: envcheck failed — bench env untrusted, do not read scores from it"; exit 1; }
}

# "Is this fetched run current evidence" has ONE implementation, shared
# with the analyzer: campaign_meta.py (stdlib-only, so the system python3
# suffices). Bash keeps only the argument plumbing — emitted frames, a
# complete non-suspect meta, and shas tying the run to THIS content-test
# script, THESE flags, and today's model/clip bytes all live there. The
# control has no local artifact under $ART; its bytes are pinned.
fetched_run_current() { # <tag> <rung-label> <clip> <extra-flags> <backend> <profile> <insize>
  # --extra-args=: the value starts with "--" and argparse would read a
  # separate token as an option.
  local args=(current "$HTP/content/$1"
    --script "$HERE/htp_content_test.sh" "--extra-args=$4"
    --backend "$5" --profile "$6" --insize "$7")
  [ -f "$ART/$2.onnx" ] && args+=(--model "$ART/$2.onnx")
  [ "$2" = control-old-nano-a16 ] && args+=(--require-sha "$OLD_NANO_SHA")
  [ -f "$OUT/clips/clip-$3.mp4" ] && args+=(--clip "$OUT/clips/clip-$3.mp4")
  python3 "$HERE/campaign_meta.py" "${args[@]}"
  local rc=$?
  # rc 4 = "not current, rerun" — its own code, because 1 belongs to the
  # interpreter (import/syntax failures exit 1 before the module's
  # catch-all runs). ANY other nonzero status is a broken guard — fatal,
  # because a broken guard reads as "rerun everything" and would silently
  # redo an entire board campaign on every invocation.
  case $rc in
  0) return 0 ;;
  4) return 1 ;;
  *) log "FATAL: retry guard broken (campaign_meta rc $rc) — fix the guard, do not blind-rerun"; exit 1 ;;
  esac
}

content_run() { # <backend> <model-path> <rung-label> <profile> <insize>
  local backend=$1 model=$2 label=$3 profile=$4 insize=$5 clip flags=""
  [ "$backend" = qnn ] && flags=$QNN_FLAGS
  for clip in $CLIPS; do
    local tag="$label-$backend-$clip"
    # Skip only on evidence of a SUCCESSFUL CURRENT run — the guard's
    # header above and campaign_meta's `_current` docstring define what
    # that means; truncated and stale-bytes runs both retry.
    if fetched_run_current "$tag" "$label" "$clip" "$flags" "$backend" "$profile" "$insize"; then
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
  remote_verified 60 ctl-sha "$HTP/.ctl-sha" "sha256sum /data/cairn-bench/yolox_nano-qdq-a16.onnx" \
    || { log "FATAL: cannot read control sha"; exit 1; }
  grep -q "$OLD_NANO_SHA" "$HTP/.ctl-sha" || {
    log "FATAL: board control bytes are not the shipped defective nano ($OLD_NANO_SHA)"
    exit 1
  }
  CLIPS="ac86" content_run qnn /data/cairn-bench/yolox_nano-qdq-a16.onnx control-old-nano-a16 yolox 416
}

pin_governor() {
  # Capture the pre-campaign governor ONCE — never on re-entry, or a
  # second pin would record "performance" and finish would then restore
  # the pin itself. What was actually there is what comes back. The save
  # and the read of the saved value ride one verified command: the
  # sentinel proves the chain ran, and the fetched copy is the value
  # do_finish will restore.
  # A failed save leaves do_finish nothing to restore (the board stays
  # pinned forever); a failed pin would label unpinned latency evidence
  # as governor-pinned.
  # if/then, not `||`: remote() interpolates into a ~c|...| sigil, so a
  # pipe character would terminate the Elixir literal mid-command.
  # test ! -s, not -f: a failed save leaves an EMPTY file, and -f would
  # then refuse to re-save forever while [ -s ] below FATALs every pin —
  # a wedge only board surgery could clear. A real saved governor is
  # never empty, so -s preserves the capture-once semantics.
  remote_verified 30 gov-save "$HTP/.gov-saved" \
    "if test ! -s /data/campaign-gov.saved; then cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /data/campaign-gov.saved; fi; cat /data/campaign-gov.saved" \
    || { log "FATAL: cannot verify saved governor"; exit 1; }
  [ -s "$HTP/.gov-saved" ] || { log "FATAL: saved governor file is empty"; exit 1; }
  remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$c/cpufreq/scaling_governor; done"
  remote_verified 30 gov "$HTP/.gov-check" "cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor" \
    || { log "FATAL: cannot read back governors"; exit 1; }
  [ -s "$HTP/.gov-check" ] || { log "FATAL: governor readback is empty"; exit 1; }
  grep -qv '^performance$' "$HTP/.gov-check" && { log "FATAL: governor pin did not take"; exit 1; }
  # The local marker records that THIS campaign pinned: do_finish uses
  # it to distinguish "nothing to restore" from "saved value unreadable".
  cp "$HTP/.gov-saved" "$HTP/.gov-pinned"
  log "governor pinned (saved: $(cat "$HTP/.gov-saved"))"
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
  # The counts line at the bottom runs on EVERY path — it is the
  # cross-check fetch()'s survivor caveat promises, and the flaky-board
  # paths that skip the bench-run pull are exactly where it matters most.
  if ! remote_verified 30 runs "$HTP/.runs-list" "ls /data/cairn-bench/runs"; then
    log "WARN: cannot list bench runs — skipping bench-run fetch"
  elif [ ! -f "$HTP/.latency-start" ]; then
    # Without a latency-stage marker there are no new bench runs to pull —
    # and pulling unfiltered would drag in every historical run dir.
    log "no latency marker — skipping bench-run fetch"
  else
    local start
    start=$(cat "$HTP/.latency-start")
    # Same fail-closed rule as the analyzer (start must be a POSITIVE
    # integer): a marker holding garbage, nothing, or zero means no
    # current latency stage — not an unfiltered pull of every historical
    # run dir, which is exactly what `ts >= 0` would do.
    if ! [ "$start" -gt 0 ] 2>/dev/null; then
      log "invalid latency marker — skipping bench-run fetch"
    else
      while read -r d; do
        local ts=${d##*-}
        case $ts in *[!0-9]*|'') continue ;; esac
        if [ "$ts" -ge "$start" ] && [ ! -d "$HTP/runs/$d" ]; then
          fetch "/data/cairn-bench/runs/$d" "$HTP/runs/" || log "WARN: run $d fetch failed"
        fi
      done < "$HTP/.runs-list"
    fi
  fi
  log "fetched: $(ls "$HTP/content" 2>/dev/null | wc -l) content dirs, $(ls "$HTP/runs" 2>/dev/null | wc -l) bench runs"
}

do_finish() {
  log "== finish: restore governor + restart container"
  # Cleanup failures must propagate: a green campaign that leaves the
  # board pinned to performance or the production NVR down is not green.
  local finish_failed=0
  # Restore ONLY what pin_governor captured: a finish reached without a
  # pin (standalone envcheck, an early failure) must not write any
  # governor at all — restore-only means exactly that. The saved file is
  # kept until a READBACK verifies the restore took (:os.cmd discards
  # the rc), so a failed restore stays restorable on the next finish.
  # Through remote_verified, not a raw fetch: a partial scp of the saved
  # value would create an empty local file that skips both the error
  # branch AND the [ -s ] restore below — finish would report success
  # with the board still pinned. The digest authenticates the bytes, and
  # `test -s` makes an EMPTY board file fail the read too (cat alone
  # succeeds on empty, skipping the same two branches). A failed read
  # with no .gov-pinned marker is the no-op path; with the marker it is
  # fatal.
  if ! remote_verified 30 gov-read "$HTP/.gov-saved" "test -s /data/campaign-gov.saved && cat /data/campaign-gov.saved" \
     && [ -f "$HTP/.gov-pinned" ]; then
    # This campaign pinned (local marker), yet the saved value is
    # unreadable — that is NOT "nothing to restore": the board may
    # still be pinned. A finish without a pin keeps the no-op path.
    log "FATAL: governor was pinned this campaign but /data/campaign-gov.saved is unreadable"
    finish_failed=1
  fi
  if [ -s "$HTP/.gov-saved" ]; then
    remote 30 "gov=\$(cat /data/campaign-gov.saved); for c in /sys/devices/system/cpu/cpu[0-9]*; do echo \$gov > \$c/cpufreq/scaling_governor; done"
    if remote_verified 30 gov "$HTP/.gov-check" "cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor" \
       && [ -s "$HTP/.gov-check" ] \
       && ! grep -qvxF "$(cat "$HTP/.gov-saved")" "$HTP/.gov-check"; then
      remote 30 "rm -f /data/campaign-gov.saved"
      rm -f "$HTP/.gov-pinned"
      log "governor restored to $(cat "$HTP/.gov-saved")"
    else
      log "FATAL: governor restore NOT verified — /data/campaign-gov.saved kept; rerun finish"
      finish_failed=1
    fi
  fi
  remote 120 "balena-engine start $CONTAINER"
  if engine_state "$HTP/.ps-check" && grep -qxF "$CONTAINER" "$HTP/.ps-check"; then
    log "cairn container back up"
  else
    log "FATAL: cairn container NOT verified running — start it: balena-engine start $CONTAINER"
    finish_failed=1
  fi
  if [ "$finish_failed" -ne 0 ]; then
    log "FATAL: cleanup incomplete — the board is not back in its pre-campaign state"
    exit 1
  fi
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
