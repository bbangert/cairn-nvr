# cairn-detect

Cairn's reference detection plugin: a single Rust binary that takes H.264 RTP
on a UDP port — or on several at once, serving a whole plugin group from one
process — and speaks the plugin contract's protocol v1 on stdout and stdin
(see `docs/plugin-contract.md`). It decodes on the video ASIC when one is
available, samples to ~5 fps, and runs an object-detection model on the CPU
through onnxruntime. The two documented defaults are **YOLOX-Nano** and
**RF-DETR-Nano**, both Apache-2.0 like Cairn itself; end-to-end (YOLOv10,
YOLO26) and raw Ultralytics (YOLOv8/v9/v11) heads also decode if you bring
your own weights. Which family a model belongs to — and so how frames must be
fed to it and how its output must be read — is one
[profile](#model-profiles), sniffed from the model itself unless the shape is
genuinely ambiguous, in which case the plugin refuses to guess.

It is both what you should deploy and the worked example to read when writing
your own plugin: everything the contract requires of a plugin is exercised
here, in the two modes Cairn can launch one in.

## At a glance

```
udp:127.0.0.1:{port}  ->  sdp demuxer (generated SDP, retried mid-GOP)
   -> decode (hardware if a backend opens, else software)
      -> wall-clock sample to 5 fps          <- full-rate frames end here
         -> stamp observed_at, resize per profile (stretch | letterbox),
            RGB24 -> CHW f32, and the projection back to frame coordinates
            -> [size-1 channel, try_send: drop when inference is behind]
               -> onnxruntime (CPU EP) -> decode + gate
                  -> frame.objects ndjson on stdout, per-camera epoch + sequence

stdin  ->  control thread  ->  per-camera stream epoch map
```

Everything expensive happens *after* the sample gate: a hardware decoder
never pays to scale or download the ~55 fps of frames it is about to discard,
and inference runs on its own thread so a slow model pass can never stall the
socket read. stdin has a thread of its own for the same reason in reverse —
Cairn writes epochs without waiting for us, so they have to be read without
waiting for anything else.

## Build (dev container)

`.cargo/config.toml` points the build at the FFmpeg 7 tree in `/opt/ffmpeg7`
and bakes an rpath so the binary runs without `LD_LIBRARY_PATH`:

```bash
cd plugins/cairn-detect
cargo build --release
```

`ort` downloads a prebuilt static onnxruntime on the first build (~90 MB,
cached in `~/.cache/ort.pyke.io`), so that build needs network. Building
anywhere else means overriding both settings — see [Shipping](#shipping).

The crate needs FFmpeg 6/7 headers; Debian 12's system FFmpeg (5.1) is too old
for rsmpeg, which is why `/opt/ffmpeg7` exists in this container.

### glibc note

The prebuilt onnxruntime is compiled against glibc >= 2.38, which redirects
`strtol` and friends to `__isoc23_*` symbols that Debian 12 (glibc 2.36) does
not export. `src/glibc_compat.rs` forwards those four symbols to their C99
equivalents.

The shims are compiled unconditionally on linux-gnu, so they are *harmless*
rather than inert: even on glibc 2.41 the statically linked onnxruntime keeps
calling them and gets C99 parsing (no `0b` prefix), which its config parsing
never depends on. They are not exported in `.dynsym`, so they cannot interpose
glibc's versions for FFmpeg or any other shared library — that stops being
true if anyone adds `-rdynamic`/`--export-dynamic` to `RUSTFLAGS` or builds
this as a cdylib. Delete the module once no build host is older than 2.38.

## Wire into config.yml

Plugin flags go *before* the contract args, which Cairn appends
(`--camera-id`, `--udp-port`, `--min-score-json`). Paths are relative to the
directory Cairn runs from:

```yaml
cameras:
  - id: front_door
    rtsp_url: rtsp://user:pass@192.168.1.10:554/stream1
    # An argv list (or a multi-word string) is an inline command: this
    # camera's own process. Receives RTP on an assigned UDP port, prints
    # ndjson detections on stdout.
    plugin:
      - plugins/cairn-detect/target/release/cairn-detect
      - --model
      # .onnx files are gitignored — fetch this one with the curl in the
      # Model section (or drop in any supported model; see Model).
      - plugins/cairn-detect/yolox_nano.onnx
      # The labels file belongs to the model above it, not to the plugin:
      # coco.names is the 80-entry list YOLOX and the Ultralytics families
      # emit, RF-DETR needs the 91-entry coco91.names. Changing --model
      # without changing this is a startup error, not a silent mislabel.
      - --labels
      - plugins/cairn-detect/coco.names
      - --decoder
      - auto
    min_score:
      default: 0.5
      person: 0.6
```

Logs land in `{data_dir}/log/plugin-front_door.log`. `--decoder auto` is the
default and can be omitted.

To serve several cameras from one process, declare the same command once as a
named group under `plugins:` and point cameras at it by name — see
[Multiplexed mode](#multiplexed-mode).

| flag | required | meaning |
|------|----------|---------|
| `--model` | yes | ONNX detection model: yolox `[1,A,5+nc]`, detr `[1,Q,4]`+`[1,Q,nc]`, end-to-end `[1,N,6]` or raw `[1,4+nc,A]` (see [Model](#model)) |
| `--labels` | no | newline-separated class names, **indexed by class id** — line 1 is class 0. Must match the model: a count that disagrees with the model's class count is a startup error, because positional indexing would emit every detection under another class's name. Ids past the end, and blank lines (unnamed slots), fall back to the numeric id |
| `--allow-label-mismatch` | no | start anyway when `--labels` and the model disagree about the class count. For a deliberately partial label file; the mislabelling it permits is silent |
| `--input-size` | no, except RF-DETR | model input `WxH` (or `N` for a square N×N). Read from the model when omitted; **required** when the model's spatial dims are dynamic, which every RF-DETR export leaves them — `--model-profile` does not substitute for it there (see [Geometry](#geometry)) |
| `--model-profile` | no | `yolox`, `rfdetr`, `yolov10` or `yolov8` (plus the aliases `rf-detr`, `yolo26`, `yolov9`, `yolo11`, `yolov11`) — the preprocessing and decode steps to run the model under. Sniffed from the model when omitted; required when a shape fits more than one profile or the model's *output* shape is dynamic (see [Model profiles](#model-profiles)) |
| `--decoder` | no | `auto` (default), `vaapi`, `qsv`, `nvdec`, `v4l2`, `videotoolbox`, `sw` |
| `--motion-json` | no | JSON object of motion-gate knobs. **Off by default** — see [Motion gate](#motion-gate) |
| `--track-floor-json` | no | JSON object with one knob, `floor`: emit detections below their class's `min_score` down to it, for the host's low-confidence tracking stage. **Off by default** — see [Track floor](#track-floor) |

## Motion gate

A Frigate-style no-change filter: each sampled frame is downscaled to a small
grayscale thumbnail, compared against a rolling-average background of the
frames before it, and the fraction of the thumbnail that changed is what the
gate reads. **It is off unless you switch it on.**

With it on, a sample of a scene that is not changing skips the model pass — the
dominant cost — and is emitted anyway, carrying the last real inference's boxes
at the scores that inference gave them, marked `"observation_kind": "tracked"`
so the host can tell a re-report from evidence. A gated camera with nothing
remembered emits the empty-`objects` liveness line instead. Every sample the
plugin would have emitted before still produces exactly one line — a camera
Cairn has not started still emits nothing at all ([The control
channel](#the-control-channel)) —
so the gate changes what a run costs and not what the host sees arriving.

Skipping is bounded on all sides: the model runs anyway for `linger_ms` past
the last motion, for `epoch_bypass_ms` after Cairn restarts the stream, every
`reverify_ms` while gated, on a camera Cairn has not started, on a frame read
as a scene cut (an IR-cut flip, a light coming on: the background it was
measured against is gone, so nothing measured says the scene is still), and
throughout the calibration window of a motion detector that has just been
built — the state a plugin-side reconnect leaves a camera in, which arrives
with no epoch change to bypass with. A scene cut is not treated as motion: it
buys the one model pass that looks at the new scene, not `linger_ms` of them.

```yaml
plugin:
  - plugins/cairn-detect/target/release/cairn-detect
  - --model
  - plugins/cairn-detect/yolox_nano.onnx
  - --motion-json
  - '{"enabled": true, "min_area_fraction": 0.005}'
```

| knob | default | meaning |
|------|---------|---------|
| `enabled` | `false` | run the gate at all. With this off no detector is built and no thumbnail is taken. The knobs below that have ranges are still checked either way, so an out-of-range value fails startup even with the gate switched off |
| `threshold` | `25` | per-pixel 0..255 difference from the background that counts as changed (`1..=254`; the comparison is strict and 255 is the largest difference there is, so 255 would count nothing) |
| `min_area_fraction` | `0.005` | fraction of the thumbnail that has to change before the frame counts as motion (`(0, 0.8)`; a frame that changes more than 80 % is a scene cut, so a floor at or above that is refused at startup rather than left unreachable) |
| `alpha` | `0.02` | how fast the background absorbs the picture: `bg = (1 - alpha) * bg + alpha * frame`, per sample (`(0, 1]`). At the 5 fps sample rate this is roughly a 10-second memory, and something that parks in frame keeps reading as motion for at least that long — longer the more it contrasts with what it covers, since the background has to decay to within `threshold` of it |
| `linger_ms` | `12000` | how long past the last motion to keep inferring anyway |
| `epoch_bypass_ms` | `15000` | how long after a stream restart to infer regardless of motion |
| `reverify_ms` | `10000` | how often to infer anyway while gated |

The last three are accepted but not range-checked, deliberately: every unsigned
duration is a policy the gate can honour. `0` switches its rule off (no linger,
no bypass; `reverify_ms: 0` is a gate that re-verifies every sample and so never
skips one), and a duration longer than the run leaves that rule always on.
Setting one wrongly costs inference that was or was not skipped, which a run's
own output shows.

An unknown knob *inside* a `motion` object is a startup error rather than a
setting that silently does nothing, so a typo'd knob fails loudly. The `motion`
key itself is not checked that way: a `--cameras-json` member carrying `"moton"`
parses, is ignored, and leaves that camera on the group's settings — the member
object stays open to keys Cairn may add.

Two behaviours are not knobs. The first 25 samples (5 seconds) after a start or
a geometry change are a calibration window in which no frame reports motion —
the background is still the scene that happened to be in front of the camera.
And a frame in which more than 80 % of the thumbnail changed is treated as a
scene cut, not as motion: the background is replaced with it outright and the
frame reports no motion, which is what keeps an IR-cut filter flipping or a
light switch from reading as the whole frame moving. Neither of the two is a
reason to skip a model pass — both are in the list of bounds above, because
"no motion" from a background that is still being learned, or from one that
has just been thrown away, is not a measurement of the scene.

The calibration window and `alpha`'s memory are both counted in samples, and
5 fps is a ceiling on the sample rate rather than the rate itself — the gate
takes at most one sample every 200 ms and otherwise takes whatever the camera
delivers. On a 2 fps substream the calibration window is 12.5 seconds and the
10-second memory is 25, so read every second in this section as "at this
camera's sample rate".

**Frigate's published numbers do not transfer as-is.** Frigate compares motion
on a frame around 100 px high; the thumbnail here is at most 96 px *wide*,
shaped from the content rectangle, and it is compared at up to 5 fps rather
than at the camera's full rate. A fraction measured on one of those is not the
same quantity as a fraction measured on the other, so treat the defaults as a
starting point and tune `min_area_fraction` against the change fractions your
own cameras produce.

They are not a starting point far from the answer, either. Across the gate-on
runs of a two-minute clip from a 2560×1920 camera looking at a parked car, the
peak changed fraction of each 5-second window ran **0.20 % to 0.55 %** — either
side of the 0.5 % default. The gate's own `plugin.status` reports that peak
(below), so the number to set the floor against is one the plugin will tell
you.

What it costs to sit on the floor is that small things decide the outcome. Each
fraction that crosses it arms `linger_ms`, and each `linger_ms` is 12 seconds of
inference, so:

- two runs of that clip at the same knobs on the same build gated **67 %** and
  **57 %** of their samples;
- the same clip gated **67 %** under yolox and **31.7 %** under rfdetr, between
  which the only relevant difference is the thumbnail's shape — 96×72 under
  yolox's letterbox, 96×96 under rfdetr's stretch — which moved the reported
  window peaks from 0.20–0.35 % to 0.21–0.55 %;
- with the floor at `0.02`, clear of that camera's noise, it gated **73 %**.

### What the gate keeps true

Five rules, and where each one lives:

1. **A gated sample is never silently swallowed.** Every sample the plugin
   would have emitted before still emits exactly one line — the remembered
   boxes as `"tracked"`, or the empty-`objects` liveness line when there is
   nothing remembered. (A camera Cairn has not started still emits nothing, as
   above: the gate changes what is in a line, never which samples produce one.)
   An empty line ages the host's live tracks toward their unseen bound, so a
   parked object the gate stopped inferring on would retire while it was still
   standing there; seeding is what keeps it seen, and the empty line stays the
   "alive, saw nothing" signal it always was. (`gate::sample_line`,
   `Publisher::seeded_line_for`.)
2. **A seed never improves on the score the model gave it.** Seeds are held at
   the score of the detection they were copied from, so they cannot beat the
   host's `best_score` for that track and cannot bypass its publish throttle —
   the host would broadcast a track update for a frame nothing looked at.
   (`emit::CameraState::last_dets`.)
3. **A stream reset is inferred through, not seeded through.** The host
   suspends its live tracks at a reset and refuses a `"tracked"` object as
   proof any of them is back, so a seed cannot re-establish what the reset
   suspended. `epoch_bypass_ms` (15 s, well inside the host's 60 s adoption
   window) forces real inference across it, and the remembered boxes are
   cleared outright at the epoch change so nothing from before the cut can be
   re-reported after it. (`Gate::decide`, `Publisher::emit`.)
4. **Inference outlasts the motion it is judging.** The host earns a track's
   `stationary` flag from detections alone, so `linger_ms` (12 s) keeps the
   model running past the last motion — longer than the host's ~10 s
   `stationary_after_ms`. (`Gate::decide`.)
5. **Seeding is protocol v1 only**, which is what this plugin speaks. v0 has
   no `observation_kind` and no way to say a box is a re-report.

### Telemetry

With the gate on, a camera emits a `plugin.status` when the answer to "are
this camera's samples reaching the model" changes — plus one baseline report
at its first closed window, change or not, so a camera that never gates still
says so once, about 5 s after its first sample:

```jsonc
// verbatim from a gate-on run of a recorded clip
{"spec":"cairn.plugin","version":1,"type":"plugin.status","camera_id":"test",
 "status":{"state":"ready","fps":2.9067005603144356,
           "detail":"motion gate: detecting -> gated; 2.91 fps inferred of 4.46 sampled over 5.2 s; peak change 0.22%"}}
```

`fps` is the **effective inference rate** — model passes per second, not
samples per second. With the gate off the two are the same number and nothing
is reported; with it on, the difference between `fps` and the sample rate in
`detail` is what the gate bought. `peak change` is the largest changed fraction
in that window, which is the number to tune `min_area_fraction` against.

The state is read over a **5-second window and is `gated` if the gate skipped
any of its samples**, so the `reverify_ms` pass does not read as the camera
leaving the gate, and at most one status per camera per window can be sent.
`state` stays `ready`: this is health, not a new lifecycle state.

Neither limit — the gate's or the host's — costs a report. The host stores and
broadcasts a status that differs from that camera's last one, and re-sends an
identical one only once every 5 s as a liveness heartbeat, dropping and
counting the repeats in between (see the wire protocol below). A gate report
always differs from the one before it, because reports fire on a state change
and consecutive details therefore name opposite transitions; and the gate's
window is the same 5 s as the heartbeat interval, so even a repeat would be
due.

## Track floor

`min_score` is where a detection stops being worth reporting. That is the
right cut for *evidence* — what starts an event, what gets recorded — and the
wrong one for *tracking*: an object walking behind a bush drops to 0.2 for a
few frames and comes back at 0.8, and a plugin that emits neither of the
middle frames leaves the host's tracker guessing whether the thing that came
back is the thing that left.

`--track-floor-json` lowers the emission cutoff and nothing else. With
`'{"floor":0.1}'` and a `min_score` of 0.5, every detection from 0.1 up is
emitted, at the score the model gave it, as an ordinary `detected` object.
**It is off unless you switch it on**, and a run without it emits exactly what
it emitted before the flag existed — byte for byte.

```yaml
plugin:
  - plugins/cairn-detect/target/release/cairn-detect
  - --model
  - plugins/cairn-detect/yolox_nano.onnx
  - --track-floor-json
  - '{"floor": 0.1}'
```

| knob | default | meaning |
|------|---------|---------|
| `floor` | absent | score down to which detections below their class's `min_score` are emitted anyway. Must be in `(0, 1)` and **strictly below every `min_score` on the camera it applies to**, or startup fails naming the floor it collided with |

Both bounds are refused rather than clamped. At or below 0 every box the model
proposes goes on the wire, which is noise the host has nothing to match it
against much under 0.05; at or above the lowest `min_score` the band
`[floor, min_score)` is empty and the flag is doing nothing the operator can
see. The pairing is per camera, so in a group the same `--track-floor-json` can
be legal for one member and refused for its neighbour — the message names the
member.

Nothing on the wire marks a sub-floor box, and nothing needs to: the host
applies the same floors to the same scores, and what it does with the ones
below is [its own two-stage
association](../../docs/plugin-contract.md#argv) — a low-confidence box may
take a live track that this frame's confident boxes did not, and it may never
mint a new one.

### What the flag keeps true

1. **It lowers a cutoff; it does not add a pipeline.** The band goes through
   the same per-class gate, the same NMS and the same caps as everything else,
   in one pass — so a sub-floor box is suppressed by a stronger box of its own
   class exactly as a weak box always was, and a stronger box of *another*
   class leaves it alone exactly as before.
2. **The band is shed first, under any floor shape.** Detections are ranked
   evidence first and score second at every cut — the candidate truncation
   before NMS, the 32-detection cap, and the 64-object and 65 536-byte cuts
   where the line is serialized — so the band is always the tail and always
   the first thing to go. Ranking by score alone would not do it: with
   `min_score` at 0.4 for `person` and 0.8 for `car`, a band `car` at 0.5
   outscores an evidence `person` at 0.45, and per-label floors are a
   configuration Cairn writes.
3. **A seed never re-reports the band.** With the [motion gate](#motion-gate)
   on as well, a skipped sample re-reports the last real line's
   *evidence-grade* boxes only. A sub-floor box is a thing seen in one frame,
   for the host to match a track against in that frame; re-asserting it for as
   long as the gate holds is what `reverify_ms` exists to prevent.
4. **It costs wire, never a detection.** Every box a flag-off run emits is
   still emitted with the flag on, under the same label and at the same score.
   That holds even where the flag reopens what an allowlist closed —
   `min_score: {"default": 1.0, "person": 0.6}`, the documented way to exclude
   every class but one, stops excluding them once a track floor sits under it,
   because the band is one number for every class. Those classes come back in
   the band and spend slots and bytes; the class you asked for still leaves
   first. Two mechanisms hold it up, not one: rule 2 ranks evidence ahead of
   the band at every *cut*, and the heads prefer an evidence class ahead of a
   higher-scoring band one at every *selection* (an rfdetr query offers one
   box under many labels, so which label wins it decides whether the detection
   exists at all). Leave the flag off if the wire the band takes is not a
   trade you want.

### NMS-free heads emit a redundant band

A head that runs no NMS — rfdetr's query head, yolov10's export — deduplicates
by *confidence*: redundant proposals for one object score below whatever floor
the model was trained to be read at, and lowering that floor with a track
floor lets them through. Measured on rfdetr_nano at floor 0.25, the band
carried about 0.9 same-label pairs per frame at IoU above 0.5 on a parked
scene (yolox, whose NMS sees the band per rule 1, measured zero in every
cell). The host is unaffected — its second stage spends at most one box per
track and drops the rest outright, and the same soak's live-track duplicate
count was zero throughout — so what the redundancy costs is exactly the wire
and slots rule 4 already prices, at a higher rate than an NMS'd head pays.
Weigh that against the floor you pick on these profiles; an NMS pass over the
band alone is a candidate follow-up if the cost matters
(`.claude/plans/tracking-roadmap.md`).

`verify/README.md` has the recipe for measuring a track-floor run: the
validator reports the **sub-floor share** of a capture when it is given the
floors the run used. It takes one `--min-score-json` for the whole capture, so
a group whose members carry different `min_score` maps has to be split by
`camera_id` first for the share to mean anything per member.

## The wire protocol

stdout carries protocol v1 ndjson and nothing else — one JSON object per
line, flushed as it is written, capped at the contract's 65 536 bytes. Every
diagnostic goes to stderr, where Cairn logs it. Three message types leave
this plugin:

```jsonc
// once, before the model load
{"spec":"cairn.plugin","version":1,"type":"plugin.hello",
 "hello":{"name":"cairn-detect","version":"0.1.0","supported_versions":[1],
          "capabilities":{"object_tracking":false}}}

// on transitions only — process lifecycle, and the motion gate's own
// report (at most one per camera per 5 s). The host rate-limits these:
// one that differs from the camera's last is stored and broadcast, an
// identical repeat only once every 5 s as a liveness heartbeat, and the
// rest are dropped and counted (`:status_rate_limited`).
{"spec":"cairn.plugin","version":1,"type":"plugin.status",
 "camera_id":"front_door","status":{"state":"ready"}}

// one per sampled frame
{"spec":"cairn.plugin","version":1,"type":"frame.objects",
 "camera_id":"front_door","stream_epoch":"01K…","sequence":41,
 "frame":{"pts":3735000,"time_base":[1,90000],
          "observed_at":"2026-07-26T12:34:56.789Z"},
 "objects":[{"label":"person","score":0.87,"bbox":[0.12,0.34,0.2,0.4]}]}
```

`capabilities.object_tracking` is `false`: this plugin mints no identities and
carries none between frames, so Cairn runs its own tracker over what it sends.
`observation_kind` is omitted above, which the host reads as `"detected"` — on
a full 64-object line the field would add about 1.9 KB to say the default. The
[motion gate](#motion-gate) is the one thing that sets it: a seeded line spells
`"tracked"` on every object, which is how the host tells a box re-reported from
an earlier frame apart from evidence. It is still Cairn that decides which
track either belongs to.

`bbox` is `[x, y, w, h]` normalized to 0..1 against the *frame*, origin
top-left, y down. `sequence` counts from 0 per camera and only advances for
lines actually written, so a jump the host sees really is frames lost between
us and it. `observed_at` is captured when the frame clears the sample gate,
before inference — it places the frame on Cairn's timeline and is not a
measure of how long the model took.

### The control channel

Cairn writes back on the plugin's **stdin**, and this is not optional
reading. A camera's *stream epoch* — a ULID minted per ffmpeg run — only ever
arrives this way:

```jsonc
{"spec":"cairn.plugin","version":1,"type":"stream.started",
 "camera_id":"front_door","stream_epoch":"01K…","rtp":{"clock_rate":90000}}
{"spec":"cairn.plugin","version":1,"type":"stream.ended",
 "camera_id":"front_door","stream_epoch":"01K…","reason":"restarted"}
```

A dedicated thread owns stdin from before the model load until the process
exits. Cairn writes with `:nosuspend`: a plugin that stops draining does not
slow the host down, it silently *loses* announcements — and a lost epoch
means every line that camera produces afterwards is discarded host-side as
stale. Unknown message types and other protocol versions are ignored rather
than treated as errors; a malformed line is logged and skipped.

**Frames decoded before a camera's first `stream.started` produce no output
for that camera.** There is no epoch to put on them that Cairn would accept,
so a line emitted then is work paid for and thrown away. Decoding continues
throughout — the first control line simply starts the output, and the count
of suppressed frames is logged. In group mode the gate is per member: a
camera Cairn has not announced (or has stopped) is silent while its
neighbours keep going. A `stream.ended` clears the epoch only when it names
the one currently held, so a late `ended` from a bounce cannot blank the
epoch that replaced it.

## Multiplexed mode

The same binary also serves a whole plugin group from one process. Reach for
it when the hardware is the constraint rather than the camera count: an
accelerator that only one process can hold at a time (a Coral Edge TPU is the
motivating case) can never be shared by a process per camera, and one model
loaded once is cheaper than N copies even where sharing is merely wasteful.

Declare the command once and let cameras join it by name:

```yaml
plugins:
  detect:
    command:
      - plugins/cairn-detect/target/release/cairn-detect
      - --model
      - plugins/cairn-detect/yolox_nano.onnx
      # coco.names goes with yolox (and yolov8/v10); an rfdetr model needs
      # coco91.names — see --labels above
      - --labels
      - plugins/cairn-detect/coco.names

cameras:
  - id: front_door
    rtsp_url: rtsp://user:pass@192.168.1.10:554/stream1
    plugin: detect
    min_score:
      default: 0.5
      person: 0.6
  - id: driveway
    rtsp_url: rtsp://user:pass@192.168.1.11:554/stream1
    plugin: detect
```

Cairn then appends one argument instead of the per-camera three:

| flag | required | meaning |
|------|----------|---------|
| `--cameras-json` | in group mode | JSON array of `{id, udp_port, min_score}`, one entry per member, in config order |

It conflicts with `--camera-id`/`--udp-port`/`--min-score-json`; give one set
or the other. `--motion-json` and `--track-floor-json` are the exceptions:
they are your own flags in the configured command rather than ones Cairn
appends, so they apply in both modes — in group mode as the default for every
member. A member may also carry its own `motion` object in `--cameras-json`,
overriding only the knobs it names, or its own `track_floor` object, replacing
the group's outright (there is one knob, so the two are the same thing).
Cairn writes neither key today, so both are reachable from a hand-driven run
(see below); a track floor is checked against *that member's* `min_score` map,
so one can be legal for one camera in a group and refused for another. Each
member gets its own decode thread and its own
newest-wins sample slot, and a single inference thread drains the slots —
picking at random among the ready ones, so a busy camera cannot starve a quiet
one. Score floors are applied per member. Startup logs the whole roster
(`cameras=[front_door@17000, driveway@17004]`) to the group's shared
`{data_dir}/log/plugin-detect.log`.

Every output line carries the `camera_id` of the member it describes, and the
`stream_epoch` Cairn last announced for *that* member — in group mode Cairn
routes by `camera_id` alone, so an untagged line has nowhere to go and is
dropped, and a line under the wrong epoch is dropped as stale. Sequence
counters are per member too; a busy camera's count never leaks into a quiet
one's.

**A silent stream is normal here, not a fault.** Cairn leaves a group running
when a member camera is stopped or its ffmpeg is bouncing, so each stream is
an open → decode → log → re-open loop, forever, backing off 5 s → 30 s (reset
after a minute of healthy run). This is the mirror image of per-camera mode,
where a failed open or the 30 s read timeout is fatal *by design* so Cairn
restarts the process. Only a model-load or inference failure exits, and it
takes every member's detection down with it until the backoff restart — the
group is one failure domain, which is exactly why per-stream trouble is kept
per-stream.

Driving it by hand, in the style of the [verify](#verifying-changes) recipe:

```bash
python3 verify/feed.py --clip /path/to/fixture.mp4 --port 17000 &
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"front_door","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 30; } \
  | timeout 30 ./target/release/cairn-detect \
      --cameras-json '[{"id":"front_door","udp_port":17000,"min_score":{"default":0.5}},
                       {"id":"driveway","udp_port":17004,"min_score":{"default":0.5}}]' \
      --model yolox_nano.onnx --labels coco.names | python3 verify/validate_ndjson.py
```

Feeding only the first port is a fine test: `driveway` just logs
`stream down ... reopening` and the process keeps serving `front_door`.
Announcing only the first camera is the other half of the same test — the
group emits `front_door` frames and logs `no stream epoch yet` for
`driveway`, which is what a stopped member looks like from in here.

## Decoder selection

`--decoder auto` probes once at startup and logs the path it chose. Order on
Linux/x86 is `vaapi → qsv → nvdec → v4l2`; macOS probes `videotoolbox`; other
Linux probes `v4l2`. Naming a backend probes only that one.

**A backend that will not open is never fatal.** Every failure is logged and
the next candidate is tried, ending at software decode — a forced
`--decoder vaapi` on a host without VAAPI runs slowly rather than
crash-looping under Cairn's restart backoff.

Sampled frames only — never the full stream — are scaled on the GPU and then
downloaded, because downloading full-resolution frames would cost more than
the decode saving. They are scaled to the **content rectangle** the resize
policy asks for, which under a stretch policy is the model input size and
under a letterbox is the aspect-preserved picture inside it — the padding is
added on the CPU side, where the tensor is packed. So `w=`/`h=` below are
`640x640` for a 640 stretch model, but a 416 YOLOX on a 16:9 camera emits
`scale_vaapi=w=416:h=234:...`. The graphs are shown for the square case:

| backend | device | decoder | sampled-frame filter graph |
|---------|--------|---------|----------------------------|
| `vaapi` | VAAPI | `h264` + hwaccel | `scale_vaapi=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `qsv` | QSV | `h264_qsv` | `scale_qsv=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `nvdec` | CUDA | `h264` + nvdec | `scale_cuda=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `videotoolbox` | VideoToolbox | `h264` + hwaccel | `scale_vt=w=640:h=640:format=nv12,hwdownload,format=nv12` |
| `v4l2` | — | `h264_v4l2m2m` | none: the M2M codec decodes on the ASIC but returns system memory, so the software scaler handles it |
| `sw` | — | `h264` | none |

NV12 is the download format because every backend's scaler supports it; the
NV12 → RGB24 convert afterwards is negligible at model-input resolution. If the FFmpeg build
lacks the backend's scaler filter, that backend is reported unavailable rather
than silently downloading full-resolution frames.

`--decoder` is plugin-owned config: like everything else in the command, it
only changes across restarts.

## Model

### Getting one: YOLOX-Nano or RF-DETR-Nano

**These two are the models this project documents.** Both are Apache-2.0 —
the same license as Cairn — so nothing about running them, redistributing
them, or building on top of them reaches back into your own code. Neither
needs a CLI installed or a venv built; both are a single `curl`.

**Verify what you downloaded.** The `.onnx` file decides what your NVR
records, and this plugin reads its input geometry straight off it. Every URL
below is pinned to an immutable revision and carries the SHA-256 of the exact
bytes that revision serves, checked against the files this repo's harness was
run with — so `sha256sum -c` is a real check, not a formality. A mismatch means
you did not get the file this README describes; stop rather than run it.

**YOLOX-Nano** — 3.6 MB, COCO-80, 416×416. The smaller and faster of the two,
and the long-standing default here:

```bash
cd plugins/cairn-detect
# a release-asset URL: the 0.1.1rc0 tag is immutable
curl -L -o yolox_nano.onnx \
  https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx
echo "c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d  yolox_nano.onnx" \
  | sha256sum -c
```

The same [Megvii release](https://github.com/Megvii-BaseDetection/YOLOX)
publishes `yolox_tiny.onnx` and `yolox_s.onnx` if you want more accuracy for
more CPU; drop either in and the plugin reads its geometry and layout off the
model. Same URL shape, same tag, and their SHA-256s from that release are:

| file | sha256 |
|---|---|
| `yolox_nano.onnx` | `c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d` |
| `yolox_tiny.onnx` | `427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7` |
| `yolox_s.onnx` | `c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063` |

`coco.names` in this directory is the COCO-80 label list these weights use.

**RF-DETR-Nano** — 108 MB, COCO-91, 384×384. Roboflow's transformer detector;
noticeably stronger than YOLOX-Nano on the same footage for noticeably more
CPU. The `onnx-community` conversions are the ready-made exports:

```bash
cd plugins/cairn-detect
# `resolve/<commit>` rather than `resolve/main`: main is a branch ref and
# moves. This commit is the repo state as of 2025-07-24.
curl -L -o rfdetr_nano.onnx \
  https://huggingface.co/onnx-community/rfdetr_nano-ONNX/resolve/eae21cee0687a91bcf9fa071605c48d7705d2d91/onnx/model.onnx
echo "9cbac6b11ce34a03034e4d5a24cfac5f18632fd6761d1311dd640232088d7fee  rfdetr_nano.onnx" \
  | sha256sum -c

./target/release/cairn-detect --model rfdetr_nano.onnx --labels coco91.names \
    --input-size 384 ...
```

That SHA-256 is also the file's Git-LFS object id, so it can be confirmed
against the Hub without downloading anything:

```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{"paths":["onnx/model.onnx"]}' \
  https://huggingface.co/api/models/onnx-community/rfdetr_nano-ONNX/paths-info/eae21cee0687a91bcf9fa071605c48d7705d2d91
```

`rfdetr_small`, `rfdetr_base`, `rfdetr_medium` and `rfdetr_large` exist at the
same URL shape, in their own repos — resolve each one's own commit and
checksum the same way, and note the sibling files in these repos
(`model_fp16.onnx`, `model_int8.onnx`, ...) are *different models*, not
different encodings of the pinned one. **Every RF-DETR export leaves its input
geometry dynamic**, so
`--input-size` is not optional for this family — the plugin refuses to start
without it rather than guess a variant's resolution (see [Geometry](#geometry)).
The resolutions, ascending, are **nano 384, small 512, base 560, medium 576,
large 704** — note `base` is smaller than `medium`, which is why they are
listed in that order here and in the error text. These come from Roboflow's
published variant table; only nano is exercised in this repo, so check yours
against upstream before deploying it. `coco91.names` in this directory
is RF-DETR's label list, which is *not* `coco.names`: RF-DETR indexes its
logits by the raw COCO category id (1 = person, 3 = car, 64 = potted plant),
so the file is 91 lines with the retired ids left as bare numbers.

`.onnx` files are gitignored, so downloading one is a per-checkout step. The
startup line reports the geometry, encoding, resize and layout the plugin
actually settled on, so you never have to assume them.

### Licensing

Cairn is Apache-2.0. So are two of the five families it can decode; the other
three are not.

| family | weights license | status here |
|---|---|---|
| **YOLOX** (Megvii) — nano / tiny / s | **Apache-2.0** | **recommended, documented, default** |
| **RF-DETR** (Roboflow) — nano / small / medium / base / large | **Apache-2.0** | **recommended, documented** |
| YOLOv9 | GPL-3.0 (AGPL-3.0 via Ultralytics) | decodes; bring your own weights, not documented here |
| YOLOv10, YOLO26, YOLOv8, YOLOv11 | AGPL-3.0 | decodes; bring your own weights, not documented here |
| the `ultralytics` package (the `yolo export` CLI) | AGPL-3.0 | not used, not installed, not invoked by anything here |

Supporting a *tensor layout* carries no license implication — a shape is not
copyrightable, and the YOLOv10, YOLOv8 and YOLOv9 decode paths stay in the
plugin so existing deployments keep working. What does carry an implication is
the weights you actually run and the tooling you install to produce them, and
the AGPL's network-use clause is a live question for an NVR that serves a web
UI. Anything exported through the `ultralytics` CLI inherits AGPL-3.0 whatever
the architecture is called, which is why there are no export instructions here
that need it.

If you already have Ultralytics or YOLOv9 weights and have satisfied yourself
about the license, point `--model` at them and everything below still applies.
This README will not walk you through obtaining them.

### Model profiles

Everything that differs between detector families lives in one **profile**: how
frames are fed to the model, and how its output is read. Four ship built in,
covering five families — the Ultralytics generations are *aliases*, not
separate profiles, because their exports are byte-for-byte the same tensor
contract:

| profile (and the names it answers to) | default size | input encoding | resize | output layout | score | NMS | weights license |
|---|---|---|---|---|---|---|---|
| **`yolox`** — nano, tiny, s | 416 | `0..255` **BGR** | **letterbox**, pad 114 | `[1, A, 5 + nc]` grid-objectness, strides 8/16/32 | `objectness × class` | IoU 0.45, top 300 | Apache-2.0 |
| **`rfdetr`** (`rf-detr`) — nano … large | none — `--input-size` required | **ImageNet-normalized** RGB | stretch | `[1, Q, 4]` + `[1, Q, nc]` detr-queries (**two tensors**) | `sigmoid(class logit)` | none (set prediction) | Apache-2.0 |
| **`yolov10`** (`yolo26`) | 640 | `0..1` **RGB** | stretch | `[1, N, 6]` end-to-end | class | none (the model did it) | AGPL-3.0 |
| **`yolov8`** (`yolov9`, `yolo11`, `yolov11`) — what Frigate commonly ships | 640 | `0..1` **RGB** | stretch | `[1, 4 + nc, A]` raw-classes | class | IoU 0.45, top 300 | AGPL-3.0 (GPL-3.0 for YOLOv9) |

An alias resolves to the profile's canonical identity, so `--model-profile
yolo11` runs and reports `profile=yolov8`. Two of the aliases are worth
calling out:

  * **`yolov9`** and **`yolov11`/`yolo11`** are *verified by construction*, not
    against a downloaded export — their detect heads emit the same
    `[1, 4 + nc, A]` tensor as YOLOv8 and no AGPL/GPL weights are fetched by
    anything in this repo. An export that turns out not to match is rejected
    by the shape check rather than decoded wrong.
  * **`yolo26` is UNVERIFIED.** YOLO26 is documented as end-to-end and NMS-free
    like YOLOv10, so it is an alias of that profile, but no YOLO26 export has
    ever been run against this decode. The same shape check applies: a
    mismatch fails loudly instead of emitting plausible garbage.

`yolox` and `rfdetr` are verified against real downloaded models —
`yolox_nano.onnx` from the Megvii 0.1.1rc0 release and
`onnx-community/rfdetr_nano-ONNX` — and `yolov10` against `yolov10n.onnx`.

What each layout means, and what the plugin does with it:

| layout | tensor | decode |
|--------|--------|--------|
| `[1, A, 5 + nc]` grid-objectness | anchor-major: `x, y, w, h` **not in pixels** — offsets inside the anchor's own grid cell, extents in log space — then objectness, then `nc` sigmoided class scores | walk the stride grids in the order the model concatenated them, argmax class per anchor, centers → corners, NMS, then un-project/clamp/gate |
| `[1, N, 6]` end-to-end | rows of `[x1, y1, x2, y2, score, class_id]` in input pixels, already sorted and de-duplicated | un-project, clamp, gate on the score floors |
| `[1, 4 + nc, A]` raw-classes | channels-first over `A` anchors: `cx, cy, w, h` in input pixels then `nc` sigmoided class scores, no objectness row | argmax class per anchor, centers → corners, NMS, then the same un-project/clamp/gate |
| `[1, Q, 4]` + `[1, Q, nc]` detr-queries | **two tensors** over `Q` learned object queries: normalized `cx, cy, w, h` in `0..1`, and **raw** class logits (roughly `-12..+2`, not probabilities) | argmax class per query, `sigmoid` the logit, scale the box into model pixels, centers → corners, **no NMS**, then the same un-project/clamp/gate |

The DETR layout is the one that breaks the older assumptions, in two ways.
It reads **more than one output tensor**, and it has **no grid**: there is no
stride, no cell offset, no `exp` on the extents and no anchor, because a query
is a learned slot whose box is already the whole picture's coordinates.
Duplicates are suppressed by the bipartite matching the model was trained
under, which is why running NMS over it would be actively wrong — it would
merge the distinct boxes two queries legitimately place on neighbouring cars.

Because RF-DETR's two exporters disagree about output *names* — Roboflow's own
`export()` emits `dets`/`labels`, the transformers/onnx-community conversion
emits `pred_boxes`/`logits` — the plugin binds the roles by **shape**: the
rank-3 output ending in 4 is the boxes, the rank-3 output over the same query
axis is the logits. Both export conventions work, and a model where the pair
is genuinely ambiguous is an error naming the outputs rather than a guess.

**Adding a family is adding a profile**, not editing the decode path: a
`ModelProfile` is a name, an `InputSpec` (size, encoding, resize policy) and an
`OutputSpec` (layout, score composition, optional NMS). Nothing in `infer.rs`
below the profile table branches on a model family.

#### Picking one

You normally don't. With no flag the profile is **sniffed** from the model's own
input and output shapes, and the startup line says which one won:

```
cairn-detect up: camera=test udp=17000 model=yolox_nano.onnx profile=yolox \
    input=images input size=416x416 (from model) encoding=0..255 bgr \
    resize=letterbox (pad 114) \
    layout=grid-objectness [1, A, 5 + 80] strides 8/16/32 (from model) \
    decoder=auto
```

Sniffing looks at the model's whole output *set*, not just its first tensor,
so a two-tensor DETR export and a one-tensor YOLO head can never be confused
for one another. RF-DETR sniffs cleanly given its geometry:

```
cairn-detect up: camera=test udp=17000 model=rfdetr_nano.onnx profile=rfdetr \
    input=pixel_values input size=384x384 (from --input-size) \
    encoding=imagenet-normalized rgb resize=stretch \
    layout=detr-queries [1, Q, 4] + [1, Q, 91] (from model) decoder=auto
```

`--model-profile <name>` names one explicitly. It wins outright and is then
**validated against the model**, so pointing it at the wrong export fails at
startup rather than emitting plausible garbage for a week:

```
fatal: --model-profile yolov10 does not describe model yolox_nano.onnx:
       output shape [1, 3549, 85] does not fit end-to-end [1, N, 6];
       expected [1, N, 6]
```

Naming a profile whose *roles* the model does not offer fails the same way,
before any frame is packed for it:

```
fatal: --model-profile rfdetr does not describe model yolov10n.onnx:
       expected one [1, Q, 4] box output and one [1, Q, nc] logit output over
       the same Q queries, but the model offers "output0" [1, 300, 6]
```

You need the flag in three cases:

  * the shape fits **more than one** profile (below),
  * the export leaves its **output shape dynamic** (YOLOX's own
    `export_onnx.py --dynamic` does). There is then nothing to sniff, and the
    encoding and resize policy have to be settled *before* the first frame is
    converted — so this is a startup error naming the flag, not a guess. `nc`
    is read off the first real output.
  * the export leaves its **input geometry dynamic** and you have not passed
    `--input-size`. Every RF-DETR export does; a symbolic *batch* axis on its
    own does not count, since this plugin always feeds one frame. Here the
    profile is **not** a substitute for the size: `--model-profile rfdetr`
    refuses to supply one, because RF-DETR's variants are trained at five
    different resolutions and nothing in any export says which variant it is.
    `--input-size 384` is what a nano run needs, and it lets the profile
    itself still be sniffed.

```
fatal: model rfdetr_small.onnx does not pin its input width and height, and
       the rfdetr profile has no default to fall back on — every export in the
       family leaves its spatial axes dynamic and declares nothing that says
       which variant it is. Pass --input-size WxH (or N); the variants are
       trained at nano 384, small 512, base 560, medium 576, large 704. A wrong
       size here is silent: the model runs and detects nothing.
```

#### Ambiguity is an error, never a guess

A shape that fits two profiles is refused with both names:

```
fatal: model m.onnx has outputs "output0" [1, 5040, 6], which at input 640x384
       fit more than one profile: yolox and yolov10. Nothing in the shapes says
       which, and they decode differently — pass --model-profile <yolox|yolov10>
       to say.
```

That is the real collision: a **1-class YOLOX** head is `[1, A, 6]`, and `6` is
also the end-to-end row width, so at any input size where `A` happens to equal
the grid anchor count the two are indistinguishable. One reads the four numbers
as final pixel corners; the other decodes them out of a stride grid with log
extents. Picking silently would emit boxes that look reasonable and are wrong.

Adding RF-DETR introduced a second, subtler collision. A single-tensor layout
binds the model's **first** output, so a DETR export that happens to declare
its logits first offers that tensor to the one-tensor profiles too. At 128×128
a YOLOX grid has `16² + 8² + 4² = 336` anchors, so a 336-query DETR's
`[1, 336, 85]` logits are also a perfectly good 80-class YOLOX head while the
pair is a perfectly good `rfdetr`:

```
fatal: model m.onnx has outputs "logits" [1, 336, 85], "pred_boxes" [1, 336, 4],
       which at input 128x128 fit more than one profile: yolox and rfdetr.
       Nothing in the shapes says which, and they decode differently — pass
       --model-profile <yolox|rfdetr> to say.
```

Shapes that are *not* ambiguous, and why:

  * A **two-tensor DETR export against the one-tensor families**, in general.
    The roles are what separate them: no single-tensor head can match a layout
    that reads two, and `pred_boxes` `[1, Q, 4]` on its own fits none of the
    one-tensor layouts — `4` is neither the end-to-end row width of 6 nor a
    plausible `4 + nc` channel axis. The 128×128 case above is the exception
    that has to be checked for, not the rule.

  * `[1, 8400, 84]` at 640×640 is a **79-class YOLOX**, uniquely. It looks like
    it could be a transposed Ultralytics head, but a stock Ultralytics detect
    export is channels-first — its anchor axis is the long one — so
    `raw-classes` refuses that orientation rather than reading `nc` as 8396.
    (Add a transposed-Ultralytics profile and this *becomes* ambiguous, which
    the machinery above already handles.)
  * **YOLOv5's `[1, 25200, 85]`** fits nothing and is still rejected. Same rank
    and row width as a 640×640 YOLOX head, but three anchor boxes per cell make
    `A` exactly 3× a YOLOX's and its boxes are already in pixels. YOLOX at
    strides other than 8/16/32 (a P6 head) is out for the same reason.

#### Labels belong to the model

`--labels` is indexed **positionally** — line 1 is class 0 — so a file that
does not describe the model's classes does not degrade the output, it
falsifies it. The two documented models make the trap concrete: YOLOX emits
dense COCO-80 class indices, RF-DETR emits the raw COCO **category id**, and
`coco.names` against an RF-DETR export renders every `person` as `bicycle` and
every `car` as `motorcycle`. Cairn then records events, crops snapshots and
drives Home Assistant under the wrong label — and the per-label `min_score`
floors gate the wrong class on the way in. So a count mismatch is a startup
error:

```
fatal: --labels lists 80 names but the model has 91 classes. Labels are indexed
       by class id, so every detection would be emitted under another class's
       name — and the per-label min_score floors would gate the wrong class.
       coco.names is the 80-entry dense COCO class list (yolox, yolov8/v10);
       coco91.names is the 91-slot COCO *category id* space RF-DETR indexes its
       logits by. Pass --allow-label-mismatch to run anyway.
```

Swapping `--model` and forgetting `--labels` is the likely operator path and
its symptom is plausible data, which is why it fails loudly instead. Omitting
`--labels` entirely is still supported — ids are then emitted as numbers — and
so is a blank line, which is how a gap-id file writes a retired id: the slot
keeps its position and renders as its number. Only the *count* is checkable; a
same-length file in the wrong order is not, by anything.

### Input

Input is the model's **first input** — named `images` in both Ultralytics and
YOLOX exports and `pixel_values` in RF-DETR's, but the name is taken from the
model and logged at startup, not assumed — float32 `[1, 3, H, W]`, CHW.

The *encoding* of those floats is not something an ONNX graph declares: it
lives in the training transform and an export inherits it as an unwritten
precondition. Getting it wrong is not a small accuracy loss, and both
documented models prove it on the same camera frame:

  * Fed `0..1` RGB, **YOLOX-Nano** returns *nothing* above 0.30 on a frame
    where `0..255` BGR finds a car and a potted plant.
  * **RF-DETR-Nano** scores its best box **0.14** fed `0..255`, **0.48** fed
    `0..1`, and **0.78** fed ImageNet-normalized RGB. Only the last is a
    detection. Its `preprocessor_config.json` says `do_normalize: false`,
    which is about what the *converter* did, not what the graph wants — the
    normalization is emphatically not baked in.

The profile is what states it, and the startup line always says which encoding
is in force. The three encodings reduce to one per-plane affine over a channel
pick, so `0..255` BGR, `0..1` RGB and `(v/255 - mean) / std` share a single
packing path rather than three.

#### Letterbox vs stretch

Neither is the resize policy — **the profile says which**, because a model was
trained one way and only that way.

  * **stretch** (`rfdetr`, `yolov10`, `yolov8`) scales each axis independently
    to fill `H × W`. For RF-DETR this is its own transform: a square
    `A.Resize(height=s, width=s)` with `do_pad: false`.
  * **letterbox** (`yolox`) scales by `min(W/w_src, H/h_src)`, places the
    picture at the **top-left corner** and fills the rest with the pad value
    (114). That is what YOLOX's own `preproc` does —
    `padded_img[: int(h*r), : int(w*r)] = resized` over a canvas of 114 — and
    matching it exactly is the point, so the un-projection matches the
    reference's `boxes /= ratio`.

> **Changed:** every model used to be stretched, on the reasoning that bboxes
> come out normalized so only ratios matter. That reasoning is sound about
> *coordinates* and wrong about the *model*: YOLOX was trained on
> aspect-preserved, 114-padded input, and on a 16:9 camera a stretch feeds it a
> picture 1.78× too tall. Measured on a 2560×1440 fixture at 416×416,
> stretch-vs-letterbox is mean IoU **0.87** on the detections both find, box
> heights **12.6% short**, and — the part that matters — the stretch run found
> **no cars at all** where the letterbox run found 7. See
> [Verifying changes](#verifying-changes).

Because a letterbox makes the model's coordinate space differ from the frame's,
every decode path is handed an explicit **projection** (built per source frame
size, alongside the scaler) rather than an input size to divide by. Under a
stretch it is exactly the old divide; under a letterbox it subtracts the offset,
divides by the real scale, and normalizes by the **original** frame dimensions.
It travels with the tensor, so a decode path cannot forget to apply it.

On the hardware path the GPU scaler is built for the *content* rectangle rather
than the full input, so the aspect-preserving scale still happens on the device;
only the padding is filled in on the CPU while packing the tensor. Letterboxed
side lengths are rounded down to even, because the GPU scalers work in NV12 and
a silently rounded odd side would shift every box by a rounding it never
reported. The projection is derived from the side actually produced, so that
costs at most one pixel of content and nothing in accuracy.

### Geometry

`H` and `W` need not be 640, and need not be equal — YOLOX-Nano is 416×416 and
RF-DETR-Nano 384×384. They are resolved once at startup, and every scaler, GPU
filter graph and tensor in the process is built for them. In precedence order:

  1. `--input-size` (`320`, `640x352`, ...) — giving it a size the model
     contradicts is rejected at startup rather than left to fail on the first
     frame;
  2. the model's own declared input shape;
  3. the profile's family default (416 for `yolox`, 640 otherwise), which
     only applies to an export with dynamic spatial axes *and* an explicit
     `--model-profile` — and **only for a family whose exports pin their
     geometry**, which excludes `rfdetr`.

Whichever of the three answered, the size is bounded before anything is built
for it: **8192 on either axis** (what the `i32` FFmpeg geometry casts are good
for) and **4 Mpx of area**, i.e. 2048×2048 (what the allocations are good for).
The area bound is the one that matters, and it exists because the size can come
straight off an untrusted model file: `[1, 3, 8192, 8192]` is inside every
per-axis check and then asks for a 768 MB tensor plus a 201 MB RGB frame **per
camera** on the first frame. Both limits are an order of magnitude past any
real detector input — RF-DETR-Large is 704 and Ultralytics tops out at 1280 —
so hitting one means a typo or a bad model, and it is a startup error either
way. A `yolox` grid head additionally requires each axis to be a multiple of
32, its coarsest stride: at a size the strides do not divide, the cell walk
cannot match the one the model was exported with.

The startup line records which of the three it came from. RF-DETR is the case
that shapes the rule: its exports declare `[?, 3, ?, ?]`, so **nothing in the
model constrains the resolution**, and its five variants are trained at five
different resolutions that no export distinguishes — every one of them
declares 300 queries and 91 logits. A `small` export handed Nano's 384 does
not run badly, it runs *blind*: frames flow, the protocol stays valid, and it
emits zero detections with nothing on stderr. So the profile declines to
guess and `--input-size` is required for RF-DETR, with the known resolutions
in the error text.

### Quantization

**Don't, for YOLOX-Nano.** Measured on 200 letterboxed calibration frames and
10 held-out ones: **1.6x slower** than FP32 (11.83 ms vs 7.56 ms) and a **0%**
detection match rate against it — 6 FP32 detections became 1, and that one is
a `banana` where FP32 saw a potted plant. It is 3.6 MB to begin with, so there
is almost nothing to win, and its opset-11 graph cannot carry the per-channel
quantization that would make the arithmetic pay. On the larger models where
the question is worth asking, static QDQ measured *no* latency improvement on
x86 with AVX-512 and slightly worse recall near the score threshold — a size
win only. If disk or transfer size genuinely matters:

```bash
cd model
python3 -m venv quant-venv && . quant-venv/bin/activate
pip install onnx onnxruntime pillow numpy sympy
python3 quantize_model.py --model ../yolox_nano.onnx \
    --calib-dir calib_frames --out ../yolox_nano-int8.onnx
```

Note what is *not* in that `pip install`: no `ultralytics`, no `torch`. The
tooling is Apache-2.0-clean, and model-agnostic **across the single-tensor
families** — it takes geometry and layout off the model and the preprocessing
(encoding *and* resize policy) off the profile that layout resolves to, so
calibration frames are letterboxed for YOLOX exactly as the plugin letterboxes
camera frames. RF-DETR is the exception and is not quantizable here: its
two-tensor layout is not one these scripts decode.

Whatever you quantize, run `model/verify_models.py` against the FP32 original
before deploying it. The trap it exists to catch: a detector's
classification-head convs may have to be excluded, or every confident
detection's score collapses to one value — measured on YOLOv10 (the three
`/model.23/one2one_cv3.{0,1,2}.2/Conv` nodes, collapsing to `0.500`) and again
on YOLOX-Nano, where an early scouting run returned a constant `zebra:0.393`
on 3 of 6 held-out frames. `--exclude-node` and
`--exclude-suffix` are there for it, and `--preprocess-only` lists the graph's
conv nodes so you can aim them.

`model/quantize-model.md` is the detailed reference — where the model comes
from, calibration/held-out frame extraction, the shape-inference workaround,
and the FP32-vs-INT8 comparison method. `model/quantize_model.py` and
`model/verify_models.py` expect the calibration artifacts it describes.

## Performance

Measured 2026-07-25 in this dev container (AMD Ryzen 9 7950X3D, 32 threads,
Debian 12), 90 s against a looped 2560x1920 H.264 @ 20 fps fixture, sampling
at 5 fps, with a 640x640 model. YOLOX-Nano at 416x416 is a smaller model at a
smaller input, so it can only be cheaper than this — the numbers below are an
upper bound on the default, not a measurement of it:

| plugin | CPU |
|--------|-----|
| the Python reference plugin it replaced (PyAV software decode, since removed) | ~840% of a core |
| `cairn-detect`, software decode | ~114% of a core |

That is a **7.3x reduction before any hardware decode**, and it is worth
knowing where it came from: most of the Python plugin's cost was
software-decoding full-rate 2K frames it then threw away, which is the
mistake the sample gate above exists to avoid.

Caveats: the container has no GPU (`/dev/dri` and CUDA both absent), so this
is the software path only — the hardware backends are implemented and fall
back cleanly, but their CPU win is unmeasured. The remaining ~114% is decode
plus inference (~27 ms/frame wall time, multi-threaded by onnxruntime); the
split between them has not been measured, and hardware decode targets the
decode half.

## Shipping

The release binary is **19.9 MB** stripped (24.9 MB unstripped; `strip = true`
is set in `[profile.release]`). Most of it is the statically linked
onnxruntime. It needs three files at runtime: itself, the `.onnx` model, and
the labels file.

Its only shared-library dependencies are FFmpeg and the C/C++ runtime:

```
libavcodec.so.61 libavformat.so.61 libavutil.so.59 libavfilter.so.10
libswscale.so.8 (+ libswresample.so.5, libpostproc.so.58 transitively)
libstdc++.so.6 libgcc_s.so.1 libm.so.6 libc.so.6
```

### Recommended: dynamic link against the distro's FFmpeg 7

Ship the binary + model + labels, and depend on the target distro's FFmpeg 7
runtime packages. onnxruntime is already inside the binary, so FFmpeg is the
*only* external dependency family — and it is precisely the piece that has to
match the host's VAAPI/QSV/NVDEC drivers, which the distro already wires up.
Bundling our own FFmpeg would mean owning the hardware-acceleration matrix for
every target we support, in exchange for removing one `apt install`.

Distro FFmpeg versions (checked 2026-07-25 against sources.debian.org and the
Launchpad API):

| distro | FFmpeg | status |
|--------|--------|--------|
| Debian 13 (trixie) | 7.1.5 | builds as-is |
| Debian 12 (bookworm) | 5.1.9 | too old — use the bundled-FFmpeg alternative |
| Ubuntu 24.04 LTS (noble) | 6.1.1 | needs rsmpeg's `ffmpeg6` feature instead of `ffmpeg7_1` (untested) |
| Ubuntu 25.04 (plucky), 25.10 (questing) | 7.1.1 | builds as-is |

Build on a fresh Debian 13 (or Ubuntu 25.04+):

```bash
sudo apt install -y build-essential pkg-config clang libclang-dev \
    libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
    libavutil-dev libpostproc-dev libswresample-dev libswscale-dev \
    libssl-dev
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

cd plugins/cairn-detect
RUSTFLAGS="" FFMPEG_PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig \
    cargo build --release
```

That is the full FFmpeg dev set, not just the five libraries this crate calls
into: `rusty_ffmpeg`'s build script pkg-configs all eight, so a missing
`libavdevice.pc` or `libpostproc.pc` fails the build regardless.

`libssl-dev` is there for a non-obvious reason: `ort-sys`'s *build script*
downloads the prebuilt onnxruntime over TLS (`ureq` → `native-tls` →
`openssl-sys`), so without it the build fails at `openssl-sys` before any of
this crate compiles. The dev container has it only because the Dockerfile
installs it for kerl, which is why this recipe went a while without it.

Both overrides are mandatory, because `.cargo/config.toml` is a
dev-container file: it pins `FFMPEG_PKG_CONFIG_PATH` to `/opt/ffmpeg7/...`
(the build *panics* if that directory does not exist) and adds an rpath to it.
Cargo's `[env]` does not force a value that is already in the environment, and
`RUSTFLAGS` overrides `[build] rustflags` — so exporting both wins without
editing the file and breaking the dev loop.

Runtime packages on the target:

```bash
# always
sudo apt install -y libavcodec61 libavformat61 libavutil59 libavfilter10 \
    libswscale8 libswresample5
# VAAPI (Intel/AMD iGPU)
sudo apt install -y libva2 libva-drm2 intel-media-va-driver-non-free  # Intel
sudo apt install -y libva2 libva-drm2 mesa-va-drivers                 # AMD
# QSV (Intel, oneVPL runtime)
sudo apt install -y libvpl2 libmfx-gen1.2
# NVDEC: libcuda.so.1 comes from the proprietary NVIDIA driver, not apt-only
```

Those are FFmpeg's driver dependencies, not ours — the plugin dlopens nothing
itself. Check what a host can actually do with `ffmpeg -hwaccels` and
`vainfo`; cairn-detect's own probe logs the same answer at startup.

glibc on both recommended targets (Debian 13: 2.41, Ubuntu 24.04: 2.39) is
newer than onnxruntime's 2.38 requirement, so `src/glibc_compat.rs` is inert
there.

### Alternative: bundle a private FFmpeg

What this container does, made relocatable — ship a `lib/` directory of
FFmpeg 7 `.so` files next to the binary and point the rpath at it:

```bash
RUSTFLAGS="-C link-args=-Wl,-rpath,\$ORIGIN/../lib -Wl,--disable-new-dtags" \
FFMPEG_PKG_CONFIG_PATH=/path/to/ffmpeg7/lib/pkgconfig \
    cargo build --release
```

Use this for hosts stuck on an older distro (Debian 12). `--disable-new-dtags`
is required, not cosmetic: `DT_RUNPATH` is not inherited by dependencies, so
libavformat would fail to find libswresample in the bundled directory.

Costs: ~40 MB of extra shared objects, and we own the FFmpeg build — its
codec/hwaccel matrix, its licence surface, and its security updates.

### Rejected: fully static libav

rusty_ffmpeg supports it (`FFMPEG_LIBS_DIR` plus `FFMPEG_LINK_MODE=static`
against an `--enable-static --disable-shared` build), but it does not solve
the problem it appears to solve: VAAPI, QSV and CUDA still dlopen driver
libraries at runtime, so a static libav removes the packaging dependency while
keeping the driver dependency, and freezes the hwaccel matrix at our build
time instead of the host's.

## Verifying changes

`verify/` holds the local harness: `feed.py` replays a fixture clip to a UDP
port with the exact ffmpeg argv Cairn uses, `validate_ndjson.py` checks a
plugin's stdout against protocol v1 (envelope and field bounds, per-camera
sequence continuity, pts monotonicity, effective sample rate, score/label
histogram), and `compare_runs.py` diffs two runs on the same clip — FP32
against INT8, a hardware backend against software. See `verify/README.md` for
the two-terminal recipe. A typical run, where the brace group stands in for
Cairn's control channel:

```bash
python3 verify/feed.py --clip /path/to/fixture.mp4 --port 17910 &
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"t","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 30; } \
  | timeout 30 ./target/release/cairn-detect --camera-id t --udp-port 17910 \
      --min-score-json '{"default":0.5}' --model yolox_nano.onnx \
      --labels coco.names | python3 verify/validate_ndjson.py
```

Drop the control line and the run is still valid — just empty: `hello` and
`status` arrive, no frames do, and the validator exits nonzero saying so.

The same recipe with `--model rfdetr_nano.onnx --labels coco91.names
--input-size 384` exercises the DETR path. On a 26 s doorbell fixture at
2560×1920 the two Apache-2.0 models both validate clean (exit 0, 48–49 frames,
no sequence gaps, ~4.7 fps effective) and disagree about how much they see:

| | detections | score min / mean / max |
|---|---|---|
| `yolox_nano.onnx` @ 416 | car 27, person 23, remote 1 | 0.510 / 0.666 / 0.878 |
| `rfdetr_nano.onnx` @ 384 | car 123, potted plant 27, person 24 | 0.506 / 0.723 / 0.958 |

Counts move by a few percent between runs — the sample gate is wall-clock, so
two runs of the same clip do not land on quite the same frames — but the gap
does not. RF-DETR finds the parked cars and the porch planter that YOLOX-Nano
mostly misses, out of a model 30× the size. Which one is right for a camera is
a CPU budget question, not a correctness one.

### Measured: the YOLOX resize policy

Both models run clean end-to-end against the harness (validator exit 0,
sequence continuity intact, ~4.7 fps effective). The resize change is the one
worth a number, so it was measured on a **2560×1440 (16:9)** fixture at
YOLOX-Nano's 416×416, 20 s, software decode, `min_score 0.4`, one build
letterboxing and one stretching, compared frame-by-frame on matching `pts`:

| | letterbox | stretch |
|---|---|---|
| detections | 42 (35 potted plant, **7 car**) | 35 (35 potted plant, **0 car**) |
| score mean / max | 0.623 / 0.706 | 0.586 / 0.631 |
| mean IoU against the other run | — | **0.868** |
| box height, vs letterbox | — | **12.6% short** (mean `dh` −0.037) |
| box top edge, vs letterbox | — | 0.026 lower (mean `dy` +0.026) |
| box left edge / width | — | unchanged (mean `dx`, `dw` < 0.001) |

Two things to read off that. First, the horizontal axis does not move at all:
a 16:9 frame into a square input is letterboxed only vertically, and the
per-axis normalization already handled `x`. Second — and this is the real cost
— the harm is not a coordinate bug. Stretching *and* un-stretching are
self-consistent, so the old pipeline's boxes were where it thought they were.
What it got wrong was the picture it handed the model: YOLOX trained on
aspect-preserved input sees a 16:9 frame 1.78× too tall under a stretch, and it
localizes worse (mean IoU 0.87) and **misses objects outright** — every car
detection in this fixture.

So: not negligible.

Unit tests (`cargo test`) cover the v1 envelope (shape, field bounds, object
cap, line-size shedding, RFC3339 formatting), control-line parsing and the
epoch map it drives (start, restart, a stale `ended`, an unserved camera),
per-camera sequence isolation and the pre-epoch gate, plus postprocessing,
score-floor parsing, the SDP string, pts rescaling, tensor packing,
input-size parsing and resolution (including the per-axis and area ceilings),
profile resolution (sniffing, the ambiguity refusal, an explicit profile
validated against the model), label loading (gap slots, the count check, the
file bounds), the resize policies and the projection they imply (including a
full-frame round-trip under both), the raw-head and grid decodes (argmax, box
conversion, IoU/NMS, the per-class gate ahead of the NMS truncation, score and
extent bounds), decoder probe order and the per-backend filter strings; none
need network, a model, or a GPU.

`cargo test` also drives one compile-*fail* case, `tests/norm_box_invariant.rs`,
through `trybuild`. `infer::geometry`'s `NormBox` keeps its inner box private so
that `Projection::unproject` is the only way to obtain one, which is what makes a
missed un-projection a type error rather than a box reported against the model's
input rectangle. The case mounts the real `geometry.rs` and fails if that field
is ever widened. It is a `trybuild` case and not a doctest because this crate has
no library target, so doctests never run.

## Implementation notes

- Joining mid-stream is normal. The open is retried 12 times, 5 s apart, with
  a generous `analyzeduration` so the probe waits out a GOP instead of failing
  with "Invalid data found"; after that we exit loudly and let Cairn back off.
  In multiplexed mode that budget is unbounded instead — one member's open
  failure re-opens forever rather than taking the group's other cameras down.
- The udp `timeout` option (30 s) bounds both ends: without it a silent port
  blocks forever inside the probe,
  so the retry loop never gets a second attempt, and a mid-run silence parks
  the packet read instead of exiting for Cairn to restart.
- The socket binds loopback explicitly (`localaddr`). The SDP's
  `c=IN IP4 127.0.0.1` does not constrain the bind — libavformat's udp
  protocol otherwise listens on `0.0.0.0`, and anything that can route to the
  host could inject frames into a camera's detector.
- The demuxer also binds `udp-port + 1` for RTCP even though Cairn sends none.
  Cairn reserves it (`Cairn.UDPPorts` allocates four ports per camera); if
  something else takes that port the stream will not open at all. `localaddr`
  moves that port to loopback too.
- Every codec context caps `max_pixels` at 32 MP. This plugin is the first
  thing in the system that decodes camera bitstream (Cairn's ffmpeg is
  `-c:v copy`), so an SPS declaring 16384x16384 would otherwise size the
  allocation.
- Frames that cannot be decoded *or* converted cost one sample, not the
  process: both are counted and logged (first, then every 50th). Only a dead
  inference thread or a dead stream is fatal.
- Inference runs on its own thread behind a size-1 channel. Held inline it
  stalls the socket read long enough to overflow the receive buffer at
  multi-megabit bitrates, which corrupts the stream rather than just dropping
  a sample. Samples are dropped, never queued; every 50th drop is logged.
- Sampling is wall-clock, not PTS-based: the goal is capping model passes per
  second, and a bursty stream would otherwise fire several at once.
- The resize policy comes from the model's profile, because a model was
  trained one way and only that way: stretch for the Ultralytics families,
  aspect-preserving letterbox with 114 padding at the top-left for YOLOX,
  matching its own `preproc`. Every decode path is handed an explicit
  projection built alongside the scaler, so a letterboxed run cannot report
  boxes against the input rectangle instead of the frame.
- NMS runs for the raw layout only — an end-to-end export did it inside the
  model — and over at most the top 300 anchors, ranked evidence first and
  score second, which bounds an O(k²) pass that would otherwise start from
  8400. Every layout that reaches that cut gates each candidate on **its own
  class's** emission floor first, because the cut cannot see a label: under
  the documented allowlist pattern (`default: 1.0` with one class lower) 300
  stronger candidates in excluded classes would otherwise push the one
  configured class out, and all 300 are discarded a step later anyway. The
  end-to-end layout is the exception — its class id is a number in the output
  row, not an index into a known class table, so it cuts at the lowest score
  anything could be emitted at instead, which is safe because that layout is
  never truncated.
- A score is clamped to 0..1 and a box to the frame before either is emitted,
  for the same reason the label is trimmed: the host validates every field and
  drops the whole *detection* on an out-of-contract one. A box more than 4×
  the model input is dropped rather than clamped — that is not a box, it is an
  `exp()` overflow in a broken export, and clamping it would report a
  full-frame detection.
- The hardware filter graph is built on the first sampled frame, not at open:
  it needs the decoder's frames pool, which does not exist until something has
  been decoded.
- Output lines are capped at the contract's 65 536 bytes — the bound both
  host ports open us with (`{:line, 65_536}`) — by shedding from the end of a
  list ranked evidence first and score second, so the least interesting
  detections go first; an oversized line would be dropped by Cairn anyway. At 64
  shaped objects a line runs to about 12.3 KB — 14.2 KB when every object is
  a seeded re-report carrying `observation_kind` — so that shedding is a
  guard rather than a working part of the path. The object list is cut at 64 first,
  and for a harsher reason: an over-cap `objects` list is a contract
  violation that costs the *whole* line host-side, not just the surplus.
  That ranking is what makes both cuts drop the least interesting boxes, and
  it is also why a [track floor](#track-floor) costs a detection nothing: the
  band it opens is the tail of the list whatever the per-label floors are,
  which score alone would not give.
- stdout is locked per line, never held. `plugin.status` is written from the
  main thread while the inference thread is emitting frames, and a held
  `StdoutLock` would park one of them for the life of the process.
- Labels are shaped where the detection is built: `--labels` is arbitrary
  user text, and the host refuses a label over 64 bytes or carrying control
  characters. Trimming keeps the detection; sending it as-is loses it. A
  label with nothing printable left becomes `object` rather than `""`, which
  the host refuses just as hard.
- A `pts` outside the contract's ±2^62 is refused before it is emitted, with
  a rate-limited stderr note and no sequence number consumed. It means the
  rescale from the stream's time base overflowed (`av_rescale_q` saturates to
  `i64::MIN`), and the host drops such a line whole — liveness signal
  included — rather than just the field.
- The control thread ending ends the process. EOF, a read error or a panic on
  it means no epoch will ever change again, and a frozen epoch map turns into
  every later line being dropped host-side as stale while this process keeps
  the accelerator busy. Exiting non-zero is the recovery: both host ports
  respawn on exit and neither watches for a wedged plugin.
- `observed_at` is stamped at the sample gate, not at emit time. A sample can
  wait behind a busy model pass, and the host uses this to place the frame on
  its timeline — stamping it late would fold our own latency into the
  timeline it feeds.
