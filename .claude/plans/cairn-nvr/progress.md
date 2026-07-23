# Progress: cairn-nvr

State: WORKING (Phase 5 in progress)

## Phase gates

| Phase | Tasks | Gate (Verify) | Result |
|-------|-------|---------------|--------|
| 1 — Scaffold/config/index | 1.1–1.8 ✅ | `mix check` green; boots with example config.yml | PASS (28 tests) — commit `Phase 1` |
| 2 — Ingest plane | 2.1–2.7 ✅ | `mix check`; fragments from a real camera in the ring | PASS (50 tests) + LIVE PASS 2026-07-22: real Reolink RTSP (192.168.2.152) ingested, ring serving fragments |
| 3 — Live preview | 3.1–3.6 ✅ | `mix check`; MSE+HLS paths | PASS (62 tests) + LIVE PASS (server half): HLS init+segments from real camera ffprobe-decode (80 frames 2560×1920 H.264). Browser render check → external gate below |
| 4 — Detection plane | 4.1–4.7 ✅ | `mix check`; mock plugin timeline drives start/update/end on `"events"` | PASS (81 tests) — commit `Phase 4` |
| 5 — Event plane | 5.1–5.7 ✅ | `mix check`; e2e: real camera + mock plugin ⇒ playable, indexed clip | PASS (87 tests) + LIVE PASS 2026-07-22: 13.9s clip w/ pre-roll (200 frames, box-valid), row `finalized` 5.2MB max_score 0.93, 2560×1920 JPEG snapshot |
| 6 — Browser/config plumbing | pending | `mix check`; LiveView tests | — |
| 7 — WebRTC | pending | `mix check`; spike verdict recorded | — |
| 8 — Probe/transcode | pending | `mix check`; refusal path tested | — |
| 9 — Release/docs/integration | pending | `mix check` + `@tag :integration` green; release boots | — |

## External gates

- **BROWSER VIDEO CHECK (open — needs a human)**: headless proxies all
  pass against the real camera (2026-07-22). Remaining human step: server
  is left running — open http://localhost:4000/ and confirm the
  reolink_main tile renders moving video (MSE; HLS is the fallback).
  Owner: Ben.

- **DESIGN HANDOFF (open)**: `docs/design-handoff.md` delivered to Claude
  Design (created early, during Phase 5). Blocks: final visual styling of
  dashboard, events list/detail, labels timeline, config page, nav chrome.
  When the export returns: wire markup into existing LiveViews keeping the
  id/`data-*`/`phx-*` contracts (see doc §Round trip).

## Scope changes

- 2026-07-22: UI built externally in Claude Design; server-side plumbing +
  minimal scaffolds only (user request, mid Phase 1).
[18:45] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[18:46] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/event_extractor.ex
[18:46] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/snapshot.ex
[18:46] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/reconciler.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/retention.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/application.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/boot.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/retention.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/extractor_telemetry.ex
[18:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/application.ex
[18:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/event_extractor.ex
[18:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/event_extractor.ex
[18:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/event_extractor_test.exs
[18:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/retention_test.exs
[18:49] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/retention.ex
[18:50] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/retention_test.exs
[18:50] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/event_extractor_test.exs
[18:50] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/event_extractor_test.exs
[18:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/plugin_port_test.exs
[18:52] Modified: /var/home/ben/.claude/projects/-var-home-ben-Programming-elixir-cairn-nvr/memory/never-skip-manual-verify-gates.md
[18:52] Modified: /var/home/ben/.claude/projects/-var-home-ben-Programming-elixir-cairn-nvr/memory/MEMORY.md
[18:59] Modified: /var/home/ben/.claude/projects/-var-home-ben-Programming-elixir-cairn-nvr/memory/test-camera-location.md
[18:59] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[18:59] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/ffmpeg_port_test.exs
[18:59] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/reconciler.ex
[18:59] Modified: /var/home/ben/Programming/elixir/cairn-nvr/priv/plugins/mock/mock_plugin.exs
[18:59] Modified: /var/home/ben/Programming/elixir/cairn-nvr/priv/plugins/mock/mock_plugin.exs
[19:01] Modified: /var/home/ben/Programming/elixir/cairn-nvr/config/dev.exs
[19:02] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/application.ex
[19:02] Modified: /var/home/ben/Programming/elixir/cairn-nvr/config/test.exs
[19:06] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[19:06] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[19:07] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[19:07] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[19:07] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[19:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[19:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/event_live.ex
[19:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/config_live.ex
[19:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/router.ex
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/timeline_seek.js
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[19:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/events_test.exs
[19:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/controllers/media_controller_test.exs
[19:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/live/events_live_test.exs
[19:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/live/config_live_test.exs
[19:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/camera_supervisor.ex
[19:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/boot.ex
[19:11] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[19:12] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[19:13] Modified: /var/home/ben/Programming/elixir/cairn-nvr/mix.exs
[19:15] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/scratchpad.md
[19:15] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/rtp/h264.ex
[19:15] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/rtp_hub.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/channels/webrtc_channel.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/channels/user_socket.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/camera.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:16] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/webrtc_player.js
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/rtp/h264_test.exs
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/rtp_hub_test.exs
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/webrtc/session_test.exs
[19:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/channels/webrtc_channel_test.exs
