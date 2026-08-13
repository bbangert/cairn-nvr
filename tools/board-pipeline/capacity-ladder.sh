#!/usr/bin/env bash
# Sparsetrack-dual-stream task 3.7 — HANDOFF SCRIPT, RUN BY BEN ON HIS
# MACHINE. Ben's standing rule: long-running board verification is a
# self-logging script he runs himself, never a loop-and-wait in an agent
# session — see CLAUDE.md and .claude/plans/sparsetrack-dual-stream/plan.md
# task 3.7. Nothing in this file was executed against the board while
# writing it; verification was `bash -n` plus `--dry-run` (see the bottom of
# this header for exactly that command).
#
# WHAT THIS DOES
#   Re-runs the QCS6490 camera-count capacity ladder from the membrane-port
#   effort (plan task 5.5, PR #99 — `.claude/plans/membrane-port/research/
#   fps-accuracy-sweep.md`: 4 cameras at 5 MP clean, every session past that
#   wall opened and then decoded NOTHING for 300 s), now comparing dual-
#   stream ingest against that single-stream baseline. `Cairn.BoardPipeline`
#   (tools/board-pipeline/board_pipeline.ex) models only the detect branch —
#   parser -> Picker -> Decoder -> Inference, fed by a packed access-unit
#   clip — which is exactly the piece phase-3 task 3.4 changed: with a
#   `substream_url` configured, the detect branch taps the SUB tee (its own
#   parser, independent codec/fps/resolution) instead of the main tee, and
#   main's tee only ever carries compressed H.264 to CMAF/RTP — never
#   decoded. So dual-stream's effect on THIS harness is fully captured by
#   swapping which packed clip feeds the branch: a main-resolution clip
#   (today's single-stream baseline, decode+infer on the full-res feed) vs a
#   sub-resolution clip (dual-stream on, decode+infer on the substream). No
#   RTSP dual-session plumbing is needed to answer the capacity question;
#   `Membrane.RTSPDualStream.Source` itself is exercised by phase 3's own
#   ExUnit suite, not by this board harness.
#
#   For each rung in LADDER_RUNGS (default the 5.5 ladder: 2 4 6 8 streams),
#   runs LADDER_REPEATS (default 2 — board-bench's "repeatability before
#   conclusions" rule) cells at BOTH clips (baseline main-res, dual-stream
#   sub-res) for LADDER_SECONDS (default 300, matching 5.5's cells). Every
#   cell's raw evidence — the harness's own `board-pipeline:` lines
#   (observations/objects/gap_p50_ms per camera, decoder opens, cpu_pct,
#   element :stats) plus a /proc resource-sample series — is pulled back
#   under LADDER_RESULT_DIR, timestamped, sha256-checksummed. A summary CSV
#   ties every cell to its run directory; nothing here averages away a
#   starved-camera cliff the way 5.5's own writeup warns against.
#
# HOW TO INVOKE (Ben)
#   One-time per checkout — compiles+validates the harness AND leaves the
#   ebin this script pushes to the board (its default build dir is a
#   throwaway mktemp, so pin one):
#
#     BOARD_PIPELINE_BUILD=/tmp/board-pipeline-build \
#       tools/board-pipeline/run-local.sh
#
#   Then, with two packed clips ready (same format `Cairn.BoardSoak` and
#   board_pipeline.ex read: repeated <<pts::signed-64, size::unsigned-32,
#   au::binary-size(size)>>, 90 kHz pts — `mix run <scratchpad>/pack_clip.exs
#   <video> <out.aus>`), one at each resolution:
#
#     LOCAL_BUILD=/tmp/board-pipeline-build \
#     MAIN_CLIP=/path/to/main-5mp.aus SUB_CLIP=/path/to/sub-640p.aus \
#       tools/board-pipeline/capacity-ladder.sh
#
#   `--dry-run` prints the full plan (every ssh/scp it would run, every
#   rung/mode/repeat) and touches neither the network nor the board.
#   `--help` prints every env var this script reads.
#
#   WHAT TO SEND BACK: the printed summary table path
#   (LADDER_RESULT_DIR/summary-<run-id>.csv) plus the whole
#   LADDER_RESULT_DIR/<run-id>/ tree it points into — every cell's out.log,
#   proc.samples, meta and their .sha256 siblings. Flag any cell whose rc
#   column is nonzero or whose starved_cams column is nonempty first; those
#   are the ones worth reading before the fps numbers.
set -euo pipefail

# -- env / defaults -----------------------------------------------------------

BOARD=${BOARD:-192.168.2.87}
REMOTE_DIR=${REMOTE_DIR:-/data/board-pipeline}
LOCAL_BUILD=${LOCAL_BUILD:-}
MAIN_CLIP=${MAIN_CLIP:-}
SUB_CLIP=${SUB_CLIP:-}
MODEL=${MODEL:-/data/cairn-bench/yolox_nano-qdq.onnx}
LABELS=${LABELS:-/data/cairn-bench/coco.names}
BACKEND=${BACKEND:-qnn}
QNN_LIBRARY=${QNN_LIBRARY:-/data/qnn-spike/lib/libonnxruntime_providers_qnn.so}
DECODER=${DECODER:-auto}
SAMPLE_FPS=${SAMPLE_FPS:-5}
NATIVE_LIB=${NATIVE_LIB:-/data/board-pipeline/native/libcairn_native.so}
ORT_LIB=${ORT_LIB:-/data/board-pipeline/native/libcairn_ort.so}
LADDER_RUNGS=${LADDER_RUNGS:-"2 4 6 8"}
LADDER_REPEATS=${LADDER_REPEATS:-2}
LADDER_SECONDS=${LADDER_SECONDS:-300}
LADDER_PIN_GOVERNOR=${LADDER_PIN_GOVERNOR:-1}
LADDER_RESULT_DIR=${LADDER_RESULT_DIR:-"$(cd "$(dirname "$0")" && pwd)/ladder-results"}
LADDER_MIN_FREE_MB=${LADDER_MIN_FREE_MB:-4096}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN=1 ;;
  --help)
    sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown argument: $arg (only --dry-run / --help)" >&2
    exit 1
    ;;
  esac
done

step() { echo "+ $*"; }              # self-logging: echo every step before running it
say() { echo "capacity-ladder: $*"; }

# -- df-check: refuse below a sane margin before any multi-GB fetch -----------
#
# Ben's standing rule (mind-dataset-disk-budget memory): df-check before
# multi-GB fetches. The two fetch points here are the local clip staging (if
# the clips themselves need pulling from elsewhere before this script can
# read them — checked once, up front) and pulling each rung's run directory
# back from the board (checked before every pull, since results accumulate
# across the whole ladder).
require_free_mb() {
  local path=$1 needed_mb=$2
  local free_mb
  free_mb=$(df -Pm "$path" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "${free_mb:-}" ]; then
    say "WARNING: could not determine free space at $path — proceeding without a df-check"
    return 0
  fi
  if [ "$free_mb" -lt "$needed_mb" ]; then
    say "REFUSING: $path has ${free_mb} MB free, below the ${needed_mb} MB margin (LADDER_MIN_FREE_MB)"
    exit 1
  fi
  say "df-check OK: $path has ${free_mb} MB free (>= ${needed_mb} MB)"
}

# -- validation (real run only — --dry-run must work with none of this in
# place, since its whole purpose is planning a run before Ben has staged
# clips or built anything) --------------------------------------------------

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS_LIB="$ROOT/_build/dev/lib"

validate_prereqs() {
  if [ -z "$LOCAL_BUILD" ] || [ ! -d "$LOCAL_BUILD/ebin" ]; then
    say "REFUSING: LOCAL_BUILD must point at a dir with ebin/ from run-local.sh, e.g.:"
    say "  BOARD_PIPELINE_BUILD=/tmp/board-pipeline-build tools/board-pipeline/run-local.sh"
    exit 1
  fi
  if [ -z "$MAIN_CLIP" ] || [ ! -r "$MAIN_CLIP" ]; then
    say "REFUSING: MAIN_CLIP must be a readable packed .aus clip (single-stream baseline)"
    exit 1
  fi
  if [ -z "$SUB_CLIP" ] || [ ! -r "$SUB_CLIP" ]; then
    say "REFUSING: SUB_CLIP must be a readable packed .aus clip (dual-stream substream)"
    exit 1
  fi
  if [ ! -d "$DEPS_LIB" ]; then
    say "REFUSING: $DEPS_LIB missing — run mix deps.get && mix compile first (same prereq as run-local.sh)"
    exit 1
  fi
}

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOCAL_RESULT_ROOT="$LADDER_RESULT_DIR/$RUN_ID"
SUMMARY_CSV="$LADDER_RESULT_DIR/summary-$RUN_ID.csv"

# -- plan (built once, used by both --dry-run and the real run) --------------

RUNGS=($LADDER_RUNGS)
MODES=(baseline dual)
declare -A CLIP_FOR=( [baseline]="$MAIN_CLIP" [dual]="$SUB_CLIP" )
declare -A REMOTE_CLIP=( [baseline]="$REMOTE_DIR/clips/main.aus" [dual]="$REMOTE_DIR/clips/sub.aus" )

print_plan() {
  say "board=$BOARD remote_dir=$REMOTE_DIR"
  say "rungs=${RUNGS[*]} repeats=$LADDER_REPEATS seconds=$LADDER_SECONDS pin_governor=$LADDER_PIN_GOVERNOR"
  say "model=$MODEL backend=$BACKEND decoder=$DECODER sample_fps=$SAMPLE_FPS"
  say "local build=$LOCAL_BUILD main_clip=$MAIN_CLIP sub_clip=$SUB_CLIP"
  say "results -> $LOCAL_RESULT_ROOT ; summary -> $SUMMARY_CSV"
  say "cells to run (fixed, deterministic — no loop-and-wait):"
  for rung in "${RUNGS[@]}"; do
    for mode in "${MODES[@]}"; do
      for rep in $(seq 1 "$LADDER_REPEATS"); do
        say "  rung=$rung mode=$mode repeat=$rep clip=${CLIP_FOR[$mode]}"
      done
    done
  done
}

report_prereq_status() {
  # Informational only in --dry-run: shows Ben what still needs staging
  # without refusing to print the rest of the plan.
  # Guard the emptiness first: an unset LOCAL_BUILD would test "/ebin".
  [ -n "$LOCAL_BUILD" ] && [ -d "$LOCAL_BUILD/ebin" ] 2>/dev/null && s1=ok || s1="MISSING (LOCAL_BUILD/ebin)"
  [ -r "$MAIN_CLIP" ] 2>/dev/null && s2=ok || s2="MISSING (MAIN_CLIP)"
  [ -r "$SUB_CLIP" ] 2>/dev/null && s3=ok || s3="MISSING (SUB_CLIP)"
  [ -d "$DEPS_LIB" ] 2>/dev/null && s4=ok || s4="MISSING (run mix deps.get/compile)"
  say "prereq check: harness build=$s1 main_clip=$s2 sub_clip=$s3 deps_lib=$s4"
}

if [ "$DRY_RUN" = 1 ]; then
  say "--dry-run: printing the plan only, no ssh/scp will run"
  report_prereq_status
  print_plan
  step "df-check would run against: $LADDER_RESULT_DIR (margin ${LADDER_MIN_FREE_MB} MB) before each pull"
  step "ssh $BOARD ':os.cmd(~c\"mkdir -p $REMOTE_DIR/clips $REMOTE_DIR/deps $REMOTE_DIR/harness $REMOTE_DIR/runs\")'"
  step "scp -r $DEPS_LIB/*/ebin  $BOARD:$REMOTE_DIR/deps/<dep>/ebin   (unconditional — only single-file pushes checksum-skip)"
  step "scp -r $LOCAL_BUILD/ebin $BOARD:$REMOTE_DIR/harness/ebin"
  step "scp    tools/board-pipeline/run-cell.sh $BOARD:$REMOTE_DIR/run-cell.sh"
  step "scp    $MAIN_CLIP $BOARD:${REMOTE_CLIP[baseline]}  (skipped if remote sha256 matches)"
  step "scp    $SUB_CLIP  $BOARD:${REMOTE_CLIP[dual]}      (skipped if remote sha256 matches)"
  for rung in "${RUNGS[@]}"; do
    for mode in "${MODES[@]}"; do
      for rep in $(seq 1 "$LADDER_REPEATS"); do
        tag="${mode}-r${rep}"
        step "ssh $BOARD ':os.cmd(~c\"PIN_GOVERNOR=$LADDER_PIN_GOVERNOR ... sh $REMOTE_DIR/run-cell.sh $tag $rung $LADDER_SECONDS ${REMOTE_CLIP[$mode]}\")'"
      done
    done
  done
  step "df-check $LOCAL_RESULT_ROOT (margin ${LADDER_MIN_FREE_MB} MB), then scp -r $BOARD:$REMOTE_DIR/runs/ $LOCAL_RESULT_ROOT/"
  step "verify every pulled *.sha256 against a fresh local sha256sum"
  step "write $SUMMARY_CSV (rung,mode,repeat,rc,run_dir,observations,starved_cams,cpu_pct_avg,rss_peak_mb)"
  say "dry run complete — nothing touched the network"
  exit 0
fi

# -- real run ------------------------------------------------------------------

validate_prereqs
say "starting capacity ladder against $BOARD — this WILL take a while"
print_plan
mkdir -p "$LOCAL_RESULT_ROOT"

remote_elixir() {
  # Board mechanics (qcs6490-effort-state memory): ssh into this board
  # evaluates ELIXIR, not a POSIX shell — nerves_ssh. Escape to a real OS
  # process (and thereby a real BEAM node, isolated from the ssh-serving
  # VM — board-first-light.md) via :os.cmd.
  local cmd=$1
  step "ssh $BOARD ':os.cmd(~c\"$cmd\")'"
  ssh "$BOARD" ":os.cmd(~c\"$cmd\") |> IO.puts()"
}

remote_sha256() {
  local remote_path=$1
  step "ssh $BOARD ':os.cmd(~c\"sha256sum $remote_path\")' (checksum probe before push)"
  ssh "$BOARD" ":os.cmd(~c\"sha256sum $remote_path 2>/dev/null | cut -d' ' -f1\") |> IO.puts()" \
    2>/dev/null | tr -d '\r\n'
}

push_if_changed() {
  local local_path=$1 remote_path=$2
  local local_sum remote_sum
  local_sum=$(sha256sum "$local_path" | cut -d' ' -f1)
  remote_sum=$(remote_sha256 "$remote_path" || true)
  if [ "$local_sum" = "$remote_sum" ]; then
    say "skip push (checksum match): $local_path -> $BOARD:$remote_path"
    return 0
  fi
  step "scp $local_path $BOARD:$remote_path"
  scp "$local_path" "$BOARD:$remote_path"
}

remote_elixir "mkdir -p $REMOTE_DIR/clips $REMOTE_DIR/deps $REMOTE_DIR/harness $REMOTE_DIR/runs"

for dep_dir in "$DEPS_LIB"/*/ebin; do
  [ -d "$dep_dir" ] || continue
  dep=$(basename "$(dirname "$dep_dir")")
  remote_elixir "mkdir -p $REMOTE_DIR/deps/$dep"
  step "scp -r $dep_dir $BOARD:$REMOTE_DIR/deps/$dep/"
  scp -r "$dep_dir" "$BOARD:$REMOTE_DIR/deps/$dep/"
done

step "scp -r $LOCAL_BUILD/ebin $BOARD:$REMOTE_DIR/harness/"
scp -r "$LOCAL_BUILD/ebin" "$BOARD:$REMOTE_DIR/harness/"

step "scp tools/board-pipeline/run-cell.sh $BOARD:$REMOTE_DIR/run-cell.sh"
scp "$ROOT/tools/board-pipeline/run-cell.sh" "$BOARD:$REMOTE_DIR/run-cell.sh"
remote_elixir "chmod 755 $REMOTE_DIR/run-cell.sh"

# The two clips are the only genuinely multi-GB pushes here (a 5 MP clip
# packs to hundreds of MB per minute) — df-check the SOURCE side isn't
# meaningful (we're not fetching them from a remote dataset in this script,
# Ben staged them locally already per the header's invocation), so the
# push itself is left to push_if_changed's checksum skip rather than a
# blind re-upload every run.
push_if_changed "$MAIN_CLIP" "${REMOTE_CLIP[baseline]}"
push_if_changed "$SUB_CLIP" "${REMOTE_CLIP[dual]}"

HARNESS_PA_REMOTE="$REMOTE_DIR/harness/ebin"
for dep_dir in "$DEPS_LIB"/*/ebin; do
  [ -d "$dep_dir" ] || continue
  dep=$(basename "$(dirname "$dep_dir")")
  HARNESS_PA_REMOTE="$HARNESS_PA_REMOTE $REMOTE_DIR/deps/$dep/ebin"
done

# Derives the per-cell columns from the pulled evidence — GNU grep/awk are
# fine here (this runs on Ben's machine, not the board's busybox). Mirrors
# what the 5.5 ladder found by hand: a starved camera's observation count
# sits far below streams * seconds * sample_fps while the box-wide cpu_pct
# stays low (the Venus cliff was 6.8% whole-box CPU at the wall — a cell
# that "looks idle" while cameras starve is the finding to catch, not miss).
parse_cell_metrics() {
  local dir=$1
  local out="$dir/out.log" proc="$dir/proc.samples" meta="$dir/meta"
  local observations="" cpu_pct_avg="" rss_peak_mb="" starved=""

  if [ -f "$out" ]; then
    # The summary line's total, not the last per-camera line — and every
    # stage `|| true`d: a crashed cell that never printed a summary must
    # yield an empty column, not abort the whole ladder under pipefail.
    observations=$(grep 'board-pipeline: summary' "$out" 2>/dev/null |
      grep -o 'observations=[0-9]*' | tail -1 | cut -d= -f2 || true)
    # A camera's expected count (sample_fps * seconds) is per-camera and
    # rung-independent; flag anything under half of it — the 5.5 wall wasn't
    # a slope, starved sessions kept a handful of AUs total, not a fraction
    # off the healthy count.
    local expected=$((SAMPLE_FPS * LADDER_SECONDS / 2))
    starved=$( (grep 'board-pipeline: cam ' "$out" 2>/dev/null || true) |
      awk -F'observations=' -v exp="$expected" \
        '{split($2,a," "); if (a[1]+0 < exp) print $0}' |
      (grep -o 'cam [^ ]*' || true) | cut -d' ' -f2 | paste -sd';' - || true)
  fi

  if [ -f "$proc" ] && [ -f "$meta" ]; then
    local clk
    clk=$(grep '^clk_tck:' "$meta" | cut -d' ' -f2)
    clk=${clk:-100}
    rss_peak_mb=$(awk '{if ($4+0>peak) peak=$4} END{if (peak>0) printf "%.1f", peak*4096/1048576}' "$proc")
    cpu_pct_avg=$(awk -v clk="$clk" '
      NR==1 {t0=$1; u0=$2+$3}
      {t1=$1; u1=$2+$3}
      END {if (t1>t0) printf "%.1f", (u1-u0)*100/clk/(t1-t0)}' "$proc")
  fi

  echo "${observations:-},${starved:-},${cpu_pct_avg:-},${rss_peak_mb:-}"
}

: > "$SUMMARY_CSV"
echo "rung,mode,repeat,rc,run_dir,observations,starved_cams,cpu_pct_avg,rss_peak_mb" >> "$SUMMARY_CSV"

for rung in "${RUNGS[@]}"; do
  for mode in "${MODES[@]}"; do
    for rep in $(seq 1 "$LADDER_REPEATS"); do
      tag="${mode}-r${rep}"
      say "=== rung=$rung mode=$mode repeat=$rep ==="
      cell_cmd="HARNESS_PA='$HARNESS_PA_REMOTE' MODEL=$MODEL LABELS=$LABELS BACKEND=$BACKEND QNN_LIBRARY=$QNN_LIBRARY DECODER=$DECODER SAMPLE_FPS=$SAMPLE_FPS NATIVE_LIB=$NATIVE_LIB ORT_LIB=$ORT_LIB RUN_ROOT=$REMOTE_DIR/runs PIN_GOVERNOR=$LADDER_PIN_GOVERNOR sh $REMOTE_DIR/run-cell.sh $tag $rung $LADDER_SECONDS ${REMOTE_CLIP[$mode]}"
      step "ssh $BOARD ':os.cmd(~c\"$cell_cmd\")' (blocks ~${LADDER_SECONDS}s)"
      set +e
      output=$(ssh "$BOARD" ":os.cmd(~c\"$cell_cmd\") |> IO.puts()")
      rc_line=$(echo "$output" | grep '^cell ' | tail -1)
      set -e
      say "$rc_line"
      run_dir=$(echo "$rc_line" | sed -n 's/.*run=\(.*\)$/\1/p')
      cell_rc=$(echo "$rc_line" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
      metrics=",,,"

      if [ -n "$run_dir" ] && [ "$run_dir" != "unknown" ]; then
        require_free_mb "$LOCAL_RESULT_ROOT" "$LADDER_MIN_FREE_MB"
        local_cell_dir="$LOCAL_RESULT_ROOT/$(basename "$run_dir")"
        step "scp -r $BOARD:$run_dir $local_cell_dir"
        mkdir -p "$local_cell_dir"
        scp -r "$BOARD:$run_dir/." "$local_cell_dir/"
        for f in out.log proc.samples meta; do
          if [ -f "$local_cell_dir/$f.sha256" ] && [ -f "$local_cell_dir/$f" ]; then
            (cd "$local_cell_dir" && sha256sum -c "$f.sha256" >/dev/null 2>&1) ||
              say "WARNING: checksum mismatch after pull for $local_cell_dir/$f — re-fetch before trusting these numbers"
          fi
        done
        metrics=$(parse_cell_metrics "$local_cell_dir")
      else
        say "WARNING: could not parse a run dir out of: $rc_line — nothing pulled for this cell"
      fi
      echo "$rung,$mode,$rep,${cell_rc:-unknown},${run_dir:-unknown},$metrics" >> "$SUMMARY_CSV"
    done
  done
done

say "ladder complete. summary: $SUMMARY_CSV"
say "results tree: $LOCAL_RESULT_ROOT"
say "send back the summary CSV path above plus the results tree it points into"
