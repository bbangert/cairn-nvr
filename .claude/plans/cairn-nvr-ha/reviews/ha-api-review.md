# Review: Home Assistant `/api` integration (Cairn Elixir side)

**Verdict: PASS WITH WARNINGS** — no blockers; all 16 plan tasks verified MET.
Two warnings are worth fixing before shipping (a token-in-logs leak and a WHEP
timeout edge case); the rest are hardening/tests.

Agents: security-analyzer, elixir-reviewer, testing-reviewer, requirements-verifier.

## Requirements Coverage
All A.1–E.3 tasks **MET** with file:line evidence. Confirmed:
- No `/api` response emits `rtsp_url` or on-disk paths (`path`/`snapshot_path`) —
  `EventJSON` emits only `clip_url`/`snapshot_url`; `probe` carries only
  codec/dimensions.
- B.3's intentional deviation (shape `%Cairn.Event{}` via `EventJSON.shape_live/1`
  instead of raw Jason, to avoid leaking paths) is correctly implemented.
- Gates verified: 401/200 auth, SSE frame kinds, WHEP non-trickle offer→answer,
  control toggles change aggregator behavior.

## Rejected (false positive)
- **Unbounded `page_size` DoS** (raised by security + elixir): REJECTED —
  `Cairn.Events.list/1:96` already clamps `page_size` to `min(_, 200)`. The
  controller passing a large value through is harmless.

## Warnings

### W1 — `?access_token=` query token leaks into application logs  *(security)*
`config/config.exs` sets no `:filter_parameters`; Phoenix's default filters only
`["password"]`. Every media fetch like `/api/media/events/42?access_token=SECRET`
writes the full static integration token into the `Parameters: %{...}` log line.
Anyone with log-read access gains indefinite `/api` + media access.
**Fix:** `config :phoenix, :filter_parameters, ["password", "access_token", "token", "sdp"]`
(and consider `Referrer-Policy: no-referrer` on `:api` — SUGGESTION S4).

### W2 — WHEP session orphaned if `handle_offer_await` call times out  *(elixir)*
`whep_controller.ex:57-69`: the `GenServer.call` has a 5s cap while the session
self-replies within 2s normally. But if `create_answer`/`set_local_description`
itself stalls, the call raises `:exit {:timeout,...}` in the Plug process,
`answer_or_teardown/4` never runs its `terminate_child`, and the orphaned session
lingers until the 30s `:connect_deadline` reaper — transiently filling
`max_children` (503s for legit requests) and returning a non-JSON 500 (inconsistent
with the controller's JSON errors). **Fix:** wrap the call in try/catch, terminate
the session on exit, return a 503 JSON envelope.

### W3 — No cap on concurrent `/api/stream` (SSE) connections  *(security)*
`event_stream_controller.ex`: WHEP caps at 32 via `WebRTC.Supervisor`, but SSE has
no limit. Each connection is a process holding a chunked socket subscribed to 4
PubSub topics; a token holder can open thousands, exhausting FDs/memory and fanning
out every broadcast N times. **Fix:** track active SSE count (ETS counter), 503 past
a limit.

### W4 — WHEP controller has zero HTTP-level tests  *(testing)*
`whep_controller.ex` is only covered indirectly via `Session` unit tests. Untested:
`201` + `Location`, `DELETE`→`204`, repeat-`DELETE`→`404`, unknown-camera `404`,
`max_children`→`503`, and that `ApiAuth` actually gates the WHEP route.

### W5 — `ApiAuth` "no token configured" path untested  *(testing)*
`api_auth_test.exs` never asserts the documented disabled-integration case
(`ha_token` nil ⇒ 401 for everything). It's the security default; it should have a test.

## Suggestions (low priority)
- **S1** `CameraControl.set/2` `@spec` accepts any `map()` but `Map.take/2` silently
  drops string keys — safe today (caller pre-validates to atoms), a footgun for
  future callers. (`camera_control.ex:52-58`)
- **S2** WHEP `DELETE` has no session-ownership binding — any token holder can kill
  any session by id. Mitigated by 128-bit unguessable ids + single-tenant.
- **S3** Set an explicit small `:length` on the SDP `read_body` (default 8 MB;
  offers are a few KB). (`whep_controller.ex`)
- **S4** Add `Referrer-Policy: no-referrer` (and other secure headers) to `:api` —
  the token rides in media query strings. (`router.ex`)
- **S5** `:gather_timeout` answers with a partial candidate set on a slow box; a
  non-trickle client reading only the initial SDP would miss late host candidates.
  Latent, masked by near-instant LAN gathering — worth a code comment.
  (`session.ex:206-208`)
- **S6** SSE loop / chunking / heartbeat / disconnect isn't exercised end-to-end
  (only `frame_for/1` is unit-tested); `refute_receive ..., 200` in the aggregator
  control tests is a mild timing gamble on two of three cases.

## Validated safe (notable)
- Token comparison is constant-time (`Plug.Crypto.secure_compare`) and fails closed
  when token or header/param is absent; no 401 bypass (all `/api*` incl. `/api/media`
  pipe through `:api`).
- The deferred non-trickle WHEP reply does **not** double-fire (both handlers guard
  on `await_from`, cleared synchronously before the next message).
- `CameraControl.get/1` ETS read on the detection hot path is a cheap single lookup;
  aggregator behavior is identical to before when control is at defaults.
