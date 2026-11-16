#!/bin/sh
# build_rungs.sh {apache|pack|all}: held-out frames -> calibration/parity sets
# -> twins -> .rknn + parity -> MANIFEST, in work/rungs. Each step skips if
# its output exists, so a failed run resumes. Log: work/final/build.log.
# `apache` needs no Ultralytics environment; `pack` (AGPL models) needs the
# qdq-export export-venv and the .pt files in work/src/weights.
set -eu
cd "$(dirname "$0")"
sel=${1:?usage: build_rungs.sh apache|pack|all}
case $sel in apache|pack|all) ;; *) echo "usage: build_rungs.sh apache|pack|all" >&2; exit 2 ;; esac
ROOT=$PWD W=work
F=$W/final R=$W/rungs H=$W/final/heldout
PY=venv/bin/python
EXPORT_PY=$ROOT/../qdq-export/export-venv/bin/python
QUANT_PY=$ROOT/../../plugins/cairn-detect/model/quant-venv/bin/python
CAL=$ROOT/../qdq-export/out-20260820
CAP=$ROOT/../qdq-export/capture_frames.sh
mkdir -p $F/build $R
echo "logging to $F/build.log" >&2
exec 3>&2 >>$F/build.log 2>&1
die() { echo "$1"; echo "$1" >&3; exit 1; }
echo "== $(date -u +%FT%TZ) build_rungs.sh $sel"
rm -f $R/MANIFEST.sha256 $R/MANIFEST.json

if [ -z "$(ls $H 2>/dev/null)" ]; then
  rm -rf $H.tmp
  [ ! -d $H ] || rmdir $H  # mv onto an existing empty dir would nest the frames inside it
  new=
  for f in $ROOT/../../data/events/reolink_main/*.mp4; do
    ls $CAL/calib/"$(basename "$f" .mp4)"_*.png >/dev/null 2>&1 || new="$new $f"
  done
  FRAMES_PER_SOURCE=2 $CAP $H.tmp $new
  FRAMES_PER_SOURCE=10 $CAP $H.tmp $CAL/clips/tmp-w2-rm.mp4 $CAL/clips/walk-c2.mp4 $CAL/clips/tmp-w2-c2.mp4 $CAL/clips/tmp-c0bd.mp4
  FRAMES_PER_SOURCE=20 $CAP $H.tmp $CAL/clips/walk-sub.mp4
  mv $H.tmp $H
fi
if [ ! -s $F/heldout-census.txt ]; then
  $QUANT_PY $ROOT/../qdq-export/calib_census.py $H --model $W/src/yolox_s.onnx > $F/heldout-census.txt.tmp
  mv $F/heldout-census.txt.tmp $F/heldout-census.txt
fi

prep() { # NAME SIZE POLICY ORDER
  [ -f $F/calib/$1/set.json ] || $PY -I prep_calib.py $CAL/calib $F/calib/$1 $2 $3 $4
  [ -f $F/parity/$1/set.json ] || $PY -I prep_calib.py $H $F/parity/$1 $2 $3 $4
}
conv() { # NAME TWIN POLICY KIND STD; convert.py refuses a parity set that shares a source with its calibration set
  [ -f $R/$1.rknn ] && return
  $PY -I convert.py $1 $R/$2 i8 --std $5 --calib $F/calib/$3 --parity $F/parity/$3 --kind $4 --out $F/build > $F/build/$1.out 2>&1 ||
    { tail -20 $F/build/$1.out; die "convert $1 failed"; }
  RKNN_OUT=$F/build $PY -I summarize.py $1
  cp $F/build/$1.rknn $R/$1.rknn.tmp
  mv $R/$1.rknn.tmp $R/$1.rknn
}

case $sel in apache|all)
  prep lb416_bgr 416 letterbox bgr
  prep lb640_bgr 640 letterbox bgr
  for m in yolox_tiny yolox_s; do
    if [ ! -f $R/$m.onnx ]; then cp $W/src/$m.onnx $R/$m.onnx.tmp; mv $R/$m.onnx.tmp $R/$m.onnx; fi
  done
  if [ ! -f $R/yolox_tiny_640.onnx ]; then
    $PY -I onnx_edit.py resize $W/src/yolox_tiny.onnx $R/yolox_tiny_640.onnx.tmp 640x640
    mv $R/yolox_tiny_640.onnx.tmp $R/yolox_tiny_640.onnx
  fi
  conv yolox_tiny_416_i8 yolox_tiny.onnx lb416_bgr yolox 1,1,1
  conv yolox_s_640_i8 yolox_s.onnx lb640_bgr yolox 1,1,1
  conv yolox_tiny_640_i8 yolox_tiny_640.onnx lb640_bgr yolox 1,1,1
esac
case $sel in pack|all)
  prep st640_rgb 640 stretch rgb
  for m in yolov8n yolov8s yolo11n yolo11s yolo26n yolo26s; do
    [ -f $R/${m}_split.onnx ] || (cd $W/src/weights && $EXPORT_PY -I $ROOT/export_ultralytics_rknn.py $m split 640 $ROOT/$R/${m}_split.onnx)
    conv ${m}_split_640_i8 ${m}_split.onnx st640_rgb split 255,255,255
  done
esac
$PY -I manifest.py $R
