# cairn-detect

Cairn's shippable reference detection plugin: a single Rust binary that takes
H.264 RTP on a UDP port and prints contract ndjson on stdout (see
`docs/plugin-contract.md`). It decodes on the video ASIC when one is
available, samples to ~5 fps, and runs an NMS-free YOLO model on the CPU
through onnxruntime.

It is a drop-in replacement for the Python `plugins/cpu-reference` command —
same argv, same output, no Cairn-side changes — and it is what you should
deploy. `plugins/cpu-reference/` stays as the minimal, readable example for
people writing their own plugin.

## At a glance

```
udp:127.0.0.1:{port}  ->  sdp demuxer (generated SDP, retried mid-GOP)
   -> decode (hardware if a backend opens, else software)
      -> wall-clock sample to 5 fps          <- full-rate frames end here
         -> 640x640 RGB24 -> CHW f32 0..1    <- GPU scale + download on HW
            -> [size-1 channel, try_send: drop when inference is behind]
               -> onnxruntime (CPU EP) -> score gate -> ndjson on stdout
```

Everything expensive happens *after* the sample gate: a hardware decoder
never pays to scale or download the ~55 fps of frames it is about to discard,
and inference runs on its own thread so a slow model pass can never stall the
socket read.

## Build (dev container)

`.cargo/config.toml` points the build at the FFmpeg 7 tree in `/opt/ffmpeg7`
and bakes an rpath so the binary runs without `LD_LIBRARY_PATH`:

```bash
cd plugins/cairn-detect
cargo build --release
```

`ort` downloads a prebuilt static onnxruntime on the first build (~90 MB,
cached in `~/.cache/ort.pyke.io`), so that build needs network. Building
anywhere else means overriding both settings — see [Shipping](#shipping).

The crate needs FFmpeg 6/7 headers; Debian 12's system FFmpeg (5.1) is too old
for rsmpeg, which is why `/opt/ffmpeg7` exists in this container.

### glibc note

The prebuilt onnxruntime is compiled against glibc >= 2.38, which redirects
`strtol` and friends to `__isoc23_*` symbols that Debian 12 (glibc 2.36) does
not export. `src/glibc_compat.rs` forwards those four symbols to their C99
equivalents.

The shims are compiled unconditionally on linux-gnu, so they are *harmless*
rather than inert: even on glibc 2.41 the statically linked onnxruntime keeps
calling them and gets C99 parsing (no `0b` prefix), which its config parsing
never depends on. They are not exported in `.dynsym`, so they cannot interpose
glibc's versions for FFmpeg or any other shared library — that stops being
true if anyone adds `-rdynamic`/`--export-dynamic` to `RUSTFLAGS` or builds
this as a cdylib. Delete the module once no build host is older than 2.38.

## Wire into config.yml

Plugin flags go *before* the contract args, which Cairn appends
(`--camera-id`, `--udp-port`, `--min-score-json`). Paths are relative to the
directory Cairn runs from:

```yaml
cameras:
  - id: front_door
    rtsp_url: rtsp://user:pass@192.168.1.10:554/stream1
    # Inference plugin command (argv or string). Receives RTP on an
    # assigned UDP port, prints ndjson detections on stdout.
    plugin:
      - plugins/cairn-detect/target/release/cairn-detect
      - --model
      # .onnx files are gitignored — produce this one with the export step
      # in model/export-model.md (or drop in any NMS-free [1,N,6] model).
      - plugins/cairn-detect/yolov10n.onnx
      - --labels
      - plugins/cairn-detect/coco.names
      - --decoder
      - auto
    min_score:
      default: 0.5
      person: 0.6
```

Logs land in `{data_dir}/log/plugin-front_door.log`. `--decoder auto` is the
default and can be omitted.

| flag | required | meaning |
|------|----------|---------|
| `--model` | yes | NMS-free ONNX detection model |
| `--labels` | no | newline-separated class names, indexed by class id; unknown ids fall back to the numeric id |
| `--decoder` | no | `auto` (default), `vaapi`, `qsv`, `nvdec`, `v4l2`, `videotoolbox`, `sw` |

## Decoder selection

`--decoder auto` probes once at startup and logs the path it chose. Order on
Linux/x86 is `vaapi → qsv → nvdec → v4l2`; macOS probes `videotoolbox`; other
Linux probes `v4l2`. Naming a backend probes only that one.

**A backend that will not open is never fatal.** Every failure is logged and
the next candidate is tried, ending at software decode — a forced
`--decoder vaapi` on a host without VAAPI runs slowly rather than
crash-looping under Cairn's restart backoff.

Sampled frames only — never the full stream — are scaled to 640x640 on the
GPU and then downloaded, because downloading full-resolution frames would cost
more than the decode saving:

| backend | device | decoder | sampled-frame filter graph |
|---------|--------|---------|----------------------------|
| `vaapi` | VAAPI | `h264` + hwaccel | `scale_vaapi=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `qsv` | QSV | `h264_qsv` | `scale_qsv=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `nvdec` | CUDA | `h264` + nvdec | `scale_cuda=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `videotoolbox` | VideoToolbox | `h264` + hwaccel | `scale_vt=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `v4l2` | — | `h264_v4l2m2m` | none: the M2M codec decodes on the ASIC but returns system memory, so the software scaler handles it |
| `sw` | — | `h264` | none |

NV12 is the download format because every backend's scaler supports it; the
640x640 NV12 → RGB24 convert afterwards is negligible. If the FFmpeg build
lacks the backend's scaler filter, that backend is reported unavailable rather
than silently downloading full-resolution frames.

`--decoder` is plugin-owned config: like everything else in the command, it
only changes across restarts.

## Model

The model must be **NMS-free** (YOLOv10 / YOLO26 style):

- input `images`, float32 `[1, 3, 640, 640]`, RGB, 0..1, CHW
- output `[1, N, 6]`, rows of `[x1, y1, x2, y2, score, class_id]` in
  640-pixel space, sorted by score descending

A plain YOLOv8 export (`(1, 84, 8400)`, which `plugins/cpu-reference`
consumes) is rejected at startup — there is deliberately no NMS in this
plugin, because the model already did it.

**`yolov10n.onnx` (FP32) is the default.** Re-export it with ultralytics in a
throwaway venv:

```bash
python3 -m venv yolo-export-venv && . yolo-export-venv/bin/activate
pip install ultralytics onnx onnxruntime torch \
    --index-url https://download.pytorch.org/whl/cpu
yolo export model=yolov10n.pt format=onnx \
    imgsz=640 batch=1 dynamic=False simplify=True nms=False
```

The `--index-url` matters: a plain `pip install ultralytics` drags in the
CUDA build of torch.

**INT8 is an opt-in for low-storage hosts, not a speed win.** Static QDQ
quantization takes the model from 9.5 MB to 2.95 MB but measured *no* latency
improvement on x86 with AVX-512 (~27 ms/frame either way) and slightly worse
recall near the score threshold. Bother with it only when disk or transfer
size matters:

```bash
cd model   # with the export venv active
python3 quantize_yolov10n.py --model ../yolov10n.onnx \
    --calib-dir calib_frames --out ../yolov10n-int8.onnx
```

One trap worth knowing before you run it: the three classification-head convs
(`/model.23/one2one_cv3.{0,1,2}.2/Conv`) must be excluded from quantization or
every confident detection's score collapses to exactly `0.500`. The script
already excludes them.

`model/export-model.md` is the detailed reference — calibration/held-out frame
extraction, the shape-inference workaround, and the full FP32-vs-INT8
comparison. `model/quantize_yolov10n.py` and `model/verify_models.py` expect
the calibration artifacts that document describes.

`coco.names` in this directory is the COCO-80 label list matching these
weights.

## Performance

Measured 2026-07-25 in this dev container (AMD Ryzen 9 7950X3D, 32 threads,
Debian 12), 90 s against the same looped 2560x1920 H.264 @ 20 fps fixture,
both plugins sampling at 5 fps:

| plugin | CPU |
|--------|-----|
| `plugins/cpu-reference` (Python, PyAV software decode) | ~840% of a core |
| `cairn-detect`, software decode | ~114% of a core |

That is a **7.3x reduction before any hardware decode** — most of the Python
plugin's cost was software-decoding full-rate 2K frames it then threw away.

Caveats: the container has no GPU (`/dev/dri` and CUDA both absent), so this
is the software path only — the hardware backends are implemented and fall
back cleanly, but their CPU win is unmeasured. The remaining ~114% is decode
plus inference (~27 ms/frame wall time, multi-threaded by onnxruntime); the
split between them has not been measured, and hardware decode targets the
decode half.

## Shipping

The release binary is **19.9 MB** stripped (24.9 MB unstripped; `strip = true`
is set in `[profile.release]`). Most of it is the statically linked
onnxruntime. It needs three files at runtime: itself, the `.onnx` model, and
the labels file.

Its only shared-library dependencies are FFmpeg and the C/C++ runtime:

```
libavcodec.so.61 libavformat.so.61 libavutil.so.59 libavfilter.so.10
libswscale.so.8 (+ libswresample.so.5, libpostproc.so.58 transitively)
libstdc++.so.6 libgcc_s.so.1 libm.so.6 libc.so.6
```

### Recommended: dynamic link against the distro's FFmpeg 7

Ship the binary + model + labels, and depend on the target distro's FFmpeg 7
runtime packages. onnxruntime is already inside the binary, so FFmpeg is the
*only* external dependency family — and it is precisely the piece that has to
match the host's VAAPI/QSV/NVDEC drivers, which the distro already wires up.
Bundling our own FFmpeg would mean owning the hardware-acceleration matrix for
every target we support, in exchange for removing one `apt install`.

Distro FFmpeg versions (checked 2026-07-25 against sources.debian.org and the
Launchpad API):

| distro | FFmpeg | status |
|--------|--------|--------|
| Debian 13 (trixie) | 7.1.5 | builds as-is |
| Debian 12 (bookworm) | 5.1.9 | too old — use the bundled-FFmpeg alternative |
| Ubuntu 24.04 LTS (noble) | 6.1.1 | needs rsmpeg's `ffmpeg6` feature instead of `ffmpeg7_1` (untested) |
| Ubuntu 25.04 (plucky), 25.10 (questing) | 7.1.1 | builds as-is |

Build on a fresh Debian 13 (or Ubuntu 25.04+):

```bash
sudo apt install -y build-essential pkg-config clang libclang-dev \
    libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev libswscale-dev
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

cd plugins/cairn-detect
RUSTFLAGS="" FFMPEG_PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig \
    cargo build --release
```

Both overrides are mandatory, because `.cargo/config.toml` is a
dev-container file: it pins `FFMPEG_PKG_CONFIG_PATH` to `/opt/ffmpeg7/...`
(the build *panics* if that directory does not exist) and adds an rpath to it.
Cargo's `[env]` does not force a value that is already in the environment, and
`RUSTFLAGS` overrides `[build] rustflags` — so exporting both wins without
editing the file and breaking the dev loop.

Runtime packages on the target:

```bash
# always
sudo apt install -y libavcodec61 libavformat61 libavutil59 libavfilter10 \
    libswscale8 libswresample5
# VAAPI (Intel/AMD iGPU)
sudo apt install -y libva2 libva-drm2 intel-media-va-driver-non-free  # Intel
sudo apt install -y libva2 libva-drm2 mesa-va-drivers                 # AMD
# QSV (Intel, oneVPL runtime)
sudo apt install -y libvpl2 libmfx-gen1.2
# NVDEC: libcuda.so.1 comes from the proprietary NVIDIA driver, not apt-only
```

Those are FFmpeg's driver dependencies, not ours — the plugin dlopens nothing
itself. Check what a host can actually do with `ffmpeg -hwaccels` and
`vainfo`; cairn-detect's own probe logs the same answer at startup.

glibc on both recommended targets (Debian 13: 2.41, Ubuntu 24.04: 2.39) is
newer than onnxruntime's 2.38 requirement, so `src/glibc_compat.rs` is inert
there.

### Alternative: bundle a private FFmpeg

What this container does, made relocatable — ship a `lib/` directory of
FFmpeg 7 `.so` files next to the binary and point the rpath at it:

```bash
RUSTFLAGS="-C link-args=-Wl,-rpath,\$ORIGIN/../lib -Wl,--disable-new-dtags" \
FFMPEG_PKG_CONFIG_PATH=/path/to/ffmpeg7/lib/pkgconfig \
    cargo build --release
```

Use this for hosts stuck on an older distro (Debian 12). `--disable-new-dtags`
is required, not cosmetic: `DT_RUNPATH` is not inherited by dependencies, so
libavformat would fail to find libswresample in the bundled directory.

Costs: ~40 MB of extra shared objects, and we own the FFmpeg build — its
codec/hwaccel matrix, its licence surface, and its security updates.

### Rejected: fully static libav

rusty_ffmpeg supports it (`FFMPEG_LIBS_DIR` plus `FFMPEG_LINK_MODE=static`
against an `--enable-static --disable-shared` build), but it does not solve
the problem it appears to solve: VAAPI, QSV and CUDA still dlopen driver
libraries at runtime, so a static libav removes the packaging dependency while
keeping the driver dependency, and freezes the hwaccel matrix at our build
time instead of the host's.

## Verifying changes

`verify/` holds the local harness: `feed.py` replays a fixture clip to a UDP
port with the exact ffmpeg argv Cairn uses, `validate_ndjson.py` checks a
plugin's stdout against the contract (line validity, pts monotonicity,
effective sample rate, score/label histogram), and `compare_runs.py` diffs two
runs — e.g. this plugin against the Python one on the same clip. See
`verify/README.md` for the two-terminal recipe. A typical run:

```bash
python3 verify/feed.py --clip /path/to/fixture.mp4 --port 17910 &
timeout 30 ./target/release/cairn-detect --camera-id t --udp-port 17910 \
    --min-score-json '{"default":0.5}' --model yolov10n.onnx \
    --labels coco.names | python3 verify/validate_ndjson.py
```

Unit tests (`cargo test`) cover postprocessing, score-floor parsing, the SDP
string, emit line-size guarding, pts rescaling, tensor packing, decoder probe
order and the per-backend filter strings; none need network, a model, or a
GPU.

## Implementation notes

- Joining mid-stream is normal. The open is retried 12 times, 5 s apart, with
  a generous `analyzeduration` so the probe waits out a GOP instead of failing
  with "Invalid data found"; after that we exit loudly and let Cairn back off.
- The udp `timeout` option (30 s, matching the Python plugin's `timeout=30`)
  bounds both ends: without it a silent port blocks forever inside the probe,
  so the retry loop never gets a second attempt, and a mid-run silence parks
  the packet read instead of exiting for Cairn to restart.
- The socket binds loopback explicitly (`localaddr`). The SDP's
  `c=IN IP4 127.0.0.1` does not constrain the bind — libavformat's udp
  protocol otherwise listens on `0.0.0.0`, and anything that can route to the
  host could inject frames into a camera's detector.
- The demuxer also binds `udp-port + 1` for RTCP even though Cairn sends none.
  Cairn reserves it (`Cairn.UDPPorts` allocates four ports per camera); if
  something else takes that port the stream will not open at all. `localaddr`
  moves that port to loopback too.
- Every codec context caps `max_pixels` at 32 MP. This plugin is the first
  thing in the system that decodes camera bitstream (Cairn's ffmpeg is
  `-c:v copy`), so an SPS declaring 16384x16384 would otherwise size the
  allocation.
- Frames that cannot be decoded *or* converted cost one sample, not the
  process: both are counted and logged (first, then every 50th). Only a dead
  inference thread or a dead stream is fatal.
- Inference runs on its own thread behind a size-1 channel. Held inline it
  stalls the socket read long enough to overflow the receive buffer at
  multi-megabit bitrates, which corrupts the stream rather than just dropping
  a sample. Samples are dropped, never queued; every 50th drop is logged.
- Sampling is wall-clock, not PTS-based, matching the Python plugin: the goal
  is capping model passes per second, and a bursty stream would otherwise fire
  several at once.
- Resizing is a letterbox-free stretch. Bboxes are normalized, so only ratios
  matter.
- The hardware filter graph is built on the first sampled frame, not at open:
  it needs the decoder's frames pool, which does not exist until something has
  been decoded.
- Output lines are capped at 8192 bytes by shedding the lowest-scoring
  detections; an oversized line would be dropped by Cairn anyway.
