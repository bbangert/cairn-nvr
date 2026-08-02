# Cairn plugin contract — protocol v1

An inference plugin is an external process supervised by Cairn. It receives
H.264 video as RTP over UDP, runs whatever detection it wants, and prints
observations as ndjson on stdout. Cairn writes stream-lifecycle messages back
on the plugin's stdin. That is the whole interface — any language, any
runtime, any model.

Two shapes, one contract:

- **one process per camera** — the default;
- **one process per named group** of cameras, for plugins that can serve
  several streams at once (an accelerator that only one process may hold).
  See [Multiplexed plugins](#multiplexed-plugins). Everything there is
  additive: the envelope, the message types and the limits are identical.

Reference implementations:

- `plugins/cairn-detect/` — **the one to deploy.** Single Rust binary,
  hardware decode (VAAPI/QSV/NVDEC/V4L2/VideoToolbox) with software
  fallback, NMS-free YOLO on onnxruntime. Serves one camera or a whole
  group, and is the worked example of every section below.
- `priv/plugins/mock/mock_plugin.exs` — deterministic timeline replay used
  by Cairn's own tests. It ignores the video entirely and speaks both argv
  variants and both protocol versions, which makes it the shortest readable
  implementation of the wire format.

**Protocol v0** — the original untagged `{"pts", "dets"}` line — is still
accepted and will stay accepted. A plugin that never sends a
[`plugin.hello`](#pluginhello) is assumed to speak it. It carries neither
time nor stream identity, so it costs accuracy; write v1 for anything new.
See [Appendix A](#appendix-a-protocol-v0).

## Table of contents

- [Inputs](#inputs) — [argv](#argv), [video](#video-input)
- [Output](#output) — [framing](#framing), [envelope](#the-envelope),
  [`frame.objects`](#frameobjects), [objects](#objects),
  [`plugin.hello`](#pluginhello), [`plugin.status`](#pluginstatus)
- [Geometry](#geometry) — and why it is not ONVIF's
- [Time](#time) — `observed_at`, `pts`, and what is **undefined**
- [Control channel (stdin)](#control-channel-stdin)
- [Stream epochs](#stream-epochs), [sequence numbers](#sequence-numbers),
  [what to do before your first
  `stream.started`](#before-your-first-streamstarted)
- [Track identity](#track-identity)
- [Limits](#limits) — every numeric bound in one table
- [What gets dropped](#what-gets-dropped)
- [Forward compatibility](#forward-compatibility)
- [Logging](#logging) and [lifecycle](#lifecycle)
- [Multiplexed plugins](#multiplexed-plugins)
- [Appendix A: protocol v0](#appendix-a-protocol-v0)

## Inputs

### argv

Cairn appends these arguments to the configured command
(`cameras[].plugin` in `config.yml`):

| flag | value |
|------|-------|
| `--camera-id` | the camera's config id (echo it back in output if you like; Cairn tracks per-port anyway) |
| `--udp-port` | UDP port on `127.0.0.1` where H.264 RTP arrives |
| `--min-score-json` | JSON object of label → min score (e.g. `{"default":0.5,"person":0.6}`) |

Anything you put in the configured command before these (model paths,
device selection, `--timeline`, …) is passed through untouched.

Pre-filtering by `--min-score-json` in the plugin is optional. Cairn applies
the same floors itself, and applies them *after* tracking: a below-floor
object still gets a track identity and still produces track frames — it just
never becomes event evidence. Filtering in the plugin saves the line, not the
semantics.

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
- Most decoders need an SDP to consume raw RTP; see `plugins/cairn-detect`
  for the standard generated-SDP trick.
- A silent port is a normal state, not an error. See
  [Lifecycle](#lifecycle).

## Output

### Framing

One JSON object per line on **stdout** (ndjson), flushed per line, at most
**65 536 bytes (64 KiB) of content per line**, excluding the newline. The
bound is inclusive: Cairn reads with `{:line, 65_536}`, and a line of exactly
65 536 content bytes still arrives whole — 65 537 is the first that does not
(measured, not inferred). A longer line is discarded whole — the truncated
head is not parsed, and neither is the remainder. Anything on stdout that is
not contract ndjson is dropped with a warning; logs go to
[stderr](#logging).

### The envelope

Every v1 message is a JSON object with:

| field | type | rule |
|---|---|---|
| `spec` | string | **required**, exactly `"cairn.plugin"`. A different value drops the line; a *missing* `spec` makes Cairn read the line as [v0](#appendix-a-protocol-v0) |
| `version` | integer | **required**, exactly `1`. Any other value drops the line |
| `type` | string | **required.** `"frame.objects"`, `"plugin.hello"`, `"plugin.status"`. An unrecognized `type` is ignored (forward compatibility); a missing or non-string `type` drops the line |

`camera_id`, `stream_epoch` and `sequence` are also envelope fields where
the message type uses them. The three message types are below.

### `frame.objects`

What you saw in one frame. This is the message that matters.

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
| `camera_id` | string 1..256 bytes | **required for a group** — it is the only routing there is. Optional and *ignored* for a per-camera plugin: the port attributes the line to the camera it owns, whatever the field says |
| `stream_epoch` | non-empty string | **required.** The epoch Cairn last gave you for this camera on stdin. A line carrying any other epoch is dropped — see [Stream epochs](#stream-epochs) |
| `sequence` | integer 0..2^62 | **required.** Your own per-camera counter, +1 per emitted line. Forward gaps are counted and reported as telemetry, never fatal |
| `frame` | object | **required** |
| `frame.pts` | number, \|pts\| ≤ 2^62 | **required.** Presentation timestamp of the analyzed frame, in `time_base` units. A JSON *number*, never a string |
| `frame.time_base` | `[num, den]` | optional; two integers in 1..1 000 000 000, default `[1, 90000]` (the RTP clock). Present but malformed drops the line |
| `frame.observed_at` | ISO8601 string | **required.** When the frame was observed — capture it *before* inference, not after. Event times derive from it. See [Time](#time) |
| `objects` | list | **required**, may be empty, at most **64** entries. 65 or more drops the whole line |
| `ended_tracks` | list of strings | optional, default `[]`, at most 64, each a printable `track_id` of 1..64 bytes. Only honoured from a plugin that declared `object_tracking` |

An empty `objects` list is a perfectly valid observation, and the normal
thing to send for a quiet frame. It is not a liveness protocol: Cairn draws
no conclusion from the absence of lines either.

Unknown fields anywhere in the message are ignored. `emitted_at`, for
instance, is accepted and discarded — there is no harm in sending it and no
effect from doing so.

### Objects

An object is a detection plus optional identity:

| field | type | rule |
|---|---|---|
| `label` | string 1..64 **bytes** | **required.** Printable text only: no control characters, no ANSI escapes, valid UTF-8 |
| `score` | number 0..1 | **required** |
| `bbox` | `[x, y, w, h]` | **required.** Exactly four numbers; `x`, `y`, `w`, `h` all in 0..1, and `w`, `h` strictly greater than zero. See [Geometry](#geometry) |
| `track_id` | string 1..64 bytes | optional; your own identity for this object, stable within an epoch. Same charset rule as `label` |
| `observation_kind` | `"detected"` or `"tracked"` | optional, default `"detected"`. Any other value refuses the object |

An object that breaks these rules is dropped **on its own** — the rest of
the line still counts, and the drop is tallied under `invalid_det`. (Contrast
an over-long `objects` list, which drops the line.)

`"tracked"` means *you predicted this object without detecting it in this
frame*. It keeps the object's track alive but is never evidence: it cannot
open an event, extend one, or add to its labels. Send `"detected"` for
anything the model actually found in this frame. A track you keep predicting
for longer than the camera's `tracking.max_unseen_ms` is flagged
*stale-predicted* and stays out of event evidence until something detects it
again.

A track is also out of event evidence while Cairn has it flagged
**stationary** — its box has held still for `tracking.stationary_after_ms` of
media time. Detections keep coming and the track stays alive; they simply stop
opening or extending events until the object has been moving for a couple of
seconds: the flag is sustained on the way out as well as on the way in, so a
detector jittering on a small box does not flick a parked object back into
evidence. Stillness is measured from *detected* boxes only, so predictions
neither create it nor break it — nor do they end that couple of seconds, which
counts detections and not elapsed time.

### `plugin.hello`

Send once at startup, **before anything else and before you load your model**.
Its absence is what makes Cairn treat you as a v0 plugin, and its
`capabilities` are read per line from whatever was last recorded — an
observation that arrives before the hello is handled as if you had promised
nothing. Model loading can take tens of seconds; announce yourself first and
report the wait with a [`plugin.status`](#pluginstatus).

```json
{"spec":"cairn.plugin","version":1,"type":"plugin.hello",
 "hello":{"name":"cairn-detect","version":"0.3.1",
          "supported_versions":[1],
          "capabilities":{"object_tracking":false}}}
```

The body may be nested under `"hello"` (canonical — it keeps your own
`version` clear of the protocol `version`) or sent flat alongside the
envelope. Flat means "every field that is not `spec`, `version`, `type`,
`camera_id`, `stream_epoch` or `sequence`".

Only these four fields are kept, and each is bounded:

| field | rule |
|---|---|
| `name` | printable string, 1..64 bytes |
| `version` | printable string, 1..64 bytes — *yours*, not the protocol's |
| `supported_versions` | list; only the **first 16 entries** are looked at, and of those only integers in 0..1000 are kept. Cairn logs a warning if the result does not contain `1` |
| `capabilities` | map of printable keys (1..32 bytes) to **booleans**; at most 32 valid entries are kept |

Anything else — or a field of the wrong shape — is dropped silently. The
*message* is not: a plugin that mis-declares itself still runs, still
detects, and is simply logged as it described itself.

`capabilities.object_tracking` is the one capability Cairn acts on today. It
is the promise that your `track_id`s are stable within a stream epoch, and
the only thing that makes Cairn use them instead of its own box matching (see
[Track identity](#track-identity)). Declare it `false`, or omit it, if you
only detect. Because it is read as a boolean, the string `"true"` is dropped
by the bounds above and reads as no promise at all.

Sending `plugin.hello` again later replaces the recorded hello. There is no
reason to; the capability is read per line from whatever was last recorded,
so flipping it mid-run flips tracking behavior mid-stream.

### `plugin.status`

Your own health, whenever it changes:

```json
{"spec":"cairn.plugin","version":1,"type":"plugin.status",
 "camera_id":"front_door",
 "status":{"state":"ready","detail":"model loaded","fps":4.9}}
```

| field | rule |
|---|---|
| `state` | **required.** Printable string, 1..32 bytes. Missing or unusable drops the line |
| `detail` | optional. Printable string, ≤ 256 bytes. Over-long or unprintable: the *field* is dropped, the status still applies |
| `fps` | optional. Number in 0..10000. Out of range: the field is dropped |

**`state` has no fixed vocabulary.** Cairn does not parse it, branch on it or
attach any meaning to it: it stores the string and shows it. `"starting"`,
`"ready"` and `"error"` are the conventional values and what the reference
plugin emits — a plugin covering model load would send
`{"state":"starting","detail":"loading yolox_nano.onnx"}` and then
`{"state":"ready"}` — but any printable 1..32-byte string is valid, and no
behavior anywhere changes with it.

**Nothing else is kept.** The status is retained per camera and pushed to
every dashboard and API subscriber, so it is a fixed set of small fields, not
a scratch space. Like `hello`, the body may be nested under `"status"` or
sent flat.

It surfaces as `plugin_status` on the camera's status (dashboard, `/api`
camera list, and the `camera_status` SSE frame).

Routing comes from the **envelope** `camera_id`, never from one inside the
status body — a `camera_id` in the body is not in the whitelist and is
discarded before it can be read:

- per-camera plugin: the status applies to your camera. You **may** include
  the envelope `camera_id` — echoing it costs nothing and keeps one code path
  for both modes — and Cairn strips it before storing, because what it stores
  is keyed by camera already. One consequence: naming a *different* camera
  does not redirect the status, it is simply discarded.
- group plugin: an envelope `camera_id` naming a member applies to that
  member. Naming a non-member drops the line (`unknown_camera`). No
  `camera_id` at all applies the status to **every** member.

Send it *when it changes*. An identical status is forwarded at most once
every 5 s as a liveness heartbeat; the rest are dropped and counted.

## Geometry

**`bbox` is `[x, y, w, h]`, normalized to 0..1 against the frame, with the
origin at the top-left corner and y increasing downward.** `x, y` is the
top-left corner of the box; `w, h` are its width and height. All four values
are in 0..1; `w` and `h` must be strictly positive.

```
(0,0) ───────────────► x
  │      ┌────────┐
  │      │        │ h
  │      └────────┘
  ▼          w
  y
```

**This is deliberately not ONVIF's convention.** ONVIF analytics metadata
uses a normalized frame whose origin is the **centre** of the image, with
axes running −1..+1 and **y increasing upward**, and expresses rectangles as
`left`/`right`/`top`/`bottom` rather than origin-plus-size. Converting an
ONVIF rectangle to a Cairn bbox is:

```
x = (left + 1) / 2
y = (1 - top) / 2
w = (right - left) / 2
h = (top - bottom) / 2
```

If you are wrapping an ONVIF-native analytics source and forget this, every
box lands mirrored vertically and half-scaled. There is no autodetection: a
mirrored box is a perfectly valid contract line.

**Letterboxing is yours to undo.** Detectors usually letterbox or pillarbox
the frame into a square model input. Boxes come out of the model in *model
input* coordinates, which include the padding. Normalizing those directly
gives boxes that are squeezed toward the centre and drift worse the further
the source aspect ratio is from the model's. Map back to the **original
decoded frame** — subtract the pad offset, divide by the scaled content size,
not by the model input size — before normalizing. `plugins/cairn-detect` does
this conversion on the way out of postprocess; it is the worked example.

Cairn never rescales, clamps or reinterprets a bbox: it stores what you sent,
draws it on snapshots at those coordinates, and publishes it verbatim to Home
Assistant.

## Time

Three clocks meet in a `frame.objects` line, and confusing them is the most
expensive mistake available in this contract.

**`frame.observed_at` — your wall clock.** Required. When the frame was
observed; capture it *before* inference, not after, or every event start
drifts by your inference latency. Cairn derives event `started_at`, label
offsets and snapshot seeks from it.

- Cairn compares it against its own clock. More than **30 s** apart and it is
  replaced by arrival time — the observation is still used, but marked
  arrival-quality, and the substitution is counted under `clock_skew`. Run
  NTP.
- It must parse as ISO8601 **with an offset** (`...Z` or `...+02:00`). A
  missing, unparseable or offset-less value drops the line.

**`frame.pts` / `frame.time_base` — the stream's own clock.** The
presentation timestamp of the analyzed frame in the RTP timeline you are
decoding, which Cairn converts to `media_ms = pts / den * num * 1000`. It is
what expires tracks (`tracking.max_unseen_ms` is media time), so it must
advance at roughly real speed for a live stream.

Media time is **not comparable across epochs**: every ffmpeg respawn restarts
the timeline. Cairn handles a backwards jump inside an epoch by expiring
nothing (negative elapsed time never exceeds a positive threshold), and a
frozen `pts` is caught by a host-clock backstop at ten times
`max_unseen_ms` — see [Track identity](#track-identity).

**Cairn's host clock.** Event `ended_at`, the post-window timers and the
status/log rate limits are the host's, not yours. This is why the skew clamp
exists: a plugin 10 minutes ahead would open events in the future and close
them in the past.

### The recording ring is not addressable by your pts

**The mapping between a plugin's RTP `pts` and the `tfdt` timestamps in
Cairn's fragmented-mp4 recording ring is UNDEFINED. Never use a plugin `pts`
to address, seek or trim a recording.**

They are two independent ffmpeg outputs of the same input. The RTP output's
timestamps are a 90 kHz clock with an arbitrary start offset; the fMP4
output's `tfdt` is a movie-timescale baseline that ffmpeg rebases per run.
Nothing in Cairn asserts, derives or verifies a relationship between them,
and nothing is planned to — establishing one was considered and deliberately
deferred. Cairn assembles a clip from the fragment ring and wall-clock times;
a plugin `pts` addresses nothing on disk. A plugin that computes a seek
offset from its own `pts` will be wrong by an unbounded amount, silently.

## Control channel (stdin)

Cairn writes ndjson to your **stdin**. One line per message, the same
envelope, the same 64 KiB line ceiling. Cairn's own control lines are a few
hundred bytes; the ceiling is stated so a reader can size its buffer and
refuse a pathological line rather than grow without bound.

```json
{"spec":"cairn.plugin","version":1,"type":"stream.started",
 "camera_id":"front_door","stream_epoch":"01J8ZQ...","rtp":{"clock_rate":90000}}
{"spec":"cairn.plugin","version":1,"type":"stream.ended",
 "camera_id":"front_door","stream_epoch":"01J8ZP...","reason":"started"}
```

| field | meaning |
|---|---|
| `camera_id` | which camera this is about. Present on both types, always, including for a per-camera plugin |
| `stream_epoch` | the epoch starting (`stream.started`) or ending (`stream.ended`) |
| `reason` (`stream.ended` only) | why the **new** epoch was minted — see below |
| `rtp.clock_rate` (`stream.started` only) | 90000, the RTP clock of the feed |

**You MUST read (or at least drain) stdin.** Writes never block Cairn: when
your stdin buffer fills, control lines are dropped and counted
(`control_stdin_busy`), and you are left believing an epoch that has ended —
your lines are then dropped as `stale_epoch`, silently, for as long as it
takes. Cairn does not resend the dropped line, but it does not record the
epoch as announced either, so the next epoch change (or your next restart)
tells you again. A plugin that has no use for the control channel must still
read and discard it. Closing stdin is worse than ignoring it: an `:epipe` on
the next write tears down the port and restarts you.

### `stream.ended` reasons

`reason` describes why the *replacement* epoch was minted, not a diagnosis of
the stream that ended:

| reason | meaning |
|---|---|
| `started` | a new decode started (normal ffmpeg (re)spawn) |
| `source_lost` | ffmpeg exited or the source went away, and is being restarted |
| `stall_bounce` | the silent-stream watchdog bounced ffmpeg |
| `camera_stopped` | the camera was stopped. **Nothing replaces this stream** — no `stream.started` follows until that camera streams again |

### `stream.started` is identity, not liveness

**`stream.started` tells you the last known stream identity for a camera. It
is not proof that media is flowing.** The per-spawn announcement is replayed
from Cairn's record of the last epoch for each camera you serve, and that
record survives your process while the announcement state does not. So after
a plugin restart you may be told `stream.started` for the last epoch of a
camera that has since stopped, with no `stream.ended` ever following.

Use it to *tag* lines. Judge liveness from RTP flow, and expect a camera you
have been "started" for to send nothing at all, indefinitely.

## Stream epochs

A **stream epoch** is a ULID naming one continuous decode of one camera.
Cairn mints a new one on every ffmpeg (re)spawn: after an outage the camera
may have moved, so nothing — track identity, `pts` continuity, decoder state
— may cross the boundary.

Rules, all of them enforced:

1. **Stamp every `frame.objects` line with the epoch of the camera it
   describes.** Cairn compares it against the epoch currently in force for
   that camera and drops any line that does not match (`stale_epoch`). That
   is the point: such a line describes a stream that no longer exists.
2. You are told the current epoch for every camera you serve immediately
   after you start, and again whenever it changes.
3. `stream.ended` precedes the new `stream.started` **only when Cairn had
   already announced a live epoch to this plugin process.** At first spawn
   you get a bare `stream.started`.
4. On a new epoch, drop your decoder state and your track identities for that
   camera and resync on the next keyframe.
5. Epochs are strictly per camera and never shared. In a group, one member's
   epoch change must not reset anything belonging to another member.
6. **You will never be told about an epoch minted in an earlier millisecond
   than one you have already been given** for that camera. Announcements can
   race (Cairn's degraded broadcast path has no ordering relation to its
   server's), so Cairn drops an out-of-order older announcement rather than
   walking you backwards onto a dead stream. The comparison is on the ULID's
   10-character timestamp prefix, so two epochs minted in the *same*
   millisecond count as one instant and the later announcement is applied —
   in practice mints for one camera are an ffmpeg respawn plus backoff apart.
   A repeat of the epoch you already hold is likewise suppressed — but treat
   a repeat as a no-op anyway.
7. A duplicate epoch is possible by design elsewhere in Cairn; idempotence on
   your side costs nothing.

An epoch you were never told about is as good as a stale one: `"unknown"`,
`""`, or a value you invented all fail. Emitting before your first
`stream.started` is legal and useless — see [Before your first
`stream.started`](#before-your-first-streamstarted).

## Sequence numbers

`sequence` is **your** counter, one per camera, incremented by one per
emitted `frame.objects` line for that camera. It exists so a gap between your
process and Cairn is visible rather than silent.

- A **forward gap** (`sequence > last + 1`) is counted as that many drops
  under `sequence_gap`, emits the `[:cairn, :plugin, :sequence_gap]`
  telemetry event with `%{count: gap}` and `%{camera_id: ...}`, and the line
  that revealed it is still processed. A gap is information, never a reason
  to discard data.
- Anything else — a repeat, a decrease, the first line after a restart —
  silently re-baselines the counter. Cairn does not police monotonicity;
  restarting at 0 after a respawn is expected and costs nothing.
- The counter resets, host-side, with your OS process. In a group it is
  tracked per member camera, so members do not need to share a counter.

**Across an epoch boundary, both conventions are valid.** You may restart the
counter at 0 for each new epoch, or keep it monotonic for the life of the
camera. Cairn re-baselines its own comparison when a camera's epoch changes —
a new epoch is a new sequence timeline — so neither convention costs you a
false gap, and neither does the line you had already emitted under the
retired epoch (refused as `stale_epoch`, and never counted a second time as
a lost frame). `plugins/cairn-detect` keeps it monotonic per camera.

**Only accepted lines move the host's baseline.** A line Cairn refused — a
stale epoch, a malformed field — never advances it. So if you suppress
frames (see [below](#before-your-first-streamstarted)) *and* advance the
counter for them anyway, the next accepted line reports a gap that describes
nothing. Advance the counter when you emit, not when you decode.

### Before your first `stream.started`

Until Cairn has told you a camera's epoch you have nothing valid to stamp a
line with, and every line you emit for it will be refused — an absent
`stream_epoch` fails the envelope, an invented one fails the epoch
comparison. The recommended behavior is therefore:

- decode and drop, or simply do not decode, until that camera's first
  `stream.started` arrives;
- **emit nothing** for it, and do not advance its sequence counter;
- resume normally on the announcement, resyncing at the next keyframe.

Nothing here is enforced — a plugin that emits into the void is merely
wasteful, and its lines are counted as drops rather than believed.

## Track identity

Cairn publishes every tracked object under a **ULID `object_id`** — the same
string that appears in an event's `labels[].object_id` and `trigger.object_id`
and on every `track_started` / `track_updated` / `track_ended` frame (see
[`docs/ha-api.md`](ha-api.md#track-frames)).

Who decides identity depends on one capability:

**Without `capabilities.object_tracking: true`,** `track_id` is ignored
entirely. Cairn matches boxes host-side by greedy IoU (threshold 0.1, raised
to 0.7 for a stationary track riding out the extended grace below) among the
live tracks *Cairn itself owns* of the same label. Nothing breaks if you
send ids anyway — they are simply decoration. Tracks a plugin owns are never
IoU candidates, which matters only if you turn the capability off mid-run:
the tracks you owned until then are unmatchable afterwards and expire on
`max_unseen_ms` rather than being adopted.

A host-side identity can **survive a stream reset**. At an epoch boundary
these tracks are suspended rather than ended, and a detection on the far side
that lands on one of them resumes it — same `object_id`, same `started_at`,
new `epoch`. How much overlap that takes depends on how long the outage was:
inside `max_unseen_ms` of absence — and at most three seconds of it, whatever
`max_unseen_ms` is set to — any suspended track will answer at 0.4, beyond it
only one Cairn had judged stationary will, and only at 0.7. A minute after the
**cut** nothing is adoptable any more and the track ends `stream_reset`,
timestamped at the last observation before the cut, which on a stream that had
already gone quiet can be well over a minute earlier. None of this needs
anything from you: it is geometry over the boxes you send.

**With it,** Cairn honours your ids and runs no box matching:

- `(your plugin instance, stream epoch, track_id)` maps 1:1 onto a ULID for
  the life of that triple. Reuse a `track_id` for the same object and it
  keeps its identity. The plugin instance is your camera id (per-camera) or
  your group name (group).
- **Ids are scoped to the epoch.** At an epoch boundary Cairn ends every track
  it holds for you with a final summary (`stream_reset`) and starts fresh —
  reusing an id across the boundary gets you a new object, not the old one.
  (Only *host*-owned tracks survive a boundary, by geometry; an identity you
  own is yours, and Cairn will not revive one behind your back.)
- List an id in `ended_tracks` when the object is gone. Cairn ends the track
  and sends its final summary (`plugin_ended`). `ended_tracks` is honoured
  only under the capability, same as `track_id`.
- **Never reuse an id you have ended.** Cairn logs a contract violation and
  treats it as a brand-new object (new ULID). It remembers up to 4 096 ended
  ids per camera tracker, halving the memory when that fills — reuse after a
  very long run may therefore go unreported, but never rebinds the old
  identity.
- **One `track_id` per object per line.** The same id twice in one
  `objects` list is a violation: the first occurrence wins and the duplicate
  object is dropped.
- Cairn expires a track you stop mentioning after `max_unseen_ms` of *media*
  time (default 3 s, per-camera configurable) — `ended_tracks` is a courtesy,
  not a requirement. A track Cairn has judged **stationary** (its box held
  still for `tracking.stationary_after_ms`) gets five times that bound
  instead, so a parked object outlasts whatever parks in front of it.

### Host policy: the live set is bounded

`media_ms` is your clock, so media-time expiry alone would leave a plugin
holding the key to Cairn's memory. Two host-side bounds close that. Neither
should ever be reachable by a plugin that behaves:

- **Host-clock backstop.** A track unseen on the *host's* clock for more than
  **ten times** its media-time bound — `max_unseen_ms`, or five times that
  for a stationary track — is expired whatever your `pts` says. A frozen
  or rewound frame clock cannot keep tracks alive.
- **Live-track cap.** Each camera holds at most `tracking.max_live_tracks`
  live tracks (default 128, per-camera configurable). At the cap, minting a
  new identity retires the least recently seen one with a final summary
  (`evicted`); if every live track was already claimed by the current line,
  the *new* object is dropped instead. Minting a fresh `track_id` per frame
  is what this exists for.

### Known limitation: identity survives your restart

Identity is scoped to `(plugin instance, epoch, track_id)`, and the plugin
instance is the camera id or group name — **it does not change when your
process restarts**. If your plugin crashes and respawns *within* one stream
epoch and resumes emitting the same `track_id` values from zero, those ids
resume the ULIDs they were previously bound to, and a new physical object can
inherit an old track's public identity.

This is accepted and documented rather than fixed. Two things make it
tolerable: an epoch boundary (the common cause of a plugin restart being
worth noticing) does cut identity, and a plugin whose ids are counters
starting at 1 will collide only with tracks still live from before the crash.
If it matters to you, make your `track_id`s unique per process run — a
per-spawn prefix is enough, and Cairn imposes no structure on the string.

## Limits

Every numeric bound in the contract, in one place. Exceeding a bound in the
**line** column drops the whole line; the **field**/**object** columns drop
only that much.

| what | limit | effect of exceeding |
|---|---|---|
| stdout line length | 65 536 bytes (64 KiB) | line dropped |
| stdin line length | 65 536 bytes (64 KiB) | Cairn never sends more; size your reader for it |
| `objects` per `frame.objects` | 64 | line dropped |
| `dets` per v0 line | 64 | detections dropped, line still forwarded as empty |
| `ended_tracks` per line | 64 | line dropped |
| `label` | 1..64 bytes, printable | object dropped |
| `score` | 0..1 | object dropped |
| `bbox` | 4 numbers; `x`,`y`,`w`,`h` ∈ 0..1; `w`,`h` > 0 | object dropped |
| `track_id` | 1..64 bytes, printable | object dropped |
| `observation_kind` | `"detected"` \| `"tracked"` | object dropped |
| `camera_id` (group) | 1..256 bytes | line dropped |
| `frame.pts` | \|pts\| ≤ 2^62 (4 611 686 018 427 387 904) | line dropped |
| `sequence` | integer 0..2^62 | line dropped |
| `frame.time_base` `num`, `den` | integers 1..1 000 000 000 | line dropped |
| `frame.observed_at` skew vs host clock | ±30 000 ms | timestamp replaced by arrival, line kept, counted |
| `hello.name`, `hello.version` | 1..64 bytes, printable | field dropped |
| `hello.supported_versions` | first 16 entries considered; each an integer 0..1000 | extra/invalid entries dropped |
| `hello.capabilities` | at most 32 entries; keys 1..32 bytes printable, values boolean | extra/invalid entries dropped |
| `status.state` | 1..32 bytes, printable | line dropped |
| `status.detail` | ≤ 256 bytes, printable | field dropped |
| `status.fps` | 0..10 000 | field dropped |
| identical `plugin.status` resend | at most 1 per 5 000 ms | extras dropped, counted |
| drop-summary log | at most 1 per 5 000 ms | — |
| `tracking.max_unseen_ms` | default 3 000 ms of media time (× 5 while stationary) | track ended (`unseen`) |
| host-clock backstop | 10 × the applicable media-time bound | track ended (`unseen`) |
| `tracking.max_live_tracks` | default 128 per camera | least recently seen track evicted |
| `tracking.stationary_after_ms` | default 10 000 ms of media time | track flagged `stationary`, and no longer event evidence |
| ended-`track_id` memory | 4 096 per camera tracker | halved; older reuse goes unreported |
| host IoU match threshold | 0.1 (0.7 for a stationary track in extended grace) | below it, a new track is minted |
| `track_updated` throttle | best-score improvement, or 1 000 ms | update not published |
| respawn backoff | 1 s → 30 s base, ×0.5–1.5 jitter (≈0.5 s → ≈45 s) | — |
| UDP ports per camera | 4 (`base + 4i` plugin, `+1` its RTCP) | — |

## What gets dropped

Malformed input never crashes anything and never kills the plugin — but it
also never detects anything. Every drop is counted per class, and the running
totals are logged **by Cairn, to its own log**, at most once every 5 s — not
to `{data_dir}/log/plugin-{camera}.log`, which is a redirect of *your* stderr
and carries nothing Cairn writes. Counters reset with your OS process, so a
fixed plugin logs a fresh summary after its restart.

The classes you will actually see, and what they mean:

| class | cause |
|---|---|
| `malformed_json` | the line is not valid JSON |
| `not_an_object` | valid JSON, but not an object |
| `unknown_spec` | `spec` present and not `"cairn.plugin"` |
| `unsupported_version` | `version` present and not `1` |
| `invalid_envelope` | `spec` fine, but `version` is missing or not an integer, or `type` is missing or not a string (a *present* `version` other than 1 is `unsupported_version` instead) |
| `missing_camera_id` | group mode: `camera_id` absent or out of bounds |
| `unknown_camera` | group mode: `camera_id` names no member of this group |
| `invalid_stream_epoch` | `stream_epoch` missing or not a non-empty string |
| `invalid_sequence` | `sequence` missing, negative, or over 2^62 |
| `invalid_frame` | `frame` missing or not an object |
| `invalid_pts` | `frame.pts` missing, not a number, or out of bounds |
| `invalid_time_base` | `frame.time_base` present and malformed |
| `invalid_observed_at` | `frame.observed_at` missing or not ISO8601-with-offset |
| `invalid_objects` | `objects` missing or not a list |
| `too_many_objects` | more than 64 objects |
| `invalid_ended_tracks` | not a list, over 64, or an entry that is not a printable ≤64-byte string |
| `invalid_det` | *per object*: an object that failed its own rules |
| `invalid_status` | `plugin.status` with no usable `state` |
| `missing_pts_or_dets` | v0 line without a numeric `pts` and a list `dets` |
| `stale_epoch` | the line's `stream_epoch` is not the camera's current one |
| `clock_skew` | `observed_at` more than 30 s from the host clock |
| `sequence_gap` | forward jump in `sequence` (counted per missing line) |
| `status_rate_limited` | identical status inside the 5 s window |
| `control_stdin_busy` | a control line Cairn could not write — you are not reading stdin |
| `control_stdin_closed` | you closed stdin |
| `codec_crash` | a line that made Cairn's decoder raise. Report it |

An unrecognized `type` is **not** a drop: it is ignored, silently and by
design.

## Forward compatibility

- **Ignore fields you do not recognize**, at every level — in messages,
  in objects, in `--cameras-json` members. Cairn does the same to you.
- **Ignore message `type`s you do not recognize.** New types are additive;
  Cairn ignores unknown ones rather than dropping the connection, and expects
  the same.
- A *malformed known field* is different from an unknown one: it drops
  something (the line, the object or the field, per the [limits
  table](#limits)) and is counted.
- New fields will be optional with a documented default. A change that is not
  backward compatible gets a new `version`, and `supported_versions` in your
  hello is how you will be asked about it.
- v0 and v1 lines may be mixed on one stdout. There is no reason to.

## Logging

**stderr only.** Cairn redirects it to `{data_dir}/log/plugin-{camera}.log`
(for a group, `plugin-{group}.log`). Anything you print to stdout that isn't
contract ndjson is dropped with a warning.

## Lifecycle

- Started when the camera starts; killed (SIGTERM) when the camera stops.
- If you exit — crash or normal — Cairn restarts you with jittered backoff
  (1 s → 30 s). Exiting on unrecoverable errors is the correct behavior.
- Be idempotent on restart: you may be re-run mid-stream at any time, and
  you must cope with joining an RTP stream mid-GOP (decoders resync on
  the next keyframe).
- Everything argv carries (min scores, camera id, port, group membership)
  changes only across restarts, never mid-run.
- A fresh process is told nothing it knew before: epochs are re-announced,
  your sequence counters are expected to restart, and Cairn's drop counters
  and recorded `hello` reset with you.

A group's lifecycle is deliberately different — see [Shared log and
lifecycle](#shared-log-and-lifecycle).

## Multiplexed plugins

Some accelerators can only be held by one process at a time — an Edge TPU is
the motivating case — so one process per camera can never share them. A
plugin can instead be declared once and serve several cameras from a single
process: N RTP inputs in, one ndjson stream out, every line tagged with the
camera it came from.

Everything above is additive and unchanged. Cameras with an inline `plugin:`
command keep the per-camera contract alongside any groups.

### Declaring a group

```yaml
plugins:
  detect:
    # the path to your built binary, resolved from Cairn's own working
    # directory — not from the plugin's
    command: plugins/cairn-detect/target/release/cairn-detect --model yolox_nano.onnx --labels coco.names

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
    plugin: ["./cairn-detect", "--model", "yolox_nano.onnx"]
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
**required** on every `frame.objects` (and every v0) line, and names the
member the line describes.

A line whose `camera_id` is missing or does not name a member of this group
is logged and dropped — Cairn routes by that field alone, having no port or
process to attribute it to. For per-camera plugins `camera_id` remains an
optional echo.

One process, one `plugin.hello`: the capabilities you declare apply to every
member. `plugin.status` routes per member as described in
[`plugin.status`](#pluginstatus).

The [control channel](#control-channel-stdin) is per member too: one
`stream.started` per member camera after you start, and an ended/started pair
whenever *one* member's stream is replaced. Keep one epoch per member, and
never take a member's epoch change as a reason to reset anything else.

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

## Appendix A: protocol v0

v0 is the original line shape. **It is supported indefinitely** — there is no
deprecation date and no plan for one. A plugin that never sends a
`plugin.hello` is assumed to speak it, and any line without a `spec` field is
read as v0 regardless of what else it contains.

```json
{"camera_id": "front_door", "pts": 90000, "dets": [
  {"label": "person", "score": 0.87, "bbox": [0.12, 0.4, 0.2, 0.5]}
]}
```

| field | rule |
|---|---|
| `pts` | **required.** A JSON *number*, \|pts\| ≤ 2^62. A line whose `pts` is the string `"90000"` is dropped whole — some JSON emitters do that to 64-bit values by default |
| `dets` | **required**, may be empty. A list of detections; `label`, `score` and `bbox` follow exactly the [object rules](#objects) |
| `camera_id` | required for a group (1..256 bytes), optional and ignored per camera |

A `dets` list longer than **64** entries is a contract violation, but it is
handled differently from v1's `objects`: the line is still forwarded, with
**zero** detections, and all of its entries are counted as drops. The empty
line survives as your liveness signal; nothing in it is believed.

What v0 costs you, and what v1 fixes:

- **No time.** Cairn stamps arrival instead, so the observation is
  arrival-quality: every event offset derived from it includes your queueing
  and scheduling latency. There is no `observed_at` to skew-check.
- **No epoch.** The line is attributed to whatever epoch is current at the
  moment it lands. An epoch changing while a line is in flight silently
  misattributes it — the stale-epoch check cannot run, because there is
  nothing to check.
- **No sequence.** Gaps between your process and Cairn are invisible.
- **No track ids and no `ended_tracks`.** Every object is `"detected"` with
  no identity, so tracking is always host-side IoU. `capabilities` cannot be
  declared without a hello, so this is consistent rather than a limitation.
- **No status.** Nothing surfaces on the dashboard for the plugin.

`time_base` is fixed at `[1, 90000]` for v0 — the RTP clock. Everything else
about a detection (bounds, geometry, printability, the 64-detection cap) is
identical to v1, and the [limits table](#limits) covers both.

The control channel still runs: Cairn writes `stream.started` and
`stream.ended` to a v0 plugin's stdin exactly as it does for a v1 one, and
the requirement to read or drain stdin is unchanged. A v0 plugin simply has
no way to act on what it is told.
