# Interview: Home Assistant Integration for Cairn

## Topic
Design the Home Assistant integration for Cairn (Frigate-alternative NVR).
Compare Frigate's method (MQTT + custom HA integration) vs the `espex`
library (present Cairn as an ESPHome device) vs other approaches.

## Coverage
What 2/2 | Why 1/2 | Scope 2/2 | Where 1/2 | How 1/2 | Edge 1/2  (~8/12)

## What (surfaces required)
User confirmed the HA experience must surface **all four**:
1. Detection **binary_sensors** (per-camera motion/object, occupancy counts) — real-time automation triggers.
2. **Live camera streams** viewable inside HA dashboards.
3. **Clips & snapshots** browsable/playable in HA (Media Browser + notification images).
4. **Config/control** from HA (toggle recording/detection, enable camera) as HA switches/numbers.

## Why
Give Cairn users a first-class HA experience on par with Frigate, so Cairn
is a drop-in NVR for the HA ecosystem.

## Where (existing hooks in Cairn)
- Internal PubSub topic `"events"` — `{:event_started|:event_updated|:event_ended, event}` (`lib/cairn/event.ex`).
- `"cameras:status"` — camera up/down (`lib/cairn/camera_status.ex`).
- `"system:alerts"` — disk alerts (`lib/cairn/retention.ex`).
- Snapshots + indexed clips per event (`lib/cairn/snapshot.ex`, `event_extractor.ex`, `events.ex`).
- Live: HLS/MSE + WebRTC (`hls_controller.ex`, `rtp_hub.ex`, `webrtc/`).
- **No MQTT dependency today** (Bandit/Phoenix/Jason/Ecto-SQLite only).
- Config-driven cameras via `config.yml` (`lib/cairn/config.ex`).

## How — DECIDED: Hybrid-B (2026-07-23)
**One custom HA integration (Python/HACS) does everything. No MQTT broker. No espex.**
Rationale: since media-browser + live-streams *require* the custom integration
regardless, that integration can also mint all sensor/control entities itself —
so both MQTT (redundant) and espex (a second protocol producing entities the
integration already makes) are dropped. Zero-install ESPHome baseline was
explicitly declined as a product goal, which is the only thing espex would have
bought.

Architecture:
- **Transport:** integration ↔ Cairn over a **websocket/SSE** exposed from Cairn's
  existing Phoenix PubSub (`"events"`, `"cameras:status"`, `"system:alerts"`).
  Socket maps 1:1 to entity updates; socket state = HA availability.
- **Entities:** integration creates binary_sensors (motion/object), sensors
  (occupancy counts), switches/numbers (recording/detection/enable), camera
  entities — all natively in Python.
- **Live streams:** camera entity backed by Cairn's existing **WebRTC** (HA
  2024.11+ native go2rtc/WebRTC camera support) — or RTSP restream fallback.
- **Clips/snapshots:** HA `media_source` platform (Media Browser) over Cairn's
  existing REST clip/snapshot endpoints.

### Dropped / deferred
- **MQTT:** not required. Optional future event-bus *publisher* for non-HA
  consumers (Node-RED etc.), orthogonal to the HA path — add only if requested.
- **espex:** declined (no zero-install baseline goal; 0.8.0 unstable; no camera
  support — Switch/BinarySensor/Sensor/Button/Light/Cover/Climate only).

## Research resolved (2026-07-23) — see research/*.md
- **Streams (HA-side):** HA 2024.11+ native WebRTC — the integration implements
  `async_handle_async_webrtc_offer(offer_sdp, session_id, send_message)` →
  `send_message(WebRTCAnswer(...))` + `async_on_webrtc_candidate` +
  `close_webrtc_session`. HA supplies signaling/STUN/(Cloud)TURN; the integration
  only shuffles SDP/ICE to the backend. `CameraEntityFeature.STREAM` required.
  `async_camera_image()` serves snapshots via HA's `/api/camera_proxy`.
  → Cairn gap: a plain **HTTP WHEP-style offer/answer + ICE endpoint** reusing
  `CairnWeb.WebRTC.Session` (Phoenix-Channel signaling isn't Python-friendly).
  RTSP `stream_source` = clean fallback (HA transcodes to HLS, ~5–10s latency).
  go2rtc unnecessary if we expose WebRTC directly.
- **Media Browser:** `MediaSource` platform — `async_browse_media` returns a
  `BrowseMediaSource` tree (date→camera→label, Frigate's model, `ITEM_LIMIT≈50`);
  `async_resolve_media` → `PlayMedia(url, "video/mp4")`. Cairn's `/media/events/:id`
  is the playable URL; needs the enumeration REST to build the tree.
- **Push shape:** DataUpdateCoordinator is wrong for push — use a custom coordinator
  whose task consumes the Cairn SSE/WS and calls `async_set_updated_data`; entities
  `_attr_should_poll = False`; availability from socket state; exp-backoff reconnect;
  raise `ConfigEntryAuthFailed` on auth error.
- **Config flow / entities:** `ConfigFlow` (host + API token) → `async_setup_entry`
  → one **device per camera** (`identifiers={(DOMAIN, camera_id)}`); dynamic
  add/remove via `async_add_entities` + entity-registry cleanup. Device classes:
  binary_sensor `MOTION`/`OCCUPANCY`/`SOUND`/`PRESENCE`; `SwitchEntity` (CONFIG)
  for recording/detection toggles; `NumberEntity` (slider) for `min_score` thresholds.

## Proposed phasing (Hybrid-B)
- **A — Cairn read surface:** auth token + read-only SSE event feed (`"events"` +
  `"cameras:status"` + `"system:alerts"`) + enumeration REST (cameras, events by
  camera/time). *Prereq for everything; small.*
- **B — Integration skeleton:** config flow, push coordinator, device-per-camera,
  detection **binary_sensors** + status + snapshot **camera image**. *Delivers surface 1 + snapshots.*
- **C — Media Browser:** `MediaSource` over enumeration REST + `/media/events/:id`. *Surface 3 (clips).*
- **D — Live streams:** Cairn WHEP endpoint (reuse `WebRTC.Session`) + integration
  WebRTC methods; RTSP `stream_source` fallback. *Surface 2.*
- **E — Control:** runtime enable/disable + `min_score` setters in Cairn →
  **switches/numbers**. *Surface 4; the one net-new feature (no runtime knobs today).*

## Open design questions (for planning)
- Websocket vs SSE for the Cairn→integration event feed (Phoenix Channel reuse?).
- Auth between integration and Cairn (token in config entry).
- Config-entry discovery/flow: how the integration enumerates cameras (REST from
  `config.yml`-derived state) and handles camera add/remove.
- Snapshot delivery for notifications vs Media Browser clip listing.
- HA camera stream path decision: native WebRTC vs go2rtc vs RTSP restream.

## Edge cases to keep in mind
- HA reconnection / availability (LWT), multiple Cairn instances (topic prefix / client_id).
- Stream transport HA can consume (RTSP/go2rtc vs WebRTC).
- Media Browser needs a stable clip/snapshot REST surface + auth.
- Discovery lifecycle when cameras are added/removed in `config.yml`.

## Research findings (2026-07-23)
- **espex** (hex.pm/packages/espex): Elixir server implementing the ESPHome
  Native API over TCP; an Elixir app exposes itself as an ESPHome device,
  hardware plugged via behaviours. Early extraction, API not final.
  Ceiling: ESPHome entity model = binary_sensor/sensor/switch/number + a
  **single-JPEG-frame** camera. **No live stream, no clips/media browser.**
- **Frigate model**: internal Dispatcher → MqttClient publishes
  `frigate/events`, `frigate/reviews`, per-camera state/switch topics; uses
  **MQTT Discovery** to auto-create entities; a **custom Python integration
  (HACS)** adds Media Browser for clips, a camera proxy (go2rtc/RTSP for
  streams), and REST endpoints (`/api/frigate/.../clips/...`). Needs the HA
  `mqtt` integration. Multi-instance via `topic_prefix` + `client_id`.
