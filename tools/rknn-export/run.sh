#!/bin/sh
# run.sh NAME ONNX MODE [convert.py args...]  — logs to work/rknn/NAME.out
cd "$(dirname "$0")"; n=$1; shift
mkdir -p work/rknn
rc=0
venv/bin/python -I convert.py "$n" "$@" > work/rknn/$n.out 2>&1 || rc=$?
venv/bin/python -I summarize.py "$n" || rc=$?
exit $rc
