#!/bin/sh
# INT8+FP16 for the Ultralytics matrix; RGB stretch 640, mean 0 std 255 (UnitRgb).
cd "$(dirname "$0")"
for n in yolov8n yolov8s yolo11n yolo11s yolo26n yolo26s; do
  for v in stock split; do
    ./run.sh ${n}_${v}_640_i8 work/src/${n}_$v.onnx i8 --std 255,255,255 --calib work/calib/st640_rgb --analysis 3
    ./run.sh ${n}_${v}_640_fp16 work/src/${n}_$v.onnx fp16 --std 255,255,255 --calib work/calib/st640_rgb
  done
done
