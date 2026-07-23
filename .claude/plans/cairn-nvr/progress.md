# Progress: cairn-nvr

State: COMPLETED (review cycle 1 done; external gates below still open)

## Phase gates

| Phase | Tasks | Gate (Verify) | Result |
|-------|-------|---------------|--------|
| 1 — Scaffold/config/index | 1.1–1.8 ✅ | `mix check` green; boots with example config.yml | PASS (28 tests) — commit `Phase 1` |
| 2 — Ingest plane | 2.1–2.7 ✅ | `mix check`; fragments from a real camera in the ring | PASS (50 tests) + LIVE PASS 2026-07-22: real Reolink RTSP (<lan-camera>) ingested, ring serving fragments |
| 3 — Live preview | 3.1–3.6 ✅ | `mix check`; MSE+HLS paths | PASS (62 tests) + LIVE PASS (server half): HLS init+segments from real camera ffprobe-decode (80 frames 2560×1920 H.264). Browser render check → external gate below |
| 4 — Detection plane | 4.1–4.7 ✅ | `mix check`; mock plugin timeline drives start/update/end on `"events"` | PASS (81 tests) — commit `Phase 4` |
| 5 — Event plane | 5.1–5.7 ✅ | `mix check`; e2e: real camera + mock plugin ⇒ playable, indexed clip | PASS (87 tests) + LIVE PASS 2026-07-22: 13.9s clip w/ pre-roll (200 frames, box-valid), row `finalized` 5.2MB max_score 0.93, 2560×1920 JPEG snapshot |
| 6 — Browser/config plumbing | 6.1–6.6 ✅ | `mix check`; LiveView tests; live endpoints | PASS (105 tests) + LIVE PASS: events list/detail/config vs real recorded event; Range 206; masked creds |
| 7 — WebRTC | 7.1–7.5 ✅ | `mix check`; spike verdict recorded | PASS (120 tests); spike verdict in scratchpad (no seq rewrite needed); hub live on :17001 with real RTP; browser WebRTC on Ben's manual list |
| 8 — Probe/transcode | 8.1–8.3 ✅ | `mix check`; refusal path tested | PASS (131 tests); real-ffprobe file probe + hung-probe timeout tested |
| 9 — Release/docs/integration | 9.1–9.5 ✅ | `mix check` + `@tag :integration` green | PASS: integration test green in 12.5s (real ffmpeg + mock plugin ⇒ finalized playable indexed clip + snapshot). Release-tarball boot smoke not run (needs prod assets build) — on Ben's list or CI |

## External gates

- **BROWSER VIDEO CHECK: PASSED 2026-07-22** — Ben confirmed smooth live
  video in-browser on BOTH paths: MSE (after live-edge cushion fix) and
  WebRTC (after in-band SPS/PPS + outbound seq rewrite). Source of record
  for the camera: Reolink HTTP-FLV (see scratchpad).

- **DESIGN HANDOFF: CLOSED 2026-07-22** — Claude Design export returned
  (docs/design/cairn-nvr-prototype.zip) and implemented: token/component
  CSS layer (assets/css/design.css), dark-only chrome + topbar, all four
  views recreated to spec with functional contracts intact. 141 tests
  green; pages live-verified.

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
[19:21] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/probe.ex
[19:21] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/camera.ex
[19:21] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/probe_test.exs
[19:22] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/transcode_test.exs
[19:23] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:24] Modified: /var/home/ben/Programming/elixir/cairn-nvr/docs/plugin-contract.md
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/plugins/cpu-reference/main.py
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/plugins/cpu-reference/requirements.txt
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/plugins/cpu-reference/README.md
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/config/runtime.exs
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/release_secrets.ex
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/mix.exs
[19:25] Modified: /var/home/ben/Programming/elixir/cairn-nvr/rel/cairn.service.example
[19:26] Modified: /var/home/ben/Programming/elixir/cairn-nvr/Dockerfile
[19:26] Modified: /var/home/ben/Programming/elixir/cairn-nvr/README.md
[19:27] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/test_helper.exs
[19:27] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/integration/full_pipeline_test.exs
[19:27] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/integration/full_pipeline_test.exs
[19:28] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/camera_supervisor_test.exs
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/camera_status_test.exs
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/udp_ports_test.exs
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/live/dashboard_live_test.exs
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/reviews/elixir.md
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/supervisor.ex
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/application.ex
[19:32] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/channels/webrtc_channel.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/detection_aggregator.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/detection_aggregator.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/detection_aggregator.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/detection_aggregator.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/detection_aggregator.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/mp4/demuxer.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/events.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:33] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/config_live.ex
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/endpoint.ex
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/data_dir.ex
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/detection_aggregator_test.exs
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/detection_aggregator_test.exs
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/detection_aggregator_test.exs
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/detection_aggregator_test.exs
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/detection_aggregator_test.exs
[19:34] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn_web/live/config_live_test.exs
[19:36] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/test_helper.exs
[19:37] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/camera_status_test.exs
[19:37] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/probe.ex
[19:38] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:38] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:38] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/rtp_hub.ex
[19:38] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/config_live.ex
[19:38] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/transcode_test.exs
[19:40] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/solutions/genserver-timer-cancel-race.md
[19:40] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/solutions/boot-writes-escape-ecto-sandbox.md
[19:40] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/solutions/port-process-management-patterns.md
[19:40] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/solutions/mse-fmp4-live-pipeline.md
[19:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[19:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/components/layouts.ex
[19:50] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/mse_player.js
[19:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/mse_player.js
[19:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/mse_player.js
[19:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/channels/stream_channel.ex
[19:54] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[19:56] Modified: /var/home/ben/.claude/projects/-var-home-ben-Programming-elixir-cairn-nvr/memory/never-pkill-by-pattern.md
[20:04] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[20:05] Modified: /var/home/ben/Programming/elixir/cairn-nvr/test/cairn/ffmpeg_port_test.exs
[20:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[20:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[20:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[20:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/webrtc/session.ex
[20:18] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/scratchpad.md
[20:18] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.claude/plans/cairn-nvr/progress.md
[21:07] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/css/app.css
[21:07] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/components/layouts/root.html.heex
[21:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/components/layouts.ex
[21:08] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/dashboard_live.ex
[21:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[21:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[21:09] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/events_live.ex
[21:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/event_live.ex
[21:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/timeline_seek.js
[21:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/hooks/copy_text.js
[21:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[21:10] Modified: /var/home/ben/Programming/elixir/cairn-nvr/assets/js/app.js
[21:11] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/live/config_live.ex
[21:47] Modified: /var/home/ben/Programming/elixir/cairn-nvr/mix.exs
[21:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/router.ex
[21:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[21:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[21:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn_web/controllers/media_controller.ex
[21:48] Modified: /var/home/ben/Programming/elixir/cairn-nvr/mix.exs
[21:49] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.github/workflows/ci.yml
[21:50] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/registry.ex
[21:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ffmpeg_port.ex
[21:51] Modified: /var/home/ben/Programming/elixir/cairn-nvr/lib/cairn/ring_buffer.ex
[22:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.github/dependabot.yml
[22:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/README.md
[22:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/mise.toml
[22:17] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.devcontainer/Dockerfile
[22:18] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.devcontainer/devcontainer.json
[22:18] Modified: /var/home/ben/Programming/elixir/cairn-nvr/.devcontainer/post-create.sh
[22:19] Modified: /var/home/ben/Programming/elixir/cairn-nvr/README.md
