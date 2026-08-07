# Golden replay fixtures

Recorded detector output replayed through `Cairn.Tracker` with exact-equality
goldens, so an extraction PR can prove "bit-identical behaviour" with an empty
golden diff. The replay driver is `Cairn.GoldenReplay`
(`test/support/golden_replay.ex`); the suite is
`test/cairn/golden_replay_test.exs`, tagged `:golden`, and runs in the default
`mix test`.

## What is committed here

- `captures/*.tsv.gz` — real plugin stdout, one line per emitted ndjson line,
  each prefixed with its **arrival time in monotonic milliseconds** and a tab:

  ```
  <now_ms>\t<raw ndjson line>
  ```

  The arrival column is not decoration: `at_ms` is stamped by
  `Cairn.ObservationClock.stamp/3` from the host's monotonic clock at line
  arrival, and that timing is not in the lines themselves. Replaying without
  it would invent a different clock and different tracking decisions.

- `steps/*.exs` — hand-authored step scripts for paths recorded clips never
  hit (suspension/adoption across a cut, live-track-cap eviction, epoch
  change, the `twin_mint: false` double-mint escape hatch, and the
  `ocr: true` paused-mover recovery). See "Step scripts" below.

- `goldens/*.golden` — the expected canonicalized output per fixture,
  regenerated only by `mix cairn.golden.regen` and reviewed as a diff.

Clips and model weights stay **uncommitted** (they are large and
operator-held); the captures are the committed artifact.

## Capture provenance

Captured 2026-08-05 at repo tip `52f07d2`, plugin binary built from sources
unchanged since `20a95eb` (last `plugins/` commit). Model:
`plugins/cairn-detect/yolox_nano.onnx` + `coco.names`.

Source clips are the two the ByteTrack/BBD soaks used, originally recorded
under `data/events/reolink_main/`:

| capture | clip | sha256 (single, pre-concat) | plugin flags |
|---|---|---|---|
| `active.tsv.gz` | `4b160d2e-…_reolink_main_1785642456.mp4` (19.3 s, dusk, IR-cut flip, walker + cars) ×6 | `13e0f0ba…60879b4` | `--min-score-json '{}' --track-floor-json '{"floor":0.25}'` |
| `still.tsv.gz` | `213c0177-…_reolink_main_1785636954.mp4` (20.0 s, parked car) ×6 | `a408a315…427a15` | same + `--motion-json '{"enabled":true}'` |

The active capture carries the sub-floor band (track floor 0.25 under the
0.5 default min-score), so BBD's stage-two association has real input; the
still capture ran gated (43.8 % seeded lines), so the re-reported-box path
is replayed too.

## Capture recipe (one-time, manual — per fixture refresh, not per run)

From `plugins/cairn-detect/verify/` conventions (see its README for why the
plugin goes first and what the control line is for). Concatenate ×6 so the
clip outlasts the 15 s `epoch_bypass_ms` window:

```sh
for i in $(seq 6); do echo "file '$PWD/clip.mp4'"; done > list.txt
ffmpeg -f concat -safe 0 -i list.txt -c copy long.mp4
```

Arrival stamping — pipe plugin stdout through this instead of `tee`:

```python
#!/usr/bin/env python3
# stamp_arrivals.py <out.tsv>: prefix each stdin line with monotonic ms + TAB
import sys, time
out = open(sys.argv[1], "w")
for line in sys.stdin:
    out.write(f"{time.monotonic_ns() // 1_000_000}\t{line}")
    out.flush()
```

Terminal 1 (the brace group is the control channel — one epoch announcement,
then a sleep holding stdin open past the feed):

```sh
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 140; } \
  | ../target/release/cairn-detect --model ../yolox_nano.onnx \
      --labels ../coco.names --camera-id test --udp-port 17800 \
      --min-score-json '{}' --track-floor-json '{"floor":0.25}' \
  | ./stamp_arrivals.py active.tsv
```

Terminal 2, once terminal 1 prints `cairn-detect up:` on stderr:

```sh
./feed.py --clip long.mp4 --port 17800 --loops 0 --duration 118
```

Then validate (`cut -f2- active.tsv | ./validate_ndjson.py --min-score-json
'{}'`), gzip -9 into `captures/`, and regenerate goldens.

A refreshed capture is a **new fixture**, not a reproduction: RTP sampling
picks its own phase and arrival timing is the machine's, so every golden
regenerates with it. That is expected; the goldens pin the *replay* of a
fixed capture, not the capture itself.

## What this harness is not

This is a **regression harness, not the soak**. It proves a refactor
bit-identical on these fixtures; it cannot detect rates-over-hours
properties — mint churn per hour, band share, identity-switch rates —
which are what the soak measured and what the soak recipe
(`.claude/plans/tracker-reeval/soak-results.md`) remains the tool for. A
green golden suite after a *behaviour* change says the change reproduces on
two driveway clips and three step scripts, nothing more.

And per `.claude/solutions/fixture-corpus-uniform-in-a-dimension`, a corpus
is blind along every dimension it holds constant. This one holds constant:

- **one camera, one model, one protocol version** — every capture is
  yolox_nano over v1 wire from a single `:camera`-mode plugin; nothing here
  exercises group routing, v0 lines, or another decoder's score/box
  distribution;
- **a live set under 32 tracks** — the canonicalizer's same-kind event sort
  guards the >32-key hashmap iteration hazard, but no fixture *reaches* it,
  so that guard is untested against the real thing;
- **a single epoch per capture** — epoch cuts live only in the step
  scripts, at exactly one cut per fixture;
- **production-scale windows** — per
  `.claude/solutions/compressed-timescale-fixture-changes-what-crosses-a-rate-floor`,
  no fixture compresses `stationary_after_ms` or the adoption window, so a
  step script added with compressed windows must re-derive which stimuli
  cross rate floors rather than reuse these fixtures' motions.

A divergence along any constant dimension will not move these goldens.
Say so honestly in any PR that leans on them.
