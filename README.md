# Cairn

[![CI](https://github.com/bbangert/cairn-nvr/actions/workflows/ci.yml/badge.svg)](https://github.com/bbangert/cairn-nvr/actions/workflows/ci.yml)

An **event-clip NVR**: cameras stream in over RTSP, an inference plugin
detects objects, and Cairn records **one mp4 clip per event** — with
pre-roll — indexes it in SQLite, and gives you a LiveView UI to watch
live and browse events. No continuous recording, no cloud, no accounts.

Built for the Home Assistant-adjacent homelab niche: small (Elixir/OTP +
ffmpeg + your plugin), event-first (clips are first-class files on disk,
`{event_id}_{camera}_{timestamp}.mp4` — the index can always be rebuilt
from the filenames), and honest about scope (if you want 24/7 recording
or a giant model zoo, use Frigate — see `docs/frigate_comparison.md`).

## How it works

Per camera, one supervised ffmpeg does RTSP in → three codec-copy
outputs: fragmented mp4 to Cairn (live view + in-memory pre-roll ring),
RTP to your inference plugin, RTP to the WebRTC hub. The plugin prints
ndjson detections; the aggregator opens an event, an extractor streams
the pre-roll + live fragments to a single mp4, and post-window quiet
closes it. Details in `docs/architecture.md`.

- **Live view**: MSE over a Phoenix channel (default), HLS fallback,
  WebRTC for sub-second latency.
- **Plugins**: any language — H.264 RTP in, ndjson out. One process per
  camera, or one shared "group" process serving several cameras when the
  accelerator can only be held by one process (`docs/plugin-contract.md`;
  a mock plugin and a Python CPU reference implementation ship in-tree).
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
renders it read-only and can hot-reload it (`/config` → Reload —
added/removed/changed cameras are started/stopped/restarted, invalid
files are rejected with the old config kept).

## Configuration reference

See `config.example.yml` — every key is documented inline. Summary:

| key | meaning |
|-----|---------|
| `data_dir` | all state: `cairn.db`, `events/`, `snapshots/`, `log/` (env `CAIRN_DATA_DIR` wins) |
| `stall_seconds` | silent-stream watchdog before ffmpeg is bounced |
| `free_space_min_mb` | emergency-cleanup threshold |
| `udp.base_port` / `udp.range` | loopback ports for plugins + WebRTC taps (4 per camera — each RTP port reserves the next for RTCP) |
| `events.pre/post/max_*_seconds` | clip windows (per-camera overridable) |
| `retention.days` / `retention.per_label` | pruning (camera overrides win; multi-label events keep the longest) |
| `cameras[]` | `id`, `rtsp_url`, `plugin` (argv or multi-word string ⇒ its own process; single token ⇒ a `plugins:` group name), `min_score` per label, `extra_ffmpeg_args`, `transcode`, `retention` |
| `plugins` | named plugin groups (`name: {command: ...}`) — one process serving every camera that names it |
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
mise plus ffmpeg, sqlite3, inotify-tools, and Python for the reference
plugin — `postCreate` runs `mix setup` and copies a starter `config.yml`.
The first container start compiles Erlang from source (one-time).

`mix check` = compile with warnings-as-errors, format check, credo,
tests. CI additionally runs `mix dialyzer` and `mix sobelow --skip
--exit --threshold medium`. The full-pipeline integration test (real
ffmpeg, fixture-loop camera, mock plugin) runs with
`mix test --include integration`.

Docs: `docs/architecture.md` · `docs/plugin-contract.md` ·
`docs/design-handoff.md` · `docs/frigate_comparison.md`
