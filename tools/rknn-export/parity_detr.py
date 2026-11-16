#!/usr/bin/env python3
"""rfdetr parity: pred_boxes (cos) and logits (cos, plus top-300 sigmoid-score agreement)."""
import sys, os, numpy as np
name = sys.argv[1]
d = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "rknn", name + ".parity.npz"))
sg = lambda x: 1 / (1 + np.exp(-x))
cos = lambda a, b: float(a.ravel() @ b.ravel() / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
for i in sorted({k.split("_")[0][3:] for k in d if k.startswith("sim")}):
    sb, sl, rb, rl = d[f"sim{i}_0"], d[f"sim{i}_1"], d[f"ref{i}_0"], d[f"ref{i}_1"]
    if sl.shape[-1] != 91: sb, sl, rb, rl = d[f"sim{i}_1"], d[f"sim{i}_0"], d[f"ref{i}_1"], d[f"ref{i}_0"]
    rs, ss = sg(rl[0]).max(1), sg(sl[0]).max(1)
    hit = rs >= 0.3
    print(name, f"frame{i}: box cos={cos(sb,rb):.4f} logit cos={cos(sl,rl):.4f} n_ref>=.3={int(hit.sum())} "
          f"conf-query box mean|d|={np.abs(sb[0][hit]-rb[0][hit]).mean() if hit.any() else float('nan'):.4f} "
          f"recall={(ss[hit]>=0.3).mean() if hit.any() else float('nan'):.2f} mean|dscore|={np.abs(ss[hit]-rs[hit]).mean() if hit.any() else float('nan'):.3f}")
