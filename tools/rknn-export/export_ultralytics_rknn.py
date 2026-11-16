#!/usr/bin/env python3
"""ONNX export of Ultralytics detectors for the rknn trial (export-venv only).

AGPL boundary as tools/qdq-export/export_ultralytics.py: operator-run, outputs
stay out of git. Variants:
  stock  default exporter graph (end2end=False: raw [1,4+nc,A])
  e2e    yolo26's NMS-free export ([1,300,6])
  split  head cut before DFL/decode, one (box, cls_sigmoid, cls_sum) triple per
         stride, the layout airockchip's model zoo feeds its RKNN post-process.
         box has 4*reg_max channels (64 for v8/v11 = DFL logits; 4 for yolo26 =
         ltrb distances in stride units). yolo26 uses its one2one head.
usage: export_ultralytics_rknn.py MODEL VARIANT IMGSZ OUT.onnx   (cwd holds MODEL.pt)
"""
import os, shutil, sys
import onnx
import torch
from ultralytics import YOLO
from ultralytics.nn.modules.head import Detect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import onnx_edit

name, variant, imgsz, dest = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
m = YOLO(f"{name}.pt")


def split_forward(self, x):
    heads = self.one2one if self.end2end else self.one2many
    outs = []
    for i in range(self.nl):
        box = heads["box_head"][i](x[i])
        cls = heads["cls_head"][i](x[i]).sigmoid()
        outs += [box, cls, cls.sum(1, keepdim=True)]
    return tuple(outs)


if variant == "split":
    Detect.forward = split_forward
    m.model.model[-1].export = True
    path = m.export(format="onnx", imgsz=imgsz, opset=12, simplify=False)
    head = m.model.model[-1]
    names = [f"{k}{i}" for i in range(3) for k in ("box", "cls", "sum")]
    try:
        onnx.save(onnx_edit.rename_outputs(onnx.load(path), names), path)
        # read back from the saved file: the parity code indexes outputs by position
        got = {o.name: [d.dim_value for d in o.type.tensor_type.shape.dim]
               for o in onnx.shape_inference.infer_shapes(onnx.load(path)).graph.output}
        assert list(got) == names, list(got)
        for i, s in enumerate((8, 16, 32)):
            g = imgsz // s
            want = {f"box{i}": [1, 4 * head.reg_max, g, g], f"cls{i}": [1, head.nc, g, g], f"sum{i}": [1, 1, g, g]}
            assert {k: got[k] for k in want} == want, (got, want)
    except BaseException:
        os.remove(path)
        raise
elif variant == "e2e":
    path = m.export(format="onnx", imgsz=imgsz, opset=12, end2end=True)
else:
    path = m.export(format="onnx", imgsz=imgsz, opset=12, end2end=False)
shutil.move(path, dest)
print("wrote", dest)
