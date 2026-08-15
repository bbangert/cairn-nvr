#!/usr/bin/env bash
# tier1-ladder phase 3 — HANDOFF SCRIPT, RUN BY BEN ON HIS MACHINE (the
# standing long-runs rule). Two boundary campaigns against the QCS6490,
# both thin delegations to capacity-ladder.sh (the proven #113 harness):
#
#   A. yolox_tiny boundary (task 3.1): rungs 26/28/30 cameras ×2, dual
#      plane, SAMPLE_FPS=2 — brackets the draft budget's predicted
#      boundary (54.6 passes/s ÷ 1.875/s ≈ 29). Rung 30 deliberately
#      forces tiny past it; where delivery breaks locates the measured
#      engine_budget.
#   B. yolox_nano 40-camera re-confirmation (task 3.2): one cell at the
#      exact parameters the SHIPPED ladder resolves for a 40-camera fleet
#      (nano, derived sample_fps 2) — the capacity campaign measured this
#      pre-ladder; this run re-confirms it through the resolution path.
#
# A preflight proves the shipped qcs6490-tier1.yml resolves exactly these
# cells (tools/board-pipeline/tier1_resolution_check.exs) and aborts on
# drift, so the board only ever measures what config actually deploys.
#
# HOW TO INVOKE (Ben) — one command; the harness build happens here too,
# validated against the same clip the ladder replays:
#
#     SUB_CLIP=/path/to/sub.aus tools/board-pipeline/tier1-boundary.sh
#
#   SUB_CLIP is the tier1-capacity campaign's sub-res packed clip
#   (213c0177…_reolink_sub, 640×480@15). Regenerate from any H.264
#   *container* (raw Annex-B has no pts — mp4/mkv it first):
#     mix run --no-start tools/board-pipeline/pack_clip.exs <video> <out.aus>
#
#   LOCAL_BUILD overrides the build dir (default /tmp/board-pipeline-build;
#   an existing ebin there is reused, delete it to force a rebuild).
#   --dry-run passes through to both ladders (prints plans, touches
#   nothing). Total real runtime: 7 cells × 300 s ≈ 40 min plus transfer.
#
# WHAT TO SEND BACK: both summary CSV paths this prints at the end, plus
# the result trees they point into (same contract as capacity-ladder.sh).
# Cells with nonzero rc or nonempty starved_cams first. Findings land in
# .claude/plans/tier-surface/research/ per ladder-protocol conventions and
# retire the tier file's DRAFT marker (task 3.3).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

SUB_CLIP=${SUB_CLIP:-}
LOCAL_BUILD=${LOCAL_BUILD:-/tmp/board-pipeline-build}
LADDER_SECONDS=${LADDER_SECONDS:-300}
RESULTS=${RESULTS:-"$HERE/ladder-results"}

DRY_RUN_ARG=""
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN_ARG="--dry-run" ;;
  --help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown argument: $arg (only --dry-run / --help)" >&2
    exit 1
    ;;
  esac
done

say() { echo "tier1-boundary: $*"; }

if [ -z "$DRY_RUN_ARG" ]; then
  if [ -z "$SUB_CLIP" ] || [ ! -r "$SUB_CLIP" ]; then
    say "REFUSING: SUB_CLIP must be a readable packed .aus clip (see --help)"
    exit 1
  fi

  # The build, validated against the same clip the ladder replays — the
  # separate run-local.sh step used to be the handoff's silent prerequisite
  # (and its clipless validation run fails opaquely without one).
  if [ ! -d "$LOCAL_BUILD/ebin" ]; then
    say "building the harness into $LOCAL_BUILD (validated against SUB_CLIP, ~1 min)"
    BOARD_PIPELINE_BUILD="$LOCAL_BUILD" BOARD_PIPELINE_CLIP="$SUB_CLIP" "$HERE/run-local.sh"
  else
    say "reusing harness build at $LOCAL_BUILD (delete it to force a rebuild)"
  fi

  say "preflight: shipped-ladder resolution check (aborts on drift)"
  (cd "$ROOT" && mix run --no-start tools/board-pipeline/tier1_resolution_check.exs)
else
  say "--dry-run: skipping the build and mix preflight, printing both ladder plans"
fi

# capacity-ladder.sh validates MAIN_CLIP even for a dual-only sweep; the
# baseline mode is never selected, so the sub clip stands in.
common=(
  env
  LOCAL_BUILD="$LOCAL_BUILD"
  MAIN_CLIP="$SUB_CLIP"
  SUB_CLIP="$SUB_CLIP"
  LADDER_MODES=dual
  LADDER_SECONDS="$LADDER_SECONDS"
  SAMPLE_FPS=2
  LABELS=/data/cairn-bench/coco.names
  BACKEND=qnn
)

say "=== campaign A: yolox_tiny boundary (26/28/30 x2, ~30 min) ==="
"${common[@]}" \
  MODEL=/data/cairn-bench/yolox_tiny-qdq.onnx \
  LADDER_RUNGS="26 28 30" \
  LADDER_REPEATS=2 \
  LADDER_RESULT_DIR="$RESULTS/tier1-boundary-tiny" \
  "$HERE/capacity-ladder.sh" $DRY_RUN_ARG

say "=== campaign B: yolox_nano 40-camera re-confirmation (1 cell, ~5 min) ==="
"${common[@]}" \
  MODEL=/data/cairn-bench/yolox_nano-qdq.onnx \
  LADDER_RUNGS="40" \
  LADDER_REPEATS=1 \
  LADDER_RESULT_DIR="$RESULTS/tier1-boundary-nano40" \
  "$HERE/capacity-ladder.sh" $DRY_RUN_ARG

say "done. Send back both summary CSVs + result trees:"
say "  $RESULTS/tier1-boundary-tiny/summary-*.csv"
say "  $RESULTS/tier1-boundary-nano40/summary-*.csv"
