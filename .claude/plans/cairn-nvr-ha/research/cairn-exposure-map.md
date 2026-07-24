# Cairn exposure map — what exists vs. the HA-integration gap

Grounds the Hybrid-B plan: the HA integration (Python) talks to Cairn over a
websocket/SSE + REST. This maps what Cairn *already* emits/serves against what
each of the four HA surfaces needs.

## Already exposed (reusable as-is)

### Real-time state (Phoenix PubSub — internal today)
- **`"events"`**: `{:event_started | :event_updated | :event_ended, %Cairn.Event{}}`.
  `%Cairn.Event{}` is `@derive Jason.Encoder`, JSON-ready. Fields: `id`,
  `camera_id`, `started_at`, `ended_at`, `status` (`:active|:finalized|:partial`),
  `labels` (`[%{t, label, score, object_id}]`), `max_scores` (`%{label => score}`),
  `max_score`, `trigger` (`%{t, label, score, bbox}`), `path`, `snapshot_path`.
  → directly feeds detection **binary_sensors** + occupancy/label **sensors**.
- **`"cameras:status"`**: `{:camera_status, camera_id, %{status:, probe:}}` where
  status ∈ `:connecting|:running|:backoff|:stalled|:transcode_unavailable|:unknown`.
  → feeds per-camera **availability** / a connectivity binary_sensor.
- **`"system:alerts"`**: `{:disk_alert, alert}` → an NVR "problem" binary_sensor.

### Recorded media (REST, on disk, index-resolved — `media_controller.ex`)
- `GET /media/events/:id` → `video/mp4`, **HTTP Range** supported (206) — clip playback.
- `GET /media/snapshots/:id` → `image/jpeg` — event snapshot.
- Paths resolved through the events index (never user input) — safe to expose.
  → the clip/snapshot **playable URLs** for HA Media Browser + notification images.

### Live (browser paths today)
- **WebRTC**: Phoenix Channel `"webrtc:{camera}"` — client `offer`/`ice`,
  server `answer`/`ice`. Backed by `CairnWeb.WebRTC.Session`. Sub-second.
- **HLS**: `GET /hls/:camera/index.m3u8` + `init.mp4` + `:segment`.

### Config
- Cameras from `config.yml` → `%Cairn.Config.Camera{}` (`id`, `rtsp_url`, `plugin`,
  `min_score` map, `transcode`, retention, pre/post/max windows). `Cairn.Config.Server`
  serves them at runtime (`camera/1`). Detection is "on" iff `plugin` is set.

## The gap (new Cairn-side work the integration needs)

| # | Surface | Have | Gap to build |
|---|---------|------|--------------|
| 1 | **Event feed to the integration** | PubSub is internal; browser uses Phoenix Channels | A **read-only SSE (or plain-WS) endpoint** relaying `"events"` + `"cameras:status"` + `"system:alerts"` as JSON. SSE is trivial for a Python integration (Phoenix Channel handshake is not). Payloads are already Jason-encodable. **Small.** |
| 2 | **Auth** | No auth pipeline anywhere | A **token** (config-entry secret) gating the event feed + REST + media. **Small but required** (media routes are currently open). |
| 3 | **Enumeration REST** | Only by-id media fetch; lists live in LiveViews | JSON API: **list cameras**, **list/browse events** (per camera, time range) for the Media Browser, snapshot/clip URL by id. `Cairn.Events` already has the queries behind `EventsLive`. **Small–medium.** |
| 4 | **Live stream HA can consume** | WebRTC via *Phoenix Channel* signaling; HLS by segment | HA's native WebRTC (2024.11+) expects a standard offer/answer the integration bridges — Cairn's signaling is channel-shaped. Likely need a **plain HTTP WHEP-style offer endpoint** reusing `WebRTC.Session`, **or** an **RTSP restream / go2rtc** sidecar HA ingests directly. *(HA-side research pending — decides which.)* **Medium.** |
| 5 | **Control toggles (switches/numbers)** | **No runtime knob** — detection = `plugin` set at config load; no enable/disable | New **runtime enable/disable** state for recording/detection per camera, wired into the pipeline + surfaced over REST for the integration to drive. **Largest lift; thinnest today.** Candidate to defer to a later phase. |

## Notes for planning
- Surfaces 1 (binary_sensors) and clips/snapshots are **almost free** — the data
  and media URLs exist; only the SSE feed + enumeration REST + auth are new.
- **Control (surface 5)** is the real net-new feature work (no runtime toggles
  exist). Sequence it last / as its own phase.
- Live streams (surface 4) hinge on the HA-side WebRTC-vs-RTSP research now running.
- Auth (surface 2) is a cross-cutting prerequisite for shipping any of it safely.
