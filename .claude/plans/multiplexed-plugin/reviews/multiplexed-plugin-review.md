# Review: multiplexed-plugin (2026-07-25)

**Verdict: PASS WITH WARNINGS** *(updated after fix pass, 2026-07-25)* —
both blockers and W1/W2 are FIXED and re-verified (`mix check` 239 tests,
cargo 48 tests, live 2-camera + dead-port smoke re-runs). W3–W6 and the
suggestions remain open as accepted-v1/follow-ups.

Fix summary: B1 → `PluginGroupPort.refresh/3` cast rebuilds routes on every
reload without touching the OS process (regression tests proven to fail
without the fix); B2 → `wait_new_pid` now flunks on exhaustion in both
supervisor test files; W1 → drop warnings throttled (1st + every 100th,
64-char id cap, counter resets on respawn); W2 → true latest-wins slots via
a `SampleSink` seam (`LatestSlot` mutex + wakeup channel — single-camera
`try_send` semantics preserved exactly, disconnect liveness preserved).

Original verdict: REQUIRES CHANGES — 2 blockers (both independently
code-verified by the orchestrator), 6 warnings after dedup, 6 suggestions.
Requirements coverage is complete; no scope creep.

Reviewers: elixir-reviewer, security-analyzer, testing-reviewer,
requirements-verifier, rust-reviewer (general-purpose). Raw output in this
directory (`elixir.md`, `security.md`, `testing.md`, `requirements.md`,
`rust.md`).

## Requirements Coverage

**29 MET · 0 UNMET · 0 non-goal violations** (from `requirements.md`).
- T17 was reported PARTIAL only because the verifier didn't re-run
  format/credo/clippy itself; the orchestrator ran the full `mix check`
  (236 tests) and `cargo fmt --check && cargo clippy && cargo test` (45
  tests) clean in this session → effectively MET.
- T13 deviation (camera identity = Select slot index instead of a field on
  `Sample`) is functionally equivalent and disclosed in the plan notes.

## Blockers

**B1 — Group routes go stale across config reloads** — HIGH CONFIDENCE
(flagged independently by elixir-reviewer and security-analyzer; verified).
`PluginGroupPort.build_routes/2` resolves `{cam, Config.windows(config,
cam)}` once at init ([plugin_group_port.ex:116-122](lib/cairn/plugin_group_port.ex#L116-L122)),
but `diff_plugin_groups/2` ([config/server.ex:132-144](lib/cairn/config/server.ex#L132-L144))
restarts a group only when `{name, command, members}` changes, and members
carry only `{id, udp_port, min_score}`. Changing `events.post_window_seconds`
(global or per-camera), `max_event_seconds`, retention, or any other camera
field restarts the camera tree, reports reload success — and the group keeps
forwarding the pre-reload camera struct and windows to
`DetectionAggregator.detections/5` until the OS process happens to respawn.
Inline `PluginPort` has no such gap (it restarts with its camera).
*Recommended fix:* refresh routes in place — a `handle_cast(:refresh,
new_config)` sent by `PluginGroupSupervisor.apply_diff/2` (or `sync/1`) that
rebuilds the routing map without touching the OS process. Windows/camera
structs are pure Elixir-side state; restarting an accelerator-holding
process for them would violate the restart-only-on-config-change intent.

**B2 — Vacuous restart assertion in the group supervisor test** (testing;
verified). [plugin_group_supervisor_test.exs:99](test/cairn/plugin_group_supervisor_test.exs#L99)
`assert wait_new_pid(a, old_a) != old_a` — `wait_new_pid/3` returns `nil`
on exhaustion and `nil != old_a` passes, so the only test guarding the
"changed groups restart" contract stays green if the group is stopped and
never restarted. *Fix:* bind the result and `assert is_pid(new)` before the
inequality. Note: `camera_supervisor_test.exs:94` has the same latent
pattern (PRE-EXISTING — copied helper).

## Warnings

**W1 — Unthrottled per-line warnings on unroutable plugin output** — HIGH
CONFIDENCE (elixir + security). [plugin_group_port.ex:155-158](lib/cairn/plugin_group_port.ex#L155-L158)
logs one warning per unknown-`camera_id`/malformed line, up to ~4 KB of
plugin-supplied data each, at N×fps forever (one misconfigured plugin =
~30 warn/s). Log dir shares `data_dir` with recordings; sustained flood
erodes `free_space_min_mb` and can stop recording. Throttle (first + every
Nth, or once per offending id per respawn).

**W2 — "Latest sample wins" is actually oldest-sample-wins** (rust).
[multiplex.rs:83-86](plugins/cairn-detect/src/multiplex.rs#L83-L86) —
`try_send` on a full bounded(1) slot drops the *new* sample, keeping the
old. Under saturation detections lag real time by up to N×inference
latency; invisible at N=1. Either drain-then-send or fix the comment and
accept the semantics deliberately.

**W3 — CPU-EP inference serializes the whole group** (rust).
[infer.rs:89](plugins/cairn-detect/src/infer.rs#L89) — one Detector serves
all members; a 4+ camera group saturates by construction, silently (only
per-stream drop counters in the shared log). Acceptable for v1 (Coral
backend is the follow-up plan that motivates this feature) but deserves a
line in the contract doc's throughput expectations.

**W4 — Group restart re-binds member UDP ports while the old process may
still hold them** (elixir + security). `apply_diff` = TERM → immediate
`sync/1`; a slow-dying process makes the new one fail its binds and puts
all N members into one 1–30 s backoff cycle. Consistent with the accepted
v1 failure domain, but a `waitpid`-ish delay or port-retry would remove it.

**W5 — Dark-camera re-open latency in multiplexed mode is ~60–70 s worst
case** (rust). `open_stream_once` burns its own ~30 s on a dead port, then
`stream_loop` sleeps up to 30 s more — vs single-camera mode's 5 s retry
cadence. Within the accepted failure domain; tune if it bites.

**W6 — Test coverage gaps in the new suites** (testing). Uncovered:
`build_routes/2` unknown-member branch, OS-process reaping on
`stop_group/1` (a leaked `sh` wrapper per reload would go unnoticed),
backoff doubling/cap, stale-port messages after respawn; integration test
hard-codes `at_ms: 8_000` wall-clock offsets (slow CI flips `:finalized`
to `:partial`); both new teardowns stop every registered group/camera, not
just their own.

## Suggestions

- `parse_specs` rejects duplicate ids but not duplicate/overlapping
  `udp_port`s — given never-exit, a bad hand-written invocation becomes a
  permanently dark camera instead of a startup error (rust S1).
- Dead-slot log line says `slot 3`, not the camera id ([multiplex.rs:211](plugins/cairn-detect/src/multiplex.rs#L211)).
- Group `command` parse failure double-reports: group error + per-camera
  "undefined plugin" for a name that *is* defined (elixir).
- `@name_regex` uses `^..$` — accepts trailing newline; use `\A..\z`
  ([config.ex:22](lib/cairn/config.ex#L22)).
- Unreachable `:error` branch in `build_routes/2`; two `unless`; bare
  `%__MODULE__{}` type (elixir, style).
- `plugin_group_port_test.exs:80` leaks a global EventCheckpoint ETS entry
  (testing).

## Cleared / noise filtered

- **Shell quoting of `--cameras-json` is safe** (security headline):
  `FFmpegPort.shell_command/2` single-quotes with correct `'\''` escaping;
  JSON quotes and hostile `min_score` label keys are inert.
- Rust concurrency machinery verified sound: no decode-thread deadlock
  (`try_send`-only), Select slot addressing correct, panic unwind drops
  only that slot, `run_single` behaviorally identical to old `run()`.
- elixir-reviewer's `start_cameras`-gate asymmetry in `apply_diff` matches
  the pre-existing `CameraSupervisor.apply_diff` shape exactly — filtered
  as noise (test-env-only, symmetric with the established pattern).
- Integration test verified to genuinely fail on misrouting (per-camera
  floors make swapped routes visible).
