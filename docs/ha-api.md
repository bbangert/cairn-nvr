# Cairn HA API (`/api`)

The interface spec for the Home Assistant integration. A separate Python HACS
integration (its own repo) consumes these endpoints; this document is the
contract it builds against.

Everything here is served under the token-authed `/api` scope. It is entirely
separate from the browser UI (`/`, `/media`, `/hls`), which stays cookie/
same-origin authed and is unaffected.

## Enabling & auth

The API is **disabled by default**. Set a token in `config.yml`:

```yaml
integrations:
  token: "a-long-random-secret"   # e.g. openssl rand -hex 32
```

With no token configured, every `/api` request returns `401`.

Authenticate each request with the token, either:

- `Authorization: Bearer <token>` (preferred), or
- `?access_token=<token>` query param — for media/stream URLs handed to players
  that can't set headers.

The token is compared in constant time. On failure the response is
`401 {"error":"unauthorized"}`.

HA fetches server-side, so CORS is not configured (not needed). Deploy on a
trusted LAN; the token is a bearer secret sent in clear unless fronted by TLS.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/cameras` | Camera inventory + runtime status + control state |
| `POST` | `/api/cameras/:id/control` | Toggle detection/recording, override `min_score` |
| `GET` | `/api/events` | Event list (filterable, paginated) |
| `GET` | `/api/events/:id` | One event |
| `GET` | `/api/labels` | Distinct detection labels seen |
| `GET` | `/api/stream` | SSE feed of live events / status / control / alerts |
| `GET` | `/api/media/events/:id` | Event clip (mp4, HTTP Range supported) |
| `GET` | `/api/media/snapshots/:id` | Event snapshot (jpg) |
| `POST` | `/api/cameras/:id/webrtc` | WHEP: start a live WebRTC stream |
| `DELETE` | `/api/webrtc/:resource_id` | WHEP: tear a stream down |

Maps to HA-side mechanisms: cameras/events/labels → `binary_sensor` + `sensor` +
Media Browser tree; `/api/stream` → push updates for entity state/availability;
media URLs → Media Browser resolution; WHEP → native WebRTC camera
(`async_handle_async_webrtc_offer`).

### `GET /api/cameras`

```json
{
  "cameras": [
    {
      "id": "front_door",
      "detection": true,
      "transcode": false,
      "min_score": {"default": 0.5, "person": 0.6},
      "windows": {"pre_seconds": 5, "post_seconds": 10, "max_seconds": 300},
      "status": "running",
      "probe": null,
      "control": {"detection_enabled": true, "recording_enabled": true, "min_score": null}
    }
  ]
}
```

`id` is stable — use it as the HA device identifier. `detection` is whether an
inference plugin is configured. **`rtsp_url` is never emitted** (it embeds
credentials). `control.min_score` is a runtime override (see below) or `null`
when the configured `min_score` applies.

### `POST /api/cameras/:id/control`

Body (any subset; JSON):

```json
{"detection_enabled": false, "recording_enabled": true, "min_score": 0.7}
```

- `detection_enabled` / `recording_enabled` — booleans.
- `min_score` — number `0..1` applied as the threshold for all labels, or `null`
  to clear the override and fall back to configured per-label `min_score`.

Returns `200 {"id": "...", "control": {...}}`. Invalid field → `422`; unknown
camera → `404`. Changes take effect immediately in the detection pipeline and are
echoed on the SSE feed as a `camera_control` event.

Semantics: `detection_enabled=false` drops incoming detections entirely (an
in-flight event finalizes normally on its post-window). `recording_enabled=false`
suppresses starting a *new* event/clip; an already-recording event continues to
completion.

### `GET /api/events`

Query params (all optional): `camera`, `label`, `from`, `to` (ISO8601),
`page` (default 1), `page_size` (default 50, max 200).

```json
{
  "events": [
    {
      "id": "e2c…",
      "camera_id": "front_door",
      "started_at": "2026-07-24T00:00:00.000000Z",
      "ended_at": "2026-07-24T00:00:12.000000Z",
      "status": "finalized",
      "bytes": 1234567,
      "max_score": 0.91,
      "labels": {"person": 0.91},
      "snapshot_url": "/api/media/snapshots/e2c…",
      "clip_url": "/api/media/events/e2c…"
    }
  ],
  "page": 1,
  "total": 42
}
```

`clip_url`/`snapshot_url` are `null` until the underlying file exists. They point
back into the token-authed `/api/media/*` routes — **no on-disk paths are ever
exposed**. `GET /api/events/:id` returns one event object (same shape) or `404`.

### `GET /api/stream` (SSE)

`Content-Type: text/event-stream`. Frames are `event: <kind>\ndata: <json>\n\n`.
A `: ping` comment heartbeat is sent every 20s; entity availability should follow
the connection. Event kinds:

| `event:` | `data` |
|----------|--------|
| `event_started` / `event_updated` / `event_ended` | live event object (id, camera_id, status, max_score, max_scores, trigger, snapshot_url, clip_url) |
| `camera_status` | `{camera_id, status, probe}` |
| `camera_control` | `{camera_id, detection_enabled, recording_enabled, min_score}` |
| `disk_alert` | `{active, free_mb, threshold_mb}` |

### Media

`GET /api/media/events/:id` streams the mp4 clip and supports single-range
`Range` requests (`206`), so seeking works. `GET /api/media/snapshots/:id` serves
the jpg. Both are the existing browser `MediaController` re-served under the
token-authed pipeline. `404` when the id or file is unknown.

### WHEP live streaming

`POST /api/cameras/:id/webrtc` with the SDP **offer** as either a raw
`application/sdp` body or JSON `{"sdp": "..."}`. The offer should be
**non-trickle** (ICE gathered to completion, candidates embedded) — the WHEP
client gathers fully before POSTing.

Response `201`, `Content-Type: application/sdp`, body = the **answer** SDP (with
the server's ICE candidates embedded — also non-trickle), and a
`Location: /api/webrtc/<resource_id>` header. `DELETE` that resource URL to stop
the stream (`204`). Unknown camera → `404`; the concurrent-session cap
(`WebRTC.Supervisor`, 32) → `503`.

Non-trickle is viable because Cairn is LAN-only with `ice_servers: []` (host
candidates gather effectively instantly). A WHEP session is self-owned: it
survives the HTTP request, is reaped if the client never connects within 30s, and
torn down on PeerConnection `failed`/`closed` or `DELETE`.

## RTSP fallback: not provided (decision)

HA's WebRTC camera can fall back to an RTSP `stream_source`. Cairn deliberately
does **not** expose one: `camera.rtsp_url` embeds credentials, and there is no
credential-free RTSP endpoint. The integration is **WebRTC-only** for live view.

A future option is a masked/credential-free restream (e.g. via go2rtc) surfaced
as a separate token-authed URL — deferred until native WebRTC proves
insufficient. Until then, cameras expose live video through WHEP only.
