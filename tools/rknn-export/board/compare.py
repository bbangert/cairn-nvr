#!/usr/bin/env python3
"""Host side: board NPU outputs (rk.py acc) vs the simulator and FP32 tensors in
$RKNN_OUT/NAME.parity.npz (default work/rknn). build_rungs.sh keeps no tensors, so a
rung from work/rungs cannot be scored here.
usage: compare.py NAME KIND BOARD.npz    (KIND as parity.py: yolox | split | e2e)
Writes $RKNN_OUT/NAME_board.parity.npz with sim:=npu so parity.py scores the board run."""
import os, subprocess, sys, numpy as np
name, kind, board = sys.argv[1:4]
here = os.path.dirname(os.path.abspath(__file__))
rk = os.environ.get("RKNN_OUT") or os.path.join(here, "..", "work", "rknn")
PY, PARITY, env = os.path.join(here, "..", "venv", "bin", "python"), os.path.join(here, "..", "parity.py"), {**os.environ, "RKNN_OUT": os.path.abspath(rk)}
t = np.load(os.path.join(rk, name + ".parity.npz")); b = np.load(board)
def cos(a, c):
    a, c = a.ravel().astype(np.float64), c.ravel().astype(np.float64)
    return a @ c / (np.linalg.norm(a) * np.linalg.norm(c) + 1e-12)
outs = sorted({int(k.split("_")[1]) for k in b})
for j in outs:
    ns = [cos(b[f"npu{i}_{j}"], t[f"sim{i}_{j}"]) for i in range(5)]
    nr = [cos(b[f"npu{i}_{j}"], t[f"ref{i}_{j}"]) for i in range(5)]
    sr = [cos(t[f"sim{i}_{j}"], t[f"ref{i}_{j}"]) for i in range(5)]
    print(f"out{j} {b[f'npu0_{j}'].shape}: cos(npu,sim)={np.mean(ns):.4f} cos(npu,fp32)={np.mean(nr):.4f} cos(sim,fp32)={np.mean(sr):.4f}")
np.savez(os.path.join(rk, name + "_board.parity.npz"),
         **{f"sim{i}_{j}": b[f"npu{i}_{j}"] for i in range(5) for j in outs},
         **{f"ref{i}_{j}": t[f"ref{i}_{j}"] for i in range(5) for j in outs})
print("-- board NPU vs FP32 (parity.py):")
subprocess.run([PY, "-I", PARITY, name + "_board", kind], env=env, check=True)
print("-- simulator vs FP32 (trial):")
subprocess.run([PY, "-I", PARITY, name, kind], env=env, check=True)
