# Test Review: multiplexed plugin (plugin groups)

## Summary

Coverage of the new surface is broad and the ExUnit idioms are mostly sound
(`async: false` is correct everywhere — global Registry, global
`DetectionAggregator`, `Application.put_env(:cairn, :start_cameras)`; the
integration test's `on_exit` LIFO ordering is deliberate and correct; the
integration assertions *would* fail on misrouting). The serious problems are
(a) one assertion that passes when the behaviour it names does not happen, and
(b) untested lifecycle paths where a failure is silent rather than loud.

## Iron Law Violations

- **NO PROCESS.SLEEP** — `Process.sleep` polling helpers in
  `test/cairn/plugin_group_supervisor_test.exs:130-142` (`wait_new_pid/3`) and
  `test/integration/plugin_group_test.exs:150-162` (`wait_for/2`). `wait_for/2`
  is acceptable (it `flunk`s on exhaustion); `wait_new_pid/3` is not — see
  BLOCKER 1.

## Issues Found

### BLOCKER

- [ ] `test/cairn/plugin_group_supervisor_test.exs:99` —
  `assert wait_new_pid(a, old_a) != old_a` **passes when the group never
  restarts.** `wait_new_pid/3` returns `other` (i.e. `nil`) when it exhausts
  its 100 attempts, and `nil != old_a` is true. Concrete failure scenario:
  `apply_diff/2` calls `stop_group/1` (sync `terminate_child`) then `sync/1`,
  which reads `Cairn.Registry.ids_for_role(:plugin_group)`. Registry
  unregistration happens when the registry partition processes the `:DOWN`
  message — *asynchronously* after `terminate_child` returns. If the stale name
  is still listed, `sync/1` takes the `unless MapSet.member?(running, ...)`
  branch and **never restarts group `a`**; `whereis` then returns `nil` forever
  and the test still goes green. Fix: `assert is_pid(wait_new_pid(a, old_a))`
  and make the helper `flunk/1` on exhaustion (same helper shape as
  `wait_for/2` in the integration test). This assertion is currently the *only*
  guard on the "restart changed groups" contract.

### WARNING

- [ ] `lib/cairn/plugin_group_port.ex:116-132` (`build_routes/2` `:error`
  branch) has **no test**. A group member that is not a configured camera is
  supposed to be logged and dropped; nothing asserts the process still starts
  and routes its remaining members. This is reachable in production whenever
  `Config` resolution and `members` drift.
- [ ] **No test that stopping a group kills the OS process.**
  `terminate/2` -> `kill_port/1` (`plugin_group_port.ex:219-231`) sends
  `kill -TERM` to `os_pid` only. With the real `FFmpegPort.shell_command/2`
  wrapper (used whenever the `:command` opt is absent — i.e. every
  supervisor-started group) the `sh` wrapper may not be the leaf process, so a
  regression leaks one plugin OS process per config reload and no test notices.
  Suggested assertion: after `stop_group/1`, poll that
  `System.cmd("kill", ["-0", "#{os_pid}"])` fails.
- [ ] **Backoff policy is under-asserted.**
  `test/cairn/plugin_group_port_test.exs:132-148` proves *a* respawn happens
  but nothing covers the doubling (`backoff_ms * 2`) or the `backoff_max_ms`
  cap at `plugin_group_port.ex:211-217`. A regression making backoff constant
  at `backoff_min_ms` (1s in prod) would busy-respawn a crash-looping plugin
  and every test would still pass.
- [ ] **Stale-port messages after respawn are untested.** All the
  `handle_info` clauses guard on `%{port: port}`; a line or `:exit_status` from
  the *previous* port falls through to the catch-all at
  `plugin_group_port.ex:106`. If that guard were dropped, a dying old port's
  `:exit_status` would trigger a second `enter_backoff` and double-spawn. Add a
  test with a command that emits, exits, and is respawned while the old port
  still has buffered output.
- [ ] `test/integration/plugin_group_test.exs:58,66,72` — hard-coded
  `at_ms: 8_000 / 8_500 / 9_500` wall-clock offsets from *plugin* start, while
  the cameras are started afterwards (`:114-115`) and must have ffmpeg
  producing segments with matching `pts` before the detections land. On a
  loaded CI box where camera startup exceeds ~8 s, the detection arrives before
  any segment exists and `{:event_ended, status: :finalized}` (`:147`) can come
  back `:partial` instead. Prefer gating the timeline start on camera readiness
  (e.g. wait for `Registry.whereis(@cam_a, :ffmpeg)` before `sync`ing the
  group, and raise `at_ms`), or at minimum document the margin.
- [ ] `test/integration/plugin_group_test.exs` — the module docstring claims
  "the whole group shares one failure domain", but **no test kills the group
  process**. The behaviour that both members resume detections after a group
  crash/respawn (the main risk of multiplexing) is uncovered end to end.
- [ ] **The UDP port contract is never validated.** `--cameras-json` carries
  `udp_port` from `Config.members_for/2` (`config.ex:228-236`), while the
  camera tree forwards RTP to the port from
  `Cairn.UDPPorts.ports_for(config, index)` in `Cairn.FFmpegPort`. Both the
  unit tests (commands are `printf`/`sleep`) and the integration test (mock
  plugin explicitly "udp ignored", `mock_plugin.exs:47`) skip UDP entirely, so
  a divergence between the two index computations ships silently. At least
  assert equality of the two derivations in a config-level test.
- [ ] `test/cairn/plugin_group_supervisor_test.exs:18-21` and
  `test/integration/plugin_group_test.exs:45-48` — `on_exit` stops **every**
  registered `:plugin_group` / `:camera`, not just the ones the test started.
  If the application boot config ever defines a group, these teardowns tear
  down app-owned children and leak failures into unrelated tests. Track the
  names started by the test instead.
- [ ] `test/cairn/plugin_group_port_test.exs:80-100` — the test opens a real
  event and never cleans the global `Cairn.EventCheckpoint` ETS entry, unlike
  `test/cairn/detection_aggregator_test.exs:29` which does
  `on_exit(fn -> EventCheckpoint.delete(camera_id) end)`. Any test or boot
  reconciliation that reads `EventCheckpoint.all()` unfiltered will see the
  leftover. Add the same `on_exit`.
- [ ] `test/cairn/plugin_group_port_test.exs:99` — `refute_received` (no
  timeout, mailbox-only) is the sole guard that cam_b's sub-floor detection was
  not routed/accepted. It is ordering-dependent: it only holds because the
  single aggregator GenServer processes b's cast before a's. If the ordering of
  the two `det_line`s at `:94` is ever swapped, the refute becomes vacuous.
  Make the dependency explicit in a comment, or assert on the aggregator state
  instead.

### SUGGESTION

- [ ] `test/cairn/plugin_group_port_test.exs:72,76,116,128` — asserting on the
  raw `{:"$gen_cast", {:detections, ...}}` wire format couples the tests to
  `GenServer.cast` internals. A tiny test double implementing the
  `DetectionAggregator` call shape and forwarding `{:detections, ...}` to the
  test pid would read better and survive a cast->call change.
- [ ] `test/cairn/plugin_group_port_test.exs:120-130` — the over-long line case
  uses 9 000 bytes, i.e. exactly one `:noeol` + one `:eol`. Add a >2x
  `@max_line` (e.g. 20 000 byte) case so the multi-fragment `skipping_long_line`
  path is exercised.
- [ ] `test/cairn/plugin_group_port_test.exs:51-60` — `build_argv` is asserted
  against members the test constructs itself, duplicating
  `Config.members_for/2`. Building the group via `Config.from_map/1` would make
  this an end-to-end contract check rather than a restatement.
- [ ] `lib/cairn/config.ex:226` — `resolve_members/1` fallback (non-integer
  `udp_base_port`) is untested; a config with an invalid `udp.base_port` plus a
  group reference takes this path.
- [ ] `test/cairn/config_server_test.exs:171-217` — a member camera's
  *non-member-affecting* change (e.g. `rtsp_url`) should mark the camera changed
  but leave the group untouched. That asymmetry is the whole point of the
  separate diffs and is not asserted.
- [ ] `test/cairn/plugin_group_supervisor_test.exs:14` — `@data_dir` is created
  but never removed; add `on_exit(fn -> File.rm_rf!(@data_dir) end)` as the
  integration test does.
- [ ] `test/cairn/plugin_group_supervisor_test.exs:31` — every member is given
  the same `udp_port: 19_300`, which cannot happen in a real config and would
  mask a port-collision check if one is ever added.
- [ ] `lib/cairn/config.ex:276` — `dups = Enum.uniq(names -- Enum.uniq(names))`
  can never be non-empty for names derived from a YAML map, so the
  "duplicate plugin name" error is unreachable; the test suite (correctly) has
  no case for it. Consider deleting the branch or covering it via `from_map/1`
  with a non-map source.

## Pre-existing (one line each)

- `test/cairn/camera_supervisor_test.exs:94` — same `wait_new_pid/3`
  false-pass-on-nil shape as BLOCKER 1.
- `test/support/data_case.ex:39` — `shared: not tags[:async]` gives global
  processes DB access only for `async: false`; fine today, but silently breaks
  any future `async: true` test that touches a named global process.
