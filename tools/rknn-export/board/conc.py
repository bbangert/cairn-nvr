#!/usr/bin/env python3
"""N rk.py worker processes, each with its own rknn_context, started on one epoch.
usage: conc.py SECONDS MODEL [MODEL...]   (repeat a model to share it)"""
import json, subprocess, sys, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rk
secs, models = float(sys.argv[1]), sys.argv[2:]
start = time.time() + 8 + 2 * len(models)   # every child inits before the epoch
t0, m0 = rk.temps(), rk.meminfo()
s = rk.Sampler()
procs = [subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "rk.py"), "worker", m, str(start), str(secs)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for m in models]
while time.time() < start: time.sleep(0.05)
s.start()
outs = [p.communicate()[0] for p in procs]
s.stop = True; s.join()
res = [json.loads(l[5:]) for o in outs for l in o.splitlines() if l.startswith("JSON:")]
errs = [o[-400:] for o in outs if "JSON:" not in o]
print("JSON:" + json.dumps({"workers": res, "agg_ips": round(sum(r["ips"] for r in res), 2), "temp_before": max(t0),
                            "temp_after": max(rk.temps()), "mem_before": m0, **s.summary(), "raw_errors": errs}))
