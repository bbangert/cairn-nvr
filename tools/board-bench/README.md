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

## An unpublished image on a bench board

The devcontainer has no docker, so CI builds every image. A manual dispatch
of `container.yml` that is not asked to push uploads the image as a
`docker load` tarball, and that is how a branch's image reaches a board
without touching the registry (proven on the HA Green, 192.168.2.155).

```sh
# host: build the branch's image, never pushing. Pass both inputs explicitly:
# a ref whose workflow predates them then rejects the run instead of publishing.
gh workflow run container.yml --ref <branch> -f board=rockchip -f push=false
gh run download <run-id> -n cairn-image-rockchip -D stage/   # cairn-image.tar
# stage/ also holds config/config.yml, config/profiles/*.yml and SHA256SUMS
sftp -b put.sftp 192.168.2.155            # into /root/<dir>: ext4, exec-capable
# board (nerves_ssh eval → sh): verify, load, run as the add-on would
sha256sum -c SHA256SUMS && podman load -q -i cairn-image.tar
podman run -d --name cairn-p1 --network host \
  --security-opt unmask=/sys/firmware \
  --device /dev/mpp_service --device /dev/rga \
  --device /dev/dri/card1 --device /dev/dri/renderD129 \
  --device /dev/dma_heap/system --device /dev/dma_heap/system-uncached \
  -v /root/<dir>/config:/config:ro -v /root/<dir>/data:/data \
  ghcr.io/bbangert/cairn-nvr-rockchip-aarch64:<version>
# host: the numbers come over HTTP, not ssh
curl -H "Authorization: Bearer <integrations.token>" http://192.168.2.155:4000/api/cameras
```

- **Move bytes with sftp, never through the ssh eval channel.** The channel
  buffers in the host's own BEAM; a 62 MB log printed through it grew that
  BEAM to 2.4 GB. Redirect every board command to a file, print a few lines,
  and `sftp get` the rest — `podman logs` included.
- `--network host` is what makes port 4000 reachable from the LAN; the
  RK3566 probe's hand-run found a published port (`-p`) was not.
- A hand-run container is not a vagus app: nothing here exercises the
  add-on's `config.yaml`. `unmask=/sys/firmware` stands in for its
  `devicetree: true`: without it `/proc/device-tree` is absent, MPP matches
  no SoC and `mpp_init` fails (`MPP_NOK`; every `--rk-probe` case, on the
  HA Green).
- The board's busybox has no `head`, `tr`, `tee`, `tar`, `wc`, `du` or `awk`;
  `grep`, `sed`, `cut` and `tail` are there.
- The artifact expires after three days.

## Capacity cells on the Green

`tools/board-pipeline/board_pipeline.ex` runs inside the image's own release
(`bin/cairn eval`, no application started): `rk-cell.sh` is one
`podman run --rm` cell, `rk-ladder.sh` a detached run of cells over stream
counts. sftp into `/root/cairn-bench-rk` (`BASE`): `h/board_pipeline.ex` and
`h/<clip>.aus` (seen at `/h`), librknnrt and the `.rknn` rungs under
`artifacts/` (`/artifacts`; a copy of a Cairn data dir's `artifacts/`, its
files named by sha256, serves), and the two scripts; results land in `runs/`.

```sh
cd /root/cairn-bench-rk
IMAGE=<image> MODEL=/artifacts/<rung> \
  INPUT_SIZE=640 RKNN_LIBRARY=/artifacts/<librknnrt> CLIP=/h/<clip>.aus \
  sh rk-ladder.sh s640 "3 4 5 6 7" >/dev/null 2>&1 &
tail -n 3 runs/s640.ladder.log; cat runs/s640.csv    # done at LADDER-DONE
```

- `bench.sh` is the QCS6490 plugin-era runner, not used on the Green: its
  blanket `killall` must never run on a board hosting other containers. The
  cell scripts touch only the container `cairn-bench-cell`.

## The add-on on a bench board, through vagus

Once the image is on ghcr and the add-on's directory is in a store repository
the board already has, the same ssh eval channel installs it: it runs inside
vagus. These are vagus's own functions as the HA Green answered them, not a
published interface.

```elixir
slug = "<repository slug>_cairn_rockchip"
Vagus.Addon.Store.reload()
{:ok, %{config: c}} = Vagus.Addon.Store.get(slug)
c = %{c | slug: slug}                     # the store entry carries the bare slug
{true, nil} = Vagus.Addon.Availability.check(c)
:ok = Vagus.App.install(c)                # pulls the image; does not start it
{:ok, _} = Vagus.App.start(slug)          # restart/1 and stop/1 take it too
```

- The first start creates the two host directories, so it comes up with no
  cameras. On the Green they are `/root/vagus/addons/addon_configs/<slug>`
  (mounted read-only at `/config`) and
  `/root/vagus/addons/addons/data/<slug>` (`/data`). `sftp` the config into
  the first, then `Vagus.App.restart(slug)`.
- Remove a hand-loaded image carrying the same tag first, or nothing shows
  that the pull came from the registry.
- vagus grants `devices:` as one cgroup rule per node over a read-only bind
  of the host's `/dev`: a node the add-on does not list is visible and
  refuses to open.
