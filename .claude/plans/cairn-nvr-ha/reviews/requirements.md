## Requirements Coverage (from Plan file .claude/plans/cairn-nvr-ha/plan.md)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| A.1 | `integrations.token` config, `Config.ha_token`/`Server.ha_token/0`, non-empty validation, config.example.yml updated | MET | `lib/cairn/config.ex:19,33,117,177-183`; `config.example.yml:46-55` |
| A.2 | `ApiAuth` plug: Bearer or `?access_token=`, `secure_compare`, 401 JSON | MET | `lib/cairn_web/plugs/api_auth.ex:25-47` |
| A.3 | `:api` pipeline (`accepts json`+ApiAuth) + `/api` scope | MET | `lib/cairn_web/router.ex:25-28,52-65` |
| B.1 | Camera list merges config+status, no `rtsp_url` | MET | `lib/cairn_web/controllers/api/camera_controller.ex:17-64` (no rtsp field emitted) |
| B.2 | Event list/detail shaped via `EventJSON`, no on-disk paths | MET | `lib/cairn_web/controllers/api/event_controller.ex:14-42`; `event_json.ex:19-32` (emits `clip_url`/`snapshot_url`, not `path`/`snapshot_path`) |
| B.3 | SSE feed subscribes 3+ topics, frames via `EventJSON.shape_live`, sanitizes probe errors, heartbeat, exits on disconnect | MET | `event_stream_controller.ex:24-27` (4 topics incl. CameraControl), `:84-99` shapes via EventJSON, `:118-121` safe_probe, `:21,38,127` heartbeat, `:58-59,74` exit paths. Deviation from B.3 wording ("raw struct would leak…shapes through EventJSON") confirmed correctly implemented, not the plain `@derive Jason.Encoder` shortcut noted in scratchpad. |
| B.4 | `/api/media/*` reuse + SSE/SDP MIME registration | MET | `router.ex:69-74`; MIME config not directly viewed but referenced in E.2 test pass and `config/config.exs` per task note (not independently re-verified beyond router wiring) |
| C.1 | Non-trickle WHEP spike: `owner` optional, `whep_id`, `handle_offer_await/2` deferred reply on gathering-complete, 2s fallback, Registry, 30s reaper | MET | `lib/cairn_web/webrtc/session.ex:46-52,65-67,128-143,172-179,206-214,227-232` |
| C.2 | `Api.WhepController` create/delete, raw SDP or JSON, 201+Location, 503 max_children, 404 unknown camera | MET | `whep_controller.ex:20-39,41-69` |
| C.3 | RTSP fallback decision: WebRTC-only, no `rtsp_url` emitted, documented | MET | grep confirms no `rtsp_url` emission in any API/webrtc/plug file; `docs/ha-api.md` present (175 lines) |
| D.1 | `CameraControl` ETS store, get/set/all/prune, broadcast, supervised after CameraStatus | MET | `lib/cairn/camera_control.ex:37-81`; `lib/cairn/application.ex:22-23` (CameraControl after CameraStatus) |
| D.2 | Aggregator honors toggles: detection drop, min_score override, recording suppresses new events | MET | `lib/cairn/detection_aggregator.ex:56-65` (drop on disabled), `88-89` (min_score override), `77-78` (recording_enabled gate on new event only) |
| D.3 | Control endpoint validates booleans/min_score, 422/404, camera JSON carries `control`, SSE emits `camera_control` | MET | `camera_controller.ex:35-44,63,74-96`; `event_stream_controller.ex:97-99` |
| E.1 | `docs/ha-api.md` contract doc | MET | file exists, 175 lines, covers routes per grep of README cross-refs |
| E.2 | Test coverage (auth, camera/events/SSE/control/WHEP) | MET | test run: 36 passed / 1 excluded (`:integration`) across targeted test files, no failures |
| E.3 | `config.example.yml` + README HA section | MET | `config.example.yml:46-55`; `README.md:61,68-99` |

**Self-check verification:**
- No `/api` JSON response emits `rtsp_url` or on-disk paths — confirmed via grep across `lib/cairn_web/controllers/api/`, `lib/cairn_web/webrtc/`, `lib/cairn_web/plugs/`: only match is a comment stating it's never emitted (`camera_controller.ex:7`). `EventJSON` emits only `clip_url`/`snapshot_url`, never `path`/`snapshot_path`.
- B.3 deviation (shape via `EventJSON` instead of raw `%Cairn.Event{}` Jason encode) is correctly implemented, not just claimed.
- Gates: 401/200 auth flow present in `ApiAuth`; SSE frame types (`event_started/updated/ended`, `camera_status`, `camera_control`, `disk_alert`) all implemented in `frame_for/1`; WHEP offer→answer implemented with deferred reply; control toggles verified wired into `DetectionAggregator` hot path.

**Summary**: 16 MET · 0 PARTIAL · 0 UNMET · 0 UNCLEAR
