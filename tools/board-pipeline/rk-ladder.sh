#!/bin/sh
# A capacity ladder on the HA Green (busybox ash), run detached: rk-cell.sh per
# stream count, REPEATS (1) times each, PAUSE (15) s apart. Env: rk-cell.sh's,
# plus STOP_ON_MISS (1) and REF_OBS.
#
#   sh rk-ladder.sh <name> "<streams list>"     e.g. sh rk-ladder.sh s640 "3 4 5 6 7"
#
# Appends to $BASE/runs/<name>.ladder.log and one row per finished cell to
# <name>.csv; p50_ms, inferences and health are engine 1's (the others are in
# the run's out.log). A cell misses when rc != 0 or min_obs * 1000 < REF * 995.
# REF is REF_OBS, or else the min_obs of the first cell that exits 0: that cell
# is trusted to have kept its rate, so start the list at a count known to, or
# give REF_OBS. With STOP_ON_MISS=1 the ladder ends after the repeats of the
# first count that missed. `LADDER-DONE` ends the log on every exit once the
# lock is held. Stop a ladder with TERM to its pid: a detached shell ignores INT.
set -u

NAME=${1:?usage: sh rk-ladder.sh <name> "<streams list>"}
LIST=${2:?usage: sh rk-ladder.sh <name> "<streams list>"}
BASE=${BASE:-/root/cairn-bench-rk}
export BASE
REPEATS=${REPEATS:-1}
PAUSE=${PAUSE:-15}
STOP_ON_MISS=${STOP_ON_MISS:-1}
REF=${REF_OBS:-}
case $0 in */*) HERE=${0%/*} ;; *) HERE=. ;; esac

RUNS="$BASE/runs"
LOCK="$RUNS/.ladder.lock"
LOG="$RUNS/$NAME.ladder.log"
CSV="$RUNS/$NAME.csv"
OUT="$RUNS/$NAME.cell.out"

case $REF in
'') ;;
0 | *[!0-9]*)
  echo "rk-ladder: REF_OBS must be a positive number, got '$REF'" >&2
  exit 2
  ;;
esac

mkdir -p "$RUNS" || exit 2
# mkdir is the atomic test-and-set. One lock whatever the name: every cell runs
# the same container name.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "rk-ladder: $LOCK exists — another ladder is running, or one died; remove it by hand" >&2
  exit 2
fi

exec >>"$LOG" 2>&1

CELL=
finish() {
  rm -f "$OUT"
  rmdir "$LOCK" 2>/dev/null
  echo "LADDER-DONE $NAME $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
# The cell is sent TERM and waited for: its own trap stops the container, and
# its last lines reach the log, before the ladder exits.
on_signal() {
  [ -n "$CELL" ] && {
    kill -TERM "$CELL" 2>/dev/null
    wait "$CELL"
    cat "$OUT"
  }
  exit "$1"
}
trap finish EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# The value of `key=` on the last line of $OUT matching `pattern`.
field() {
  grep -e "$1" "$OUT" | tail -n 1 | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}

echo "ladder $NAME streams=\"$LIST\" repeats=$REPEATS stop_on_miss=$STOP_ON_MISS ref=${REF:--} start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -s "$CSV" ] || echo "name,streams,repeat,rc,total_obs,min_obs,max_obs,p50_ms,inferences,health,run_dir" >"$CSV"

first=1
for n in $LIST; do
  missed=0
  r=1
  while [ "$r" -le "$REPEATS" ]; do
    [ "$first" = 1 ] || sleep "$PAUSE"
    first=0

    sh "$HERE/rk-cell.sh" "$NAME-r$r" "$n" >"$OUT" 2>&1 &
    CELL=$!
    wait "$CELL"
    rc=$?
    CELL=
    cat "$OUT"

    total=$(field '^board-pipeline: result ' total_obs)
    min=$(field '^board-pipeline: result ' min_obs)
    max=$(field '^board-pipeline: result ' max_obs)
    p50=$(field '^board-pipeline: engine n=1 ' p50_ms)
    inferences=$(field '^board-pipeline: engine n=1 ' inferences)
    health=$(field '^board-pipeline: engine n=1 ' health)
    run=$(field '^cell ' run)
    echo "$NAME,$n,$r,$rc,$total,$min,$max,$p50,$inferences,$health,$run" >>"$CSV"

    miss=0
    case $min in
      '' | 0 | *[!0-9]*) miss=1 ;;
    esac
    [ "$rc" = 0 ] || miss=1
    if [ "$miss" = 0 ]; then
      [ -n "$REF" ] || REF=$min
      [ $((min * 1000)) -lt $((REF * 995)) ] && miss=1
    fi
    echo "cell streams=$n repeat=$r rc=$rc min_obs=${min:--} ref=${REF:--} miss=$miss"
    [ "$miss" = 1 ] && missed=1
    r=$((r + 1))
  done

  if [ "$missed" = 1 ] && [ "$STOP_ON_MISS" = 1 ]; then
    echo "ladder $NAME stops: streams=$n missed its rate"
    break
  fi
done
