#!/bin/sh
# conc.sh OUT : the concurrency set, 60 s each, 20 s idle between.
cd "$(dirname "$0")"; out=$1; M=models
for set in "$M/yolov8n_split_640_i8.rknn" \
           "$M/yolov8n_split_640_i8.rknn $M/yolov8n_split_640_i8.rknn" \
           "$M/yolov8n_split_640_i8.rknn $M/yolov8n_split_640_i8.rknn $M/yolov8n_split_640_i8.rknn" \
           "$M/yolov8n_split_640_i8.rknn $M/yolox_tiny_416_i8.rknn" \
           "$M/yolox_s_640_i8.rknn $M/yolox_s_640_i8.rknn"; do
  python3 conc.py 60 $set 2>&1 | grep -v "^E RKNN" >> "$out"; sleep 20
done
echo DONE >> "$out"
