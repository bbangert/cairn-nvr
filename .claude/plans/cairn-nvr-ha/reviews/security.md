# Security Audit: Cairn NVR — Home Assistant `/api` surface

## Executive Summary

The new token-authed `/api` surface is well-constructed and meets its hard
requirements: no response leaks `rtsp_url`, absolute paths, `path`, or
`snapshot_path` (verified across `event_json.ex`, `camera_controller.ex`, and
the `probe` field — probe carries only codec/width/height/fps/profile; ffprobe
stderr is routed to `/dev/null`, and `format_error/1` inspects only atoms/tuples,
so credentials cannot reach `probe`). Token comparison is constant-time and
fails safe. No SQL injection, no `String.to_atom`, no `raw/1`, no atom
exhaustion. Remaining issues are DoS and a token-in-logs leak — no BLOCKER.

## Findings

### WARNING — `access_token` query param leaks into application logs
- **Location**: `config/config.exs` (no `:filter_parameters` configured) +
  `lib/cairn_web/plugs/api_auth.ex:38`
- **Issue**: `?access_token=` is accepted for media URLs. Phoenix's default
  `filter_parameters` is only `["password"]`, so `access_token` lands in
  `conn.params` and is emitted in the `Parameters: %{...}` controller log line.
- **Scenario**: HA hands a player `/api/media/events/42?access_token=SECRET`.
  Every fetch writes the full integration token to the log file / log
  aggregator. Anyone with log read access gains total `/api` + media access
  indefinitely (the token is static, from `config.yml`).
- **Fix**: `config :phoenix, :filter_parameters, ["password", "access_token", "token", "sdp"]`.
  Consider also stripping the query param from access logs.

### WARNING — Unbounded `page_size` enables memory/CPU DoS
- **Location**: `lib/cairn_web/controllers/api/event_controller.ex:21` →
  `parse_int/2` (`:57`) caps nothing above 0.
- **Scenario**: `GET /api/events?page_size=100000000` asks `Events.list/1` to
  load the entire event table into memory in one query, per request.
- **Fix**: clamp, e.g. `min(parse_int(...), 200)`.

### WARNING — Unbounded concurrent SSE connections
- **Location**: `lib/cairn_web/controllers/api/event_stream_controller.ex:23`
- **Issue**: WHEP is capped at 32 by `WebRTC.Supervisor`, but `/api/stream`
  has no connection cap. Each connection is a process holding a chunked
  socket subscribed to 4 PubSub topics.
- **Scenario**: A token holder (or leaked token) opens thousands of
  `/api/stream` connections, exhausting file descriptors / memory and
  fanning out every PubSub broadcast N times.
- **Fix**: track active SSE count (ETS/counter) and return 503 past a limit.

### SUGGESTION — WHEP DELETE has no session-ownership binding
- **Location**: `lib/cairn_web/controllers/api/whep_controller.ex:30`
- Any token holder can terminate any session by `resource_id`. Ids are
  128-bit `strong_rand_bytes` (unguessable), and this is single-tenant, so
  low risk — noted for defense in depth.

### SUGGESTION — SDP `read_body` uses default 8 MB limit
- **Location**: `lib/cairn_web/controllers/api/whep_controller.ex:86`
- An SDP offer is a few KB; the default bound is generous. Bodies over the
  default fall to `:no_offer` (safe), but set an explicit small `:length`
  (e.g. 64 KB) to tighten the surface.

### SUGGESTION — No security headers on the `:api` pipeline
- **Location**: `lib/cairn_web/router.ex:25`
- `put_secure_browser_headers` (incl. Referrer-Policy) applies only to
  `:browser`. Media URLs carry the token in the query string; a strict
  `Referrer-Policy: no-referrer` reduces token leakage via Referer. LAN-only
  deployment mitigates.

## Security Posture

- **Token auth** (`api_auth.ex`): constant-time `Plug.Crypto.secure_compare`;
  `nil`/absent token and absent header/param both fail closed to 401 via the
  `is_binary/1` guards. No bypass found — every `/api*` scope, including
  `/api/media`, pipes through `:api`. Clean.
- **Credential/path non-leakage** (hard requirement): MET. Verified
  `event_json.ex` emits only `clip_url`/`snapshot_url`; `camera_controller`
  emits no `rtsp_url`; `probe` cannot carry credentials.
- **Input validation** (`camera_controller.ex` control): strict — `min_score`
  `is_number 0..1` or explicit `nil`, booleans via `is_boolean`, unknown/typed-
  wrong values 422. Atom keys come from a fixed list, not user input. Clean.
- **WHEP resource id**: 128-bit CSPRNG, unguessable. Clean.
- Checked SQL injection (Events queries pin with `^`, `event_controller`,
  `events.ex:173` fragment parameterized), atom exhaustion, XSS/`raw`,
  deserialization, path traversal (`MediaController` resolves paths from DB
  rows, never request input): all clean.

## Pre-existing (not deep-analyzed)
- `lib/cairn/probe.ex:34` — spawns `/bin/sh -c` with `shell_escape/1`-quoted
  argv; args come from config, not `/api` input. Out of scope; noted.
- `lib/cairn_web/controllers/media_controller.ex:18,36` — path from DB row,
  Range parser bounds-checked. Reused safely under `:api`.

## Tools to Recommend (agent has no Bash access)
- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
