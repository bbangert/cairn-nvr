# Plan: Home Assistant integration — Cairn (Elixir) side

**Scope:** the Cairn/Phoenix endpoints + runtime that a separate Python HACS
integration consumes (Hybrid-B, decided in `interview.md`). **Out of scope:**
the Python integration itself (separate track), MQTT, espex.

**Sources:** `interview.md` (decision + phasing), `research/cairn-exposure-map.md`
(gap), `research/ha-camera-streams.md` + `research/ha-integration-patterns.md`
(HA-side contract each endpoint must satisfy), `scratchpad.md` (design wrinkles).

**Shape of the work:** three of the four HA surfaces ride on plumbing that already
exists (`Cairn.Events`, `MediaController`, `%Cairn.Event{}`, `WebRTC.Session`).
Net-new Cairn code is: a **token-authed `/api` scope**, a **read API + SSE feed**,
a **WHEP WebRTC endpoint**, and a **runtime control overlay** (the only real
feature build). Phases A–C deliver the read/notify/clip/stream experience; Phase D
adds control; Phase E hardens + documents the contract for the Python track.

**Verification gate (every phase):** `mix check` green (compile + format + credo
+ dialyzer + test per `mix.exs` aliases). Phase-specific live checks noted inline.

---

## Phase A — Token auth + `/api` foundation

Goal: a parallel, token-authed HTTP surface that leaves the browser's cookie-based
`/`, `/media`, `/hls` untouched.

- [x] **A.1 `[config]` HA token in config.yml.** Chose `integrations.token`
  (nested sub-map, matches udp/events/retention pattern) → `Config.ha_token`;
  `Config.Server.ha_token/0` accessor; validated non-empty string when present.
  Update `config.example.yml`. *(Files: `lib/cairn/config.ex`,
  `lib/cairn/config/server.ex`, `config.example.yml`.)*
- [x] **A.2 `[web]` Token-auth plug.** `CairnWeb.Plugs.ApiAuth` — `Bearer` header
  or `?access_token=` (fetch_query_params first), `Plug.Crypto.secure_compare/2`,
  401 JSON on miss/absent-token. *(New: `lib/cairn_web/plugs/api_auth.ex`.)*
- [x] **A.3 `[web]` `:api` pipeline + scope.** `:api` = `accepts json` +
  `ApiAuth`; `scope "/api", CairnWeb.Api`. SDP content-type deferred to WHEP
  controller (sdp not a registered MIME ext). *(File: `lib/cairn_web/router.ex`.)*

**Gate:** `mix check`; `curl /api/...` 401 without token, 200 with; browser pages +
`/media` unaffected.

---

## Phase B — Read API + SSE event feed  *(HA surface 1 + snapshots + clip listing)*

Goal: real-time detection state + enumerable events/cameras for binary_sensors,
sensors, and the Media Browser tree.

- [x] **B.1 `[json]` Camera list.** `Api.CameraController.index` merges
  `Config.Server` cameras (id, detection = `plugin != nil`, transcode, windows,
  min_score) with `CameraStatus.all/0`. No `rtsp_url`. *(New:
  `lib/cairn_web/controllers/api/camera_controller.ex`.)*
- [x] **B.2 `[json][ecto]` Event list + detail.** `Api.EventController`
  index/show/labels over `Cairn.Events`; ISO8601 parse; shaped via
  `Api.EventJSON` (clip_url/snapshot_url, **no on-disk paths**). *(New:
  `event_controller.ex`, `event_json.ex`.)*
- [x] **B.3 `[web]` SSE event feed.** `Api.EventStreamController.stream` at
  `GET /api/stream`; subscribes to Event/CameraStatus/Retention topics; frames
  via `send_chunked`+`chunk`; **shapes `%Cairn.Event{}` through `EventJSON`**
  (raw struct would leak path/snapshot_path); sanitizes `{:error, _}` probes;
  20s heartbeat; exits on `{:plug_conn, :sent}`/`{:error, _}`. *(New:
  `event_stream_controller.ex`.)*
- [x] **B.4 `[json]` Token-authed media reuse.** `/api/media/events/:id` +
  `/api/media/snapshots/:id` → existing `MediaController` under `:api`. Also
  registered `text/event-stream`+`application/sdp` MIME types so `:accepts`
  allows SSE/SDP. *(Files: `router.ex`, `config/config.exs`.)*

**Gate:** `mix check`; live: open SSE with `curl -N`, drive a mock-plugin event,
observe `event_started/updated/ended` frames; `/api/events` returns the finalized
row with working `clip_url`/`snapshot_url`.

---

## Phase C — WHEP WebRTC endpoint  *(HA surface 2: live streams)*

Goal: an HTTP offer/answer HA's native WebRTC (`async_handle_async_webrtc_offer`)
can drive, reusing `WebRTC.Session`.

- [x] **C.1 `[otp]` SPIKE — non-trickle WHEP.** VERDICT recorded in scratchpad.
  `Session` now takes optional `owner` (nil = self-owned) + `whep_id`;
  `handle_offer_await/2` defers the reply until `ice_gathering_state_change:
  :complete` (2s timeout fallback), returns `get_local_description.sdp` with
  candidates embedded. Self-owned session registers `{whep_id, :whep}` in
  `Cairn.Registry`; 30s connect-deadline reaper + existing `:failed/:closed`
  teardown. Browser trickle path untouched (existing tests green). *(Files:
  `lib/cairn_web/webrtc/session.ex`.)*
- [x] **C.2 `[web]` `Api.WhepController`.** `POST /api/cameras/:id/webrtc`
  (raw `application/sdp` via `read_body`, or JSON `{sdp}`) → `start_whep` +
  `handle_offer_await`, `201` answer SDP + `Location: /api/webrtc/:id`;
  `DELETE /api/webrtc/:resource_id` via Registry lookup. `max_children` → 503;
  unknown camera → 404. *(New: `whep_controller.ex`; `router.ex`.)*
- [x] **C.3 `[docs]` RTSP fallback decision.** WebRTC-only; `rtsp_url` never
  emitted; masked restream deferred. Written into `docs/ha-api.md` (E.1).

**Gate:** `mix check`; live: POST a browser-generated offer to
`/api/cameras/:id/webrtc`, confirm answer negotiates and H.264 frames flow (real
ExWebRTC, LAN). Cross-check against the browser WebRTC path already verified in
Phase 7.

---

## Phase D — Runtime control  *(HA surface 4: switches / numbers — net-new feature)*

Goal: HA can toggle detection/recording and adjust `min_score` at runtime. No such
knob exists today (detection = `plugin` set at config load), so this is real
pipeline work — sequenced last, independently shippable.

- [x] **D.1 `[otp]` Runtime camera-control store.** `Cairn.CameraControl` (ETS,
  `:protected`, mirrors `CameraStatus`): `detection_enabled`/`recording_enabled`/
  `min_score` per camera, defaults on/on/nil. `get/1` (direct ETS, hot path),
  `set/2`, `all/0`, `prune/1`; broadcasts `{:camera_control, id, ctrl}` on
  `"cameras:control"`. Supervised after `CameraStatus`. (Note: `prune/1`
  provided but unwired — matches `CameraStatus.prune`, which has no reload hook.)
  *(New: `lib/cairn/camera_control.ex`; `application.ex`.)*
- [x] **D.2 `[otp]` Honor toggles.** `handle_cast` reads `CameraControl.get/1`:
  `detection_enabled=false` drops the batch (in-flight event finalizes on its
  timer); `min_score` override → `%{"default" => v}`; `recording_enabled=false`
  suppresses new event start (existing events continue). Extracted
  `process_detections/6`. *(File: `detection_aggregator.ex`.)*
- [x] **D.3 `[web][json]` Control endpoint.** `POST /api/cameras/:id/control`
  validates booleans + min_score 0..1 (or null to clear) → 422 on bad field,
  404 unknown camera; returns `{id, control}`. Camera JSON now carries
  `control`; SSE emits `camera_control` frames. *(Files: `camera_controller.ex`,
  `event_stream_controller.ex`, `router.ex`.)*

**Gate:** `mix check`; live: toggle detection off via `/api/cameras/:id/control`,
confirm no events start on a driving mock plugin; flip `min_score`, confirm the
threshold changes which detections pass; SSE emits the control change.

---

## Phase E — Contract docs + tests + release

- [x] **E.1 `[docs]` API contract.** `docs/ha-api.md` — every route (auth,
  params, JSON shapes, SSE kinds, WHEP flow, media), HA-mechanism mapping, and
  the C.3 RTSP-fallback decision (WebRTC-only, no rtsp_url).
- [x] **E.2 `[test]` Coverage.** 401/wrong/bearer/query-param auth; camera list
  (no rtsp_url) + control validation (422/404/null-clear); events index/show/
  labels with media URLs and no on-disk paths; SSE `frame_for/1` lifecycle→frame
  (paths stripped, probe sanitized); CameraControl store; aggregator control
  toggles (detection/recording/min_score); WHEP non-trickle answer + registry +
  `@tag :integration` full offer→answer→:connected with real ExWebRTC. All green
  (193 pass / 2 integration).
- [x] **E.3 `[docs]` Ops.** `config.example.yml` (`integrations.token`), README
  "Home Assistant integration" section + config table row; notes the Python
  integration is a separate repo.

**Gate:** `mix check` + `@tag :integration` green; `docs/ha-api.md` complete.

---

## Task routing summary
`[config]` A.1 · `[web]` A.2 A.3 B.3 B.4 C.2 D.3 · `[json]` B.1 B.2 D.3 ·
`[ecto]` B.2 · `[otp]` C.1 D.1 D.2 · `[docs]` C.3 E.1 E.3 · `[test]` E.2

## Risks & self-check (deep)
- **Does this leak credentials?** `rtsp_url` is deliberately never emitted (B.1,
  C.3); media/streams reachable only with the token (A.2). Media routes stay
  reused, not re-authed for the browser. *Verify no `/api` response includes
  `rtsp_url` or on-disk paths (only opaque ids).*
- **What's the hardest part?** C.1 — WHEP session ownership/lifecycle vs the
  channel-owned trickle model. Isolated as a spike; non-trickle + LAN host
  candidates de-risk it. *Fallback: if non-trickle answers don't satisfy HA,
  document RTSP-restream path instead and ship A/B/D without native WebRTC.*
- **What could silently break existing behavior?** Phase D edits the hot detection
  path (`DetectionAggregator`). *Mitigate: overrides default to config values so
  behavior is identical until HA sets something; cover with D.2 tests before
  wiring D.3.*
- **Ordering:** A → B is the critical path (most value, least risk). C and D are
  independent and can ship in either order or be deferred. E closes the contract
  for the Python track.

## Explicitly deferred (not in this plan)
- Python HACS integration (separate track; E.1 gives it the contract).
- MQTT event bus for non-HA consumers (optional future publisher).
- RTSP/go2rtc credential-free restream (only if native WebRTC proves insufficient).
