# Scratchpad: Cairn HA integration (Elixir side)

## Key decisions
- **Separate `/api` scope, token-authed.** Do NOT bolt auth onto `/media` +
  `/hls` — the browser LiveViews consume those via cookie session/same-origin.
  HA gets a parallel token-authed surface; controllers/logic are reused, auth
  differs at the pipeline. Keeps browser UX untouched.
- **Token in config.yml** (`server.ha_token` or `integrations.token`), parsed by
  `Cairn.Config.Server`, compared with `Plug.Crypto.secure_compare`. Absent
  token ⇒ `/api` returns 401 for all (integration disabled by default).
- **SSE, not WebSocket, for the event feed.** Python consumes `text/event-stream`
  trivially; Phoenix `Plug.Conn.chunk/2` from a process subscribed to the three
  PubSub topics. Heartbeat comment every ~20s; entities' availability follows
  the connection.

## Open design wrinkles (flagged as tasks/spikes)
- **WHEP session ownership (C.1).** `WebRTC.Session.start(camera_id, owner)`
  monitors `owner` and `{:stop}` when it dies; trickle ICE is `send(owner, ...)`.
  An HTTP request process is transient → session would die at response end.
  Options: (a) non-trickle WHEP — wait for ICE gathering-complete, embed
  candidates in the answer SDP, return once; own the session with a persistent
  keeper (Registry-tracked) torn down on PeerConnection `:failed/:closed` or a
  TTL. LAN-only + `ice_servers: []` (host candidates) makes non-trickle viable.
  (b) trickle over WHEP PATCH — more moving parts; likely unnecessary on LAN.
  → Lean (a). Spike to confirm gathering-complete answer works with HA's
  `async_handle_async_webrtc_offer`.
- **RTSP fallback exposes creds.** `camera.rtsp_url` embeds credentials. Do NOT
  hand it to HA raw. Either omit RTSP fallback (WebRTC-primary) or provide a
  credential-free restream later. Default: WebRTC-only in D; document RTSP as a
  future option.
- **Control (Phase D) is net-new.** No runtime enable/disable exists; detection =
  `plugin` set at load. Needs a runtime overlay store the pipeline reads. Highest
  risk/lift; sequenced last and independently shippable.

## C.1 SPIKE VERDICT (resolved) — non-trickle WHEP, self-owned session
- **Verdict: option (a) non-trickle.** `Session` now takes an optional `owner`
  (nil = self-owned) and an optional `whep_id`. Browser path unchanged (owner =
  channel pid, trickle `send/2` preserved).
- **Non-trickle answer:** new `handle_offer_await/2` → `{:offer_await, sdp}` call
  sets remote/creates answer/sets local, then **defers the GenServer reply**
  (stores `from`) until `{:ice_gathering_state_change, :complete}` arrives, then
  replies with `PeerConnection.get_local_description(pc).sdp` (candidates embedded
  by ExWebRTC). A `@gather_timeout_ms` (2s) fallback replies with whatever's
  gathered — LAN host candidates gather in <100ms, so this is belt-and-braces.
- **Lifecycle:** self-owned session registers in `Cairn.Registry` under
  `{whep_id, :whep}`; DELETE looks it up and terminates it. A `:connect_deadline`
  (30s) stops a session that never reaches `:connected`; existing
  `:failed/:closed` handler tears down after connect. Reuses `WebRTC.Supervisor`
  `max_children: 32` → `{:error, :max_children}` → 503.
- **ICE handler guarded:** only `send(owner, ...)` when owner is a pid (nil would
  crash). Non-trickle needs no trickle out anyway.

## Reused, already-exists (do not rebuild)
- `Cairn.Events.list/1` (camera/label/from/to/page filters, %{events,page,total}),
  `Events.get/1`, `Events.known_labels/0`.
- `MediaController.event_clip/snapshot` (Range-capable) — reuse under `/api`.
- `%Cairn.Event{}` is `@derive Jason.Encoder`.
- `WebRTC.Session.handle_offer/2`, `add_ice/2`.
- `Config.Server` camera list; `CameraStatus.all/0` + `"cameras:status"`.
