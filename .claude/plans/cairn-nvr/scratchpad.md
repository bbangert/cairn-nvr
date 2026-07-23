# Scratchpad: cairn-nvr plan

Decisions, corrections, and dead-ends discovered during planning.
Append during /phx:work — do not rewrite history.

## Corrections to docs/architecture.md (2026-07-22, planning)

1. **RingBuffer `drain_and_subscribe` sketch is buggy**:
   `Phoenix.PubSub.subscribe/2` subscribes the *calling* process, so the
   sketch subscribes the ring itself, not the extractor. Plan uses
   ring-managed subscriber list (monitored pids, direct send) for
   extractors; PubSub retained for MSE/HLS viewers only. → tasks 2.5, 5.1.
2. **ffmpeg `-reconnect*` flags are HTTP-only** — no effect on RTSP.
   Resilience = in-process jittered backoff respawn + fragment-rate
   watchdog. Also `-stimeout` renamed `-timeout` in modern ffmpeg; argv
   builder handles both. → task 2.4.
3. **Port stderr**: cannot separate stderr without corrupting the fmp4
   stdout stream; spawn via `/bin/sh -c "exec ffmpeg … 2>> log"` per
   camera. Same for plugins/ffprobe (also gives us `exec` so Port kill
   reaches the real process). → tasks 2.4, 4.2, 8.1.

## Planning decisions

- **Single phased plan** (9 phases, ~45 tasks) rather than split plans:
  dependencies are linear, one coherent v1 scope. Phases 3 and 5 are
  demo-able milestones. QCS6490 NPU plugin split out as a follow-up plan
  (hardware-dependent).
- **Phase order puts MSE live preview (3) before detection (4/5)**: gives a
  visible end-to-end milestone from just the ingest plane, de-risks the
  demuxer early.
- **No Oban**: retention pruner + emergency cleanup are plain periodic
  GenServers; no job-queue semantics needed on SQLite.
- Extractor inserts the `active` index row at event start (not only on
  finalize) — makes crash-mid-event reconciliation trivial (`active` row +
  file ⇒ `partial`).
- Reconnect/backoff loops live *inside* FFmpegPort/PluginPort GenServers;
  supervisor restarts reserved for crashes (dead camera = normal state, must
  not exhaust restart intensity).

## Open questions (minor, defer to implementation)

- ex_webrtc GOP replay: does `send_rtp` on an outbound track require seq/ts
  rewriting for the replayed packets? Spike in task 7.3; fallback = no
  replay (≤2s first frame).
- Exact codec-string derivation coverage (High/Main/Baseline profiles) in
  Demuxer — extend fixtures if a camera produces an unparseable `avcC`.
- `mix phx.new . --app cairn` into a dir that already has `docs/` +
  `.claude/` — expect prompt about non-empty dir; confirm overwrite is safe
  (nothing colliding).

## Mid-work scope change (2026-07-22, user)

- **UI is NOT built here.** User will design the UI in Claude Design from a
  handoff document (`docs/design-handoff.md`) and export it back. We build
  all server-side plumbing + minimal functional LiveView/template scaffolds
  (enough to compile, test, and demo data flow), and maintain the handoff
  doc with page map, components, states, events, and data contracts.
  Affects tasks 3.2, 3.3, 6.1–6.4, 7.4 (UI portions only).

## Spike results

- **7.3 ex_webrtc `send_rtp` GOP replay (2026-07-22)**: read
  `ExWebRTC.RTPSender.do_send_packet/3` (v0.17.0) — it rewrites only
  `payload_type` and `ssrc` (+ MID header ext). **Sequence numbers and
  timestamps pass through untouched.** Replaying the GOP buffer then
  continuing with live packets from the same camera RTP stream keeps
  seq/ts continuity with NO rewriting. Dedupe guard needed at the
  replay→live boundary (subscribe-then-snapshot, drop seq <= last
  replayed). Verdict: replay is safe; no seq rewriter built.
  **REVISED 2026-07-22 (live testing)**: passthrough seq DIES at the SRTP
  layer — ffmpeg's random initial seq wraps/regresses and libsrtp's
  outbound replay protection rejects everything (`Unable to protect RTP:
  :replay_old` → first frame renders, then freeze). The session now
  rewrites seq with its own monotonic counter on every sent packet
  (timestamps still pass through). Confirmed smooth in Ben's browser.

## Dead-ends already settled in research (do not revisit)

tmpfs ring, slice_ring_buffer/Rust sidecar, Live555, GStreamer-as-ingest,
webrtcbin-in-plugin, membrane_http_adaptive_stream, raw exqlite, raw
WebSock for MSE, dynamic UDP port handshake, libx264 fallback.

## Review cycle results (2026-07-22, /phx:full REVIEWING)

3 agents (elixir-reviewer, security-analyzer, testing-reviewer). Full
elixir findings: .claude/reviews/elixir.md. All confirmed findings fixed
in commit "Review fixes:...". Accepted-as-is (documented, not fixed):
known_labels/0 full-table scan (thousands of rows by design),
label_entries O(n) append (capped at 5000), System.cmd("kill") briefly
blocking terminate, creds visible in local `ps` (LAN/dev tradeoff).
Clean surfaces per security agent: shell escaping, SQL injection, path
traversal, atom exhaustion, XSS.
