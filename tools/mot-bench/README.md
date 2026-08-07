# mot-bench

Tracker-only MOT accuracy harness for the cairn tracker. Feeds recorded
MOTChallenge / PersonPath22 public detections through `Cairn.Tracker` (no
pixels, no detector) and scores the output with
[TrackEval](https://github.com/JonathonLuiten/TrackEval) (HOTA, CLEAR,
Identity).

## Quickstart

```sh
cd tools/mot-bench
./setup.sh                                  # venv + vendored TrackEval
python3 fetch.py --dataset labels           # MOT17/MOT20/TrackEval-gt/PersonPath22-anno

# from the repo root: run the tracker over a sequence
mix cairn.mot.track tools/mot-bench/data/mot17/train/MOT17-04-SDP \
  --out tools/mot-bench/data/preds/base/MOT17-04-SDP.txt --bbd --oru

# back in tools/mot-bench: score the predictions
.venv/bin/python score.py --preds data/preds/base --benchmark MOT17 \
  --tracker-name base --out data/out/base
```

`mix cairn.mot.track` emits one `<Seq>.txt` prediction file plus a
`<Seq>.config.json` sidecar per run; the full CLI is documented in that mix
task's moduledoc (`lib/mix/tasks/cairn.mot.track.ex`). `score.py` folds any
sidecars it finds into `report.md` under "Config echo" so every number is
re-derivable.

## Frame-rate warning

TrackEval does **not** auto-map frame rates between predictions and ground
truth — it assumes both already share the same frame axis. If you want to
evaluate at a reduced rate, make the mismatch explicit first with
`convert/resample.py --seq <dir> --keep-every N --out <dir>`.

## PersonPath22 keyframe remap

PersonPath22 only annotates ~5fps keyframes on the native-fps grid, so
`convert/personpath_to_mot.py` renumbers each video's sparse native
`frame_idx` values onto a dense `1..K` MOT frame axis before writing
`gt.txt`. Any detections scored against these sequences must go through the
same native→dense mapping (`keyframe_map()` in that module) or frame numbers
won't line up.

## What is NOT downloaded here

Raw images and videos (full MOT17 is ~5.5GB, PersonPath22 raw video is much
larger) are deliberately out of scope for this harness — this is
tracker-only scoring against public detections and ground truth labels.
Pixels arrive with the phase-6 end-to-end work via upstream tooling.

## License / obligations

See [OBLIGATIONS.md](OBLIGATIONS.md) — MOT17/MOT20 (CC BY-NC-SA 3.0) and
PersonPath22 (CC BY-NC 4.0) both restrict redistribution and commercial use;
`data/` is gitignored and datasets are fetched on demand rather than
committed.

## numpy/scipy pin rationale

`requirements.txt` pins `numpy==1.23.5` / `scipy==1.10.1`, not the newer
`numpy==1.26.4` / `scipy==1.11.4` originally targeted. The pinned TrackEval
checkout (`12c8791b`) uses numpy aliases removed in numpy>=1.24 (`np.float`,
`np.int`) in its core MOT scoring path (`mot_challenge_2d_box.py`,
`hota.py`, `identity.py`), so 1.26.4 crashes with `AttributeError`. Verified
empirically by running the oracle scoring test end to end.
