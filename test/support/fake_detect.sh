#!/bin/sh
# Stands in for the cairn-detect binary in Cairn.Native.Canary tests: the
# outcomes a probe load has, selected by the --model path it is given.
#
#   *bad*    model will not open -> the binary's own `fatal:` on stderr, exit 1
#   *hang*   neither ready nor dead, so the probe's timeout is what ends it
#   *deaf*   ready, then ignores SIGTERM: only the escalation ends it
#   *noise*  talks, but never says ready, and exits
#   else     the group-mode `plugin.status` ready line, then it waits like the
#            real one does with no packets arriving
#
# A --model path with a directory in it also gets its pid written to
# `<model>.pid`: that is how a test names the OS process it has to prove is
# gone. Bare model names (the tests that do not care) write nothing, so nothing
# lands in the checked-out tree.
args="$*"

model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2" ;;
  esac
  shift
done

case "$model" in
  */*) echo $$ > "$model.pid" ;;
esac

ready='{"spec":"cairn.plugin","version":1,"type":"plugin.status","status":{"state":"ready"}}'

case "$args" in
  *--cpu-baseline*)
    # The baseline mode: outcome selected by the model name, like the probe's.
    case "$model" in
      *bad*)
        echo "fatal: opening the model: no such file" >&2
        exit 1
        ;;
      *hang*)
        exec sleep 30
        ;;
      *)
        echo "cpu-baseline-ms: 123.456"
        exit 0
        ;;
    esac
    ;;
  *bad*)
    echo "fatal: opening the model: no such file" >&2
    exit 1
    ;;
  *hang*)
    # exec so the pid above is the process that has to be signalled, rather
    # than a shell holding it
    exec sleep 30
    ;;
  *deaf*)
    trap '' TERM
    echo "$ready"
    while :; do sleep 1; done
    ;;
  *noise*)
    echo '{"spec":"cairn.plugin","version":1,"type":"plugin.status","status":{"state":"starting"}}'
    echo 'libav: this is not ndjson at all'
    exit 2
    ;;
  *)
    echo "$ready"
    exec sleep 30
    ;;
esac
