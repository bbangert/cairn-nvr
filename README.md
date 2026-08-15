# Cairn

[![CI](https://github.com/bbangert/cairn-nvr/actions/workflows/ci.yml/badge.svg)](https://github.com/bbangert/cairn-nvr/actions/workflows/ci.yml)

An **event-clip NVR**: cameras stream in over RTSP, an in-process
detection engine finds objects, and Cairn records **one mp4 clip per
event** — with pre-roll — indexes it in SQLite, and gives you a LiveView
UI to watch live and browse events. No continuous recording, no cloud,
no accounts.

Built for the Home Assistant-adjacent homelab niche: small (Elixir/OTP +
ffmpeg + one Rust NIF), event-first (clips are first-class files on disk,
`{event_id}_{camera}_{timestamp}.mp4` — the index can always be rebuilt
from the filenames), and honest about scope (if you want 24/7 recording
or a giant model zoo, use Frigate — see `docs/frigate_comparison.md`).

## How it works

Per camera, one supervised ingest session (ffmpeg as a dumb RTSP→MPEG-TS
bridge, or a native RTSP client with `ingest: rtsp`) feeds a Membrane
pipeline that fans the compressed video out three ways in-process:
CMAF fragments to the pre-roll ring (live view + recording), RTP to the
WebRTC hub, and encoded access units to the detect branch, which decodes
and infers in the node's own engine (`cairn-native`, a Rust NIF on dirty
schedulers). The tracker opens an event, an extractor streams the
pre-roll + live fragments to a single mp4, and post-window quiet closes
it. Details in `docs/architecture.md`.

- **Live view**: MSE over a Phoenix channel (default), HLS fallback,
  WebRTC for sub-second latency.
- **Detection**: in the VM — `plugins/cairn-detect` (hardware decode,
  ONNX Runtime, optional QNN on Qualcomm NPUs) linked as a NIF. New
  models are a hardware-profile edit, not code. The retired external
  plugin protocol is archived at
  [`docs/archive/plugin-contract.md`](docs/archive/plugin-contract.md).
- **Hardware profiles**: one YAML file per board naming the model (or a
  model *ladder* — an ordered rung list config resolves against the fleet
  size, picking the most accurate model whose measured budget covers the
  configured cameras and deriving each camera's sample rate from it), the
  family, the inference backend, the rate (a declared fps band, or derived
  per rung) and the tracker stages that go with it. A plugin group names
  its profile and config load expands it into the engine's model config and
  the host's tracking policy, so the two halves cannot disagree. Four ship
  in `priv/profiles/`; writing one for a new board needs no code change —
  see [`docs/profile-authoring.md`](docs/profile-authoring.md).
- **Retention**: per-label day counts, plus emergency cleanup that
  deletes oldest events when disk runs low.

## Running (dev)

Requires Elixir 1.17+, ffmpeg/ffprobe on PATH.

```bash
mix setup
cp config.example.yml config.yml   # add your cameras
mix phx.server                     # http://localhost:4000
```

`config.yml` is the source of truth (path via `CAIRN_CONFIG`); the UI
renders it read-only and can hot-reload it (`/config` → Reload — added and
removed cameras are started and stopped; a change that reaches a subprocess
or the ring (`rtsp_url`, `substream_url`, `plugin`, `min_score`, `ingest`,
`transcode`, `extra_ffmpeg_args`, `motion_json`, the pre-event window, the
resolved tier, a ladder profile's resolved rung or derived rate) restarts
that camera, and
everything else — the `track:` / `record:` tiers, the post/max windows, the
tracking bounds, retention — is applied to the running camera without
cutting its stream or its live tracks. Invalid files are rejected with the
old config kept).

## Configuration reference

See `config.example.yml` — every key is documented inline. Summary:

| key | meaning |
|-----|---------|
| `data_dir` | all state: `cairn.db`, `events/`, `snapshots/`, `log/` (env `CAIRN_DATA_DIR` wins) |
| `stall_seconds` | silent-stream watchdog before ffmpeg is bounced |
| `free_space_min_mb` | emergency-cleanup threshold |
| `events.pre/post/max_*_seconds` | clip windows (per-camera overridable) |
| `tracking.max_unseen_ms` / `tracking.max_live_tracks` / `tracking.stationary_after_ms` | track expiry in stream time (×5 while stationary), per-camera live-track cap, and how long a box must hold still to count as parked (per-camera overridable) |
| `tracking.tracker` | which tracker core the camera's tracker element hosts: `cairn` (default) or `sparsetrack`, the port of the vendored SparseTrack reference. Resolves camera → profile → global; an unknown name is a config error |
| `tracking.bbd` | admit an association pair on the distance between the boxes' centres as well as on overlap, so a track coasting through a gap wider than its own box keeps its identity (default off; no per-camera form; superseded per group by a profile; stationary tracks excluded) |
| `tracking.oru` | rebuild a track's motion filter across an unmatched gap of 1–10 s, replaying it between the two real boxes either side, so a re-detection leaves the filter believing where the object went rather than where it was heading before it vanished (default off; no per-camera form; superseded per group by a profile; never fires across a seeded stretch) |
| `tracking.ocr` | after both association passes and bbd, offer a live coasted track's last observed box (not its Kalman prediction) against still-unmatched detections, recovering a mover that pauses behind an occluder and reappears where it vanished (default off; no per-camera form; superseded per group by a profile; stationary tracks excluded) |
| `tracking.reid` | fuse a person detection's embedding (wire field, sent only when the plugin runs an embedder) into a rolling per-track appearance, giving the bbd admission an appearance veto and a cost tiebreak — its only seam is that admission, so it requires `tracking.bbd: true` and config load refuses the combination otherwise (default off; no per-camera form; not superseded by a profile — a profiled group whose stage list drops bbd gets a load warning instead, since reid does nothing there either) |
| `profile_dirs` | directories of your own hardware profiles, searched after the ones cairn ships (a same-named file of yours wins, with a warning) |
| `retention.days` / `retention.per_label` | pruning (camera overrides win; multi-label events keep the longest) |
| `retention.tracks_days` | how long track rows live (default 365; global only, and exempt from emergency cleanup) |
| `cameras[]` | `id`, `rtsp_url`, `substream_url` (optional second stream detection runs on while recording keeps cutting from the main one — always `rtsp://`, whatever `ingest` says, and it must share the main stream's aspect ratio), `plugin` (a `plugins:` group name — absent ⇒ no detection), `ingest` (`ffmpeg` bridge default, `rtsp` native), `min_score` per label (the wire floor), `track` / `record` (the two host-side tiers above it: what earns a track row, what earns video), `motion_json` (the motion gate's scene config, verbatim JSON — operator-owned per D-P6; rejected on a tier-2 group, see `docs/profile-authoring.md`), `extra_ffmpeg_args`, `transcode`, `retention` |
| `plugins` | named plugin groups (`name: {profile: ...}`) — the hardware profile the in-VM engine loads for every camera naming the group (it owns the model config and the tracker's stage list); `allow_experimental:` consents to a profile whose backend is not proven in soak |
| `integrations.token` | bearer token that enables the Home Assistant API (see below); absent ⇒ `/api` disabled |

Non-H.264 cameras: Cairn probes each stream and warns. Opt-in
`transcode: true` uses hardware `h264_v4l2m2m` only — if unavailable the
camera refuses to start with a clear status; there is deliberately no
silent CPU-encode fallback.

## Home Assistant integration

Cairn exposes a token-authed `/api` surface for Home Assistant (camera/event
sensors, snapshots, event clips, an SSE live feed, WHEP WebRTC live streams, and
runtime detection/recording control). It is **disabled until you set a token**:

```yaml
integrations:
  token: "a-long-random-secret"   # e.g. openssl rand -hex 32
```

Requests authenticate with `Authorization: Bearer <token>` (or `?access_token=`
for media URLs). The browser UI (`/`, `/media`, `/hls`) is unaffected. The full
endpoint contract is in [`docs/ha-api.md`](docs/ha-api.md).

The **Python HACS integration that consumes this API lives in a separate repo**;
`docs/ha-api.md` is the interface it builds against. Serve the API over TLS or a
trusted LAN only — the token is a bearer secret.

## Deployment

```bash
MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release
CAIRN_DATA_DIR=/var/lib/cairn CAIRN_CONFIG=/etc/cairn/config.yml \
  PHX_SERVER=true _build/prod/rel/cairn/bin/cairn start
```

Migrations run at boot. A systemd unit example lives in
`rel/cairn.service.example`; an optional `Dockerfile` is included.

> **No auth in v1.** Cairn trusts its LAN. Do not expose it directly to
> the internet — put a reverse proxy with auth (or Home Assistant
> ingress, Tailscale, …) in front for anything beyond your trusted
> network.

## Development

Toolchain is pinned in `mise.toml` (`mise install`), or open the repo in
the **devcontainer** (`.devcontainer/`) which brings Erlang/Elixir via
mise plus ffmpeg, sqlite3 and inotify-tools — `postCreate` runs `mix setup`
and copies a starter `config.yml`. The first container start compiles
Erlang from source (one-time).

`mix check` = compile with warnings-as-errors, format check, credo,
tests. CI additionally runs `mix dialyzer` and `mix sobelow --skip
--exit --threshold medium`. Integration tests (real ffmpeg through the
pipeline) run with `mix test --include integration`; the end-to-end
suite needs the built NIFs — `mix test --only e2e_membrane`.

Docs: [`docs/architecture.md`](docs/architecture.md) ·
[`docs/profile-authoring.md`](docs/profile-authoring.md) (hardware
profiles) · [`docs/ha-api.md`](docs/ha-api.md) ·
[`docs/archive/plugin-contract.md`](docs/archive/plugin-contract.md)
(retired external-plugin wire protocol; still the format of the recorded
captures the parity/golden harnesses replay) ·
[`docs/design-handoff.md`](docs/design-handoff.md) ·
[`docs/frigate_comparison.md`](docs/frigate_comparison.md)
