# Cairn plugin contract

An inference plugin is an external process supervised by Cairn. It receives
H.264 video as RTP over UDP, runs whatever detection it wants, and prints
detections as ndjson on stdout. That is the whole interface — any language,
any runtime, any model.

Two shapes, one contract: **one process per camera** (the default, described
below), or **one process per named group** of cameras for plugins that can
serve several streams at once — see [Multiplexed
plugins](#multiplexed-plugins).

Reference implementations:

- `plugins/cairn-detect/` — **the one to deploy.** Single Rust binary,
  hardware decode (VAAPI/QSV/NVDEC/V4L2/VideoToolbox) with software
  fallback, NMS-free YOLO on onnxruntime. Serves one camera or a whole
  group.
- `plugins/cpu-reference/` — the minimal Python example (PyAV decode →
  ONNX), kept short on purpose for people writing their own plugin.
- `priv/plugins/mock/mock_plugin.exs` — deterministic timeline replay
  (used by Cairn's own tests; ignores the video entirely). Speaks both
  argv variants.

## Inputs

### argv

Cairn appends these arguments to the configured command
(`cameras[].plugin` in `config.yml`):

| flag | value |
|------|-------|
| `--camera-id` | the camera's config id (echo it back in output if you like; Cairn tracks per-port anyway) |
| `--udp-port` | UDP port on `127.0.0.1` where H.264 RTP arrives |
| `--min-score-json` | JSON object of label → min score (e.g. `{"default":0.5,"person":0.6}`) — pre-filtering in the plugin is optional; Cairn enforces it regardless |

Anything you put in the configured command before these (model paths,
device selection, `--timeline`, …) is passed through untouched.

A plugin serving a group is configured with one argument instead — see
[`--cameras-json`](#--cameras-json).

### Video input

- H.264 RTP/UDP on `127.0.0.1:{udp-port}`, payload type 96, 90 kHz clock.
- `{udp-port} + 1` is reserved for you. Cairn sends no RTCP, but most RTP
  receivers bind it anyway (ffmpeg's SDP demuxer refuses to open the stream
  if it cannot, and ignores an `a=rtcp:` override) — so nothing else will be
  placed there. Ports are allocated four per camera for this reason.
- Sent by ffmpeg's `-f rtp` output (codec copy of the camera stream, or
  the transcoded stream when the camera opts into transcode).
- No RTCP, no handshake: packets flow whether or not you listen.
- Most decoders need an SDP to consume raw RTP; see the reference plugin
  for the standard generated-SDP trick.

## Output

One JSON object per line on **stdout** (ndjson), flushed per line, at most
65536 bytes (64 KiB) per line:

```json
{"camera_id": "front_door", "pts": 90000, "dets": [
  {"label": "person", "score": 0.87, "bbox": [0.12, 0.4, 0.2, 0.5]}
]}
```

- `pts` — the RTP timestamp (90 kHz) of the analyzed frame, as a **JSON
  number**, not a string. Required; a line whose `pts` is `"90000"` is
  dropped whole, and some JSON emitters do that to 64-bit values by default.
- `dets` — possibly empty list, **at most 64 entries**. A longer list is a
  contract violation, not a crowded frame: the whole line is dropped. (Cairn
  tracks objects across batches at a cost quadratic in detections per line,
  in one process shared by every camera.)
- Emit at whatever rate you sample; ~5 fps is plenty. Empty `dets` lines
  are fine (and useful as a liveness signal).
- Malformed lines are dropped by Cairn — they will not crash anything, but
  they also won't detect anything. A detection that breaks the rules is
  dropped on its own; the rest of the line still counts. Precisely, a
  detection is kept iff:
  - `label` is a string of 1..64 **bytes** (not characters) with no control
    characters or escape sequences — printable text only;
  - `score` is a number in 0..1;
  - `bbox` is exactly four numbers `[x, y, w, h]` with `x`/`y` in 0..1 and
    `w`/`h` in 0..1 and greater than zero.
- Drops are counted per reason and logged at most once every few seconds,
  with the running totals.

## Logging

**stderr only.** Cairn redirects it to `{data_dir}/log/plugin-{camera}.log`
(for a group, `plugin-{group}.log`). Anything you print to stdout that isn't
contract ndjson is dropped with a warning.

## Lifecycle

- Started when the camera starts; killed (SIGTERM) when the camera stops.
- If you exit — crash or normal — Cairn restarts you with jittered backoff
  (1s → 30s). Exiting on unrecoverable errors is the correct behavior.
- Be idempotent on restart: you may be re-run mid-stream at any time, and
  you must cope with joining an RTP stream mid-GOP (decoders resync on
  the next keyframe).
- Config (min scores, camera id, port) only changes across restarts —
  never mid-run.

A group's lifecycle is deliberately different — see [Shared log and
lifecycle](#shared-log-and-lifecycle).

## Multiplexed plugins

Some accelerators can only be held by one process at a time — an Edge TPU is
the motivating case — so one process per camera can never share them. A
plugin can instead be declared once and serve several cameras from a single
process: N RTP inputs in, one ndjson stream out, every line tagged with the
camera it came from.

Everything below is additive. Cameras with an inline `plugin:` command keep
the per-camera contract above, unchanged, alongside any groups.

### Declaring a group

```yaml
plugins:
  detect:
    command: ./cairn-detect --model yolov10n.onnx --labels coco.names

cameras:
  - id: front_door
    rtsp_url: rtsp://user:pass@10.0.0.10:554/stream1
    plugin: detect
    min_score:
      default: 0.5
      person: 0.6
  - id: driveway
    rtsp_url: rtsp://user:pass@10.0.0.11:554/stream1
    plugin: detect
  - id: garage
    rtsp_url: rtsp://user:pass@10.0.0.12:554/stream1
    # inline command: its own process, per-camera contract, as before
    plugin: ["./cairn-detect", "--model", "yolov10n.onnx"]
```

- `plugins:` maps a group name to a `command` — a string (split on
  whitespace) or an argv list. A camera joins with `plugin: <name>`.
- One process per group that has at least one member. A group nothing
  references is valid config and simply never starts; removing its last
  member stops it.
- Group names are `[a-z0-9][a-z0-9_-]*` and must not collide with a camera
  id — both name the same `plugin-{name}.log` file.
- One member is still a group. The config shape decides the mode, not the
  member count: a group with a single camera is launched with
  `--cameras-json`, not the per-camera flags.

### Name or inline?

A `plugin:` string **without whitespace** is a group name. A string with
whitespace, or a list, is an inline command:

```yaml
plugin: detect                       # group named "detect" — error if undefined
plugin: python3 plug.py --model m    # inline command
plugin: ["./my-plugin"]              # inline, no flags — the escape hatch
```

An undefined name is a config error rather than a command to run: a typo
would otherwise turn into a process that cannot spawn, crash-looping behind
the backoff instead of failing the reload.

Compat note: a bare single-token string (`plugin: my-plugin`) used to be an
inline command and is now read as a group reference. Write those as a
one-element list.

### `--cameras-json`

A group launch replaces `--camera-id`, `--udp-port` and `--min-score-json`
with one argument:

| flag | value |
|------|-------|
| `--cameras-json` | JSON array of `{"id", "udp_port", "min_score"}`, one entry per member camera, in config order |

```json
[{"id":"front_door","udp_port":17000,"min_score":{"default":0.5,"person":0.6}},
 {"id":"driveway","udp_port":17004,"min_score":{"default":0.5}}]
```

Each field means exactly what the per-camera flag of the same name means
(see [argv](#argv)): `udp_port` is where that camera's H.264 RTP arrives and
reserves `udp_port + 1` for RTCP, `min_score` is that camera's floor map.
Anything before this argument in the configured command is still passed
through untouched.

**Ignore fields you do not recognize.** The member schema gains per-camera
fields over time; a plugin that rejects unknown keys breaks on the next one.

### Tagged output

The same ndjson as [Output](#output), with one difference: `camera_id` is
**required**, and names the member the line describes.

```json
{"camera_id": "driveway", "pts": 90000, "dets": []}
```

A line whose `camera_id` is missing or does not name a member of this group
is logged and dropped — Cairn routes by that field alone, having no port or
process to attribute it to. (For per-camera plugins `camera_id` remains an
optional echo, as today.)

### Shared log and lifecycle

stderr for every member lands in one `{data_dir}/log/plugin-{group}.log`,
named for the group rather than any camera.

- A group is restarted **only on config change**: its command, its
  membership, a member's `min_score`, or a member's UDP port. Ports are
  positional, so reordering `cameras:` shifts them and counts as a change
  even when nothing else was edited.
- Nothing a camera does at runtime restarts the group. Stopping or starting
  a member, toggling its detection or recording, an ffmpeg crash and its
  backoff — the group keeps running and simply stops seeing packets on that
  member's port.
- **So a silent stream must be a normal state.** An open failure, a read
  timeout, or a decode error on one stream is a wait-and-re-open loop,
  forever — never an exit. A stopped camera is routine, and exiting over it
  would take every other member down too. Resync mid-GOP on the next
  keyframe when the packets come back.
- The group is one failure domain: an exit stops detection for every member
  until the backoff restart brings the process back. Reserve exits for
  genuinely unrecoverable faults — model load, inference failure — and let
  per-stream trouble stay per-stream.
- Membership never changes mid-run. Cairn restarts the process with a new
  `--cameras-json` instead, so the array you are launched with is valid for
  your whole lifetime.
