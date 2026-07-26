# Code Review: multiplexed plugin (working tree, base HEAD)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 1 blocker-ish correctness gap, 3 warnings, 4 suggestions

Scope: `lib/cairn/config/plugin_group.ex`, `lib/cairn/plugin_group_port.ex`,
`lib/cairn/plugin_group_supervisor.ex`, plus changed regions of
`config.ex`, `config/server.ex`, `config/camera.ex`, `camera.ex`, `boot.ex`,
`application.ex`, `plugin_port.ex`, `config_live.ex`, `mock_plugin.exs`.
Settled design decisions from the WHY-context are not flagged.

---

## Blockers

### 1. Group routes cache stale event windows across reloads

`lib/cairn/plugin_group_port.ex:66` + `:116-132` resolve
`{cam, Config.windows(config, cam)}` **once at init**.
`lib/cairn/config/server.ex:132-144` decides group restarts by comparing
`%Config.PluginGroup{}` structs, whose `members` carry only
`{id, udp_port, min_score}` (`lib/cairn/config/plugin_group.ex:17-25`).
Event windows are not in that fingerprint, so a window change never restarts
the group.

Failure scenario:

1. `config.yml` has `events: {post_window_seconds: 30}` and cameras in group
   `yolo`.
2. Operator lowers it to `5` (or sets a per-camera `pre_window_seconds`) and
   hits reload.
3. `diff_cameras` marks every camera changed (`camera_changed?` compares
   `Config.windows/2`) → camera trees restart with the new `RingBuffer`
   pre-window.
4. `diff_plugin_groups` sees an identical group → **no restart**.
5. `PluginGroupPort` keeps forwarding the old `%{pre: _, post: 30, max: _}`
   to `DetectionAggregator.detections/5`, which uses it verbatim for
   `schedule(:post_window, ...)` / `schedule(:max_event, ...)`
   (`lib/cairn/detection_aggregator.ex:149-150`).

Result: clips for grouped cameras silently keep the *old* post/max windows
until the group process happens to restart, while the ring buffer already
uses the new pre-window — the two halves of the same event disagree. This is
a regression relative to inline `PluginPort`, which is restarted with its
camera (`lib/cairn/camera.ex:47-49`) and therefore always fresh.

The same staleness applies to `state.config` used for the log path at
`plugin_group_port.ex:196-200` (a `data_dir` change is not picked up until
the OS process respawns) and to the cached `%Camera{}` struct itself for any
field outside `{id, udp_port, min_score}`.

Two workable fixes:

```elixir
# A. cheapest — make the diff see what the group actually caches
# lib/cairn/config/server.ex
defp group_fingerprint(config, group) do
  {group.command, group.members,
   Enum.map(group.members, fn m ->
     cam = Enum.find(config.cameras, &(&1.id == m.id))
     {cam, Config.windows(config, cam)}
   end)}
end
```

```elixir
# B. nicer — refresh without dropping the video stream
# lib/cairn/plugin_group_port.ex
def update_config(name, config),
  do: GenServer.cast(Cairn.Registry.via(name, :plugin_group), {:config, config})

def handle_cast({:config, config}, state),
  do: {:noreply, %{state | config: config, routes: build_routes(state.group, config)}}
```

B is preferable: windows/data_dir are pure Elixir-side state, so an argv-
identical group need not tear down its OS process at all.

---

## Warnings

### 2. Per-line `Logger.warning` on a multiplexed process is a log-flood vector

`lib/cairn/plugin_group_port.ex:140-146` and `:155-158` warn on *every*
malformed line and *every* line for an unknown `camera_id`. Inline
`PluginPort` has the same shape, but a group aggregates N cameras: a plugin
that misspells one `camera_id` and emits at 30 fps produces 30 warnings/sec
indefinitely, and the group has no per-camera failure isolation to stop it.
At minimum sample/dedupe (log once per unknown id, or once per N seconds per
id) — keep a counter in state and log on transition.

### 3. `apply_diff/2` stops groups even when `start_cameras: false`

`lib/cairn/plugin_group_supervisor.ex:50-53`: `stop_group/1` runs
unconditionally, but the restart path funnels through `sync/1`, which is
gated on `Application.get_env(:cairn, :start_cameras, true)`
(`:29-35`). In a test/embedded setup with `start_cameras: false`, a reload
would terminate any manually-started group and never bring it back. Mirrors
`CameraSupervisor.apply_diff/2:50-53`, so it is pre-existing in shape, but
the new code copies it — put the gate at the top of `apply_diff/2` instead.

### 4. Group-restart / OS-process teardown race on the shared UDP ports

`stop_group/1` → `DynamicSupervisor.terminate_child/2` → `terminate/2` →
`kill_port/1` sends only `SIGTERM` and does not wait
(`plugin_group_port.ex:219-231`). `sync/1` then starts the replacement
immediately, and the new plugin binds the *same* member UDP ports. If the
old plugin ignores/slow-handles `SIGTERM`, the new one fails to bind and
falls into backoff — a group restart that should be sub-second becomes 1-30 s
of dead detection for **every** member camera at once (vs. one camera in the
inline case). The `kill_port` mechanics duplication is accepted per the WHY
context, but the blast radius is not the same; consider awaiting the port's
`:exit_status`/`DOWN` (bounded wait, then `kill -KILL`) before returning from
`terminate/2`.

---

## Suggestions

### 5. Double error message for a group whose `command` is invalid

`lib/cairn/config.ex:176-194` drops a `PluginGroup` that fails to parse
(returns `nil`), so its name never reaches `names` in `resolve_plugins/2`
(`:199-205`). A group with a missing `command` therefore produces both
`plugin yolo: command is required` and
`camera front: unknown plugin "yolo" — define it under plugins: ...`, the
second of which is actively misleading (it *is* defined). Build `names` from
the raw `plugins:` keys rather than from successfully-parsed groups.

### 6. Dead branch in `build_routes/2`

`lib/cairn/plugin_group_port.ex:124-130`: `members` are constructed by
`Config.members_for/2` from `config.cameras`, and the group is always started
with the same `%Config{}` (`plugin_group_supervisor.ex:57`), so the `:error`
branch cannot fire. Either drop it or, if it is meant as a
defence-in-depth assertion, say so — a `Logger.error` that can never run
reads as a live invariant to the next maintainer.

### 7. `@type t :: %__MODULE__{}` erases the struct's field types

`lib/cairn/config/plugin_group.ex:27`. The `member/0` type right above it is
fully specified, which makes the untyped `t/0` stand out; with the 1.20+
compiler checker and Dialyzer both consuming these, spelling out
`%__MODULE__{name: String.t(), command: [String.t()], members: [member()]}`
is cheap. (Matches the existing `Config.Camera` style, so low priority.)

### 8. `unless` in the new/touched code

`plugin_group_port.ex:90`, `plugin_group_supervisor.ex:44` use `unless`,
deprecated since 1.18. `if not ...` / `if ... == false` reads the same and
avoids the warning once the deprecation hardens.

---

## Verified-good (no action)

- `Camera.plugin_child/3` correctly omits `PluginPort` for `{:group, _}`
  cameras while ffmpeg still emits RTP to the positional plugin port
  (`ffmpeg_port.ex:153`) — the group binds the identical port via
  `Config.members_for/2:228-236`, which uses the same
  `Enum.with_index/1` ordering as `CameraSupervisor.do_sync/1:41-45`.
- `plugins:` name/camera-id collision is validated (`config.ex:273-288`),
  which is required since both share the `plugin-{name}.log` namespace and
  the `Cairn.Registry` key space.
- `Application` child order puts `PluginGroupSupervisor` before
  `CameraSupervisor` (`application.ex:29-31`), consistent with `Boot.run/1`.
- Test coverage exists for all three new modules plus an integration test and
  a config fixture.

## Pre-existing (unchanged files, one-line each)

- `lib/cairn/camera_supervisor.ex:50` — `apply_diff/2` stops children outside
  the `start_cameras` gate (same shape as finding #3).
- `lib/cairn/plugin_port.ex:175-181` — backoff never resets after a long
  healthy run, so a plugin that crashes rarely still creeps to the 30 s cap.
</content>
</invoke>
