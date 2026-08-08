# board-bench — repeatable QCS6490 benchmark runs

Phase-4 harness (qcs6490-profiles plan): `deploy.sh` builds and pushes
the bundle; `bench.sh` runs one config on the board; results land as
one md per run under the plan's `research/bench-results/`, numbers
re-derivable from the `runs/<tag>/` dir each run leaves on the board.

## Protocol

Matrix per model: backend {ort, qnn} × cameras {2, 4, 8} (interview 6's
minimal sweep), fixed duration (≥120 s), `--sample-fps` at the profile's
target. Per cell record: p50/p95 inference latency (the plugin's own
`infer latency:` lines), achieved inference rate vs `ncams ×
sample_fps`, CPU % and RSS peak, and the run's cpufreq governor.

```
# on the board (via nerves_ssh :os.cmd), qnn at 4 cameras:
MODEL=/data/cairn-bench/yolo26s-qdq.onnx PIN_GOVERNOR=1 \
sh /data/cairn-bench/bench.sh qnn 120 4 \
  --qnn-library /data/qnn-spike/lib/libonnxruntime_providers_qnn.so \
  --qnn-soc-model 35 --qnn-htp-arch 68
```

## Iron rules (all measured, all bitten)

- **Record the governor, or pin it** (`PIN_GOVERNOR=1`). Idle-board
  `schedutil` inflates QNN p50 ~2× flat and noiseless — it looks like a
  real HTP number and is not (docs/npu-backends.md).
- **A qnn run proves nothing without its ort twin.** Same artifact,
  same cameras: D-P5's ≥3× same-artifact delta is the only fallback
  detector. The deliberate-CPU control run doubles as proof the harness
  would catch the fallback case (plan 4.5).
- **Repeatability before conclusions**: two consecutive runs of one
  config must agree within noise before any cross-config comparison.
- `cdsprpcd` is NOT needed for unsigned-PD offload (phase-0 spike);
  nothing here manages it.
- HA workload realism: when benching "under real load", verify the
  board's containers are actually up first (the phase-0 board probe
  showed how); a bench on an idle board answers a different question —
  say which one the results file answers.

## Feeds

Default: N looping local-clip feeds (`CLIP`, annexb .ts — remux once
with `-bsf:v h264_mp4toannexb -f mpegts`; the bsf breaks at loop
boundaries when streaming mp4 directly). Real cameras: `CAM_URLS` file,
one `rtsp://` URL per line — same decode+inference load plus real
network arrival. The plugin binds RTP on loopback only, so feeds always
run on the board.
