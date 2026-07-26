# Plan: Multiplexed plugin contract (single binary, multiple streams)

**Status**: READY
**Date**: 2026-07-25
**Source**: `.claude/plans/multiplexed-plugin/interview.md` (12/12),
`research/codebase-scan.md`, `research/web-research.md`
**Depth**: deep (config + OTP supervision + Rust plugin + contract docs)

## Context

Exclusive-access accelerators (Coral Edge TPU via `libedgetpu`) can only be
held by one process, so the current one-process-per-camera plugin contract can
never share them. This plan extends the contract so one supervised plugin
process serves N camera streams: N RTP/UDP inputs in, one shared ndjson stdout
(every line already carries `camera_id`) out. Cairn gains a named top-level
`plugins:` config map, one supervised child per named group, and routing by
`camera_id` instead of by port/process. Proven with `plugins/cairn-detect`'s
existing ONNX backend running N cameras in one process. The Coral TFLite
backend itself is an explicitly separate follow-up plan.

## Settled decisions (from interview — do not relitigate)

- **Config shape**: top-level `plugins:` map (name → command); a camera opts
  in with `plugin: <name>`. Inline argv commands keep today's
  per-camera-process behavior exactly — the multiplexed path is additive.
- **Argv convention**: group launches get one `--cameras-json` argument
  (JSON array of `{id, udp_port, min_score}` per camera) replacing
  `--camera-id`/`--udp-port`/`--min-score-json`.
- **Routing**: the group port owner routes each stdout line by its
  `camera_id` to `Cairn.DetectionAggregator` with that camera's
  config/windows. Unknown/missing `camera_id` → log + drop.
- **Restart policy**: groups restart **only on config change** (membership,
  command, min_score, ports). Runtime camera stop/start, CameraControl
  toggles, and ffmpeg crash/backoff never touch the group — it sees RTP
  silence and resyncs on the next keyframe.
- A named plugin referenced by one camera still launches multiplexed
  (`--cameras-json` with one entry) — config shape decides, not member count.
- **Failure domain accepted for v1**: one poisoned stream/panic takes down
  the whole group until the contract's exit-and-backoff restart. No new
  mitigations (per-stream isolation, stall watchdog) in this plan.
- **Reorder fix in scope**: `diff_cameras/2` must treat a positional index
  change (hence UDP port shift) as "changed" — pre-existing latent bug that
  groups make worse because `--cameras-json` bakes ports in at launch.
- UDP allocation stays positional and unchanged (4 ports/camera,
  `lib/cairn/udp_ports.ex`).

## Decisions made in this plan (review these)

1. **Name-vs-inline disambiguation**: a `plugin:` string **without
   whitespace** is a group-name reference (config **error** if undefined —
   the interview requires typo detection); a string with whitespace or an
   argv list is inline. Escape hatch for a genuine zero-flag inline command:
   write it as a one-element list (`plugin: ["./my-plugin"]`). ⚠ Small
   compat break: a bare single-token string command (`plugin: my-bin`) was
   inline before and becomes an "undefined plugin name" error — judged
   acceptable because real plugin commands carry flags; called out in the
   contract doc.
2. **Internal representation**: `Config.Camera.plugin` becomes
   `nil | {:inline, argv} | {:group, name}`. Consumers updated:
   [camera.ex:36](lib/cairn/camera.ex#L36),
   [plugin_port.ex:42](lib/cairn/plugin_port.ex#L42),
   [camera_controller.ex:52](lib/cairn_web/controllers/api/camera_controller.ex#L52),
   [config_live.ex:111](lib/cairn_web/live/config_live.ex#L111).
3. **Members resolved at config-load time**: `Config.PluginGroup` bakes
   `members: [%{id, udp_port, min_score}]` (ports via
   `Cairn.UDPPorts.ports_for/2` on the camera's global index) into the
   struct during `from_map/1`, so `diff_plugin_groups/2` is plain struct
   `!=` — same pattern as `diff_cameras/2`.
4. **No per-group wrapper supervisor**: `PluginGroupSupervisor`
   (DynamicSupervisor) supervises `PluginGroupPort` GenServers directly —
   a group is a single process, a wrapper adds nothing. Registry:
   `Cairn.Registry.via(group_name, :plugin_group)` (no registry changes).
5. **Reload seam**: `Config.Server` gains a second injectable
   `apply_group_diff` (default `&Cairn.PluginGroupSupervisor.apply_diff/2`),
   applied **before** the camera diff. Strict interleaving is not
   load-bearing — UDP is handshake-free, ffmpeg sending into a not-yet-open
   listener is harmless for the moment it lasts.
6. **Group name validation**: same regex as camera ids
   (`[a-z0-9][a-z0-9_-]*`), unique, and **disjoint from camera ids** (both
   namespaces feed `plugin-{name}.log`).
7. **Per-stream resilience in cairn-detect (new — interview gap)**: the
   current single-camera behavior "RTP open failure / 30 s read timeout →
   process exit" ([rtp.rs:64](plugins/cairn-detect/src/rtp.rs#L64),
   [rtp.rs:144-166](plugins/cairn-detect/src/rtp.rs#L144-L166)) is **wrong
   per-stream in a group**: a stopped member camera is a *normal* state per
   the restart policy, and letting one silent stream kill the process would
   crash-loop the whole group. In multiplexed mode each stream runs an
   open → decode → on-error log + re-open loop forever; only truly
   unrecoverable errors (model load, inference panic) exit the process.
   Single-camera mode keeps today's exit semantics unchanged.
8. **Mock plugin**: extend `priv/plugins/mock/mock_plugin.exs` in place
   with a `--cameras-json` mode (canonical test fixture stays canonical);
   in that mode timeline entries carry their own `"camera_id"`.

## Non-goals (v1)

- Coral TFLite/`libedgetpu` backend (separate follow-up plan owns the
  backend-trait-vs-sibling-plugin decision).
- Failure-domain mitigations beyond contract backoff.
- Dynamic camera add/remove without group restart (contract forbids mid-run
  config changes).
- TPU scheduling/throughput work; stable-by-id UDP allocation.

## Architecture

```
config.yml                       Cairn.Application
  plugins:                         ├─ ...
    detect: {command}              ├─ Cairn.DetectionAggregator
  cameras:                         ├─ Cairn.PluginGroupSupervisor   (new, before CameraSupervisor)
    - plugin: detect  ──┐          │    └─ PluginGroupPort "detect" ──── one OS process
    - plugin: detect  ──┤          │         --cameras-json '[{front_door,17000,...},
    - plugin: [inline] ─┼──┐       │                           {driveway,17004,...}]'
                        │  │       ├─ Cairn.CameraSupervisor
                        │  │       │    ├─ Camera front_door: Ring → FFmpeg → RTPHub   (no plugin child)
                        │  │       │    ├─ Camera driveway:   Ring → FFmpeg → RTPHub   (no plugin child)
                        │  └───────│    └─ Camera garage:     Ring → FFmpeg → PluginPort → RTPHub
                        │          │
   stdout ndjson w/ camera_id ─────┴─► route by camera_id → DetectionAggregator
```

Detection lines flow: group process stdout → `PluginGroupPort.handle_line`
→ lookup `%{camera_id => {camera, windows}}` map → 
`DetectionAggregator.detections/5` (unchanged; CameraControl overlay
unchanged). ~100 lines/sec at 20 cams × 5 fps — inline routing in one
GenServer is comfortably sufficient (research-validated).

## Tasks

### Phase 1 — Config model `[config]`

- [x] **T1** New `lib/cairn/config/plugin_group.ex` — `Cairn.Config.PluginGroup`
  struct `%{name, command, members: []}`; `parse/3` mirroring
  `Config.Camera.parse/3` conventions (`{struct_or_nil, acc}`, `@known_keys
  ~w(command)`, delegate `add_error`/`add_warning`/`warn_unknown` to
  `Cairn.Config`). `command` accepts string (split) or argv list, required.
- [x] **T2** [config.ex](lib/cairn/config.ex) — add `"plugins"` to
  `@known_keys` (line 15); `plugin_groups: []` struct field;
  `parse_plugins/2` over the `plugins:` map; after the struct is built,
  a resolve pass: (a) camera `plugin` raw values → `{:inline, argv} |
  {:group, name}` per decision 1, error on undefined name; (b) fill each
  group's `members` (id, udp_port via `UDPPorts.ports_for(config,
  global_index)`, min_score) for referencing cameras in config order.
  New `validate_plugins/2`: name regex, uniqueness, disjoint from camera
  ids. A group referenced by zero cameras parses fine and simply gets
  empty `members` (won't launch).
- [x] **T3** [config/camera.ex](lib/cairn/config/camera.ex) —
  `parse_plugin/3` produces the pre-resolution form (`{:inline, argv}` for
  lists/multi-token strings, `{:pending, name}` for single-token strings,
  resolved in T2); update moduledoc. Update the two web consumers:
  `detection:` flag ([camera_controller.ex:52](lib/cairn_web/controllers/api/camera_controller.ex#L52)
  — any non-nil plugin) and config display
  ([config_live.ex:111](lib/cairn_web/live/config_live.ex#L111) — inline →
  joined argv, group → name).
- [x] **T4** [config/server.ex](lib/cairn/config/server.ex) — **reorder
  fix**: `diff_cameras/2` also marks a camera "changed" when its index in
  the cameras list changed (ports shift). New `diff_plugin_groups/2`
  (Map.new by name, MapSet add/remove, `!=` for changed — members bake
  ports/min_score so this catches everything). `init/1` gains injectable
  `apply_group_diff` (default `&Cairn.PluginGroupSupervisor.apply_diff/2`);
  `handle_call(:reload, ...)` computes both diffs and applies groups
  first. `reload/1` return keeps its shape (camera diff), group diff
  logged.
- [x] **T5** [test] Extend `test/cairn/config_test.exs` (plugins parsing,
  name/inline disambiguation incl. single-token error + list escape hatch,
  member resolution with ports, validation errors, zero-ref group) and
  `test/cairn/config_server_test.exs` (`diff_plugin_groups/2`, reorder →
  changed for both cameras and groups, group-before-camera apply order via
  injected fns). Fixture in `test/support/fixtures/configs/`.
  Phase 1 notes: `apply_group_diff` default uses
  `apply(Cairn.PluginGroupSupervisor, :apply_diff, ...)` via
  `default_apply_group_diff/2` (forward ref, credo-disabled line — Phase 2
  T8 inlines the call); reload only calls apply_group_diff on NON-EMPTY
  group diff (else Phase 1 would crash on missing module — revisit in T7/T8
  if unconditional sync wanted); camera.ex:36 `if cam.plugin` still truthy
  for `{:group, _}` until T8 narrows to `{:inline, _}`; fixture
  `test/support/fixtures/configs/plugin_groups.yml`; 223 tests green.

### Phase 2 — Supervision & routing `[otp]`

- [x] **T6** New `lib/cairn/plugin_group_port.ex` — `Cairn.PluginGroupPort`
  GenServer: copy framing (`{:line, @max_line}`, long-line skip), jittered
  backoff, `spawn_command`/`kill_port` verbatim from
  [plugin_port.ex](lib/cairn/plugin_port.ex); state holds `group` +
  pre-resolved `%{camera_id => {camera, windows}}` map built at init from
  config. `build_argv(group)` = `group.command ++ ["--cameras-json",
  Jason.encode!(members)]`. `handle_line/2` requires `"camera_id"` in the
  decoded map; known id → forward with that camera's config/windows;
  unknown/missing → log + drop. Log path `plugin-{group_name}.log`. Name
  via `Cairn.Registry.via(name, :plugin_group)`. Keep `command:` /
  `aggregator:` / `backoff_*` opt seams for tests.
- [x] **T7** New `lib/cairn/plugin_group_supervisor.ex` — DynamicSupervisor
  mirroring [camera_supervisor.ex](lib/cairn/camera_supervisor.ex):
  `sync/1` (wanted = groups with `members != []`, running via
  `Registry.ids_for_role(:plugin_group)`), `apply_diff/2` = stop
  `removed ++ changed` then `sync/1`, honor the `:start_cameras` app-env
  gate (same flag — test envs must not spawn real processes).
- [x] **T8** Wire in: [application.ex](lib/cairn/application.ex) child
  before `CameraSupervisor`; [boot.ex](lib/cairn/boot.ex)
  `PluginGroupSupervisor.sync(config)` before `CameraSupervisor.sync/1`;
  [camera.ex:36](lib/cairn/camera.ex#L36) only `{:inline, argv}` cameras
  get a `PluginPort` child (group cameras: Ring → FFmpeg → RTPHub);
  [plugin_port.ex:42](lib/cairn/plugin_port.ex#L42) `build_argv` extracts
  argv from `{:inline, argv}`.
- [x] **T9** [test] New `test/cairn/plugin_group_port_test.exs` (mirror
  `plugin_port_test.exs` style: `async: false`, injected `command:` shell
  string + `aggregator:`): lines routed to correct camera's
  config/windows across ≥2 cameras, unknown `camera_id` dropped without
  crash, malformed/long lines, backoff respawn. New
  `test/cairn/plugin_group_supervisor_test.exs` (mirror
  `camera_supervisor_test.exs`, `wait_new_pid` poll pattern): sync
  starts/stops, apply_diff restarts on member/command change, zero-member
  group not started.
  Phase 2 notes: group diff now applied UNCONDITIONALLY on reload (guard +
  apply/3 workaround removed, direct call); routing map init skips (logs
  :error) members missing from cameras instead of crashing; port tests use
  `aggregator: self()` and assert the `$gen_cast` tuple; 236 tests green.

### Phase 3 — Mock plugin + integration `[test]`

- [x] **T10** [mock_plugin.exs](priv/plugins/mock/mock_plugin.exs) — add
  `--cameras-json` mode alongside the single-camera mode (clearly
  commented as the two contract variants): parse the JSON array, timeline
  entries carry `"camera_id"`, emitted lines echo it. Single-camera mode
  byte-for-byte unchanged.
- [x] **T11** [test] Group integration test: one mock process in
  multiplexed mode, 2 cameras, distinct timelines → assert
  DetectionAggregator receives each camera's detections with the right
  camera/windows; camera restart (stop/start one member) does not restart
  the group process (pid stable).
  Phase 3 notes: new `test/integration/plugin_group_test.exs` (GenServer
  AND OS pid stability asserted); mock keeps one shared emit closure —
  per-entry `camera_id` only in --cameras-json mode; test cleans
  events/snapshots dirs on exit (pre-existing orphan-clip hazard that
  crashes next run's Boot reconciliation — repo-wide, worth a follow-up).

### Phase 4 — cairn-detect N-stream `[rust]`

- [x] **T12** [main.rs](plugins/cairn-detect/src/main.rs) — new
  `--cameras-json` arg (serde struct `{id, udp_port, min_score}`),
  mutually exclusive with `--camera-id`/`--udp-port`/`--min-score-json`
  (clap `conflicts_with`, one of the two forms required). Single-camera
  path preserved exactly.
- [x] **T13** Multi-stream runtime: per-camera decode thread (own
  `rtp::open_stream` + `decode::run`, own bounded(1) latest-sample slot);
  `Sample` (or a wrapper) gains the camera identity; one inference thread
  `crossbeam_channel::Select`s across slots (inherent fairness at 5 fps),
  applies that camera's `ScoreFloors`, emits with that camera's id.
- [x] **T14** Per-stream resilience (decision 7): in multiplexed mode a
  stream's open failure / read timeout / decode error → `eprintln` + delay
  + re-open loop, never process exit; keep the existing
  give-up-and-exit behavior in single-camera mode. Inference-thread errors
  stay fatal (exit 1 → Cairn backoff-restarts the group).
- [x] **T15** [rust tests] cameras-json parsing (valid/invalid/conflict
  with single-camera flags), per-camera floor selection; existing tests
  stay green (`cargo test`).
  Phase 4 notes: new `src/multiplex.rs` isolates the multiplexed error
  policy (per-stream eternal re-open, 5s→30s backoff, healthy-60s reset,
  throttled logs; decode-thread panic drops the slot, exit only when ALL
  streams gone; inference errors fatal). Camera identity = Select slot
  index (Sample untouched). Deviations: single-camera total-open-failure
  stderr differs by one line (exit semantics identical);
  `--min-score-json` default moved from clap to parse site. 45 cargo
  tests green; smoke-tested exit-vs-survive on dead ports; live 2-feeder
  run 113/113 lines balanced (Select fairness risk settled).

### Phase 5 — Contract docs & verification `[docs]`

- [x] **T16** [docs/plugin-contract.md](docs/plugin-contract.md) — new
  "Multiplexed plugins" section: `plugins:` config shape, `--cameras-json`
  argv contract (schema, room for future per-camera fields), `camera_id`
  **required** in output lines for multiplexed plugins (optional echo for
  per-camera ones, as today), shared `plugin-{name}.log`, lifecycle
  (restart only on config change; member ffmpeg restarts are RTP silence,
  resync mid-GOP; whole-group failure domain), the single-token
  name-vs-inline rule + list escape hatch.
- [x] **T17** Full verification: `mix check` (compile --warnings-as-errors,
  format, credo, test) at repo root; `cargo fmt --check && cargo clippy &&
  cargo test` in `plugins/cairn-detect/`; grep that no call site still
  treats `camera.plugin` as a bare argv list.
  Phase 5 notes: mix check ✓ (236 tests), cargo fmt/clippy/test ✓ (45
  tests), argv-grep clean (all sites tagged-tuple aware). BONUS live e2e:
  full app booted with 2 real cameras (reolink_main + rtsp://192.168.2.31)
  in one `detect` group — single process with --cameras-json, both streams
  software-decoding, 60 s clean window, zero routing warnings. Doc
  follow-ups flagged: config.example.yml lacks plugins: block;
  docs/architecture.md still says one-process-per-camera.

## Verification

- After each Elixir task: `mix compile --warnings-as-errors && mix format && mix test test/cairn/<touched>_test.exs`
- After each Rust task: `cargo clippy && cargo test` in `plugins/cairn-detect/`
- Final: `mix check` + full `cargo test` (T17).

## Risks / open items

- **Single-token compat break** (decision 1) — flagged for user review; the
  alternative (fall back to inline when no group matches) silently turns
  typos into spawn-failure crash loops.
- **Reorder fix is user-visible**: a pure reorder of `cameras:` now
  restarts the shifted cameras/groups on reload. Correct (their ports
  moved) but new behavior worth a line in the reload log.
- **Select fairness in cairn-detect**: `Select` across N slots is ready-set
  random, not strict round-robin; at ~6–10 ms/invoke vs 200 ms sample
  intervals starvation is implausible, but T13's test should sanity-check
  all cameras emit.
- **Group startup vs slow members**: with per-stream re-open loops (T14) a
  group starts producing for live cameras even while one member is dark —
  matches the restart-policy intent; empty-`dets` liveness now only proves
  *the process* lives, not every stream (accepted v1 failure domain).

### Self-check (deep)

1. *What breaks existing users?* Only the single-token `plugin:` string
   edge (decision 1); every existing multi-token/list config parses
   identically, and per-camera contract/argv is untouched.
2. *What's the riskiest task?* T13/T14 (Rust multi-stream + resilience) —
   it inverts a deliberate single-camera design choice (exit on stall);
   mitigated by keeping the two modes' error paths visibly separate.
3. *What did we not research?* Live behavior of N ffmpeg RTP senders into
   one process's N sockets on loopback (buffer pressure at high bitrate ×
   N). Research covered single-socket sizing (4 MB rcvbuf); T13 keeps
   per-stream sockets so the math is unchanged per stream — verify with a
   2-camera live run before merging Phase 4.

## Follow-ons (out of scope, noted)

- Coral TFLite/`libedgetpu` backend plan (consumes this contract).
- Per-stream isolation in cairn-detect / whole-group stall watchdog /
  per-camera staleness in CameraStatus — if the shared failure domain bites.
- Stable-by-id UDP port allocation (would obsolete the reorder-restart).
