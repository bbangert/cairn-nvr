## Requirements Coverage (from plan file .claude/plans/multiplexed-plugin/plan.md)

**Summary**: 29 MET · 1 PARTIAL · 0 UNMET · 1 UNCLEAR · 0 non-goals violated

### Decisions made in this plan (1–8)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| D1 | Whitespace-free `plugin:` string = group name (error if undefined); whitespace/list = inline; 1-elem list escape hatch | MET | `lib/cairn/config/camera.ex:117-137` (`[name] -> {:pending, name}`, list -> `{:inline, argv}`); undefined-name error `lib/cairn/config.ex:206-215`; compat break documented `docs/plugin-contract.md:129` |
| D2 | `Camera.plugin` becomes `nil \| {:inline, argv} \| {:group, name}`; all 4 consumers updated | MET | camera.ex:47-52 (`{:inline,_}` only gets PluginPort); `lib/cairn/plugin_port.ex:41` pattern match; `camera_controller.ex:52` (`!= nil`, tuple-safe); `config_live.ex:111,120-122` `plugin_label/1` |
| D3 | Members (id, udp_port via `UDPPorts.ports_for/2`, min_score) baked at config-load; diff is struct `!=` | MET | `lib/cairn/config.ex:224-234` `members_for/2`; `config/server.ex:126-138` `diff_plugin_groups/2` uses `!=` |
| D4 | No per-group wrapper supervisor; DynamicSupervisor over `PluginGroupPort`; `Registry.via(name, :plugin_group)` | MET | `lib/cairn/plugin_group_supervisor.ex:12,24,57`; `plugin_group_port.ex:45` |
| D5 | `Config.Server` injectable `apply_group_diff`, applied before camera diff | MET | `config/server.ex:58,93-96`; order asserted `test/cairn/config_server_test.exs:113-144` |
| D6 | Group-name validation: regex, unique, disjoint from camera ids | MET | `lib/cairn/config.ex:271-287` (`@name_regex` line 22, dup + collision checks) |
| D7 | cairn-detect per-stream resilience in multiplexed mode only; single-camera exit semantics unchanged | MET | `plugins/cairn-detect/src/multiplex.rs:104-133` (eternal re-open, 5s→30s, 60s healthy reset); `rtp.rs:145-147` `open_stream_once`; single path `main.rs:113-160` unchanged; inference errors fatal `multiplex.rs:163,171` |
| D8 | Mock plugin gains `--cameras-json` mode in place; per-entry `camera_id` | MET | `priv/plugins/mock/mock_plugin.exs:22-32,63-65`; single-camera emit output byte-identical |

### Tasks T1–T17

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| T1 | `Config.PluginGroup` struct + `parse/3` mirroring Camera conventions; command string-or-list, required | MET | `lib/cairn/config/plugin_group.ex:15-70` (`@known_keys ~w(command)`, `{struct_or_nil, acc}`, delegated add_error/warn_unknown) |
| T2 | `"plugins"` in `@known_keys`, `plugin_groups:` field, `parse_plugins/2`, resolve pass (a) + (b), `validate_plugins/2`, zero-ref group OK | MET | `config.ex:15-16,36,107,122,173-234,271-287`; zero-ref group test `config_test.exs:172` + fixture `test/support/fixtures/configs/plugin_groups.yml` |
| T3 | `parse_plugin/3` pre-resolution form; moduledoc; both web consumers updated | MET | `config/camera.ex:5-16,117-137`; `camera_controller.ex:52`; `config_live.ex:120-122` |
| T4 | Reorder fix in `diff_cameras/2`; `diff_plugin_groups/2`; injectable `apply_group_diff`; groups applied first; `reload/1` shape kept, group diff logged | MET | `config/server.ex:112-118,141-146` (index compare), `126-138`, `58`, `93-96`, `164-171` `log_group_diff/1` |
| T5 | Tests: parsing, disambiguation (single-token error + list hatch), member ports, validation, zero-ref; diff/reorder/order tests; fixture | MET | `config_test.exs:148,172,193,206,270,275`; `config_server_test.exs:91,113,171-215`; fixture present |
| T6 | `PluginGroupPort` GenServer: framing, long-line skip, jittered backoff, spawn/kill verbatim, routes map, `build_argv`, camera_id required, log path, via-registry, test seams | MET | `lib/cairn/plugin_group_port.ex:30-52,80-106,116-171,173-231` |
| T7 | `PluginGroupSupervisor`: `sync/1` (members != [], Registry role), `apply_diff/2` = stop removed++changed then sync, `:start_cameras` gate | MET | `plugin_group_supervisor.ex:29-53` |
| T8 | Wire-in: application child before CameraSupervisor, boot sync order, camera.ex inline-only child, plugin_port build_argv | MET | `application.ex:29-30`; `boot.ex:18-19`; `camera.ex:47-52`; `plugin_port.ex:41-42` |
| T9 | Port + supervisor tests (routing ≥2 cams, unknown id, malformed/long lines, backoff; sync/apply_diff/zero-member) | MET | `test/cairn/plugin_group_port_test.exs:51,62,80,102,120,132`; `plugin_group_supervisor_test.exs:45,60,76,104,117,126` |
| T10 | Mock `--cameras-json` mode, both variants commented, single mode unchanged | MET | `mock_plugin.exs:5-18,22-32,60-65` |
| T11 | Group integration test: 2 cameras distinct timelines, correct routing; member restart leaves group pid stable | MET | `test/integration/plugin_group_test.exs:111-147` (GenServer pid line 143 and OS pid line 144 asserted) |
| T12 | `--cameras-json` clap arg, mutually exclusive with per-camera flags, one form required, single path preserved | MET | `main.rs:39-62` (`required_unless_present`/`conflicts_with`), `88-91`; tests `main.rs:206-241` |
| T13 | Per-camera decode thread + bounded(1) slot; identity carried; one inference thread `Select`s slots, per-camera floors and id | MET (documented deviation) | `multiplex.rs:73-96,153-218`; identity = Select slot index rather than a field on `Sample` (`multiplex.rs:195`) — plan's Phase 4 note records this |
| T14 | Multiplexed: open/read/decode error → log + delay + re-open, never exit; single mode keeps give-up-and-exit; inference errors fatal | MET | `multiplex.rs:104-133,135-151,163-171`; single-mode fatal path `main.rs:148-160`; `rtp.rs:137-183` retry budget split |
| T15 | Rust tests: cameras-json parsing (valid/invalid/conflict), per-camera floor selection; existing tests green | MET | `multiplex.rs:227-323`, `main.rs:206-241`; `cargo test` re-run: 45 passed, 0 failed |
| T16 | Contract doc: `plugins:` shape, `--cameras-json` schema, required `camera_id`, shared log, lifecycle, name-vs-inline rule + hatch | MET | `docs/plugin-contract.md:96-200` (sections Declaring a group / Name or inline? / `--cameras-json` / Tagged output / Shared log and lifecycle) |
| T17 | Full verification: `mix check`, `cargo fmt --check && clippy && test`, argv-grep clean | PARTIAL | Re-verified here: `mix test` 236 passed; `cargo test` 45 passed; argv grep clean (only `!= nil`, `plugin_label/1`, `== {:group,_}`, tagged-tuple `build_argv`). `mix format`/`credo` and `cargo fmt`/`clippy` not re-run in this review |

### Verification section

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| V1 | Per-task `mix compile --warnings-as-errors && mix format && mix test` / `cargo clippy && cargo test` | UNCLEAR | per-task execution cannot be verified from the tree; final-state suites are green (236 Elixir / 45 Rust) |

### Non-goals (scope creep check)

| Non-goal | Held? | Evidence |
|---|---|---|
| Coral TFLite / libedgetpu backend | HELD | no `coral`/`tflite`/`edgetpu` match in `lib/`, `plugins/cairn-detect/src/`, `Cargo.toml`, contract doc |
| Failure-domain mitigations beyond contract backoff | HELD | only jittered backoff (`plugin_group_port.ex:211-217`) + per-stream re-open required by D7; no watchdog/per-stream isolation |
| Dynamic camera add/remove without group restart | HELD | membership fixed at init (`plugin_group_port.ex:57-73`); restart via `apply_diff/2` only |
| TPU scheduling / stable-by-id UDP allocation | HELD | `lib/cairn/udp_ports.ex` untouched; allocation still positional (`config.ex:229`) |

### Notes (documentation follow-ups flagged in plan, not requirements)

- `config.example.yml` still has no `plugins:` block (confirmed absent).
