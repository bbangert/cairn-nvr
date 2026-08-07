#!/usr/bin/env python3
"""Phase-2 baseline matrix: {BBD off/on} x {ORU off/on} x {floor 0/0.25}.

Runs `mix cairn.mot.track` per sequence per cell, scores each dataset-cell
with score.py, and reduces every COMBINED row into one matrix.csv. Resumable:
existing prediction files and per_sequence.csv outputs are skipped, so a
killed run continues where it stopped.

Run from tools/mot-bench with the venv python:

    .venv/bin/python matrix.py --jobs 8
"""
from __future__ import annotations

import argparse
import csv
import itertools
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent

CELLS = [
    {"bbd": bbd, "oru": oru, "floor": floor}
    for bbd, oru, floor in itertools.product([False, True], [False, True], [0.0, 0.25])
]


def cell_id(cell: dict) -> str:
    return f"bbd{int(cell['bbd'])}_oru{int(cell['oru'])}_f{round(cell['floor'] * 100):03d}"


def cell_flags(cell: dict) -> list[str]:
    return [
        "--bbd" if cell["bbd"] else "--no-bbd",
        "--oru" if cell["oru"] else "--no-oru",
        "--min-score",
        str(cell["floor"]),
    ]


def dataset_spec(name: str) -> dict:
    """Build one dataset's spec lazily, so unselected datasets need no data."""
    if name == "mot17":
        return {
            "seqs": sorted((ROOT / "data/mot17/train").iterdir()),
            "gt_root": ROOT / "data/trackeval_gt/data/gt/mot_challenge",
            "benchmark": "MOT17",
            "split": "train",
        }
    if name == "mot20":
        return {
            "seqs": sorted((ROOT / "data/mot20/train").iterdir()),
            "gt_root": ROOT / "data/trackeval_gt/data/gt/mot_challenge",
            "benchmark": "MOT20",
            "split": "train",
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
        }
    raise SystemExit(f"unknown dataset {name!r} (choose from mot17, mot20, pp22)")


def datasets(selected: list[str]) -> dict[str, dict]:
    return {name: dataset_spec(name) for name in selected}


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


def score_cell(ds_name: str, spec: dict, cid: str, preds_dir: Path, out_dir: Path) -> None:
    if (out_dir / "per_sequence.csv").exists():
        print(f"SKIP score (exists): {out_dir.name}", flush=True)
        return
    cmd = [
        str(ROOT / ".venv/bin/python"),
        str(ROOT / "score.py"),
        "--preds", str(preds_dir),
        "--tracker-name", f"cairn-{cid}",
        "--gt-root", str(spec["gt_root"]),
        "--benchmark", spec["benchmark"],
        "--split", spec["split"],
        "--out", str(out_dir),
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"score.py failed for {ds_name}/{cid}:\n"
            f"{result.stdout[-1500:]}\n{result.stderr[-1500:]}"
        )
    print(f"scored {ds_name}/{cid}", flush=True)


def combined_row(out_dir: Path) -> dict[str, str]:
    with (out_dir / "per_sequence.csv").open() as f:
        rows = [r for r in csv.DictReader(f) if r["seq"] == "COMBINED"]
    if not rows:
        raise SystemExit(f"no COMBINED row in {out_dir / 'per_sequence.csv'}")
    return rows[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--datasets", nargs="*", default=["mot17", "mot20", "pp22"])
    parser.add_argument(
        "--det-min",
        nargs="*",
        default=[],
        metavar="DATASET:FLOAT",
        help="per-dataset detection prefilter, e.g. pp22:0.5; the dataset's "
        "dirs and matrix rows get a dm suffix so unfiltered runs are kept apart",
    )
    parser.add_argument(
        "--ocr",
        action="store_true",
        help="run every cell with the tracking.ocr recovery stage on; cell ids "
        "gain an _ocr1 suffix so baseline rows are kept apart",
    )
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--preds", type=Path, default=ROOT / "data/preds/baseline")
    parser.add_argument("--out", type=Path, default=ROOT / "data/results/baseline")
    args = parser.parse_args()

    specs = datasets(args.datasets)
    for override in args.det_min:
        name, sep, value = override.partition(":")
        if not sep:
            raise SystemExit(f"--det-min expects DATASET:FLOAT, got {override!r}")
        if name not in specs:
            raise SystemExit(f"--det-min names {name!r}, which is not in --datasets {args.datasets}")
        spec = specs.pop(name)
        try:
            spec["det_min"] = float(value)
        except ValueError:
            raise SystemExit(f"--det-min expects DATASET:FLOAT, got {override!r}") from None
        specs[f"{name}dm{round(float(value) * 100):02d}"] = spec
    matrix_rows = []

    for cell in CELLS:
        cid = cell_id(cell) + ("_ocr1" if args.ocr else "")
        flags = cell_flags(cell) + (["--ocr"] if args.ocr else [])
        for ds_name, spec in specs.items():
            preds_dir = args.preds / f"{ds_name}-{cid}"
            preds_dir.mkdir(parents=True, exist_ok=True)
            ds_flags = list(flags)
            if "det_min" in spec:
                ds_flags += ["--det-min", str(spec["det_min"])]
            jobs = [(seq, preds_dir / f"{seq.name}.txt") for seq in spec["seqs"]]

            with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                errors = [
                    e
                    for e in pool.map(lambda j: track_one(j[0], j[1], ds_flags), jobs)
                    if e is not None
                ]
            if errors:
                raise SystemExit(f"{ds_name}/{cid}: {len(errors)} tracker runs failed:\n" + "\n".join(errors[:5]))
            print(f"tracked {ds_name}/{cid} ({len(jobs)} seqs)", flush=True)

            out_dir = args.out / f"{ds_name}-{cid}"
            score_cell(ds_name, spec, cid, preds_dir, out_dir)

            row = combined_row(out_dir)
            matrix_rows.append(
                {
                    "dataset": ds_name,
                    "cell": cid,
                    "bbd": int(cell["bbd"]),
                    "oru": int(cell["oru"]),
                    "floor": cell["floor"],
                    **{k: row[k] for k in ["HOTA", "DetA", "AssA", "LocA", "IDF1", "MOTA", "IDSW"]},
                }
            )

    if not matrix_rows:
        raise SystemExit("no dataset-cells were selected; nothing to write")

    # Upsert by (dataset, cell): a --datasets subset run must not clobber
    # rows an earlier full run produced.
    matrix_path = args.out / "matrix.csv"
    merged: dict[tuple[str, str], dict] = {}
    if matrix_path.exists():
        with matrix_path.open() as f:
            for row in csv.DictReader(f):
                merged[(row["dataset"], row["cell"])] = row
    for row in matrix_rows:
        merged[(row["dataset"], row["cell"])] = {k: str(v) for k, v in row.items()}
    with matrix_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(matrix_rows[0].keys()))
        writer.writeheader()
        writer.writerows(merged.values())
    print(f"Wrote {matrix_path} ({len(merged)} rows, {len(matrix_rows)} from this run)")


if __name__ == "__main__":
    main()
