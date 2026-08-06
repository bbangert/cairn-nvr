# qnn-spike — QNN/HTP toolchain spike for QCS6490

Phase-0 spike artifacts from the qcs6490-profiles plan: proves ONE
believable HTP inference on the Radxa Dragon Q6A and records the recipe.
The code is disposable; the recipe is the deliverable. Full findings:
`.claude/plans/qcs6490-profiles/research/spike-results.md`.

**Result (2026-08-06)**: yolox_nano full-QDQ 416×416, N=100 on-board —
CPU EP p50 40.6 ms vs QNN/HTP p50 **6.66 ms** (6.1×; D-P5 bar was 3×).

## The version triple

| Component | Version | Where it comes from |
|---|---|---|
| ONNX Runtime (base) | 1.26.0 | GitHub release `onnxruntime-linux-aarch64-1.26.0.tgz` — `libonnxruntime.so` + C headers |
| QNN plugin EP | 2.4.0 | PyPI `onnxruntime-qnn`, `cp312-manylinux_2_34_aarch64` wheel |
| QAIRT (QNN SDK) | 2.48.40 | bundled inside that wheel — including `libQnnHtpV68Skel.so`; no Qualcomm account needed |

Board floor: glibc ≥2.34 (board ships 2.43), `libstdc++.so.6` in `/lib`.

## Files

- `qnn_spike.c` — driver: one model, one EP (`cpu`|`qnn`), N timed
  inferences after warmup, JSON result line with p50/p95. QNN mode uses
  the ORT ≥1.22 plugin-EP C API (`RegisterExecutionProviderLibrary` →
  `SessionOptionsAppendExecutionProvider_V2`, registration name
  `QNNExecutionProvider`, `backend_type=htp`), and passes extra
  `key=value` argv on to the EP.
- `build.sh` — downloads both runtime pieces, cross-compiles the driver
  (`gcc-aarch64-linux-gnu`), quantizes the spike model, and assembles
  `work/bundle/` (~130 MB — `libQnnHtpPrepare.so` alone is 89 MB and IS
  required: graph prepare runs on-device at session creation, ~1.1 s).
  Model prerequisites (both gitignored; see
  `plugins/cairn-detect/model/quantize-model.md`): `yolox_nano.onnx` in
  the plugin root and the `model/quant-venv` virtualenv. `MODEL=` skips
  quantization but must point at a FULL-op-coverage QDQ model.
- `spike_quant.py` — full-op-coverage QDQ quantization (w8a8,
  per-channel), reusing the repo's calibration reader/preprocessing.
  This is what produced the PASS artifact; the repo's CPU-tuned
  conv-island `*-int8.onnx` models do NOT run on HTP (see traps).
- `run_spike.sh` — on-board runner (busybox ash), CPU then QNN
  (passes `soc_model=35 htp_arch=68`).

## Deploy + run (from the dev container)

Board exec is nerves_ssh: commands are ELIXIR; shell via `:os.cmd`.
busybox has no `chmod`; scp needs the dir pre-made and exits 1 even on
success (check sizes instead).

```sh
./build.sh
ssh 192.168.2.87 'File.mkdir_p!("/data/qnn-spike")'
scp -r work/bundle/. 192.168.2.87:/data/qnn-spike/
ssh 192.168.2.87 'File.chmod!("/data/qnn-spike/qnn_spike", 0o755)'
ssh 192.168.2.87 ':os.cmd(~c"sh /data/qnn-spike/run_spike.sh 100 2>&1") |> IO.puts()'
```

Success criterion is the latency DELTA (QNN p50 ≤ CPU p50 / 3), never
"no errors": both silent failure modes on this board (whole-session CPU
fallback, wrong-DTB DSP degrade) produce clean-looking runs.

## Traps this spike hit so later phases don't

- Pass `soc_model=35 htp_arch=68` explicitly — platform detection
  fails without them. `Unable to set HTP power configurations` persists
  either way (burst mode likely inert; open watch-item).
- Conv-island QDQ models (the repo's CPU-tuned `*-int8.onnx`) do NOT
  run on HTP — FP32 gaps fail validation en masse and an ORT NHWC
  MaxPool layout bug then aborts the session. HTP needs full-op-coverage
  QDQ (w8a8, per-channel).
- yolov10n full-QDQ segfaults at first inference (NMS-free tail
  straddling QDQ partitions, QNN 2.4.0) — the yolov10/YOLO26 export
  pipeline must strip or FP32-exclude the tail.
- `cdsprpcd` is not needed for unsigned-PD offload.
- Skel delivery: `ADSP_LIBRARY_PATH="/data/qnn-spike/dsp;"` (and
  `DSP_LIBRARY_PATH`, same value) — no rootfs change required.
