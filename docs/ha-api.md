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
  to clear the override and fall back to configured per-label `min_score`. It
  moves the floor and only the floor: on a camera with a `record:` block a
  detection still has to clear that tier's own threshold to open or extend an
  event, so the override can raise the bar but cannot bring back a label the
  block leaves out.

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
| `event_clip_ready` / `event_clip_failed` | artifact object (below), with `clip_url` |
| `event_snapshot_ready` / `event_snapshot_failed` | artifact object (below), with `snapshot_url` |
| `track_started` / `track_updated` / `track_ended` | track object (below) |
| `camera_status` | `{camera_id, status, probe, plugin_status}` — `plugin_status` is the plugin's own `{state, detail, fps}` ([`plugin.status`](plugin-contract.md#pluginstatus)), `null` until it reports one |
| `camera_control` | `{camera_id, detection_enabled, recording_enabled, min_score}` |
| `disk_alert` | `{active, free_mb, threshold_mb}` |

> **Breaking change — `object_id` is now a ULID string.** It used to be a small
> per-camera integer (`1`, `2`, …) that was reused after a restart or a stream
> reconnect, so two different objects could share an id. It is now a 26-character
> Crockford-base32 ULID (`"01J8ZQ0P8B7X0N2R4C6D8E0F2G"`), minted once and never
> reused — across cameras, stream reconnects or host restarts. It appears in an
> event's `trigger.object_id`, in the stored `labels.entries[].object_id`, and as
> `object_id` on every track frame, and it is the key that ties them together.
> Clients that stored or compared it as a number must treat it as an opaque
> string. There is no compatibility mode.

#### Artifact frames

`event_ended` means one thing only: **the detection window closed**. At that
moment the clip is still being remuxed and the snapshot has not been taken, so
`clip_url`/`snapshot_url` on the `event_ended` frame may still be `null` and a
fetch of them may 404. The artifact frames are the signal that the media is on
disk and fetchable:

```json
{
  "event_id": "e2c…",
  "camera_id": "front_door",
  "bytes": 1234567,
  "reason": null,
  "clip_url": "/api/media/events/e2c…"
}
```

- `event_clip_ready` — the clip is closed, remuxed and indexed. `bytes` is its
  final (post-remux) size; `clip_url` is fetchable now.
- `event_snapshot_ready` — the jpg exists and is recorded on the event. `bytes`
  is its size, and the frame carries `snapshot_url` in place of `clip_url`.
- `event_clip_failed` / `event_snapshot_failed` — that artifact is not coming
  for this event. `bytes` and the URL field are `null`, and `reason` is one of
  `no_output` (ffmpeg wrote nothing usable), `not_found` (the event was gone by
  the time the artifact landed), `index_write_failed` (the index rejected the
  update) or `exception`. Nothing retries; a failed snapshot leaves the clip
  unaffected. `event_clip_failed` is terminal for the whole event: the snapshot
  is cut from the finished clip, so it is not attempted and **no**
  `event_snapshot_*` frame follows — do not wait for one.

Each artifact is announced at most once per event, and exactly one of
`_ready`/`_failed` per attempt. Ordering is guaranteed: `event_ended` precedes
`event_clip_*`, which precedes `event_snapshot_*` (the snapshot is cut from the
finished clip). On-disk paths are never emitted — fetch through the `*_url`
fields, as everywhere else.

`event_ended` itself is **at-least-once**: if Cairn crashes in the window
between announcing it and recording that it announced it, the event is
announced again on restart (the replay may carry `"status": "partial"` and a
later `ended_at`). Dedupe on the event `id` — a second `event_ended` for an id
you have already finished is a repeat, not a second event.

Recommended client flow:

1. Drive entity state (motion/occupancy `binary_sensor`, attributes) off
   `event_started` / `event_updated` / `event_ended`. Do not wait for media.
2. Fetch media only on the matching `*_ready` — the clip on `event_clip_ready`,
   the thumbnail on `event_snapshot_ready`. Tie them to the event by `event_id`.
3. On `*_failed`, stop waiting for that artifact: keep the event, show the
   placeholder, and do not poll `/api/events/:id` for a URL that is not coming.
4. An event whose recording crashed emits **no** artifact frames at all; it is
   announced as `event_ended` with `"status": "partial"`. Treat that as "no
   media is coming" too.
5. If the connection dropped between `event_ended` and a `*_ready`, re-read
   `GET /api/events/:id` on reconnect. Mind what those URLs mean there:
   `clip_url` is non-`null` once a clip path has been *recorded*, which happens
   when recording starts — so an `active` row (recording in flight) or a
   `partial` one (the recorder crashed) can return a `clip_url` for a file that
   is truncated, unplayable or already gone. Only a `finalized` status, or the
   `event_clip_ready` frame, means the clip is complete. `snapshot_url` is
   written after the jpg exists, so it is safe once non-`null`.

#### Track frames

A **track** is one physical object followed through time. Cairn assigns the
identity itself (IoU on the detections) unless the plugin declares the
`object_tracking` capability, in which case the plugin's own ids are honoured
and mapped onto ULIDs. The producing side of this — who owns identity, how it
is scoped, and what bounds it — is
[`docs/plugin-contract.md` → Track identity](plugin-contract.md#track-identity).

```json
{
  "object_id": "01J8ZQ0P8B7X0N2R4C6D8E0F2G",
  "camera_id": "front_door",
  "label": "person",
  "score": 0.81,
  "best_score": 0.9,
  "bbox": [0.12, 0.4, 0.2, 0.5],
  "source": "host",
  "plugin_track_id": null,
  "started_at": "2026-07-24T00:00:00.000000Z",
  "last_seen_at": "2026-07-24T00:00:02.000000Z",
  "last_detected_at": "2026-07-24T00:00:01.000000Z",
  "stale_predicted": false,
  "stationary": false,
  "stationary_since": null,
  "stationary_ms": 0,
  "end_reason": null
}
```

`stationary` is true once the object's box has held still for the camera's
`tracking.stationary_after_ms` of stream time; `stationary_since` is when it
flipped (`null` while moving) and `stationary_ms` the total stream time it has
spent stationary over the whole track, which only grows. The measure is the
box, so a camera that pans moves every track at once, and someone standing in
place is stationary whatever they are doing.

A stationary object is **not event evidence**: a car that parks in view stops
holding its event open, so that event ends on the post window and nothing it
does while parked opens another. It counts again the moment it moves.

Same schema for all three kinds:

- `track_started` — a new identity. Always sent.
- `track_updated` — **throttled**: sent only when `best_score` improves or at
  most once a second per track. It is deliberately *not* a per-frame feed; do
  not use it to drive animation. One frame is never throttled: the one where
  `stationary` flips, in either direction. Cairn's own event logic keys off
  that flag, so it is sent the moment it changes.
- `track_ended` — **self-contained**: everything above is filled in, so a
  client that missed every other frame still learns what the track was.
  `end_reason` is one of `unseen` (not seen for the configured
  `tracking.max_unseen_ms` of stream time, or ten times that of *host* time —
  the backstop for a plugin whose stream clock stops moving), `plugin_ended`
  (the plugin said so), `stream_reset` (the camera's stream reconnected —
  nothing may span the cut), `evicted` (the camera hit its
  `tracking.max_live_tracks` cap and this was the least recently seen track),
  `detection_disabled` (detection was switched off for this camera) or
  `host_restart` (Cairn restarted; the track is over whatever the camera sees).

  **It is sent for every ending Cairn observes, but it is not a guarantee
  across a Cairn restart.** Tracks belonging to a camera with an event in
  flight are checkpointed and end as `host_restart`; tracks on a camera with
  no open event are lost with the process and get no final at all. Treat the
  SSE stream reconnecting after a Cairn restart as the end of every track you
  are holding, not just the ones you were told about.

- `bbox` is `[x, y, w, h]`, normalized 0..1, origin top-left, y increasing
  **downward** — deliberately not ONVIF's centre-origin, y-up frame. The
  conversion and the reasoning are in
  [`docs/plugin-contract.md` → Geometry](plugin-contract.md#geometry).
- `source` is `"host"` or `"plugin"`; `plugin_track_id` is the plugin's own id
  when `source` is `"plugin"`, else `null`.
- `score` is the latest observation, `best_score` the best over the track's life.
- `stale_predicted: true` means the track is alive but has not actually been
  *detected* recently — the plugin is predicting it. Cairn never treats such an
  object as evidence, and neither should an automation.
- A track is not an event: tracks come and go inside one event, and exist even
  when recording is off. Events remain the thing to drive `binary_sensor` state
  from.

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
