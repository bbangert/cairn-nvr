import json,sys
for f in sys.argv[1:]:
  for l in open(f):
    if not l.startswith('JSON:'): print(l.strip()[:300]); continue
    r=json.loads(l[5:])
    if 'error' in r: print(r); continue
    s=r['sustained']
    print(f"{r['model']:28s} set {r['inputs_set']['p50']:5.2f} run p50 {r['run']['p50']:7.2f} p95 {r['run']['p95']:7.2f} get {r['outputs_get']['p50']:5.2f} | sus {s['ips']:6.2f}/s n={s['n']} load {s['npu_load_mean']}/{s['npu_load_max']} T {r['temp_before']:.1f}->{s['temp_max']:.1f}->{r['temp_after']:.1f} cma {s['cma_free_min_mb']} avail {s['mem_avail_min_mb']} dma {r['info']['dma_mb']} w {r['info']['weight_mb']} init {r['info']['init_ms']}")
