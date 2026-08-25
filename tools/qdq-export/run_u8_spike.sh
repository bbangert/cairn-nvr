#!/usr/bin/env bash
# uint8-IO spike driver: does OUR yolox_s-a8 artifact, edge-converted to
# uint8 graph IO (u8_io_surgery.py), reproduce Qualcomm's ~1.6x on the
# QCS6490 HTP? Measures all four contracts — float, input-only,
# output-only, both — in ONE boot session, because cross-session variance
# on this board is ±20% and only same-session pairs are comparable.
#
#   tools/qdq-export/run_u8_spike.sh [all|build|push|run|content|fetch]
#
# Stages (all = the lot, in order):
#   build    cross-build the spike's cairn-detect (aarch64, ort-load-dynamic)
#   push     binary (previous one backed up) + 4 artifacts + 3 sidecars,
#            sha-verified
#   run      reboot (clean CDSP) -> stop container -> pin governor ->
#            on-board CPU baselines -> 2 interleaved latency rounds x 4
#            variants (bench.sh, 60s each). Governor restore + container
#            restart ride an EXIT trap.
#   content  own boot session: 4 content runs (clip ac86, score parity
#            evidence) via the spike-local u8_content_test.sh
#   fetch    pull the new bench run dirs + content evidence
#
# Deliberately throwaway (spike-first decision, 2026-08-24): board
# helpers are copied from run_htp_campaign.sh rather than shared, and no
# campaign analyzer learns these tags. The one number that matters is the
# per-variant p50 table this produces; the production effort, if the win
# reproduces, redoes the tooling properly.
#
# HTP-proof criterion (D-P5): only the latency delta against the same
# artifact's on-board CPU baseline proves HTP execution — "no errors"
# proves nothing on this board. The float leg doubles as the env control:
# it must reproduce the campaign's known ~18.5ms signature, and a flat
# ~19ms with everything "working" is the schedutil trap, not a result.
set -u
BOARD=${BOARD:-192.168.2.87}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CRATE=$ROOT/plugins/cairn-detect
OUT=${OUT:-$HERE/out-20260820}
ART=$OUT/artifacts
SPIKE=$OUT/htp/u8spike
CONTAINER=addon_c2da371c_cairn
QNN_FLAGS="--qnn-library /data/qnn-spike/lib/libonnxruntime_providers_qnn.so --qnn-soc-model 35 --qnn-htp-arch 68"
BENCH=/data/cairn-bench
STAGE=${1:-all}
mkdir -p "$SPIKE"
LOG=$SPIKE/spike.log

# tag:artifact-stem — float first so the baseline signature is read
# before any u8 leg can be blamed for a broken env.
VARIANTS="
float:yolox_s-qdq-a8
u8in:yolox_s-qdq-a8-u8in
u8out:yolox_s-qdq-a8-u8out
u8io:yolox_s-qdq-a8-u8io
"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ---- board helpers, copied from run_htp_campaign.sh (see header) ----
remote() { # <timeout-secs> <shell command, no pipes>
  local t=$1; shift
  timeout "$t" ssh -n -o BatchMode=yes "$BOARD" ":os.cmd(~c|$*|)" > /dev/null 2>&1
}
fetch() { # <remote path> <local path>
  timeout 300 scp -q -r -o BatchMode=yes "$BOARD:$1" "$2" < /dev/null 2>/dev/null
  case $2 in
  */) [ -e "$2$(basename "$1")" ] ;;
  *) [ -e "$2" ] ;;
  esac
}
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

do_reboot() {
  log "== reboot: clearing CDSP session-leak state"
  remote_verified 30 bootid "$SPIKE/.bootid-before" "cat /proc/sys/kernel/random/boot_id" \
    || { log "FATAL: cannot read boot id"; exit 1; }
  [ -s "$SPIKE/.bootid-before" ] || { log "FATAL: boot id snapshot is empty"; exit 1; }
  remote 20 reboot
  sleep 20
  local waited=20
  while :; do
    if remote_verified 15 bootid "$SPIKE/.bootid-after" "cat /proc/sys/kernel/random/boot_id" \
       && [ -s "$SPIKE/.bootid-after" ] \
       && ! cmp -s "$SPIKE/.bootid-before" "$SPIKE/.bootid-after"; then
      break
    fi
    sleep 10
    waited=$((waited + 10))
    [ "$waited" -ge 300 ] && { log "FATAL: boot id unchanged after ${waited}s"; exit 1; }
  done
  log "board back with a new boot id after ~${waited}s"
  sleep 30
}

engine_state() {
  remote_verified 30 ps "$1" "balena-engine ps --format {{.Names}}"
}
ensure_engine_stopped() {
  local f=$SPIKE/.ps-check
  engine_state "$f" || { log "FATAL: cannot read engine state — refusing to measure blind"; exit 1; }
  if grep -q cairn "$f"; then
    log "cairn container running — stopping (holds the NPU)"
    remote 90 "balena-engine stop $CONTAINER"
    engine_state "$f" || { log "FATAL: cannot re-read engine state"; exit 1; }
    grep -q cairn "$f" && { log "FATAL: container did not stop"; exit 1; }
    log "container stopped"
  fi
}

pin_governor() {
  # Own save path (u8spike-gov.saved), same capture-once semantics as the
  # campaign's — never share its /data/campaign-gov.saved state.
  remote_verified 30 gov-save "$SPIKE/.gov-saved" \
    "if test ! -s /data/u8spike-gov.saved; then cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /data/u8spike-gov.saved; fi; cat /data/u8spike-gov.saved" \
    || { log "FATAL: cannot verify saved governor"; exit 1; }
  [ -s "$SPIKE/.gov-saved" ] || { log "FATAL: saved governor file is empty"; exit 1; }
  remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$c/cpufreq/scaling_governor; done"
  remote_verified 30 gov "$SPIKE/.gov-check" "cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor" \
    || { log "FATAL: cannot read back governors"; exit 1; }
  [ -s "$SPIKE/.gov-check" ] || { log "FATAL: governor readback is empty"; exit 1; }
  grep -qv '^performance$' "$SPIKE/.gov-check" && { log "FATAL: governor pin did not take"; exit 1; }
  cp "$SPIKE/.gov-saved" "$SPIKE/.gov-pinned"
  log "governor pinned (saved: $(cat "$SPIKE/.gov-saved"))"
}

do_finish() {
  log "== finish: restore governor + restart container"
  if [ -f "$SPIKE/.gov-pinned" ]; then
    local gov
    gov=$(cat "$SPIKE/.gov-pinned")
    remote 30 "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo $gov > \$c/cpufreq/scaling_governor; done; rm -f /data/u8spike-gov.saved"
    log "governor restored to $gov"
  fi
  remote 90 "balena-engine start $CONTAINER"
  log "container start requested"
}

# ---- stages ----
do_build() {
  log "== build: aarch64 cairn-detect (deploy.sh recipe)"
  local ff=$CRATE/target/board/ffmpeg-aarch64
  [ -d "$ff/lib/pkgconfig" ] || { log "FATAL: no aarch64 FFmpeg tree at $ff (tools/board-bench/deploy.sh prints the recipe)"; exit 1; }
  (cd "$CRATE" &&
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS= \
    FFMPEG_PKG_CONFIG_PATH="$ff/lib/pkgconfig" PKG_CONFIG_ALLOW_CROSS=1 \
    cargo build --release --target aarch64-unknown-linux-gnu --features ort-load-dynamic) \
    || { log "FATAL: cross-build failed"; exit 1; }
  # readelf, not file(1): the dev container does not ship file.
  readelf -h "$CRATE/target/aarch64-unknown-linux-gnu/release/cairn-detect" 2>/dev/null \
    | grep -q AArch64 || { log "FATAL: built binary is not aarch64"; exit 1; }
  log "build ok"
}

do_push() {
  log "== push: spike binary + artifacts + sidecars"
  # The campaign's binary is backed up once (cp -n); restore = mv back.
  remote 30 "cp -n $BENCH/cairn-detect $BENCH/cairn-detect.pre-u8spike"
  timeout 120 scp -q -o BatchMode=yes \
    "$CRATE/target/aarch64-unknown-linux-gnu/release/cairn-detect" \
    "$BOARD:$BENCH/cairn-detect" 2>/dev/null
  remote 30 "chmod +x $BENCH/cairn-detect"
  timeout 60 scp -q -o BatchMode=yes "$HERE/htp_content_test.sh" "$BOARD:$BENCH/" 2>/dev/null
  local files=()
  while IFS=: read -r tag stem; do
    [ -z "$tag" ] && continue
    files+=("$ART/$stem.onnx")
    [ -f "$ART/$stem.onnx.qparams.json" ] && files+=("$ART/$stem.onnx.qparams.json")
  done <<< "$VARIANTS"
  timeout 900 scp -q -o BatchMode=yes "${files[@]}" "$BOARD:$BENCH/artifacts-fixed/" 2>/dev/null
  # The content clip does not live on the board between campaigns.
  timeout 300 scp -q -o BatchMode=yes "$OUT/clips/clip-ac86.mp4" "$BOARD:$BENCH/" 2>/dev/null
  # scp over nerves_ssh exits 1 even on success — verify by checksum,
  # binary included (a stale binary would run the OLD float-only build
  # and fail every u8 leg with a message about f32 tensors).
  remote_verified 300 u8-push "$SPIKE/pushed.sha256" \
    "sha256sum $BENCH/cairn-detect $BENCH/htp_content_test.sh $BENCH/clip-ac86.mp4 $BENCH/artifacts-fixed/yolox_s-qdq-a8*.onnx $BENCH/artifacts-fixed/yolox_s-qdq-a8*.qparams.json" \
    || { log "FATAL: cannot verify push"; exit 1; }
  local bad=0 want have
  files+=("$OUT/clips/clip-ac86.mp4")
  for f in "${files[@]}" ; do
    want=$(sha256sum "$f" | cut -d' ' -f1)
    have=$(grep "/$(basename "$f")\$" "$SPIKE/pushed.sha256" | cut -d' ' -f1)
    [ "$want" = "$have" ] || { log "PUSH MISMATCH: $(basename "$f")"; bad=1; }
  done
  want=$(sha256sum "$CRATE/target/aarch64-unknown-linux-gnu/release/cairn-detect" | cut -d' ' -f1)
  have=$(grep "cairn-detect\$" "$SPIKE/pushed.sha256" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { log "PUSH MISMATCH: cairn-detect binary"; bad=1; }
  want=$(sha256sum "$HERE/htp_content_test.sh" | cut -d' ' -f1)
  have=$(grep "htp_content_test.sh\$" "$SPIKE/pushed.sha256" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { log "PUSH MISMATCH: htp_content_test.sh"; bad=1; }
  [ "$bad" = 0 ] || { log "FATAL: push verification failed"; exit 1; }
  log "push verified: binary + script + $(( ${#files[@]} )) artifact files"
}

# One bench.sh latency leg. $1 tag, $2 artifact stem, $3 round.
latency_leg() {
  local tag=$1 stem=$2 round=$3
  ensure_engine_stopped
  log "latency $tag round $round (60s qnn)"
  remote 200 "MODEL=$BENCH/artifacts-fixed/$stem.onnx SAMPLE_FPS=30 PIN_GOVERNOR=1 sh $BENCH/bench.sh qnn 60 1 --model-profile yolox --input-size 640 $QNN_FLAGS" \
    || log "WARN: latency $tag r$round rc nonzero"
}

do_run() {
  # INT/TERM must EXIT after restoring: a trapped signal otherwise
  # resumes the script, which would keep measuring against a restarted
  # container and a restored governor -- the exact silent invalidation
  # this teardown exists to prevent.
  trap 'do_finish; trap - EXIT; exit 130' INT TERM
  trap do_finish EXIT
  do_reboot
  ensure_engine_stopped
  pin_governor
  remote_verified 30 runs-before "$SPIKE/.runs-before" "ls $BENCH/runs" || : > "$SPIKE/.runs-before"

  log "== on-board CPU baselines (D-P5 references)"
  remote_verified 120 cpu-float "$SPIKE/cpu-baseline-float.txt" \
    "LD_LIBRARY_PATH=$BENCH/lib:/data/qnn-spike/lib ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1 $BENCH/cairn-detect --cpu-baseline 5 --model $BENCH/artifacts-fixed/yolox_s-qdq-a8.onnx --model-profile yolox --input-size 640 --labels $BENCH/coco.names" \
    || { log "FATAL: float CPU baseline failed"; exit 1; }
  remote_verified 120 cpu-u8io "$SPIKE/cpu-baseline-u8io.txt" \
    "LD_LIBRARY_PATH=$BENCH/lib:/data/qnn-spike/lib ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1 $BENCH/cairn-detect --cpu-baseline 5 --model $BENCH/artifacts-fixed/yolox_s-qdq-a8-u8io.onnx --model-profile yolox --input-size 640 --labels $BENCH/coco.names" \
    || { log "FATAL: u8io CPU baseline failed"; exit 1; }
  log "cpu baselines: float=$(grep -o 'cpu-baseline-ms: .*' "$SPIKE/cpu-baseline-float.txt" || echo '?') u8io=$(grep -o 'cpu-baseline-ms: .*' "$SPIKE/cpu-baseline-u8io.txt" || echo '?')"

  # Two interleaved rounds: drift between a variant's rounds bounds the
  # within-session noise the verdict must clear. 8 QNN sessions.
  for round in 1 2; do
    while IFS=: read -r tag stem; do
      [ -z "$tag" ] && continue
      latency_leg "$tag" "$stem" "$round"
    done <<< "$VARIANTS"
  done

  # Under `all`, do_finish fires once, at script exit — an EXIT trap
  # does not fire on function return, so a following stage re-pins over
  # a still-pinned governor (capture-once semantics make that safe).
}

# Score-parity runs, separated from do_run after the first board day:
# htp_content_test.sh WAS fifo-based then, and the 0.1.8 image's busybox
# has no mkfifo, so its runs died in 2s (since converted to the same
# pipe+done-file mechanics; this stage keeps the spike-local
# u8_content_test.sh so the spike's methodology digest stays its own).
# One clean reboot first: the fifo casualties' aborted QNN loads count
# against the CDSP session budget too.
do_content() {
  # INT/TERM must EXIT after restoring: a trapped signal otherwise
  # resumes the script, which would keep measuring against a restarted
  # container and a restored governor -- the exact silent invalidation
  # this teardown exists to prevent.
  trap 'do_finish; trap - EXIT; exit 130' INT TERM
  trap do_finish EXIT
  timeout 60 scp -q -o BatchMode=yes "$HERE/u8_content_test.sh" "$BOARD:$BENCH/" 2>/dev/null
  remote_verified 60 u8-content-sha "$SPIKE/.content-sha" "sha256sum $BENCH/u8_content_test.sh" \
    || { log "FATAL: cannot verify content-script push"; exit 1; }
  [ "$(cut -d' ' -f1 "$SPIKE/.content-sha")" = "$(sha256sum "$HERE/u8_content_test.sh" | cut -d' ' -f1)" ] \
    || { log "FATAL: u8_content_test.sh push mismatch"; exit 1; }
  do_reboot
  ensure_engine_stopped
  pin_governor
  log "== content runs (clip ac86)"
  while IFS=: read -r tag stem; do
    [ -z "$tag" ] && continue
    ensure_engine_stopped
    log "content $tag"
    remote 400 "PROFILE=yolox INSIZE=640 sh $BENCH/u8_content_test.sh qnn $BENCH/artifacts-fixed/$stem.onnx $BENCH/clip-ac86.mp4 u8spike-$tag $QNN_FLAGS" \
      || log "WARN: content $tag rc nonzero"
  done <<< "$VARIANTS"
  # do_finish fires at script exit (see do_run's closing note)
}

do_fetch() {
  log "== fetch evidence"
  mkdir -p "$SPIKE/content" "$SPIKE/runs"
  for tag in float u8in u8out u8io; do
    fetch "$BENCH/content/u8spike-$tag" "$SPIKE/content/" || log "WARN: content u8spike-$tag fetch incomplete"
  done
  if remote_verified 30 runs-after "$SPIKE/.runs-after" "ls $BENCH/runs"; then
    # New run dirs only: everything not in the pre-run listing.
    while read -r d; do
      [ -z "$d" ] && continue
      grep -qxF "$d" "$SPIKE/.runs-before" 2>/dev/null && continue
      fetch "$BENCH/runs/$d" "$SPIKE/runs/" || log "WARN: run $d fetch incomplete"
    done < "$SPIKE/.runs-after"
  else
    log "WARN: cannot list bench runs"
  fi
  log "fetched: $(ls "$SPIKE/content" 2>/dev/null | wc -l) content dirs, $(ls "$SPIKE/runs" 2>/dev/null | wc -l) run dirs"
}

case $STAGE in
build) do_build ;;
push) do_push ;;
run) do_run ;;
content) do_content ;;
fetch) do_fetch ;;
all)
  do_build
  do_push
  do_run
  do_content
  do_fetch
  ;;
*)
  echo "usage: $0 [all|build|push|run|content|fetch]" >&2
  exit 2
  ;;
esac
