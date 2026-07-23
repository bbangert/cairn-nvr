# Plan: Cairn NVR v1 — event-based Elixir NVR

**Status**: READY
**Date**: 2026-07-22
**Depth**: deep
**Source**: `.claude/plans/cairn-nvr/interview.md` (12/12 COMPLETE), `docs/architecture.md`,
`docs/frigate_comparison.md`, research in `.claude/plans/cairn-nvr/research/`
**Scratchpad**: `.claude/plans/cairn-nvr/scratchpad.md`

## Context

Greenfield OTP/Phoenix app. Per camera: one supervised ffmpeg Port (RTSP in,
three codec-copy outputs: fmp4 fragments on stdout, RTP to inference plugin,
RTP to WebRTC hub), an in-BEAM pre-window ring buffer, a Port-supervised
inference plugin emitting ndjson detections, a detection aggregator owning
event lifecycle, and one EventExtractor per active event streaming fragments
to a single mp4 on disk. SQLite (ecto_sqlite3) event index. LiveView
dashboard + event browser. MSE-over-Channel default live view, HLS fallback,
ex_webrtc for sub-second view.

All architectural decisions are settled (see interview §How and §Session 2).
**Do not relitigate**: ffmpeg ingest, in-BEAM ring, ex_webrtc, ecto_sqlite3,
ffprobe probe, Phoenix Channel MSE transport, configured UDP port ranges,
YAML config source-of-truth, no auth in v1, no continuous recording, no
silent libx264 fallback.

### Corrections to architecture.md sketches (carried into tasks)

1. **`drain_and_subscribe` atomicity**: `Phoenix.PubSub.subscribe/2` only
   subscribes the *calling* process — the sketch subscribes the RingBuffer
   itself. Fix: the ring manages extractor subscribers directly (list of
   monitored pids, direct `send`), giving true atomic drain+subscribe.
   PubSub broadcast is kept for viewers (MSE/HLS), where a race-free
   boundary doesn't matter.
2. **ffmpeg `-reconnect*` flags are HTTP-protocol options** — no effect on
   RTSP. Resilience = supervisor restart with in-process backoff + the
   fragment-rate watchdog. Also `-stimeout` was renamed `-timeout` for RTSP
   in modern ffmpeg — the argv builder must handle this.
3. **stderr vs stdout**: a Port either merges stderr into stdout (corrupting
   the fmp4 stream) or drops it. Spawn via
   `/bin/sh -c "exec ffmpeg … 2>> $LOG"` so stdout stays clean and stderr
   lands in a per-camera log file under the data dir. Same trick for plugins.

## Naming & layout

- App `:cairn`, modules `Cairn.*` / `CairnWeb.*`.
- All mutable state under `data_dir` (env `CAIRN_DATA_DIR`):
  `cairn.db`, `events/{camera_id}/`, `snapshots/`, `log/`.
- Event filenames encode identity for index rebuild:
  `events/{camera_id}/{event_id}_{camera_id}_{unix_ts}.mp4`.
- YAML config path from env `CAIRN_CONFIG` (default `config.yml` in cwd,
  documented). UI is read-only for config; apply via restart or explicit
  reload.

> **Scope change (2026-07-22)**: UI is designed externally in Claude Design.
> All `[liveview]`/`[js]` tasks deliver server-side plumbing + minimal
> functional scaffolds only; visual design is specced in
> `docs/design-handoff.md` (see task 6.6) for round-trip with Claude Design.

## Breadboard (UI map)

- **Dashboard** (`/`): camera grid → tile[MSE player, status badge,
  live-event marker, MSE↔WebRTC toggle]; disk-alert banner.
- **Events** (`/events`): filters[camera, label, date] → paginated list
  (streams, thumbnails) → **Event detail** (`/events/:id`): `<video>` clip
  playback (Range endpoint), labels timeline, metadata.
- **Config** (`/config`): read-only rendered config, per-camera probe
  results/warnings, Reload button → shows diff + warnings.

---

## Phase 1 — Scaffold, config core, event index

- [x] 1.1 [infra] Generate project in repo root: `mix phx.new . --app cairn
      --database sqlite3 --no-mailer --no-gettext` (LiveView default). Keep
      `docs/`. `git init`, add `credo` + `mix format`; CI-ready aliases
      (`mix check` = compile --warnings-as-errors, format --check-formatted,
      credo, test).
- [x] 1.2 [infra] Deps: `yaml_elixir` (config), `jason` (already). Defer
      `ex_webrtc` to Phase 7.
- [x] 1.3 [otp] `Cairn.Config`: typed structs (`Config`, `Config.Camera`)
      + `load/1` from YAML + validation returning `{:error, [msg]}`:
      required fields, `pre/post/max` window sanity, UDP base+range present,
      **reject overlapping/exhausted UDP ranges** (2 ports per camera),
      per-camera fields (`id`, `rtsp_url`, `min_score` per label,
      `extra_ffmpeg_args`, `transcode: false`, retention days + per-label
      override). Globals: `data_dir`, `stall_seconds` (15), free-space
      emergency threshold, retention defaults.
- [x] 1.4 [otp] `Cairn.Config.Server`: holds active config; `reload/0`
      re-reads YAML, validates, diffs cameras (added/removed/changed →
      start/stop/restart camera children), returns diff + warnings for UI.
      Invalid reload keeps old config and returns errors.
- [x] 1.5 [otp] `Cairn.DataDir`: resolve + ensure `events/ snapshots/ log/`
      subdirs at boot.
- [x] 1.6 [ecto] Repo on `{data_dir}/cairn.db`: `busy_timeout: 5_000`,
      `pool_size: 2`, WAL (adapter default). Migration `events`: `id`
      (uuid/string PK), `camera_id`, `started_at`, `ended_at`, `status`
      (`active|finalized|partial`), `path`, `bytes`, `labels` (JSON:
      time-indexed label entries + max scores), `max_score`,
      `snapshot_path`, timestamps. Indexes: `(camera_id, started_at)`,
      `status`. Migrations run at application boot (release-safe migrator).
- [x] 1.7 [otp] Supervision skeleton per architecture tree: `Cairn.PubSub`,
      Repo, `Cairn.Registry` (per-camera process names via
      `{camera_id, role}` keys), `Cairn.CameraSupervisor` (DynamicSupervisor),
      `Cairn.DetectionAggregator` (stub), `Cairn.EventSupervisor`
      (DynamicSupervisor), Endpoint. Camera children started from config at
      boot (after reconciliation task lands in 5.4, order: repo → reconcile
      → cameras).
- [x] 1.8 [test] Config load/validation tests (fixtures incl. UDP overlap,
      bad windows, unknown keys warning); reload diff tests; migration
      smoke test.

**Verify**: `mix check` green. App boots with example `config.yml`
(no cameras yet → empty grid).

## Phase 2 — Ingest plane: ffmpeg Port, fmp4 demuxer, ring buffer

- [x] 2.1 [otp] `Cairn.Camera` supervisor (`:rest_for_one`), child order:
      `RingBuffer` → `FFmpegPort` → (Phase 4: `PluginPort`) → (Phase 7:
      `RTPHub`). Ring death restarts ffmpeg (new ring is empty anyway);
      ffmpeg death restarts downstream consumers of its UDP outputs only.
- [x] 2.2 [port] `Cairn.MP4.Demuxer` — pure, incremental byte-stream parser:
      box framing; captures init segment (`ftyp`+`moov`); emits complete
      `moof`+`mdat` fragments; extracts `pts` from `tfdt`
      baseMediaDecodeTime, duration from `trun`, timescale from `mdhd`;
      extracts RFC 6381 codec string (`avc1.PPCCLL` from `avcC`) for MSE.
      Struct: `%Cairn.Fragment{camera_id, seq, pts, duration_ms, data}`.
- [x] 2.3 [infra] Fixture generator `mix cairn.gen.fixtures`: ffmpeg
      `testsrc` → committed fmp4 fixture(s) with the exact `-movflags` used
      in production; used by demuxer/ring/extractor tests.
- [x] 2.4 [port] `Cairn.FFmpegPort`: argv builder (TCP transport, `-timeout`
      with `-stimeout` fallback detection, `-nostats -loglevel warning`,
      three outputs per architecture.md invocation, `extra_ffmpeg_args`
      splice point, transcode variant deferred to 8.2); spawn via
      `/bin/sh -c "exec ffmpeg … 2>> {data_dir}/log/ffmpeg-{camera}.log"`,
      Port opts `[:binary, :exit_status]`; stream stdout through Demuxer;
      cast fragments + init segment to RingBuffer; on `:exit_status` enter
      backoff state (1s→30s jittered) then respawn **inside** the GenServer
      (avoid supervisor restart-intensity blowout on a dead camera);
      emit status transitions (`:connecting/:running/:backoff`) for 3.4.
- [x] 2.5 [otp] `Cairn.RingBuffer`: `:queue` of fragments; evict on pts
      window (`pre_window_seconds`, 90kHz-aware via fragment pts+timescale);
      cache init segment + codec string; on each fragment: broadcast
      `{:fragment, frag}` on PubSub `"camera:{id}:fragments"` **and** send
      to directly-managed extractor subscribers; atomic
      `drain_and_subscribe(camera_id, since_pts, pid)` (correction #1):
      returns `{init_segment, fragments}`, adds+monitors pid; `unsubscribe/2`;
      `last_fragment_at` for the watchdog; `fetch_recent/2` for HLS.
- [x] 2.6 [otp] Stall watchdog: periodic timer in FFmpegPort checks ring's
      `last_fragment_at`; silent stall > `stall_seconds` → close port,
      backoff-respawn, status `:stalled` → UI.
- [x] 2.7 [test] Demuxer against fixtures (incl. split-mid-box chunked
      feeds, property: any chunking yields identical fragments); ring
      eviction/drain/monitor-cleanup tests; FFmpegPort lifecycle test with
      `test/support/fake_ffmpeg.sh` (cats fixture, sleeps, exits — asserts
      backoff respawn + watchdog bounce).

**Verify**: `mix check`. Manual: point at one real RTSP camera (or
`file://` fixture loop), observe fragments in ring via IEx.

## Phase 3 — Live preview: MSE channel + minimal dashboard + HLS

- [x] 3.1 [liveview] `CairnWeb.StreamChannel` (`"camera:{id}"`): join reply
      carries codec string; push init segment then live fragments as binary
      frames (`{:binary, data}`). **Slow-consumer policy (explicit design
      obligation)**: every fragment, check transport pid
      `message_queue_len`; > high-water (e.g. 8 fragments) → stop channel
      with `:slow_consumer` (client reconnects fresh at live edge).
- [x] 3.2 [js] MSE LiveView hook (vanilla, ~40 lines): Phoenix Channel
      binary frames → `MediaSource`/`SourceBuffer` (codec from join reply),
      trim buffered ranges > 30s, rejoin-on-close with backoff, fall back
      to HLS `<video src>` when `MediaSource` unsupported.
- [x] 3.3 [liveview] Dashboard v0 (`/`): camera grid from config, per-tile
      MSE player + status badge; subscribes `"cameras:status"`.
- [x] 3.4 [otp] `Cairn.CameraStatus`: ETS + PubSub broadcast of per-camera
      status (`connecting/running/stalled/backoff` + probe results later);
      written by FFmpegPort/watchdog.
- [x] 3.5 [liveview] HLS fallback: controller `GET /hls/:camera/index.m3u8`
      (playlist over `RingBuffer.fetch_recent`, `EXT-X-MAP` init URL) +
      `GET /hls/:camera/init.mp4` + `/hls/:camera/:seq.m4s`. ~100 lines, no
      library.
- [x] 3.6 [test] Channel join/binary-push/slow-consumer tests; HLS playlist
      correctness; dashboard LiveView render test.

**Verify**: `mix check`. Manual milestone: **live video in browser** from a
real camera/fixture loop, both MSE and HLS paths.

## Phase 4 — Detection plane: plugin Port, mock plugin, aggregator

- [x] 4.1 [otp] `Cairn.UDPPorts`: pure allocator — camera index → 
      `{plugin_port, rtp_port}` = base + 2×index (validated in 1.3).
- [x] 4.2 [port] `Cairn.PluginPort`: spawn configured plugin command with
      argv `--camera-id --udp-port --min-score-json …` (contract: config via
      argv/env, RTP in on assigned UDP port, ndjson detections on stdout,
      logs on stderr → per-camera log via sh wrapper); Port opts
      `[:binary, {:line, 8192}, :exit_status]`; decode each line
      (`camera_id`, `pts`, `dets[{label,bbox,score}]`), forward to
      aggregator; malformed line → log + drop; backoff-respawn like 2.4.
- [x] 4.3 [infra] Mock plugin `priv/plugins/mock/mock_plugin.exs` (escript
      or plain script): replays a scripted detection timeline (JSON file +
      timing), ignores UDP input; deterministic for ExUnit/CI — exercises
      full Port lifecycle.
- [x] 4.4 [otp] `Cairn.DetectionAggregator`: per-camera state
      (`active_event`, `last_detection_pts`, tracker); `min_score` per-label
      filter; greedy-IoU tracker assigning stable object ids; lifecycle:
      no-active + detection → start `EventExtractor` via EventSupervisor;
      detection during event → reset post-window timer + accumulate
      time-indexed labels; `post_window_seconds` quiet → finalize;
      `max_event_seconds` → finalize + reopen if detections continue.
      Overlapping detections merge into the one active event per camera.
      Inject clock/timer (send_after wrapper) for tests.
- [x] 4.5 [otp] Aggregator ETS checkpoint: public named table owned by the
      app supervisor; aggregator restores active-event refs on restart
      (re-attach or finalize orphaned extractors).
- [x] 4.6 [otp] **Event lifecycle contract (publisher-friendly — design
      obligation)**: `Cairn.Event` struct + internal PubSub topic
      `"events"` emitting `{:event_started | :event_updated |
      :event_ended, %Cairn.Event{}}` with stable JSON-serializable shape
      (id first, media async later). Dashboard consumes it now; MQTT/webhooks
      bolt on later without touching the aggregator.
- [x] 4.7 [test] Tracker/lifecycle unit tests (fake clock: debounce, post
      window, max-cap split, merge); PluginPort integration with mock
      plugin (spawn real Port, assert aggregator receives detections);
      checkpoint-restore test.

**Verify**: `mix check`. Mock plugin timeline drives correct
start/update/end messages on `"events"`.

## Phase 5 — Event plane: extractor, index, retention, reconciliation

- [x] 5.1 [otp] `Cairn.EventExtractor` (`:temporary` under EventSupervisor):
      init → insert `active` index row, open
      `events/{camera}/{event_id}_{camera}_{ts}.mp4` (`[:write, :binary,
      :raw, :delayed_write]`), write init segment,
      `RingBuffer.drain_and_subscribe(since: started_at_pts - pre_window)`,
      write pre-window then streamed fragments (direct ring sends);
      `fsync` every ~2s of fragments; memory constant w.r.t. event length;
      finalize → close, update row (`finalized`, ended_at, bytes, labels,
      max_score), trigger 5.3, exit `:normal`. Crash → row stays `active`,
      reconciliation marks `partial`.
- [x] 5.2 [ecto] `Cairn.Events` context: `create_active/1`, `finalize/2`,
      `mark_partial/1`, `list/1` (filter camera/label/time, paginate),
      `oldest_for_cleanup/1`, prune queries. Aggregator/extractor go through
      this context only.
- [x] 5.3 [otp] Snapshot per event: async Task post-finalize — `ffmpeg -i
      clip -frames:v 1 -q:v 4 snapshots/{event_id}.jpg` (first keyframe),
      update `snapshot_path`; failure is non-fatal (log only).
- [x] 5.4 [otp] Startup reconciliation task (before cameras start; **disk is
      truth**): index rows without files → delete row; orphaned mp4s
      (parse filename schema) → adopt as `partial`; `active` rows with file
      → `partial`. Log summary counts.
- [x] 5.5 [otp] Retention pruner (hourly): per-camera retention days with
      per-label override → delete clip + snapshot + row. **Emergency disk
      cleanup** (every 60s): free space below threshold → delete oldest
      events regardless of retention, broadcast persistent UI alert
      (`"system:alerts"`).
- [x] 5.6 [otp] Extractor instrumentation (`:telemetry`): write duration,
      fragment count, bytes, finalization timing, drain size; attach a
      logger handler summarizing per event.
- [x] 5.7 [test] Extractor test: fixture fragments through a real ring →
      output file box-parses as valid fmp4 (re-use Demuxer), pre-window
      content present, no gap/duplicate at drain boundary; crash-mid-event
      → `partial` after reconciliation; retention + emergency cleanup tests
      in tmp data dir.

**Verify**: `mix check`. End-to-end on dev box: fixture-loop camera + mock
plugin ⇒ clip on disk, playable, indexed, snapshot present.

## Phase 6 — Event browser + config UI

- [x] 6.1 [liveview] `/events`: LiveView with streams-based paginated list,
      filters (camera, label, date range), snapshot thumbnails (static route
      serving `snapshots/` read-only).
- [x] 6.2 [liveview] `/events/:id`: clip playback via
      `GET /media/events/:id` controller with **HTTP Range support**
      (send_file + Range header handling — needed for `<video>` seeking);
      labels timeline + metadata panel; `partial` badge.
- [x] 6.3 [liveview] Dashboard live-event indicators (subscribe `"events"`)
      + disk-alert banner (subscribe `"system:alerts"`).
- [x] 6.4 [liveview] `/config`: read-only config render, per-camera probe
      results/warnings (populated fully in Phase 8), Reload button →
      `Config.Server.reload/0`, render returned diff/warnings/errors.
- [x] 6.5 [test] LiveView tests: event list filtering/pagination, Range
      controller (206 responses), reload flow with invalid YAML (old config
      retained, errors shown).
- [x] 6.6 [docs] `docs/design-handoff.md` for Claude Design: page map,
      per-page components/states/empty-states, data contracts (assigns,
      PubSub topics, channel protocol, hook interfaces, endpoints),
      Tailwind/daisyUI baseline, export-back instructions.
      **Done early (during Phase 5) so the design side can start in
      parallel.** GATE: final visual styling of dashboard/events/config
      is blocked on the design export returning; functional scaffolds
      keep the app demoable meanwhile.

**Verify**: `mix check`. Manual: browse and play back real recorded events.

## Phase 7 — WebRTC path

- [ ] 7.1 [infra] Add `ex_webrtc` dep (pin current release).
- [ ] 7.2 [otp] `Cairn.RTPHub` (per camera): `gen_udp` active socket on
      assigned port; parse RTP header (seq, ts, marker, payload type);
      H.264 payload inspection (NAL type incl. FU-A/STAP-A) to detect
      keyframe/SPS boundaries; maintain last-GOP replay buffer; broadcast
      `{:rtp, packet}` on `"camera:{id}:rtp"`.
- [ ] 7.3 [otp] **Spike inside task**: verify ex_webrtc `send_rtp` semantics
      for replayed GOP (sequence-number/timestamp continuity — likely needs
      seq rewriting on the outbound track). Then
      `CairnWeb.WebRTC.Session`: one process per viewer wrapping
      `ExWebRTC.PeerConnection` (sendonly H.264 track, no B-frames assumed);
      on connect: replay GOP buffer, then live RTP from PubSub; teardown on
      socket close.
- [ ] 7.4 [liveview] Signaling over a Phoenix channel or LiveView events
      (SDP offer/answer + ICE trickle); dashboard tile toggle MSE ↔ WebRTC.
- [ ] 7.5 [test] RTP parser + GOP-buffer unit tests (fixture pcap/packet
      list); session negotiation test against ex_webrtc's own APIs; manual
      checklist for browsers (Chrome/Firefox/Safari).

**Verify**: `mix check`. Manual: sub-second live view, instant first frame
on join.

## Phase 8 — Codec probe + opt-in hardware transcode

- [ ] 8.1 [port] `Cairn.Probe`: `ffprobe -v error -show_streams
      -show_format -of json` with hard timeout (Task.yield + kill via sh
      wrapper `exec`); parse codec, resolution, fps, profile; run on camera
      start and on reload; store in CameraStatus → config page + dashboard
      badge. Non-H.264 → warning: "switch camera to H.264 or enable
      transcode".
- [ ] 8.2 [port] Transcode argv variant (camera `transcode: true`):
      `-c:v h264_v4l2m2m -g {2×fps} -bf 0` replacing `-c:v copy` on all
      three outputs' source; boot-time capability check (`ffmpeg -encoders`
      contains `h264_v4l2m2m`) — if unavailable, **refuse with a clear
      per-camera error status** (no libx264 fallback, settled decision).
- [ ] 8.3 [test] Probe JSON parser fixtures (H.264/HEVC/MJPEG cams); argv
      builder tests for transcode + `-g` derivation from probed fps;
      refusal path test.

**Verify**: `mix check`. Manual: HEVC camera shows warning; opt-in transcode
works on hw with v4l2m2m (or cleanly refuses on dev box).

## Phase 9 — CPU reference plugin, release, docs, integration test

- [ ] 9.1 [infra] CPU reference plugin `plugins/cpu-reference/` (Python:
      GStreamer or PyAV decode of RTP H.264 → sample ~5 fps → small ONNX
      model via onnxruntime → contract ndjson on stdout). Runs full
      pipeline on x86 dev machines; doubles as plugin-author documentation.
      Own README + requirements.txt; not part of the Elixir release.
- [ ] 9.2 [docs] `docs/plugin-contract.md`: formal spec — argv/env inputs,
      UDP RTP input, ndjson output schema, stderr logging, restart/backoff
      expectations, mock + reference plugins as examples.
- [ ] 9.3 [infra] Release: `mix release` with `runtime.exs` reading
      `CAIRN_DATA_DIR`/`CAIRN_CONFIG`/`PORT`; boot migrator (1.6); example
      `config.example.yml`; systemd unit example; optional Dockerfile;
      docs note: **no auth in v1 — LAN-trusted; reverse proxy / HA ingress
      for anything else**.
- [ ] 9.4 [docs] README (positioning: event-clips NVR, HA-adjacent),
      config reference, deployment guide, `docs/` cross-links.
- [ ] 9.5 [test] Full-pipeline integration test (`@tag :integration`, skipped
      unless ffmpeg present): camera configured with `file://` fixture +
      `-stream_loop -1` + `-re`, mock plugin timeline ⇒ assert event clip
      written, box-valid, indexed `finalized`, snapshot exists, `"events"`
      lifecycle messages seen. Runs in CI where ffmpeg is installable.

**Verify**: `mix check` + integration tag green; release boots from tarball
with only `CAIRN_DATA_DIR`/`CAIRN_CONFIG` set.

---

## Follow-up plans (not in this plan)

- **QCS6490 Hexagon NPU plugin** (GStreamer `v4l2h264dec` + NPU element) —
  hardware-dependent; separate plan when device access is available. The
  contract (9.2) + reference plugin (9.1) are its spec.
- **HA integration** (MQTT/webhooks/HACS) — deferred per session 2; the
  `"events"` topic (4.6) is the designed extension point.
- **Continuous recording** — future fourth fragment subscriber; no refactor
  expected.
- **DetectionSource behaviour** (ONVIF/MQTT camera-side AI) — deferred; the
  aggregator input contract is the extension point.

## Risks & mitigations

- **fmp4 demuxer vs real-camera streams** (box interleaving, `sidx`,
  timescales, audio tracks present despite `-map 0:v`): mitigated by
  property-chunking tests (2.7), fixtures from multiple ffmpeg versions,
  and a "capture 30s of any misbehaving camera into a fixture" policy.
- **GOP replay over ex_webrtc** (seq/timestamp rewrite): explicit spike in
  7.3 before building the session; fallback = accept up-to-2s first-frame
  wait (GOP replay is an enhancement, not a correctness requirement).
- **Slow MSE consumers**: policy specified (3.1) — disconnect at high-water,
  client rejoins at live edge; never buffer unboundedly in the channel.
- **Backoff vs supervisor restart intensity**: dead cameras are normal
  operation → reconnect loops live inside FFmpegPort/PluginPort with
  jittered backoff; supervisor restarts are reserved for crashes.
- **SQLite contention**: negligible by design (thousands of rows, pool 2,
  WAL, busy_timeout 5s).
- **ffmpeg flag drift across versions** (`-stimeout`→`-timeout`): argv
  builder probes ffmpeg version once at boot; both handled in 2.4.

### Self-check (deep)

1. *What's the riskiest unverified assumption?* That `drain_and_subscribe`
   plus direct ring→extractor sends yields gap-free, duplicate-free clips
   under load. Addressed with a dedicated boundary test in 5.7 (assert
   fragment seq continuity across the drain boundary).
2. *What would a reviewer flag first?* The three architecture.md sketch bugs
   (PubSub self-subscription, HTTP-only reconnect flags, stderr merging) —
   already converted into corrected task specs (2.4, 2.5).
3. *What could invalidate the plan mid-flight?* ex_webrtc API mismatch for
   raw-RTP forwarding (7.3 spike, isolated to Phase 7 — MSE path is the
   product default and unaffected) and fmp4 edge cases from real cameras
   (fixture policy above). Neither blocks Phases 1–6.

## Verification (global)

- Every phase: `mix compile --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo`, `mix test` (aliased as `mix check`).
- Phase 3 and Phase 5 end with runnable milestones (live video in browser;
  event clip on disk) — verify manually with a fixture-loop camera before
  proceeding.
- Phase 9 integration test is the regression net for the whole pipeline.
