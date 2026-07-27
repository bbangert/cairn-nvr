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
65536 bytes (64 KiB) per line. Two shapes are accepted: the original one
below, and the richer [protocol v1](#protocol-v1) envelope — write v1 for
anything new, and keep reading here for the rules v1 inherits.

```json
{"camera_id": "front_door", "pts": 90000, "dets": [
  {"label": "person", "score": 0.87, "bbox": [0.12, 0.4, 0.2, 0.5]}
]}
```

- `pts` — the RTP timestamp (90 kHz) of the analyzed frame, as a **JSON
  number**, not a string. Required; a line whose `pts` is `"90000"` is
  dropped whole, and some JSON emitters do that to 64-bit values by default.
  Magnitude at most 2^62 — a 90 kHz clock reaches that in a million
  centuries, so this only ever rejects a number no arithmetic could hold.
- `dets` — possibly empty list, **at most 64 entries**. A longer list is a
  contract violation, not a crowded frame: the whole line is dropped. (Cairn
  tracks objects across batches at a cost quadratic in detections per line,
  in one process shared by every camera.)
- Emit at whatever rate you sample; ~5 fps is plenty. Empty `dets` lines
  are fine.
- A v0 line carries no time and no stream epoch, so Cairn stamps it on
  arrival: every event offset derived from it includes your queueing and
  scheduling latency, and the line is attributed to whatever epoch is
  current when it lands. v1 fixes both.
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

## Protocol v1

The line above is protocol **v0**: still supported, still correct, and what
a plugin that says nothing is assumed to speak. v1 is the same idea with the
context v0 could not carry — which stream the line belongs to, when the
frame was seen, and what was lost on the way.

A v1 message is a JSON object carrying `"spec": "cairn.plugin"` and
`"version": 1`. Its `type` says what it is. Everything below is one line of
ndjson on stdout, at most 65536 bytes.

### `frame.objects`

```json
{"spec":"cairn.plugin","version":1,"type":"frame.objects",
 "camera_id":"front_door",
 "stream_epoch":"01J8ZQ0P8B7X0N2R4C6D8E0F2G",
 "sequence":41,
 "frame":{"pts":90000,"time_base":[1,90000],
          "observed_at":"2026-07-26T12:00:00.500Z"},
 "objects":[{"label":"person","score":0.87,"bbox":[0.12,0.4,0.2,0.5],
             "track_id":"a1","observation_kind":"detected"}],
 "ended_tracks":["a0"]}
```

| field | type | rule |
|---|---|---|
| `camera_id` | string | **required for a group**, optional (and ignored) for a per-camera plugin |
| `stream_epoch` | string | the epoch Cairn gave you for this camera on stdin; a line from any other epoch is dropped |
| `sequence` | integer 0..2^62 | your own per-camera counter, +1 per emitted line. Gaps are counted, not fatal |
| `frame.pts` | number, \|pts\| ≤ 2^62 | presentation timestamp of the analyzed frame, in `time_base` units |
| `frame.time_base` | `[num, den]` | integers in 1..1000000000, default `[1, 90000]` (the RTP clock) |
| `frame.observed_at` | ISO8601 string | **required.** When the frame was observed — capture it *before* inference, not after. Event times derive from it. More than 30 s from Cairn's own clock and it is replaced by arrival time (the observation is still used, and marked as arrival-quality) — run NTP |
| `emitted_at` | ISO8601 string | optional, informational |
| `objects` | list | required, may be empty, at most **64** entries |
| `ended_tracks` | list of strings | optional, default `[]`, at most 64, each ≤ 64 bytes |

An object is a v0 detection (`label`, `score`, `bbox` — same rules) plus:

| field | type | rule |
|---|---|---|
| `track_id` | string ≤ 64 bytes | optional; your own identity for this object, stable within an epoch |
| `observation_kind` | `"detected"` or `"tracked"` | optional, default `"detected"` |

`"tracked"` means *you predicted this object without detecting it in this
frame*. It keeps the object's track alive but is never evidence: it cannot
open an event, extend one, or add to its labels. Send `"detected"` for
anything the model actually found in this frame.

An empty `objects` list is a perfectly valid observation. It is not a
liveness protocol and Cairn draws no conclusion from its absence.

### `plugin.hello`

Send once at startup, before anything else:

```json
{"spec":"cairn.plugin","version":1,"type":"plugin.hello",
 "hello":{"name":"cairn-detect","version":"0.3.1",
          "supported_versions":[1],
          "capabilities":{"object_tracking":false}}}
```

The body may also be sent flat (alongside the envelope) — but nesting keeps
your `version` clear of the protocol `version`. Cairn logs it and warns if
`supported_versions` does not include 1.

Only these four fields are kept, and each is bounded: `name` and `version`
are printable strings of at most 64 bytes; `supported_versions` is a list of
at most 16 integers in 0..1000; `capabilities` is a map of at most 32
printable keys (≤ 32 bytes) to **booleans**. Anything else — or a field of
the wrong shape — is dropped. The message is not: a plugin that mis-declares
itself still runs.

### `plugin.status`

Your own health, whenever it changes:

```json
{"spec":"cairn.plugin","version":1,"type":"plugin.status",
 "camera_id":"front_door",
 "status":{"state":"ready","detail":"model loaded"}}
```

`state` is required: a printable string of 1..32 bytes. `detail` (printable,
≤ 256 bytes) and `fps` (number, 0..10000) are optional. **Nothing else is
kept** — the status is retained per camera and pushed to every dashboard and
API subscriber, so it is a fixed set of small fields, not a scratch space.
A missing or unusable `state` drops the line.

It surfaces as `plugin_status` on the camera's status (dashboard, `/api`
camera list, and the `camera_status` SSE frame). For a group, a status with
a `camera_id` applies to that member; without one it applies to every
member (a `camera_id` inside the `status` body is ignored — routing comes
from the envelope).

Send it *when it changes*. An unchanged status is forwarded at most once
every 5 s; the rest are dropped and counted.

### Forward compatibility

- **Ignore fields you do not recognize**, at every level. Cairn does.
- Cairn ignores message `type`s it does not know, so new types are additive.
- A *malformed known field* is different: that line is dropped and counted.
- v0 and v1 lines may be mixed on one stdout, though there is no reason to.

## Control channel (stdin)

Cairn writes ndjson to your **stdin**. One line per message, same envelope.

**You MUST read (or at least drain) stdin.** Writes never block Cairn: when
your stdin buffer fills, control lines are dropped and counted, and you are
left believing an epoch that has ended — your lines are then dropped as
stale. Cairn does not resend the dropped line, but it does not consider the
epoch announced either, so the next epoch change (or your next restart)
tells you again. A plugin that ignores stdin should still read and discard
it.

```json
{"spec":"cairn.plugin","version":1,"type":"stream.started",
 "camera_id":"front_door","stream_epoch":"01J8ZQ...","rtp":{"clock_rate":90000}}
{"spec":"cairn.plugin","version":1,"type":"stream.ended",
 "camera_id":"front_door","stream_epoch":"01J8ZP...","reason":"source_lost"}
```

- A **stream epoch** names one continuous decode of one camera. Cairn mints
  a new one on every ffmpeg (re)spawn: after an outage the camera may have
  moved, so nothing — track ids, pts continuity — may cross the boundary.
- You are told the current epoch for every camera you serve immediately
  after you start, and again whenever it changes. `stream.ended` (with a
  `reason`: `started`, `source_lost`, `stall_bounce`, `camera_stopped`)
  precedes the new `stream.started` when Cairn had already announced a live
  epoch to you.
- `reason: "camera_stopped"` ends a stream that nothing replaces: while your
  process keeps running, no `stream.started` follows until that camera
  streams again.
- **Stamp every `frame.objects` line with the epoch of the camera it
  describes.** Lines carrying a stale or unknown epoch are dropped — that is
  the point: they describe a stream that no longer exists.
- On a new epoch, drop your decoder state and your track identities for that
  camera and resync on the next keyframe.
- **`stream.started` is the last known stream identity, not proof of live
  media.** The per-spawn announcement is replayed from Cairn's record of the
  last epoch for each camera you serve, and that record survives your process
  while the announcement state does not — so after a restart you may be told
  `stream.started` for the last epoch of a camera that has since stopped, with
  no `stream.ended` to follow. Use it to *tag* lines; judge liveness from RTP
  flow, and expect a camera you have been "started" for to send nothing at
  all.

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
optional echo, as today.) The same holds for a v1 `frame.objects` line.

The [control channel](#control-channel-stdin) is per member too: one
`stream.started` per member camera after you start, and an
ended/started pair whenever *one* member's stream is replaced. Epochs are
per camera and never shared — keep one per member, and never take a
member's epoch change as a reason to reset anything else.

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
