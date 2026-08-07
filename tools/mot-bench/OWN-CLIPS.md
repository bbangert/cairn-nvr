# Own-clips protocol: recording and annotating ground truth

The benchmark datasets cover generic surveillance; the numbers that matter
most come from ~10 clips of the cameras this NVR actually watches. Clips
and their ground truth are **never committed** — they live outside the
repo (see the path convention below), like every other dataset here.

## Recording (~10 clips, 30–60 s each)

Record through Cairn itself (event clips under `data/events/` are fine as
source material) or straight from the camera. Aim one clip at each failure
mode the tracker is measured on, per the tier2-accuracy plan:

1. **Occlusion crossings** — two people crossing paths, one passing behind
   the other; at least one clip with a full occlusion of 1–3 s.
2. **Stationary park** — a person or car entering, parking dead still past
   the stationary threshold (>10 s), then leaving; ideally with a passer-by
   walking close to the parked object while it is still.
3. **Re-entry** — an object leaving the frame and returning within
   ~10–60 s at a similar spot (tests coast/recovery/Re-ID).
4. **Two similar objects** — two people in similar clothing sharing the
   frame, crossing at least once (the Re-ID stress case).

Keep the camera static, native resolution and frame rate. Vary lighting
across the set (day/dusk/night if the cameras see them).

## Annotating with CVAT

```bash
# one-time: self-hosted CVAT
git clone --depth 1 https://github.com/cvat-ai/cvat ~/cvat && cd ~/cvat
docker compose up -d
# open http://localhost:8080, create an account, create a project
# with one label: person (add car if a clip needs it)
```

Per clip: create a **video task** from the mp4, annotate in **track mode**
— draw a box on the first frame an identity appears, use interpolation
(the wand between keyframes), correct every ~10–20 frames, and mark the
track **outside** when the object leaves. One track per real-world
identity — the same person re-entering continues their existing track
(that is the whole point of the re-entry clip). Occluded-but-present
frames: keep the box on your best estimate of the full extent (MOT
convention), do not break the track.

Export: **Actions → Export task dataset → MOT 1.1**, images off. The zip
contains `gt/gt.txt` and a `seqinfo.ini` shell.

## From export to the harness layout

Path convention (outside the repo):

```
~/cairn-clips/
  clips/<name>.mp4          # the recording fed to the plugin
  gt/OWN-<name>/
    seqinfo.ini             # from the export; verify frameRate matches
    gt/gt.txt               #   the clip (ffprobe), fix seqLength if blank
```

Checklist per exported clip:

- [ ] `seqinfo.ini` has the clip's real `frameRate`, `seqLength`,
      `imWidth`, `imHeight` (CVAT sometimes leaves these generic — fill
      from `ffprobe -show_entries stream=width,height,r_frame_rate,nb_frames`).
- [ ] `gt.txt` class column is 1 and the conf flag column is 1 for every
      row you want scored (CVAT writes conf 1 by default).
- [ ] Frame indices are 1-based and within `seqLength`.
- [ ] Sequence dir name starts with `OWN-` (keeps seqmaps readable).
- [ ] `seqinfo.ini`'s `name=` field is set to exactly the sequence dir's
      basename (`OWN-<name>`, matching the directory it lives in) —
      score.py matches predictions to ground truth by that name, and
      e2e.py refuses to run a sequence where they disagree.

## Scoring

Own clips are end-to-end only (they have no public detections):

```bash
cd tools/mot-bench
python3 e2e.py --seqs ~/cairn-clips/gt/OWN-* \
  --tag own-nano-reid \
  --model ../../plugins/cairn-detect/yolox_nano.onnx \
  --labels ../../plugins/cairn-detect/coco.names \
  --embedder-model ../../plugins/cairn-detect/osnet_x0_25.onnx \
  --bbd --reid \
  --gt-root ~/cairn-clips/gt-trackeval --benchmark OWN --split test
```

(the gt-trackeval tree is the usual `OWN-test/<seq>/gt/` symlink layout;
`score.py` builds its scratch dirs from it. When a seq dir has no `img1/`,
e2e.py looks for its clip in order: first `clips/<name>.mp4` next to `gt/`
— i.e. `~/cairn-clips/clips/<name>.mp4`, where `<name>` is the seq dir's
basename with a leading `OWN-` stripped — then, if that's missing, a video
named exactly after the seq dir itself, `~/cairn-clips/gt/OWN-<name>.mp4`.
It errors out listing both paths tried if neither exists.)

Two runs of one clip are not byte-identical — the plugin's sample gate is
wall-clock (`verify/README.md`) — so score each config twice and read the
pair as the noise band, exactly like the phase-2 protocol. e2e.py caches
the capture and prediction by `<seq>-<tag>`, so simply rerunning the same
command reuses them and produces a byte-identical second score — no
noise band. To actually get a second, independently-fed sample, rerun
with a distinct tag (e.g. `--tag own-nano-reid-b`); that forces a fresh
real-time feed and a fresh capture/pred pair under the new tag, which is
what you want to diff against the first run.
