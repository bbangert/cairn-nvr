#!/usr/bin/env python3
"""fps <-> accuracy sweep: how tracking accuracy degrades with sample rate.

Membrane-port task 5.5's requirement half. Resamples each dataset to a set
of target sample rates (per-sequence keep_every = round(native/target), so
sequences with different native rates land on their nearest achievable
rate — the sidecars record the actual fps), drives the tracker per
rate x cell, scores each dataset-rate-cell against gt resampled onto the
SAME frame axis (TrackEval does not map rates), and reduces every COMBINED
row into fps_matrix.csv.

Native-rate cells are re-run here rather than copied from the phase-2
baseline so every point on the curve comes from one code state.

Cells: the baseline spine (bbd0_oru1) plus bbd1_oru1 — the BBD<->rate
interaction the baseline explicitly deferred. Floors follow the baseline
findings: MOT17 0.25, MOT20 0.0 (binary confs), PP22 0.25 + --det-min 0.5.

Resumable like matrix.py: existing resampled dirs, preds and
per_sequence.csv outputs are skipped.

Run from tools/mot-bench with the venv python:

    .venv/bin/python fps_sweep.py --jobs 8
"""
from __future__ import annotations

import argparse
import configparser
import csv
import json
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
WORK = ROOT / "data/work/fps_sweep"

CELLS = [{"bbd": False, "oru": True}, {"bbd": True, "oru": True}]

# label -> target fps; None = native (no resample, original gt tree)
RATES = {
    "mot17": [("native", None), ("f15", 15.0), ("f10", 10.0), ("f5", 5.0), ("f2.5", 2.5)],
    "mot20": [("native", None), ("f12.5", 12.5), ("f8.3", 8.33), ("f5", 5.0), ("f2.5", 2.5)],
    "pp22": [("native", None), ("f2.5", 2.5)],
}


def dataset_spec(name: str) -> dict:
    if name == "mot17":
        return {
            "seqs": sorted((ROOT / "data/mot17/train").iterdir()),
            "gt_root": ROOT / "data/trackeval_gt/data/gt/mot_challenge",
            "benchmark": "MOT17",
            "split": "train",
            "floor": 0.25,
        }
    if name == "mot20":
        return {
            "seqs": sorted((ROOT / "data/mot20/train").iterdir()),
            "gt_root": ROOT / "data/trackeval_gt/data/gt/mot_challenge",
            "benchmark": "MOT20",
            "split": "train",
            "floor": 0.0,
        }
    if name == "pp22":
        return {
            "seqs": [
                ROOT / "data/personpath22/mot" / stem.replace(".mp4", "")
                for stem in sorted(
                    json.loads((ROOT / "data/personpath22/splits.json").read_text())["test"]
                )
            ],
            "gt_root": ROOT / "data/personpath22/trackeval",
            "benchmark": "PP22",
            "split": "test",
            "floor": 0.25,
            "det_min": 0.5,
        }
    raise SystemExit(f"unknown dataset {name!r} (choose from mot17, mot20, pp22)")


def cell_id(cell: dict) -> str:
    return f"bbd{int(cell['bbd'])}_oru{int(cell['oru'])}"


def native_fps(seq_dir: Path) -> float:
    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(seq_dir / "seqinfo.ini")
    return float(config["Sequence"]["frameRate"])


def keep_every(native: float, target: float) -> int:
    return max(1, int(native / target + 0.5))


def resample(src: Path, dst: Path, n: int) -> None:
    """resample.py refuses an existing out dir, which doubles as resume.

    The resample itself is not atomic, so it runs into a `.part` dir that is
    renamed only on success — a kill mid-resample leaves a stale `.part`
    (swept on the next run), never a partial tree that resume would trust.
    """
    if dst.exists():
        return
    part = dst.parent / (dst.name + ".part")
    if part.exists():
        shutil.rmtree(part)
    cmd = [
        str(ROOT / ".venv/bin/python"),
        str(ROOT / "convert/resample.py"),
        "--seq", str(src),
        "--keep-every", str(n),
        "--out", str(part),
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"resample failed for {src}:\n{result.stdout[-500:]}\n{result.stderr[-500:]}")
    part.rename(dst)


def build_rate_trees(ds_name: str, spec: dict, rate_label: str, target: float) -> tuple[list[Path], Path]:
    """Resample seq dirs (tracking input) and gt dirs (scoring axis) for one
    target rate. Returns (seq_dirs, gt_root). keep_every == 1 still copies —
    a uniform tree beats special cases, and the identity copy is small."""
    seqs_out = WORK / "seqs" / ds_name / rate_label
    gt_out = WORK / "gt" / ds_name / rate_label
    gt_split = f"{spec['benchmark']}-{spec['split']}"

    seq_dirs = []
    for seq in spec["seqs"]:
        n = keep_every(native_fps(seq), target)
        resample(seq, seqs_out / seq.name, n)
        resample(spec["gt_root"] / gt_split / seq.name, gt_out / gt_split / seq.name, n)
        seq_dirs.append(seqs_out / seq.name)
    return seq_dirs, gt_out


def track_one(seq_dir: Path, pred: Path, flags: list[str]) -> str | None:
    if pred.exists():
        return None
    cmd = ["mix", "cairn.mot.track", str(seq_dir), "--out", str(pred), *flags]
    try:
        result = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        pred.unlink(missing_ok=True)
        return f"FAILED {seq_dir.name}: timed out after 900s"
    if result.returncode != 0:
        return f"FAILED {seq_dir.name}: {result.stdout[-300:]} {result.stderr[-300:]}"
    return None


def score_cell(spec: dict, tracker_name: str, gt_root: Path, preds_dir: Path, out_dir: Path) -> None:
    if (out_dir / "per_sequence.csv").exists():
        print(f"SKIP score (exists): {tracker_name}", flush=True)
        return
    cmd = [
        str(ROOT / ".venv/bin/python"),
        str(ROOT / "score.py"),
        "--preds", str(preds_dir),
        "--tracker-name", tracker_name,
        "--gt-root", str(gt_root),
        "--benchmark", spec["benchmark"],
        "--split", spec["split"],
        "--out", str(out_dir),
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"score.py failed for {tracker_name}:\n{result.stdout[-1500:]}\n{result.stderr[-1500:]}"
        )
    print(f"scored {tracker_name}", flush=True)


def combined_row(out_dir: Path) -> dict[str, str]:
    with (out_dir / "per_sequence.csv").open() as f:
        rows = [r for r in csv.DictReader(f) if r["seq"] == "COMBINED"]
    if not rows:
        raise SystemExit(f"no COMBINED row in {out_dir / 'per_sequence.csv'}")
    return rows[0]


def upsert_matrix(out: Path, rows: list[dict], key_fields: tuple[str, ...]) -> int:
    """Merge rows into an existing matrix CSV by key instead of rewriting it
    wholesale — a `--datasets mot20` rerun must not drop the other datasets'
    rows (matrix.py's convention). Returns the total row count written."""
    if not rows:
        raise SystemExit("no dataset-cells were selected; nothing to write")
    merged: dict[tuple, dict] = {}
    if out.exists():
        with out.open() as f:
            for row in csv.DictReader(f):
                merged[tuple(row.get(k, "") for k in key_fields)] = row
    for row in rows:
        merged[tuple(str(row.get(k, "")) for k in key_fields)] = row
    out.parent.mkdir(parents=True, exist_ok=True)
    ordered = sorted(merged.values(), key=lambda r: [str(r.get(k, "")) for k in key_fields])
    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(ordered)
    return len(ordered)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--datasets", nargs="*", default=["mot17", "mot20", "pp22"])
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--out", type=Path, default=WORK / "fps_matrix.csv")
    args = parser.parse_args()

    matrix_rows = []
    for ds_name in args.datasets:
        spec = dataset_spec(ds_name)
        for rate_label, target in RATES[ds_name]:
            if target is None:
                seq_dirs, gt_root = spec["seqs"], spec["gt_root"]
            else:
                seq_dirs, gt_root = build_rate_trees(ds_name, spec, rate_label, target)

            for cell in CELLS:
                cid = cell_id(cell)
                flags = [
                    "--bbd" if cell["bbd"] else "--no-bbd",
                    "--oru" if cell["oru"] else "--no-oru",
                    "--min-score", str(spec["floor"]),
                ]
                if "det_min" in spec:
                    flags += ["--det-min", str(spec["det_min"])]

                run_id = f"{ds_name}-{rate_label}-{cid}"
                preds_dir = WORK / "preds" / run_id
                preds_dir.mkdir(parents=True, exist_ok=True)
                jobs = [(seq, preds_dir / f"{seq.name}.txt") for seq in seq_dirs]

                with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                    errors = [
                        e
                        for e in pool.map(lambda j: track_one(j[0], j[1], flags), jobs)
                        if e is not None
                    ]
                if errors:
                    raise SystemExit(
                        f"{run_id}: {len(errors)} tracker runs failed:\n" + "\n".join(errors[:5])
                    )
                print(f"tracked {run_id} ({len(jobs)} seqs)", flush=True)

                out_dir = WORK / "out" / run_id
                score_cell(spec, run_id, gt_root, preds_dir, out_dir)

                row = combined_row(out_dir)
                matrix_rows.append(
                    {
                        "dataset": ds_name,
                        "rate": rate_label,
                        "cell": cid,
                        "bbd": int(cell["bbd"]),
                        "oru": int(cell["oru"]),
                        "floor": spec["floor"],
                        "det_min": spec.get("det_min", ""),
                        **{k: row[k] for k in ["HOTA", "DetA", "AssA", "LocA", "IDF1", "MOTA", "IDSW"]},
                    }
                )

    total = upsert_matrix(args.out, matrix_rows, ("dataset", "rate", "cell"))
    print(f"Wrote {args.out} ({len(matrix_rows)} rows this run, {total} total)")


if __name__ == "__main__":
    main()
