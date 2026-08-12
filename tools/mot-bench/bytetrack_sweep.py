#!/usr/bin/env python3
"""Reference no-Re-ID MOT trackers over the same rate ladder as fps_sweep.py.

Round 1 (ByteTrack alone) answered Ben's first question — cairn's flat
fps↔accuracy curve is its 5 fps tuning, not physics: reference ByteTrack
beats the hybrid by ~2.5-3.3 HOTA at 8+ fps on stationary benchmarks, ties
at 5, loses below (see the postscript in
membrane-port/research/fps-accuracy-sweep.md). Round 2 adds the two
strongest appearance-free trackers above ByteTrack on the leaderboards,
same protocol:

  * OC-SORT (vendor/ocsort @ 8462e7e, MIT) — observation-centric Kalman
    (ORU/OCM/OCR). Also a control on cairn's own history: cairn ported ORU
    (kept) and OCR (measured net-negative) into a different chassis; the
    reference tells us whether OCR's negative was OCR or the transplant.
    Params: det_thresh 0.6, iou 0.3, delta_t 3, asso iou, inertia 0.2,
    use_byte off (their MOT defaults).
  * SparseTrack (vendor/sparsetrack @ 499844f, MIT) — pseudo-depth scene
    decomposition, cascaded matching; the published MOT20 (dense static
    crowds) leader among appearance-free trackers. Published per-dataset
    configs: MOT17 match 0.75 / buffer 30 / depth 1+3 / confirm 0.8;
    MOT20 match 0.6 / buffer 60 / depth 1+8 / confirm 0.7 (PP22 runs the
    MOT17 config — a choice, recorded). GMC never runs (detections-only
    harness passes no images; the authors' own MOT20 protocol disables it).

Protocol notes shared with round 1, all deliberate:

  * Same resampled sequence/gt trees as fps_sweep.py (TrackEval maps no
    rates); identical axes make every cell comparable with the cairn rows.
  * RAW detections, no floor — the low-score second stages need them.
    Scores clipped to [0, 1] (DPM's SVM scores are off-scale; caveat).
    MOT20's binary confs are fed at score 1.0 for every tracker (the
    conf-0 majority would be hard-dropped below the 0.1 low bounds — the
    round-1 first run measured DetA 3.4 before this correction).
  * Two buffer denominations per tracker: `buf30` = published frame
    counts (frame_rate=30 / max_age 30); `buf1s` = the published buffer's
    TIME SPAN at the actual rate (frame_rate=fps scales `track_buffer`
    linearly — ~1 s for the 30-frame defaults, ~2 s for SparseTrack's
    60-frame MOT20 config). Round 1 found the variants within noise —
    kept so round 2 can confirm that transfers.
  * Output filters as published (min box area 100 px², vertical aspect
    w/h > 1.6 dropped), uniformly across trackers.

Tracker cores are vendored by setup.sh (clone at pinned SHA + mechanical
patches); provenance, licenses and patch rationale live in
vendor-patches/README.md, and the lapx/filterpy deps are pinned in
requirements.txt.

Resumable: existing prediction files and per_sequence.csv outputs are
skipped — the completed round-1 `bt-*` cells are cache hits. Run from
tools/mot-bench with the venv python (round 2 adds ~2x round 1's time):

    .venv/bin/python bytetrack_sweep.py 2>&1 | tee -a data/work/bytetrack_sweep/run.log
"""
from __future__ import annotations

import argparse
import configparser
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT))

from bytetrack.byte_tracker import BYTETracker  # noqa: E402
from ocsort.ocsort import OCSort  # noqa: E402
from sparsetrack.sparse_tracker import SparseTracker  # noqa: E402
from fps_sweep import (  # noqa: E402
    RATES,
    build_rate_trees,
    combined_row,
    dataset_spec,
    score_cell,
    upsert_matrix,
)

WORK = ROOT / "data/work/bytetrack_sweep"

MIN_BOX_AREA = 100.0
VERTICAL_ASPECT = 1.6

TRACKER_PREFIX = {"bytetrack": "bt", "ocsort": "oc", "sparsetrack": "sp"}


class BTArgs:
    track_thresh = 0.6
    track_buffer = 30
    match_thresh = 0.8
    mot20 = False


class SPArgs:
    """SparseTrack's published per-dataset track configs (mot{17,20}_track_cfg.py)."""

    def __init__(self, mot20: bool):
        self.track_thresh = 0.6
        self.track_buffer = 60 if mot20 else 30
        self.match_thresh = 0.6 if mot20 else 0.75
        self.down_scale = 4
        self.depth_levels = 1
        self.depth_levels_low = 8 if mot20 else 3
        self.confirm_thresh = 0.7 if mot20 else 0.8
        self.mot20 = mot20
        self.val_ann = ""  # not '_half.json': det_thresh = track_thresh + 0.05


def make_stepper(tracker: str, mot20: bool, fps: float, variant: str, im_hw: tuple[int, int]):
    """One per-frame closure: numpy (N,5) in, [(id, x, y, w, h)] out."""
    frame_rate = 30 if variant == "buf30" else max(1, round(fps))

    if tracker == "bytetrack":
        args = BTArgs()
        args.mot20 = mot20
        t = BYTETracker(args, frame_rate=frame_rate)

        def step(arr):
            return [(s.track_id, *s.tlwh) for s in t.update(arr, im_hw, im_hw)]

    elif tracker == "ocsort":
        t = OCSort(det_thresh=0.6, max_age=frame_rate, min_hits=3, iou_threshold=0.3)

        def step(arr):
            out = t.update(arr, im_hw, im_hw)
            return [
                (int(r[4]), r[0], r[1], r[2] - r[0], r[3] - r[1]) for r in np.asarray(out)
            ]

    elif tracker == "sparsetrack":
        t = SparseTracker(SPArgs(mot20), frame_rate=frame_rate)

        def step(arr):
            return [(s.track_id, *s.tlwh) for s in t.update(arr)]

    else:
        raise SystemExit(f"unknown tracker {tracker!r}")

    return step


def read_seqinfo(seq_dir: Path) -> tuple[float, int, int, int]:
    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(seq_dir / "seqinfo.ini")
    s = config["Sequence"]
    return float(s["frameRate"]), int(s["seqLength"]), int(s["imWidth"]), int(s["imHeight"])


def dets_by_frame(seq_dir: Path, all_scores_one: bool) -> dict[int, list[list[float]]]:
    by_frame: dict[int, list[list[float]]] = {}
    with (seq_dir / "det" / "det.txt").open() as f:
        for line in f:
            if not line.strip():
                continue
            p = line.split(",")
            frame = int(float(p[0]))
            x, y, w, h, conf = (float(v) for v in p[2:7])
            # tlbr + score, conf clipped onto the trackers' [0,1] scale (DPM
            # caveat in the moduledoc); boxes stay in pixels.
            # all_scores_one is the MOT20 binary-conf correction.
            score = 1.0 if all_scores_one else min(max(conf, 0.0), 1.0)
            by_frame.setdefault(frame, []).append([x, y, x + w, y + h, score])
    return by_frame


def track_seq(seq_dir: Path, pred: Path, tracker: str, mot20: bool, variant: str) -> None:
    if pred.exists():
        return
    fps, seq_length, im_w, im_h = read_seqinfo(seq_dir)
    frames = dets_by_frame(seq_dir, all_scores_one=mot20)
    step = make_stepper(tracker, mot20, fps, variant, (im_h, im_w))

    lines: list[str] = []
    empty = np.zeros((0, 5), dtype=np.float64)
    for frame in range(1, seq_length + 1):
        dets = frames.get(frame)
        arr = np.asarray(dets, dtype=np.float64) if dets else empty
        for track_id, x, y, w, h in step(arr):
            if w * h <= MIN_BOX_AREA or w / max(h, 1e-6) > VERTICAL_ASPECT:
                continue
            lines.append(f"{frame},{track_id},{x:.2f},{y:.2f},{w:.2f},{h:.2f},1,-1,-1,-1\n")

    pred.parent.mkdir(parents=True, exist_ok=True)
    tmp = pred.with_suffix(".part")
    tmp.write_text("".join(lines))
    tmp.rename(pred)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--datasets", nargs="*", default=["pp22", "mot17", "mot20"])
    parser.add_argument("--trackers", nargs="*", default=["bytetrack", "ocsort", "sparsetrack"])
    parser.add_argument("--variants", nargs="*", default=["buf30", "buf1s"])
    parser.add_argument("--out", type=Path, default=WORK / "bytetrack_matrix.csv")
    args = parser.parse_args()

    WORK.mkdir(parents=True, exist_ok=True)
    matrix_rows = []

    for ds_name in args.datasets:
        spec = dataset_spec(ds_name)
        for rate_label, target in RATES[ds_name]:
            if target is None:
                seq_dirs, gt_root = spec["seqs"], spec["gt_root"]
            else:
                seq_dirs, gt_root = build_rate_trees(ds_name, spec, rate_label, target)

            for tracker in args.trackers:
                for variant in args.variants:
                    run_id = f"{TRACKER_PREFIX[tracker]}-{variant}-{ds_name}-{rate_label}"
                    preds_dir = WORK / "preds" / run_id
                    for seq_dir in seq_dirs:
                        track_seq(
                            seq_dir,
                            preds_dir / f"{seq_dir.name}.txt",
                            tracker=tracker,
                            mot20=(ds_name == "mot20"),
                            variant=variant,
                        )
                    print(f"tracked {run_id} ({len(seq_dirs)} seqs)", flush=True)

                    out_dir = WORK / "out" / run_id
                    score_cell(spec, run_id, gt_root, preds_dir, out_dir)

                    row = combined_row(out_dir)
                    matrix_rows.append(
                        {
                            "dataset": ds_name,
                            "rate": rate_label,
                            "tracker": f"{tracker}-{variant}",
                            **{k: row[k] for k in ["HOTA", "DetA", "AssA", "LocA", "IDF1", "MOTA", "IDSW"]},
                        }
                    )

    total = upsert_matrix(args.out, matrix_rows, ("dataset", "rate", "tracker"))
    print(f"Wrote {args.out} ({len(matrix_rows)} rows this run, {total} total)")


if __name__ == "__main__":
    main()
