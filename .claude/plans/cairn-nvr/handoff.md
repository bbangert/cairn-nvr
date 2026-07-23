# Handoff: Cairn NVR — state & what's next

_Last updated: 2026-07-23 (end of the v1 build session)_

## Where things stand

v1 is **complete, shipped, and verified**:

- All 54 plan tasks done (plan.md), three-agent review findings fixed,
  live-verified against the real Reolink camera: smooth MSE **and**
  WebRTC in-browser, real event clip with pre-roll indexed + snapshotted.
- Repo: **github.com/bbangert/cairn-nvr** (private). CI green: compile
  (warnings-as-errors) → format → credo → sobelow (medium threshold) →
  dialyzer → tests → real-ffmpeg integration test. ~1m15s warm.
- Devcontainer with mise toolchain (Erlang 29.0.3 / Elixir 1.20.2) +
  ffmpeg + Claude Code (CLI + extension, config persisted in a volume).
- UI implements the Claude Design export (docs/design/…zip); functional
  contracts in docs/design-handoff.md.

**Camera source of record**: the Reolink's HTTP-FLV URL, not RTSP
(RTSP emits non-monotonic DTS → stutter). URLs live in the gitignored
`.env.local` and `config.yml`. Local dev server: `mix phx.server`,
port from `$PORT` (falls back 4400; Ben's env pins 4000).

## Next up (in priority order)

1. **Real detections — CPU reference plugin** (top pick). Everything so
   far uses the mock plugin; the product has never truly detected
   anything. `plugins/cpu-reference/` has never been executed: venv,
   `pip install -r requirements.txt`, YOLOv8n ONNX export + coco.names,
   wire into `config.yml` (README in that dir has the exact block).
   Expect a debug loop: the SDP-over-RTP decode path and the YOLO
   postprocess layout are untested guesses. Success = a real
   person-walks-by clip with correct labels/scores in the events UI.

2. **Deploy for real**: `MIX_ENV=prod mix assets.deploy && mix release`,
   systemd unit (rel/cairn.service.example), CAIRN_DATA_DIR somewhere
   durable. This also closes the still-open release-boot smoke test.

3. **Merge the two Dependabot PRs** (actions/checkout v7, actions/cache
   v6 — both already passed CI): `gh pr merge 1 --squash`, `gh pr merge 2 --squash`.

4. **Home Assistant integration**: MQTT/webhook publisher subscribed to
   the `"events"` PubSub topic (`Cairn.Event.subscribe/0`) — designed
   extension point, aggregator untouched.

5. **QCS6490 NPU plugin** (needs the device): GStreamer v4l2h264dec +
   NPU inference per docs/plugin-contract.md; also the real
   `h264_v4l2m2m` transcode test (refusal path is tested, the happy
   path has never run on real hardware).

6. **Continuous recording** (if wanted): a fourth fragment subscriber on
   the ring's PubSub topic; no refactor expected.

## Known caveats / open items

- **Going public** requires a history rewrite first if the LAN camera IP
  in pre-scrub commits matters (tracked files are clean as of the
  "Repo polish" commit).
- **Hard-killed BEAM orphans ffmpeg** children (sh-exec'd); terminate/2
  handles graceful stops. If cleanup is ever needed: verify PID by
  `/proc/<pid>/cwd` == repo — **never pattern-pkill** (Ben's machine
  runs many BEAM apps; this burned us once).
- Accepted-as-is from review (documented in scratchpad): known_labels
  full scan, label-entry O(n) append (capped 5000), creds visible in
  local `ps`.
- Aggregator restore after restart uses global default windows (camera
  overrides unknown at restore) — cosmetic.
- MSE runs ~3s behind live by design (`TARGET_LATENCY_S` in
  assets/js/hooks/mse_player.js); WebRTC is the sub-second path.

## Key artifacts

- Plan/progress/scratchpad: `.claude/plans/cairn-nvr/` (spike verdicts,
  review record, gate table — all closed except items above)
- Solutions (institutional knowledge): `.claude/solutions/*.md` — SRTP
  seq rewrite, fmp4 pipeline lessons, sandbox pollution, Port patterns,
  timer-token race
- Review findings: `.claude/reviews/elixir.md`
- Design round-trip: `docs/design-handoff.md` (contracts) +
  `docs/design/cairn-nvr-prototype.zip` (source)
