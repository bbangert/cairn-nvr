# Codebase scan: multiplexed plugin groups

Note: Cairn is an Elixir/OTP app (Phoenix is just the web/LiveView layer for
a UI, not the architectural center — no Ash). This scan focuses on
supervision, config, and port-handling conventions, not Phoenix contexts.

## 1. Config pipeline

- `lib/cairn/config.ex` — top-level `Cairn.Config` struct + `from_map/1`.
  `@known_keys` (line 15) whitelists top-level YAML keys and drives
  "unknown key" warnings (`warn_unknown/4`, line 278). **A `plugins:` key
  must be added to `@known_keys`** or it'll warn as unknown.
  - Parsing pipeline in `from_map/1` (config.ex:92-126): warn-unknown passes
    for each known sub-map, then `parse_cameras/2` (config.ex:149), then the
    struct is built, then `validate/2` (config.ex:167) runs a pipeline of
    `validate_*` functions threading an `%{errors, warnings}` accumulator.
    A new `plugins:` section should follow the same shape: a
    `parse_plugins/2` producing `[Config.PluginGroup.t()]` (mirroring
    `lib/cairn/config/camera.ex`'s `Config.Camera.parse/3` pattern — each
    entry parsed via `{struct_or_nil, acc}`, nils rejected), plus a
    `validate_plugins/2` step (name uniqueness, referenced-name resolution
    against `cameras[].plugin` when it becomes a name instead of argv,
    and UDP port math when a group's per-camera port list is derived).
  - **Name-reference resolution**: today `Config.Camera.plugin` is *always*
    inline argv (`config/camera.ex:107-120`, `parse_plugin/3` — accepts a
    command string split on whitespace or an argv list). For the new
    design, `cameras[].plugin` needs to also accept a *string that is a
    plugin group name* (bare word matching a `plugins:` key) vs. an
    inline command. That disambiguation must happen in
    `Config.from_map/1` **after** both `cameras` and `plugins` are parsed
    (camera parsing today has no visibility into the `plugins:` map — it's
    parsed standalone in `Camera.parse/3`). Two options: (a) pass the
    known plugin-group names into `Camera.parse/3` as a 4th arg so it can
    decide argv-vs-name at parse time, or (b) parse `cameras` blind to
    plugins (keep `plugin` as `{:inline, argv} | {:group, name} | nil}`)
    then cross-validate name references exist in a dedicated
    `validate_plugin_refs/2` pass. (b) matches the existing style better —
    validation is centralized in `validate/2`, not scattered into per-field
    parsers.
  - UDP port validation (`validate_udp/2`, config.ex:230) currently sizes
    the range as `ports_per_camera() * length(config.cameras)` — see UDP
    section below for how group membership changes this count.
  - `@type diff :: %{added: [...], removed: [...], changed: [...]}` is
    camera-only today (`config/server.ex:15`). A parallel
    `plugin_group_diff` type/field is needed; see below.

- `lib/cairn/config/camera.ex` — per-camera struct/parser, `@known_keys`
  whitelist pattern to copy for a new `lib/cairn/config/plugin_group.ex`
  module. Follows: `parse/3` takes `(raw, idx_or_key, acc)` returns
  `{struct | nil, acc}`, delegates `add_error`/`add_warning`/`warn_unknown`
  back to `Cairn.Config` (camera.ex:138-140) — new module should do the
  same trivial delegation, not reimplement error accumulation.

- `lib/cairn/config/server.ex` — `Cairn.Config.Server` (GenServer) holds
  the live config, drives reload. Key pieces:
  - `init/1` (server.ex:51) takes `apply_diff` as an injectable function
    defaulting to `&Cairn.CameraSupervisor.apply_diff/2` — this is the
    seam for a `&Cairn.PluginGroupSupervisor.apply_diff/2` equivalent. The
    `state` map only holds *one* `apply_diff` fun currently; adding a
    second supervisor to reconcile means either (a) adding a second
    injectable `apply_group_diff` field, or (b) having a single
    `apply_diff` callback that calls both camera and group appliers in the
    right order. Given group changes should be applied and *then* cameras
    resynced (since a camera's `plugin` group membership affects which
    group process routes its detections), ordering matters: **groups
    should be started/updated before camera trees start referencing
    them**, and **stopped/updated after old camera trees referencing a
    changed group are torn down** (mirrors `CameraSupervisor.apply_diff/2`
    which stops `removed ++ changed` cameras before calling `sync/1`).
  - `handle_call(:reload, ...)` (server.ex:78-90) computes `diff =
    diff_cameras(state.config, new_config)`, calls
    `state.apply_diff.(diff, new_config)`, then swaps state. A
    `diff_plugin_groups/2` (mirroring `diff_cameras/2`, server.ex:94-111)
    is needed: same `Map.new(by name)`, `MapSet` add/remove, `changed`
    when `old != new` (struct equality) — the design's "group needs
    restart" trigger is membership (`cameras` list), `command`,
    `min_score` per camera, or `ports` per camera — i.e. any field of the
    resolved group spec, so plain struct `!=` comparison (like
    `diff_cameras` does) is sufficient *if* the resolved-per-camera view
    (ids, udp_port, min_score) is baked into the `PluginGroup.t()` struct
    at config-load time rather than recomputed later. That argues for
    resolving `--cameras-json` payload composition (id/udp_port/min_score
    per camera) into the `Config.PluginGroup` struct itself during
    `from_map/1`, not deferred to launch time — makes diffing trivial reuse
    of the existing `!=` pattern.
  - Important ordering note: `diff_cameras/2` also treats a windows change
    as "changed" (server.ex:103, via `Config.windows/2` merge) even though
    `windows` isn't stored on `Camera` directly — same subtlety will apply
    if `min_score` overrides for a camera can come from CameraControl or
    config; but plugin routing itself only cares about the *config* view,
    not runtime CameraControl overrides (confirm this assumption in
    planning — CameraControl.min_score is a *runtime* override applied at
    the DetectionAggregator, not passed to the plugin's argv/min-score-json
    today, so it's out of scope for group launch config).

- Test coverage: `test/cairn/config_test.exs`, `test/cairn/config_server_test.exs`
  — read these before writing plugin-group parsing/diff tests to match
  fixture style (`test/support/fixtures/configs/`).

## 2. Supervision & lifecycle

- `lib/cairn/camera.ex` — `Cairn.Camera` is a `:rest_for_one` Supervisor,
  children in strict order: `:probe` (temporary Task) → `RingBuffer` →
  `FFmpegPort` → **conditionally** `PluginPort` (only `if cam.plugin`,
  camera.ex:36-40) → `RTPHub`. `:rest_for_one` means a `PluginPort` crash
  restarts only `RTPHub` (later in the list); an `FFmpegPort` crash
  restarts `PluginPort` + `RTPHub`; `RingBuffer` crash restarts everything
  downstream.
  - **Removing PluginPort from this tree for name-referenced cameras**:
    when `cam.plugin` resolves to a group reference instead of inline
    argv, the `if cam.plugin do [...] end` branch (camera.ex:36-40) must
    become `if cam.plugin == {:inline, argv}` (or similar) — i.e. only
    inline-argv cameras keep a per-camera `PluginPort` child. Name-
    referenced cameras drop straight to `RTPHub` with no plugin child in
    the per-camera tree at all. **Hazard**: `rest_for_one` restart
    semantics were implicitly relying on PluginPort sitting between
    FFmpegPort and RTPHub — removing it entirely for grouped cameras is
    fine (RTPHub just follows FFmpegPort directly), but it means an
    FFmpegPort restart (e.g. after ffmpeg dies) does **not** cause any
    restart of the group process feeding on that camera's UDP port. That
    matches the desired behavior (the group process doesn't care about a
    single camera's ffmpeg restart — it just keeps listening on the UDP
    port) but should be called out as an explicit design decision: a
    camera's ffmpeg restart never needs to restart its plugin group.
  - `Cairn.UDPPorts.ports_for(config, index)` is called in `Camera.init/1`
    (camera.ex:24) to get `{plugin_port, rtp_port}` even when there's no
    PluginPort child — `rtp_port` is always used, `plugin_port` currently
    always computed but only consumed today by `PluginPort.spawn_command/1`
    calling `ports_for` *again* independently (plugin_port.ex:164). For
    grouped cameras, the plugin_port value from this positional scheme
    needs to be threaded to whichever process launches the group (see UDP
    section — hazard on reordering).

- `lib/cairn/camera_supervisor.ex` — `Cairn.CameraSupervisor` is a
  `DynamicSupervisor`. `sync/1` (line 27) reconciles: stop cameras whose id
  isn't in `wanted`, start any not in `running`, using
  `Cairn.Registry.ids_for_role(:camera)` (registry.ex:27, a `Registry.select`
  over the `{id, role}` composite key) to discover currently-running
  cameras. `apply_diff/2` (line 50) stops `removed ++ changed` then calls
  `sync/1`. This is the exact shape to replicate for a
  `Cairn.PluginGroupSupervisor`: a `DynamicSupervisor`, `sync/1` using
  `Registry.ids_for_role(:plugin_group)` (a new registry role — see below),
  `apply_diff/2` doing stop-then-sync. Camera trees don't need to be aware
  of the group process at start time beyond knowing the pre-assigned UDP
  port for their own RTP output (ffmpeg targets `127.0.0.1:{plugin_port}`
  regardless of who's listening) — no runtime coupling needed between
  `Cairn.Camera` and the group process except via UDP + the aggregator.
  - **Ordering hazard for `Config.Server` reload**: since `apply_diff` for
    groups needs to run and settle *before* `CameraSupervisor.apply_diff`
    starts new/changed cameras that reference those groups (so the group's
    UDP listener exists before ffmpeg starts sending RTP — though this
    isn't strictly fatal since ffmpeg would just be sending into a black
    hole briefly and the group would come up moments later; UDP has no
    handshake per `docs/plugin-contract.md`). Still, doing groups-first is
    the safer ordering and mirrors "config first, everything else hangs
    off it" from `application.ex` comment (line 14).

- `lib/cairn/application.ex` — top-level supervisor `Cairn.Supervisor`,
  `:one_for_one`, children listed in strict dependency order (comment at
  line 14: "Config first... everything else hangs off it"). Order today:
  `Config.Server` → `Repo` → migrator → PubSub → `Cairn.Registry` →
  `CameraStatus` → `CameraControl` → ... → `DetectionAggregator` →
  `EventSupervisor` → **`CameraSupervisor`** → `Retention` → ... → `Boot`.
  **A new `Cairn.PluginGroupSupervisor` must be added as a sibling,
  positioned before `CameraSupervisor`** (application.ex, insert around
  line 28-29) so groups exist before `Boot` triggers `CameraSupervisor.sync/1`
  (Boot calls sync per `camera_supervisor.ex` moduledoc / boot.ex — verify
  in `lib/cairn/boot.ex`, not read in this pass but referenced by
  `CameraSupervisor` moduledoc "Boot" flow). Also needs to be positioned
  after `DetectionAggregator` since group PluginGroupPort processes will
  call `DetectionAggregator.detections/5` directly, same as PluginPort
  does today (no extra ordering requirement beyond DetectionAggregator
  already being up, which it is by line 27).

- `lib/cairn/camera_control.ex` — `Cairn.CameraControl` ETS overlay for
  `detection_enabled`/`recording_enabled`/`min_score`, keyed by camera_id,
  read hot-path by `DetectionAggregator.handle_cast/2` (not by PluginPort
  or the plugin process itself). This is unaffected by the group work:
  groups still emit raw detections per camera_id, and
  `DetectionAggregator` (unchanged) still applies `CameraControl.get(camera_id)`
  filtering downstream. No changes needed here, confirmed by tracing
  `detection_aggregator.ex:56` (`CameraControl.get(camera.id)`).

- `lib/cairn/registry.ex` — single `Registry` (`Cairn.Registry`), unique
  keys `{camera_id, role}`, `via/2` builds the via-tuple, `whereis/2` and
  `ids_for_role/1` (a `Registry.select`). Existing roles observed in the
  codebase: `:camera`, `:ring_buffer`, `:ffmpeg`, `:plugin`, `:rtp_hub`,
  and `{:extractor, event_id}` (composite role for event extractors, per
  the registry moduledoc). **Registration convention for the group
  process**: the registry is keyed by `{camera_id, role}`, which doesn't
  fit a group process 1:1 (a group serves N cameras, keyed by *group
  name*, not camera id). Two consistent options:
  1. Register the group's own Supervisor/Port under
     `Cairn.Registry.via(group_name, :plugin_group)` — i.e. reuse the same
     registry with the "id" slot holding a plugin-group name instead of a
     camera id. `ids_for_role(:plugin_group)` then naturally lists running
     group names, mirroring `ids_for_role(:camera)` used by
     `CameraSupervisor.sync/1`. **This is the pattern to follow** — it
     requires zero changes to `Cairn.Registry` itself (the key is already
     a generic `{String.t(), role}` pair, docstring just says "camera_id"
     but nothing enforces that) and matches existing `via`/`whereis`
     call-sites exactly.
  2. A second `Registry` — more code, no benefit; reject.
  - A `PluginGroupSupervisor` (per-group, `:one_for_one` or `:rest_for_one`
    with just one child — a `PluginGroupPort`) should mirror `Cairn.Camera`'s
    role as the DynamicSupervisor's child spec, registered via
    `Cairn.Registry.via(group_name, :plugin_group)`, with the inner
    `PluginGroupPort` registered via `Cairn.Registry.via(group_name, :plugin_group_port)`
    if a distinct lookup for the port process itself is ever needed (e.g.
    for tests reaching in) — compare `Cairn.Camera` which wraps a single
    `FFmpegPort`/`PluginPort` and only the outer Supervisor is registered
    under `:camera` while the inner processes get their own roles
    (`:ffmpeg`, `:plugin`). Following that: outer supervisor → `:plugin_group`,
    inner port → `:plugin_group_port`.

## 3. PluginPort mechanics to generalize

- `lib/cairn/plugin_port.ex` (196 lines) — GenServer wrapping a single
  `Port`. Key mechanics to reuse for a `PluginGroupPort`:
  - **Line framing**: `Port.open({:spawn_executable, "/bin/sh"}, [:binary,
    :exit_status, {:line, @max_line}, args: ["-c", command]])`
    (plugin_port.ex:141-147), `@max_line 8_192`. Long-line handling via
    `{:noeol, _partial}` messages sets `skipping_long_line` to drop the
    rest of an oversized line until the next `{:eol, _}` (lines 77-92) —
    copy verbatim, this logic is not camera-specific.
  - **Backoff**: `@backoff_min_ms 1_000`, `@backoff_max_ms 30_000`,
    `enter_backoff/1` (lines 175-181) does jittered exponential backoff
    (`trunc(backoff_ms * (0.5 + jitter))`, doubling capped at max) — same
    pattern in `FFmpegPort` (ffmpeg_port.ex, referenced at line 313 area),
    so this is an established codebase-wide convention, not
    plugin-specific; reuse identically.
  - **spawn via `sh -c`, stderr redirect**: `FFmpegPort.shell_command/2`
    (ffmpeg_port.ex:160-165) builds `"exec " <> shell-escaped argv <> " 2>>
    " <> shell-escaped log path`. `PluginPort.spawn_command/1`
    (plugin_port.ex:158-173) calls this with `build_argv(camera,
    plugin_port) |> FFmpegPort.shell_command(log)`, log path
    `{data_dir}/log/plugin-{camera_id}.log`
    (`Cairn.DataDir.log_dir/1`). For the group variant, the log path
    should be `plugin-{group_name}.log` (one shared log for the whole
    group process, not per-camera) — natural given one process serves N
    cameras.
  - **argv contract**: `build_argv/2` (plugin_port.ex:40-52) appends
    `--camera-id`, `--udp-port`, `--min-score-json` to the configured
    command. The **group launch replaces this entirely** with a single
    `--cameras-json` argument carrying an array of
    `{id, udp_port, min_score}` per the planned design — this is a
    *new* argv-building function, not a variant of `build_argv/2` (the
    contract shape is fundamentally different: N cameras' worth of data
    serialized as one JSON blob vs. flat flags). Suggest
    `PluginGroupPort.build_argv(cameras_with_ports)` returning
    `configured_command ++ ["--cameras-json", Jason.encode!(payload)]`.
    **This will require updating `docs/plugin-contract.md`** to document
    the new multiplexed argv contract as an alternative to the existing
    per-camera one — plugin authors need to know which mode a given
    binary should implement (probably: two entry contracts, single-camera
    argv XOR `--cameras-json`, selected by which one Cairn invokes based
    on config; a plugin binary that wants to support multiplexing declares
    it by being referenced from `plugins:` rather than `cameras[].plugin`
    inline argv).
  - **kill handling**: `kill_port/1` (plugin_port.ex:183-195) sends
    `kill -TERM` to the OS pid (fetched via `Port.info(port, :os_pid)`)
    then `Port.close/1` guarded against `ArgumentError` (already closed).
    Reuse verbatim — group process has exactly one OS child same as today,
    just serving multiple cameras internally.
  - **State shape for the group variant**: today's `%PluginPort{camera,
    config, index, port, os_pid, backoff_ms, skipping_long_line, opts}`
    (struct at plugin_port.ex:26-33) is single-camera. Group variant needs
    a `cameras` map (or list) of `%{id, windows, min_score, ...}` keyed by
    `camera_id` instead of a single `camera`/`config`/`index`. Since
    `forward/3` (plugin_port.ex:126-136) needs `Cairn.Config.windows(config,
    camera)` and the camera struct itself to call
    `DetectionAggregator.detections/5`, the group state should pre-resolve
    a `%{camera_id => {camera_config, windows}}` map at init time (from the
    `Config.PluginGroup` struct assembled during config load — see config
    section) so line-routing is a plain map lookup by the `camera_id` field
    already present in every detection line's JSON per
    `docs/plugin-contract.md`'s documented output shape (confirmed: the
    contract doc's example already includes `"camera_id": "front_door"` in
    the ndjson output, and `priv/plugins/mock/mock_plugin.exs` already
    echoes `camera_id` in its emitted JSON — line-routing by that field
    requires **no contract change on the output side**, only on the argv
    input side).
  - **Routing hazard**: `handle_line/2` (plugin_port.ex:113-124) currently
    pattern-matches `%{"pts" => pts, "dets" => dets}` and ignores any other
    key including `camera_id` (Jason.decode doesn't strict-match extra
    keys, so this already silently tolerates a `camera_id` field being
    present without using it). The group variant must add `"camera_id" =>
    camera_id` to the match and look it up in the per-camera map; **an
    unknown `camera_id` (plugin misconfiguration, or a race where a config
    reload dropped a camera from group membership but the group process
    hasn't yet restarted) needs a defined fallback** — log + drop, matching
    the existing "malformed line dropped" pattern (line 121-122), not a
    crash.

## 4. UDP port allocation

- `lib/cairn/udp_ports.ex` (29 lines) — **pure positional** allocator:
  `ports_for(config, index) = {base + 4*index, base + 4*index + 2}`, where
  `index` is the camera's position in `config.cameras` (the plain list
  index, computed at every call-site via `Enum.with_index` —
  `camera_supervisor.ex:42`, `config.ex` validate_udp doesn't call it
  directly but sizes range via `ports_per_camera() * length(cameras)`).
  **This is the sharpest hazard for the group design**: today `index` is
  recomputed fresh every time from `config.cameras`'s list order — nothing
  persists port assignments across reloads except implicitly (by camera
  staying at the same list position). If a config reload reorders the
  `cameras:` list (e.g. adds a camera in the middle, or a user manually
  reorders entries), **every camera after that point gets reassigned UDP
  ports**, and `diff_cameras/2` (server.ex:94) would need to flag them all
  as "changed" to trigger `PluginPort`/`FFmpegPort` restarts on the new
  ports. Today this already "works" only because
  `Config.Server.diff_cameras/2` compares whole `Camera` structs by `!=`
  — but the port itself isn't part of the `Camera` struct, it's derived
  positionally at supervision time from `index`, so a *pure reorder with
  no field changes* would NOT be detected as "changed" by `diff_cameras/2`
  today, yet the port assignment *would* silently shift underneath the
  running FFmpegPort processes that didn't restart. **This looks like a
  pre-existing latent bug**, not something the group feature introduces,
  but the group feature makes it worse: a group process's
  `--cameras-json` payload embeds specific `udp_port` values per camera at
  *launch* time; if a reorder shifts ports without the group restarting,
  the group's stale `udp_port` values become permanently wrong until next
  restart (whereas today at least `PluginPort` recomputes
  `ports_for(config, index)` fresh on every own-process restart/backoff
  cycle, so it self-heals faster). **Flag this hazard explicitly in
  planning** — either (a) accept it as pre-existing/out-of-scope and
  document, or (b) use this feature as the trigger to make port allocation
  stable-by-id (e.g. hash or explicit `udp_port:` config field) rather
  than positional. Given the scope note says "any pitfalls when cameras
  reorder" was explicitly asked about, this should be called out to the
  user/planner, not silently absorbed.
  - For the group launch, the `--cameras-json` payload's `udp_port` per
    camera should be computed via the exact same `Cairn.UDPPorts.ports_for/2`
    (using each camera's index within the *global* `config.cameras` list,
    not a group-local index) so port math stays centralized in one module
    and consistent with what ffmpeg is told to send to.

## 5. Tests

- Layout: `test/cairn/*_test.exs` mirrors `lib/cairn/*.ex` 1:1 (e.g.
  `plugin_port_test.exs`, `camera_supervisor_test.exs`, `config_test.exs`,
  `config_server_test.exs`). A new group feature should add
  `test/cairn/plugin_group_port_test.exs`,
  `test/cairn/plugin_group_supervisor_test.exs`, and extend
  `config_test.exs`/`config_server_test.exs` for the new `plugins:` section
  and diffing — not new top-level test directories.
- `test/cairn/plugin_port_test.exs` patterns to mirror for the group port:
  - Uses `@mock Path.absname("priv/plugins/mock/mock_plugin.exs")` +
    `@timeline` fixture JSON, invoked via `elixir <path> --camera-id ... `.
    **The mock plugin does not currently support `--cameras-json` or
    emitting multiple distinct camera_ids from one process** — it only
    accepts one `--camera-id`/`--timeline` pair and hardcodes that single
    id into every emitted line (`priv/plugins/mock/mock_plugin.exs`, uses
    `camera_id` from `--camera-id` opt in every `IO.puts`). **The group
    test plan will need either**: (a) extend `mock_plugin.exs` to accept
    `--cameras-json` and multiple `--timeline`-like per-camera schedules
    (probably a new `--timelines-json` mapping camera_id → timeline path,
    or reuse `--timeline` but require the timeline file itself to carry
    `camera_id` per entry), or (b) write a small separate mock script just
    for group tests. Given `mock_plugin.exs` is explicitly the "reference
    used by Cairn's own tests," extending it in place (adding a
    `--cameras-json` mode alongside the existing single-camera mode) is
    more consistent with "this is the canonical test fixture" than forking
    a second script — but it does mean touching a file described in
    `docs/plugin-contract.md` as a *reference implementation example*, so
    keep the two modes clearly separated in that file's own comments.
  - Tests use `start_supervised!({PluginPort, camera: ..., config: ...,
    index: 0, command: <full shell string>, aggregator: agg})` — the
    `command:` opt (plugin_port.ex `spawn_command/1`, line 158-173)
    bypasses `build_argv`/`shell_command` entirely for test injection.
    **The group port should keep the same `command:` opt override
    convention** for direct shell-string test injection (see
    `plugin_port_test.exs` lines 46-53, 76-83, 102-114 — all three tests
    inject a raw command string rather than going through real argv
    building).
  - `DetectionAggregator` is started via `start_supervised!({DetectionAggregator,
    name: nil, start_extractor: fn ..., finalize_extractor: fn ...})` with
    injected fakes — same pattern applies untouched for group tests since
    `DetectionAggregator.detections/5` doesn't change signature.
  - Async: `use ExUnit.Case, async: false` in both `plugin_port_test.exs`
    and `camera_supervisor_test.exs` — Ports/OS processes and shared
    Registry state make these non-parallelizable; group tests should
    follow suit (`async: false`).
- `test/cairn/camera_supervisor_test.exs` patterns for the group
  supervisor test: helper `config(cameras, base)` builds minimal
  `%Config{}` fixtures; `wait_new_pid/3` polling helper (lines 85-97) for
  asserting a restart actually produced a new pid — copy this poll-loop
  pattern for asserting group process restarts on `apply_diff`.
- No `Mox`/`Hammox` observed in these files — tests use plain injected
  functions (`start_extractor:`, `finalize_extractor:`, `aggregator:`)
  passed as `opts`/state fields, i.e. this codebase's mocking convention is
  "accept a function in opts, default to the real module" rather than a
  mocking library. Follow this convention for anything the group port or
  supervisor needs to fake in tests (e.g. inject `aggregator:` the same
  way `PluginPort` does).

## Summary of concrete hazards to flag in planning

1. **UDP port reordering hazard is pre-existing but sharper for groups**
   (`lib/cairn/udp_ports.ex` positional allocation + `diff_cameras/2` not
   detecting pure reorders) — decide whether to fix now or explicitly defer.
2. **`cameras[].plugin` disambiguation** (inline argv vs. group name
   reference) needs a config-parsing-order fix since `Camera.parse/3` runs
   independently of `plugins:` parsing today.
3. **Reload ordering**: groups must be created/updated before dependent
   cameras (re)start, and old groups torn down after old camera
   references are gone — `Config.Server`'s single `apply_diff` seam
   (server.ex:53, :82) needs to become two ordered calls or one combined
   callback.
4. **Registry role reuse**: use the existing `Cairn.Registry` with group
   name in the "camera_id" slot and new roles `:plugin_group` /
   `:plugin_group_port` — no registry code changes needed.
5. **Mock plugin extension required** for any group-path integration test
   (`priv/plugins/mock/mock_plugin.exs` has no multi-camera mode today).
6. **`docs/plugin-contract.md` update required** for the new
   `--cameras-json` argv contract — output-side (`camera_id` in each
   ndjson line) already matches the design with zero changes needed.
</content>
