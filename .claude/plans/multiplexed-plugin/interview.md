# Brainstorm: Multiplexed plugin contract (single binary, multiple streams)

**Status**: COMPLETE
**Date**: 2026-07-25
**Coverage**: What ████ | Why ████ | Where ████ | How ████ | Edge ████ | Scope ████
**Score**: 12/12

Predecessor artifacts: `.claude/plans/cpu-plugin/` (cairn-detect, PR #7,
merged) and its `handoff-multiplexed-plugin.md`, which seeded this interview.

## Summary

Extend Cairn's plugin contract so a single supervised plugin process can
serve multiple camera streams, because exclusive-access accelerators
(Coral Edge TPU via `libedgetpu`) can only be held by one process — the
current one-process-per-camera contract can never share them. v1 delivers
the contract extension and the Cairn-side config/supervision/routing
support, proven with `plugins/cairn-detect`'s existing ONNX backend
running N cameras in one process; the Coral TFLite backend itself is an
explicitly separate follow-up plan. Config gains a named top-level
`plugins:` map that cameras reference by name; the group process receives
one `--cameras-json` argument; groups restart only on config changes; v1
accepts the shared failure domain with no new mitigations beyond the
contract's existing exit-and-backoff rule.

## Coverage Details

### What (2/2)

A contract extension ("multiplexed plugin"): one plugin process handles N
camera streams — N RTP/UDP inputs, one shared stdout of ndjson detection
lines already carrying `camera_id`. Cairn launches one supervised child
per named plugin group instead of one per camera, and routes detections
by the `camera_id` field instead of by which port/process they arrived on.

Decisions made:

1. **Config shape — named top-level plugins.** New top-level `plugins:`
   map of named entries (command + settings). A camera opts in with
   `plugin: <name>` in place of an inline command; cameras referencing the
   same name share one process. Inline argv commands stay supported and
   keep today's per-camera-process behavior, so existing configs work
   unchanged.

   ```yaml
   plugins:
     detect:
       command: cairn-detect --model yolov10m.onnx

   cameras:
     - id: front_door
       rtsp_url: rtsp://...
       plugin: detect              # reference by name → shared process
       min_score: {person: 0.6}
     - id: driveway
       plugin: detect
     - id: garage
       plugin: cpu-ref --model x.onnx   # inline = private process, as today
   ```

2. **Argv convention — single `--cameras-json`.** Cairn appends one JSON
   array argument carrying everything per camera: id, udp_port, min_score
   — with room for future per-camera fields (zones, sample fps) without
   new flags. Replaces `--camera-id`/`--udp-port`/`--min-score-json` for
   multiplexed launches.

   ```
   cairn-detect --model m.onnx \
     --cameras-json '[
       {"id":"front_door","udp_port":17000,
        "min_score":{"default":0.5,"person":0.6}},
       {"id":"driveway","udp_port":17004,
        "min_score":{"default":0.5}}
     ]'
   ```

3. **Routing** — a group process owner parses the shared stdout, routes
   each line by its `camera_id` to `Cairn.DetectionAggregator` with that
   camera's config/windows (per-camera map held in the group state).
   Unknown `camera_id` → log and drop.

### Why (2/2)

The Coral Edge TPU (which the user owns and wants to use) is opened
exclusively by `libedgetpu` — exactly one process can hold it, so N
per-camera plugin processes can never share the device. This is the
Frigate problem solved Cairn's way: one child owns the TPU, N decode
paths feed one inference loop. Throughput is not the issue — at ~6–10 ms
per invoke one TPU covers ~20 cameras at 5 fps — so the work is the
contract and supervision shape, not TPU scheduling.

### Where (2/2)

- `docs/plugin-contract.md` — contract extension text.
- `lib/cairn/config/camera.ex` + `lib/cairn/config.ex` — new top-level
  `plugins:` section; `camera.plugin` becomes name-reference-or-inline-argv.
- `lib/cairn/plugin_port.ex` — today's per-camera port owner; the group
  variant (new module, e.g. `Cairn.PluginGroupPort`) generalizes it:
  same line framing/backoff, per-camera config map, route by `camera_id`.
- `lib/cairn/camera.ex` — per-camera tree keeps `PluginPort` only for
  inline plugins; name-referenced cameras get no plugin child.
- `lib/cairn/application.ex` / new sibling supervisor — group processes
  live at top level next to `Cairn.CameraSupervisor` (a group spans
  cameras, so it cannot live inside one camera's `:rest_for_one` tree).
- `lib/cairn/udp_ports.ex` — unchanged allocation (positional, four ports
  per camera); the group is launched with each member camera's existing
  plugin port.
- `plugins/cairn-detect/` — accept `--cameras-json`, open N RTP inputs
  feeding the existing decoder-trait / latest-sample-slot seams and one
  inference loop (ONNX backend; no Coral in v1).
- `priv/plugins/mock/mock_plugin.exs` — needs a multiplexed mode for
  Cairn's own tests.
- Log naming: `plugin-{camera}.log` → `plugin-{name}.log` for groups.

### How (2/2)

- **Supervision**: one long-lived child per named plugin group under a
  top-level (dynamic) supervisor, sibling to `Cairn.CameraSupervisor`;
  same jittered exit-backoff policy as today's `PluginPort`.
- **Restart policy — config changes only.** The group restarts only when
  a config reload changes what it was launched with: membership, command,
  min_score, or port assignments (consistent with the contract's "config
  only changes across restarts"). Runtime camera stop/start — CameraControl
  toggle, ffmpeg crash/backoff — does NOT touch the group: it sees RTP
  silence and resyncs on the next keyframe when packets return, so
  detection on other member cameras is never interrupted. (Note: ffmpeg
  restart no longer restarts the plugin for multiplexed cameras — the
  contract's mid-GOP-join requirement already covers this.)
- **Backward compatibility**: inline per-camera plugins keep the existing
  contract and argv exactly; the multiplexed path is purely additive. A
  named plugin referenced by only one camera still launches multiplexed
  (`--cameras-json` with one entry) — the convention is decided by config
  shape, not member count.

### Edge Cases (2/2)

- **Failure domain — accepted for v1.** One poisoned stream or panic
  takes down detection for all member cameras until restart; the user
  explicitly chose to ship v1 with only the existing contract rule (exit
  on unrecoverable errors → Cairn restarts with jittered backoff;
  empty-`dets` lines remain the liveness signal). Deferred, available
  later if it bites: plugin-side per-stream isolation in cairn-detect,
  Cairn-side whole-group stall watchdog, per-camera staleness in
  CameraStatus.
- Unknown/missing `camera_id` on a line from a group plugin: log + drop
  (per-camera plugins keep working without echoing camera_id, since Cairn
  tracks those per-port).
- Config validation: camera referencing an undefined plugin name is a
  config error; a `plugins:` entry referenced by zero cameras simply
  doesn't launch.
- Config reload reordering cameras shifts positional UDP ports — already
  a restart-everything event today; the group restarts with fresh ports
  via the config-change rule.

### Scope (2/2)

**In**: contract doc extension; `plugins:` config section + camera name
references; group supervision, launch, routing, restart-on-config-change;
`--cameras-json` support and N-stream multiplexing in cairn-detect (ONNX
backend); multiplexed mock plugin + tests; reorder-detection fix in
config diffing (see Research Findings — restart affected cameras/groups
when their positional index, hence UDP ports, changes).

**Out (explicit)**: the Coral TFLite/`libedgetpu` backend itself
(follow-up plan — backend-trait-in-cairn-detect vs. sibling plugin
deliberately left to that plan); failure-domain mitigations beyond
contract backoff; dynamic camera add/remove without restart (stdin
control channel — contract forbids mid-run config changes); TPU
scheduling/throughput work.

## Codebase Context

- Contract today (`docs/plugin-contract.md`): one process per camera;
  Cairn appends `--camera-id`, `--udp-port`, `--min-score-json`; ndjson
  stdout (≤8192 bytes/line) with `camera_id` already in every line;
  stderr → `{data_dir}/log/plugin-{camera}.log`; SIGTERM on stop; jittered
  1s→30s backoff on exit; mid-GOP RTP join required; config immutable
  mid-run.
- `Cairn.PluginPort` (`lib/cairn/plugin_port.ex`): GenServer owning the
  process via `/bin/sh -c` Port; line framing with long-line skip;
  decodes `pts`/`dets`, forwards to `DetectionAggregator` with camera
  config + windows; internal backoff respawn (port exit does not crash
  the GenServer).
- Supervision (`lib/cairn/camera.ex`): per-camera `:rest_for_one` —
  RingBuffer → FFmpegPort → (PluginPort) → RTPHub; ffmpeg death currently
  restarts the plugin. `Cairn.CameraSupervisor` is a top-level
  DynamicSupervisor with `sync/1` + `apply_diff/2` for config reloads;
  camera start/stop is positional (UDP ports).
- Config (`lib/cairn/config/camera.ex`): `plugin` is argv list (string is
  split), absent = no detection; `min_score` map with `"default"` key.
- `plugins/cairn-detect` (PR #7): per-camera RTP open, decoder trait,
  size-1 latest-sample slots — internal seams already fit N-stream input;
  every output line already carries `camera_id`.

## Research Findings

Full notes: `research/codebase-scan.md` (codebase) and
`research/web-research.md` (external, with sources).

### External validation (web)

- **Frigate** solves the same problem with a shared work queue feeding one
  detector process; device selection via strings (`usb:0`, `pci:0`);
  multiple TPUs = multiple detector processes. Confirms the "one process
  owns the accelerator" shape; Cairn's design differs (per-camera RTP in,
  ndjson out) but the failure-handling lesson carries: per-frame timeouts
  are how Frigate notices a wedged detector.
- **libedgetpu was archived (Oct 2025)** — unmaintained. Exclusivity is
  inherent to the single-context ASIC. Relevant to the Coral follow-up,
  not this phase.
- **OTP Port throughput**: at ~100 lines/sec (20 cams × 5 fps) inline
  routing in one GenServer `handle_info` is comfortably sufficient — no
  demux processes needed. Validates the single `PluginGroupPort` router.
- **Coral follow-up reality**: EfficientDet-Lite0 / SSD-MobileNet v2 are
  the production-ready models; YOLO compiles poorly to EdgeTPU (many ops
  fall back to CPU). One model per detector instance.

### Codebase scan — plan-relevant specifics

- `plugins:` must be added to `@known_keys` in `config.ex:15`; a new
  `Config.PluginGroup` should mirror `Config.Camera.parse/3` conventions.
- **Parse disambiguation decision needed**: `Camera.parse/3` has no
  visibility into the `plugins:` map, so "inline argv" vs "group name"
  needs either group names passed into camera parsing or a post-hoc
  cross-validation pass.
- **Reload ordering**: `Config.Server`'s `apply_diff` seam
  (server.ex:53,82) only knows cameras; groups need ordered application
  (create/update groups before member cameras start, tear down after).
  `diff_cameras/2` (server.ex:94) is the template for
  `diff_plugin_groups/2`.
- `Cairn.Registry` needs no changes — groups register via
  `Registry.via(group_name, :plugin_group)`. New `PluginGroupSupervisor`
  mirrors `CameraSupervisor.sync/apply_diff`, added as an application
  sibling before `CameraSupervisor`.
- `PluginPort`'s framing/backoff/spawn/kill internals copy verbatim;
  only `build_argv/2` is replaced. Mock plugin already echoes
  `camera_id`; today's `handle_line/2` just ignores it.
- **⚠ Pre-existing hazard surfaced — DECIDED: fix in this plan.** UDP
  allocation is positional (`base + 4*index`) and a *pure reorder* of the
  cameras list is not detected by `diff_cameras/2` as a change — ports
  silently shift under running processes today. Groups make it worse
  (`--cameras-json` bakes ports in at launch). Decision: make
  `diff_cameras/2` (and the new `diff_plugin_groups/2`) treat an index
  change as a change, so affected cameras and groups restart on reorder.
  Positional allocation itself stays.
- Tests: mirror `plugin_port_test.exs` / `camera_supervisor_test.exs`
  (`async: false`, injected `command:`/`aggregator:` opts, no Mox); mock
  plugin needs a multi-camera mode for group integration tests.
