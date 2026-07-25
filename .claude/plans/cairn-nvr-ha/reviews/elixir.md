# Elixir Review: Home Assistant `/api` Integration

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 5

## Verified Safe (called out in prompt, checked against source)
- **`double-fire reply` race** (`lib/cairn_web/webrtc/session.ex:173-208`): NOT a bug.
  `:gather_timeout` and `:ice_gathering_state_change/:complete` both guard on
  `not is_nil(from)`, and `reply_answer/1` (line 227-232) sets `await_from: nil`
  before either message can be processed again — GenServer handles messages
  serially, so the second one to arrive falls through to the guard and no-ops.
  `Process.cancel_timer` on an already-fired timer is a safe no-op.

## Warnings

1. **`lib/cairn_web/controllers/api/whep_controller.ex:57-69` — orphaned session on `GenServer.call` timeout.**
   `handle_offer_await/2` (session.ex:66-67) has a 5s call timeout, but the
   session always self-replies within 2s (gather-complete or `:gather_timeout`
   fallback) under normal operation. If `PeerConnection.create_answer/1` or
   `set_local_description/2` itself stalls (slow/loaded BEAM, ex_webrtc NIF
   hiccup), the `GenServer.call` raises `:exit, {:timeout, ...}` in the Plug
   process. `answer_or_teardown/4`'s `case` never runs, so
   `DynamicSupervisor.terminate_child/2` is never called — the session sits
   alive (unauthenticated, unsubscribed) until the 30s `:connect_deadline`
   reaper fires. Under repeated timeouts this transiently fills
   `WebRTC.Supervisor`'s `max_children` and starts 503-ing legitimate
   requests. Also: an uncaught exit here returns Phoenix's default 500 HTML/
   plain error, inconsistent with `send_error/3`'s JSON envelope used
   everywhere else in this controller.

2. **`lib/cairn/camera_control.ex:52-58` — silent no-op on non-atom-keyed `attrs`.**
   `set/2`'s `@spec` accepts any `map()`, but `Map.take(attrs, Map.keys(@defaults))`
   only matches atom keys. The one caller today (`camera_controller.ex:74-83`)
   pre-validates into atom keys, so this is currently safe, but the public
   API silently drops string-keyed input (e.g. `%{"detection_enabled" => false}`)
   with no error — a future caller passing raw HA webhook params would see
   the merge return unchanged control and assume it worked.

## Suggestions

1. **`lib/cairn_web/controllers/api/event_controller.ex:21` — unbounded `page_size`.**
   `parse_int(params["page_size"], 50)` has no upper clamp; a client-supplied
   `page_size=1000000` reaches `Events.list/1` unclamped. Low risk (token-authed
   HA-only surface) but cheap to bound (e.g. `min(n, 200)`).

2. **`lib/cairn_web/webrtc/session.ex:206-208` — `:gather_timeout` fallback answers with a partial candidate set by design**, per the moduledoc/comment; worth an explicit code comment noting HA/WHEP clients that only read candidates from the initial SDP (no trickle) will never receive host candidates gathered after the 2s cutoff on a loaded box — currently masked because LAN gathering is near-instant, but it's a real (if rare) latent gap for slower NICs/VLANs.

3. **`lib/cairn/detection_aggregator.ex:56-65`** — `CameraControl.get/1` ETS lookup per batch (hot path) is a single `:ets.lookup/2` on a `:protected read_concurrency` table; negligible cost, no concern. Confirms design intent from the plan.

## Not Reviewed In Depth (turn budget)
- `lib/cairn/config.ex` / `config/server.ex` ha_token validation — read, looks correct (rejects empty-string token, `nil` = disabled).
- `event_json.ex`, `camera_controller.ex` shape/JSON output — no idiom issues found on read.
