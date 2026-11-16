#!/usr/bin/env python3
"""yolo26 end-to-end [1,300,6] (x1,y1,x2,y2,score,cls): per ref det >=0.3, is there a sim det of the
same class with IoU>=0.5 and >=0.3?  usage: parity_e2e.py NAME"""
import sys, os, numpy as np
name = sys.argv[1]
d = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "rknn", name + ".parity.npz"))
def iou(a, b):
    w = max(0, min(a[2], b[2]) - max(a[0], b[0])); h = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - w*h
    return w*h/u if u > 0 else 0
tot = hit = 0; ns = nr = 0
for i in sorted({k.split("_")[0][3:] for k in d if k.startswith("sim")}):
    s, r = d[f"sim{i}_0"][0], d[f"ref{i}_0"][0]
    rr, ss = r[r[:, 4] >= .3], s[s[:, 4] >= .3]
    nr += len(rr); ns += len(ss)
    for x in rr:
        tot += 1; hit += any(int(y[5]) == int(x[5]) and iou(x, y) >= .5 for y in ss)
print(f"{name}: ref dets>=.3={nr} sim dets>=.3={ns} matched(same cls, IoU>=.5)={hit}/{tot}")
