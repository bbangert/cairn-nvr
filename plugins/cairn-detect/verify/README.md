# cairn-detect verify harness

```
./feed.py --port 17000 --duration 20
some_plugin --udp-port 17000 --camera-id test | tee run.ndjson | ./validate_ndjson.py
./compare_runs.py --a fp32.ndjson --b int8.ndjson
```

**The plugin emits no detections until it is told a stream epoch.** Cairn
sends one `stream.started` per camera on the plugin's stdin at spawn, and a
`frame.objects` line has no valid `stream_epoch` to carry before that — so a
run driven by hand has to supply the control line itself, and keep stdin open
afterwards. EOF on stdin **exits the plugin** (an epoch map that can never
change again is worse than a restart), so a run whose control channel closes
early ends there rather than going quietly silent.

End-to-end: terminal 1 runs the plugin under test, tees its stdout to a file
and validates it live; terminal 2 feeds a fixture clip as RTP once the plugin
is up (the model loads before the RTP listener opens, so a feed started first
plays into a port nothing is listening on):

```
# terminal 1 — the brace group is the control channel: one epoch
# announcement, then a sleep that holds stdin open for the run
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 40; } \
  | ../target/release/cairn-detect --model ../yolox_nano.onnx \
      --labels ../coco.names --camera-id test --udp-port 17000 \
      --min-score-json '{}' \
  | tee fp32.ndjson | ./validate_ndjson.py

# terminal 2 — once terminal 1 has printed `cairn-detect up:` on stderr
./feed.py --port 17000 --duration 30

# terminal 2 (rerun for the other model or decoder backend), then:
./compare_runs.py --a fp32.ndjson --b int8.ndjson
```

`validate_ndjson.py` exits nonzero if it saw no `frame.objects` line at all,
which is exactly what a forgotten control line looks like: `plugin.hello` and
`plugin.status` arrive, frames never do.

## Gated runs

**The motion gate needs that same control line to gate at all.** A camera with
no stream epoch is never gated (nothing it emits would be accepted host-side,
so there is nothing to protect), which means a hand-driven run that forgets the
`stream.started` does not merely lose its frames — a run that supplies one
*late* silently measures the ungated behaviour up to that point. The epoch also
opens an `epoch_bypass_ms` window of forced inference, so the first 15 seconds
after it are inferred whatever the scene is doing.

**The plugin goes first here, not the feed.** It loads the model before it
opens the RTP listener, and packets sent into that gap are gone — so start
terminal 1, wait for the `cairn-detect up: camera=…` line it prints on stderr
once the model is loaded, and only then start terminal 2. How long that takes
is the model's business (a 3 MB yolox_nano and a 108 MB rfdetr are not the
same wait), which is why the line is the cue rather than a number. Starting
the feed first is not recoverable: `--duration 118` on a 118 s concat has
nothing to make up the lost seconds from, and the `epoch_bypass_ms` window
then spends 15 s of what is left, so the gated share is measured over less
scene than the run intended.

```
# terminal 1 — same control-line brace group as above, plus --motion-json
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 140; } \
  | ../target/release/cairn-detect --model ../yolox_nano.onnx \
      --labels ../coco.names --camera-id test --udp-port 17400 \
      --min-score-json '{}' --motion-json '{"enabled":true}' \
  | tee gate-on.ndjson | ./validate_ndjson.py

# terminal 2 — once terminal 1 has printed `cairn-detect up:`. The clip has
# to outlast the 15 s bypass to show a gated stretch after it, and these
# fixtures run 8-20 s, so concatenate:
#   for i in $(seq 6); do echo "file '$PWD/clip.mp4'"; done > list.txt
#   ffmpeg -f concat -safe 0 -i list.txt -c copy long.mp4
./feed.py --clip long.mp4 --port 17400 --loops 0 --duration 118
```

`feed.py --loops` is ffmpeg's `-stream_loop` and is not a substitute for
concatenating: `h264_mp4toannexb` fails at the loop boundary ("A non-NULL
packet sent after an EOF"), the feed dies, and the plugin exits on its 30 s
read timeout.

The validator's summary is what reads a gated run. This is what that recipe
printed against a two-minute concat of a 2560×1920 camera watching a parked
car, with the gate at the defaults `'{"enabled":true}'` leaves in place
(long lines wrapped here):

```
line kinds: seeded=345 fresh-detection=170 empty-objects=0 of 515 frame(s)
emit rate: 4.36 fps (every line, seeded or not)
effective inference rate: 1.44..1.44 fps (33.0% of lines carry a fresh
  detection, 0.0% are empty and could be either)
gate: on -- 67.0% of lines re-report an earlier frame's boxes instead of
  this frame's detections
```

That 67 % is one run of one clip at the default `min_area_fraction`: a rerun
of the same clip on the same build gated 57.4 %, and raising the floor to
`0.02` gated 73.0 %. Read a gated share as a property of the scene and the
knobs, not of the build.

The emit rate is unchanged by the gate — every sample still produces a line —
and the inference rate is what the gate bought. It is a *range* because an
empty-`objects` line is a model pass that found nothing and a gated sample with
nothing to re-report, and the wire cannot tell those apart; with something to
seed (as above) the range collapses. The plugin also says so itself, in
`plugin.status`: `grep 'motion gate' gate-on.ndjson` prints one line per
transition between gated and detecting — plus one baseline line at the first
closed window, whether or not anything changed — each carrying that window's
rate in `fps`.

`compare_runs.py` compares a gate-off capture against a gate-on one. The two
runs are fed the same clip but are not frame-aligned — each starts sampling at
its own phase and the sample gate is a floor, not a metronome — so read the
per-label rates and bucket overlap, not equality.

## Track-floor runs

`--track-floor-json` emits the detections between the track floor and each
class's `min_score`, at their real scores, for the host's low-confidence
association stage. **It is off unless you switch it on**, and a run without it
is byte-identical to one from before the flag existed — so the way to read one
is against a capture of the same clip without it.

The validator needs the floors the plugin ran under to say anything about the
band: they are not on the wire. Give it the same `--min-score-json` and it
reports the sub-floor share.

```
# terminal 1 — same control-line brace group as above
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 40; } \
  | ../target/release/cairn-detect --model ../yolox_nano.onnx \
      --labels ../coco.names --camera-id test --udp-port 17000 \
      --min-score-json '{"default":0.5}' --track-floor-json '{"floor":0.1}' \
  | tee floor-on.ndjson | ./validate_ndjson.py --min-score-json '{"default":0.5}'

# terminal 2 — once terminal 1 has printed `cairn-detect up:`
./feed.py --port 17000 --duration 30

# then the same clip with the flag left off, and:
./compare_runs.py --a floor-off.ndjson --b floor-on.ndjson
```

Under rfdetr instead, the model needs **both** of the flags the yolox examples
above do not carry — `--input-size 384` because every RF-DETR export leaves its
spatial dims dynamic, and `--labels ../coco91.names` because it indexes the
91-slot COCO *category id* space rather than the 80-entry dense list:

```
  | ../target/release/cairn-detect --model ../rfdetr_nano.onnx \
      --labels ../coco91.names --input-size 384 \
      --camera-id test --udp-port 17000 \
      --min-score-json '{"default":0.5}' --track-floor-json '{"floor":0.1}' \
```

What to read:

- **the sub-floor share** in the validator's summary. The flag-off run is the
  baseline for it — near zero, and exactly zero unless a floor has more than
  three decimals (the validator compares the rounded score on the wire, the
  plugin decides on the score before rounding) — so the flag-on number is what
  the band cost in wire.
- **`N of them on seeded lines`**, printed on that same line whether or not it
  is zero. For cairn-detect it is zero: a seed re-reports evidence, never the
  band (`emit::CameraState::last_dets`). Anything else on a gated track-floor
  run is a seeding regression.
- Give the validator the **same floors the plugin ran under**. It applies one
  `--min-score-json` to every camera in the capture, so a `--cameras-json`
  group whose members carry different `min_score` maps needs the capture split
  by `camera_id` before the share means anything per member.
- **`compare_runs.py` needs no flag of its own.** Its label table and bucket
  overlap are counts of what each run emitted, and its duplicate-pair table
  is geometry — none of them read a floor. What moves is the score column:
  the flag-on run's `min` falls to about the track floor, which is the band
  arriving and not a divergence. The per-label *rates* will diverge too, for
  the same reason, so its >3× verdict is not a parity verdict on this pair.
