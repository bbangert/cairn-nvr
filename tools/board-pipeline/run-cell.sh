#!/bin/sh
# On-board cell runner (busybox ash) — companion to run-local.sh, invoked by
# ../capacity-ladder.sh via `:os.cmd` from the nerves_ssh shell. Runs ONE
# ladder cell (fixed stream count, clip, duration) as its own OS process, so
# a NIF fault in the cell can never take the ssh-serving VM with it
# (membrane-port research/board-first-light.md: the standalone BEAM must not
# be the vagus VM the ssh shell evaluates in).
#
# Ported from tools/board-bench/bench.sh's governor-pin, stale-process-sweep
# and /proc sampling discipline rather than reusing it directly: bench.sh
# drives the `cairn-detect` binary, which CLAUDE.md retired to canary/parity
# duty after the membrane cutover (#100) — it is no longer a capacity
# vehicle. This drives `Cairn.BoardPipeline.run/1`, the in-VM harness task
# 5.5 grew for exactly this measurement (PR #99).
#
#   sh run-cell.sh <tag> <streams> <seconds> <clip>
#
# Writes everything under $RUN_ROOT/<tag>-<streams>cam-<epoch>/: out.log (the
# harness's own `board-pipeline: ...` lines — the fps/objects/gap/cpu_pct
# figures live there, parsed back on the caller's side because CR-heavy
# board output over a live ssh channel is known to render blank; see
# qcs6490-effort-state memory), proc (ts/utime/stime/rss samples), meta
# (governor + config), out.log.sha256 (evidence integrity for the pulled
# copy). Exit 0 only if the harness itself exited 0 (`Cairn.BoardPipeline.run`
# returns `:ok` or `{:error, _}`, translated below to a halt code).
#
# Env (all set by capacity-ladder.sh; defaults let a human run one cell by
# hand):
#   HARNESS_PA    space-separated -pa dirs: every dep's ebin + the harness's
#                 own (from run-local.sh's DEPS list, plus this cell script's
#                 own compiled output)
#   MODEL LABELS BACKEND QNN_LIBRARY DECODER SAMPLE_FPS NATIVE_LIB ORT_LIB
#                 -> BOARD_PIPELINE_* (board-side paths; not pushed by this
#                 script — reuse the phase 0-5 bundles already on the board,
#                 e.g. /data/cairn-bench, /data/cairn5, per board-first-light.md)
#   RUN_ROOT      board-side dir this cell's evidence lands under
#   PIN_GOVERNOR=1  pin cpufreq to performance for the cell, restore after —
#                 unpinned schedutil reads QNN ~2x slow (docs/npu-backends.md)
set -u
TAG=${1:?tag required}
STREAMS=${2:?streams required}
SECS=${3:?seconds required}
CLIP=${4:?clip path required}

# Nerves ships no `elixir` CLI — and the `erl` wrapper script needs
# readlink/dirname/sed this busybox lacks — so the harness boots as its own
# BEAM through `erlexec` directly, handed the env the wrapper would have
# derived (how erlinit boots the firmware itself). POSIX glob-loops, not
# `head` (absent here too).
ROOTDIR=/srv/erlang
for b in /srv/erlang/erts-*/bin; do BINDIR=$b; done
EMU=beam
PROGNAME=erl
export ROOTDIR BINDIR EMU PROGNAME
for d in /srv/erlang/lib/elixir-*/ebin; do ELIXIR_EBIN=$d; done
for d in /srv/erlang/lib/logger-*/ebin; do LOGGER_EBIN=$d; done
# The pruned release has no default bootfile; its start_clean needs the
# $RELEASE_LIB the release manager would have expanded.
for f in /srv/erlang/releases/*/start_clean.boot; do BOOT=${f%.boot}; done
RUN_ROOT=${RUN_ROOT:?RUN_ROOT required}
HARNESS_PA=${HARNESS_PA:?HARNESS_PA required (space-separated -pa dirs)}

case ${STREAMS} in
'' | *[!0-9]* | 0) echo "streams must be a positive integer" >&2; exit 1 ;;
esac
case ${SECS} in
'' | *[!0-9]* | 0) echo "seconds must be a positive integer" >&2; exit 1 ;;
esac
if [ ! -r "$CLIP" ]; then
  echo "clip $CLIP is not readable on the board" >&2
  exit 1
fi

RUN="$RUN_ROOT/$TAG-${STREAMS}cam-$(date +%s)"
mkdir -p "$RUN"

# Stale-run sweep, scoped by cmdline rather than bench.sh's blanket
# `killall`: this board also runs the nerves_ssh VM that this cell's own ssh
# invocation is evaluating inside, and a name-based kill (`beam.smp`,
# `elixir`) would take it down mid-sweep. Grep /proc for our own harness
# path instead — busybox has no pgrep, but /proc/*/cmdline is always there.
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  # Never ourselves or our shell: this script's own cmdline carries the
  # board-pipeline path, so the sweep would otherwise kill the cell it is
  # starting.
  [ "$pid" = "$$" ] && continue
  [ "$pid" = "$PPID" ] && continue
  # cmdline is NUL-separated; grep straight at it is busybox-dependent.
  if [ -r "$p/cmdline" ] && tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "board-pipeline"; then
    kill "$pid" 2>/dev/null
  fi
done

GOV_FILE=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
GOV=$(cat "$GOV_FILE" 2>/dev/null || echo unknown)
HARNESS_PID=""
cleanup() {
  [ -n "$HARNESS_PID" ] && kill "$HARNESS_PID" 2>/dev/null
  if [ "${PIN_GOVERNOR:-0}" = "1" ] && [ "$GOV" != "unknown" ]; then
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      echo "$GOV" > "$c/cpufreq/scaling_governor" 2>/dev/null
    done
  fi
}
trap cleanup EXIT INT TERM
if [ "${PIN_GOVERNOR:-0}" = "1" ]; then
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance > "$c/cpufreq/scaling_governor" 2>/dev/null
  done
fi
echo "governor: $(cat "$GOV_FILE" 2>/dev/null || echo unknown) (was $GOV)" > "$RUN/meta"
echo "tag: $TAG streams: $STREAMS seconds: $SECS clip: $CLIP backend: ${BACKEND:-} decoder: ${DECODER:-} sample_fps: ${SAMPLE_FPS:-}" >> "$RUN/meta"

PA_FLAGS=""
for dir in $HARNESS_PA; do
  PA_FLAGS="$PA_FLAGS -pa $dir"
done

# `board-pipeline:` prefix matches Cairn.BoardSoak's ssh-log discipline
# (board_pipeline.ex moduledoc); harness options come entirely from
# BOARD_PIPELINE_* env, matching how run-local.sh drives the same module.
BOARD_PIPELINE_MODEL="${MODEL:-}" \
  BOARD_PIPELINE_LABELS="${LABELS:-}" \
  BOARD_PIPELINE_BACKEND="${BACKEND:-}" \
  BOARD_PIPELINE_QNN_LIBRARY="${QNN_LIBRARY:-}" \
  BOARD_PIPELINE_CLIP="$CLIP" \
  BOARD_PIPELINE_SECONDS="$SECS" \
  BOARD_PIPELINE_DECODER="${DECODER:-}" \
  BOARD_PIPELINE_SAMPLE_FPS="${SAMPLE_FPS:-}" \
  BOARD_PIPELINE_STREAMS="$STREAMS" \
  BOARD_PIPELINE_NATIVE_LIB="${NATIVE_LIB:-}" \
  BOARD_PIPELINE_ORT_LIB="${ORT_LIB:-}" \
  LD_LIBRARY_PATH=/data/cairn-bench/lib:/data/qnn-spike/lib \
  ORT_DYLIB_PATH=/data/qnn-spike/lib/libonnxruntime.so.1 \
  "$BINDIR/erlexec" -boot "$BOOT" -boot_var RELEASE_LIB /srv/erlang/lib \
  -pa "$ELIXIR_EBIN" -pa "$LOGGER_EBIN" $PA_FLAGS -noshell \
  -eval '{ok,_} = application:ensure_all_started(elixir), {ok,_} = application:ensure_all_started(logger), case '\''Elixir.Cairn.BoardPipeline'\'':run() of ok -> erlang:halt(0); Other -> io:format("board-pipeline: ~p~n", [Other]), erlang:halt(1) end' \
  > "$RUN/out.log" 2>&1 &
HARNESS_PID=$!

# /proc sampling while the cell runs, as bench.sh: field extraction via
# `set --`, not cut/awk (absent on this busybox); comm field ("(erl)" or
# "(beam.smp)") is one token, so utime/stime are $14/$15.
# CAVEAT the ladder README flags: `erl` execs through erlexec into beam.smp
# — $! survives an `exec` (same pid, replaced image) but NOT a fork, so if
# this ERTS ever forks instead of exec'ing, these samples silently read the
# wrong (parent) process. The
# `comm` field recorded per sample makes that failure mode visible in the
# pulled file rather than silently mislabeling every number. CPU%/RSS-peak
# arithmetic is deferred to capacity-ladder.sh after the pull (this busybox
# has no bc/awk for it, and the raw counters plus CLK_TCK are cheap to ship).
echo "clk_tck: $(getconf CLK_TCK 2>/dev/null || echo 100)" >> "$RUN/meta"
: > "$RUN/proc.samples"
while kill -0 "$HARNESS_PID" 2>/dev/null; do
  if [ -r "/proc/$HARNESS_PID/stat" ]; then
    stat_line=$(cat "/proc/$HARNESS_PID/stat" 2>/dev/null) || stat_line=""
    statm_line=$(cat "/proc/$HARNESS_PID/statm" 2>/dev/null) || statm_line=""
    if [ -n "$stat_line" ] && [ -n "$statm_line" ]; then
      comm=$(expr "$stat_line" : '[0-9]* (\(.*\)) .*') 2>/dev/null || comm="?"
      set -- $stat_line
      ut=${14}
      st=${15}
      set -- $statm_line
      echo "$(date +%s) $ut $st $2 $comm" >> "$RUN/proc.samples"
    fi
  fi
  sleep 5
done
wait "$HARNESS_PID"
rc=$?
HARNESS_PID=""

# Checksum every artifact the ladder script pulls back — its own df-checked
# fetch step re-verifies these against the copy that lands locally. Relative
# names, hashed from inside the run dir: an absolute board path in the
# manifest would make the local `sha256sum -c` follow the board's path
# instead of the pulled file. The cksum fallback is prefixed so the local
# verifier knows it is not a sha256 manifest.
for f in out.log proc.samples meta; do
  (cd "$RUN" && sha256sum "$f" > "$f.sha256") 2>/dev/null ||
    {
      sum=$(cd "$RUN" && cksum "$f" 2>/dev/null | cut -d' ' -f1-2) || sum="unavailable"
      echo "cksum:$sum  $f" > "$RUN/$f.sha256"
    }
done

echo "cell $TAG streams=$STREAMS rc=$rc run=$RUN"
exit "$rc"
