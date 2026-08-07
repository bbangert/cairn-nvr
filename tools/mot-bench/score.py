#!/usr/bin/env python3
"""One-command MOT accuracy scoring wrapper around TrackEval.

Takes a directory of MOT-format tracker output files (one <SeqName>.txt per
sequence, as emitted by `mix cairn.mot.track`), builds a scratch TrackEval
directory layout pointing at the real ground truth, runs TrackEval's
run_mot_challenge.py, and reduces its detailed CSV into a small per-sequence
report plus a markdown summary. Optional `<SeqName>.config.json` sidecars
next to the predictions are echoed verbatim into the report so that scores
are re-derivable.

Must be run with the project venv's python (`.venv/bin/python score.py ...`)
since it invokes TrackEval as a subprocess using that same interpreter.
"""
from __future__ import annotations

import argparse
import csv
import datetime
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TRACKEVAL_SHA = "12c8791b303e0a0b50f753af204249e622d0281a"

DETAILED_COLUMNS = [
    ("HOTA", "HOTA___AUC"),
    ("DetA", "DetA___AUC"),
    ("AssA", "AssA___AUC"),
    ("LocA", "LocA___AUC"),
    ("IDF1", "IDF1"),
    ("MOTA", "MOTA"),
]


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


def discover_sequences(preds_dir: Path) -> list[str]:
    seqs = sorted(p.stem for p in preds_dir.glob("*.txt"))
    if not seqs:
        die(f"No <SeqName>.txt files found in {preds_dir}")
    return seqs


def verify_gt_present(gt_root: Path, benchmark: str, split: str, seqs: list[str]) -> Path:
    gt_split_dir = gt_root / f"{benchmark}-{split}"
    missing = []
    for seq in seqs:
        gt_txt = gt_split_dir / seq / "gt" / "gt.txt"
        seqinfo = gt_split_dir / seq / "seqinfo.ini"
        if not gt_txt.exists() or not seqinfo.exists():
            missing.append(seq)
    if missing:
        die(
            "Missing ground truth for sequences: "
            + ", ".join(missing)
            + f"\n(expected under {gt_split_dir}/<seq>/{{gt/gt.txt,seqinfo.ini}})"
        )
    return gt_split_dir


def build_work_dir(
    work_root: Path,
    gt_split_dir: Path,
    preds_dir: Path,
    benchmark: str,
    split: str,
    tracker_name: str,
    seqs: list[str],
) -> Path:
    if work_root.exists():
        shutil.rmtree(work_root)

    gt_mc = work_root / "gt" / "mot_challenge"
    gt_split_out = gt_mc / f"{benchmark}-{split}"
    seqmaps_dir = gt_mc / "seqmaps"
    tracker_data_dir = (
        work_root / "trackers" / "mot_challenge" / f"{benchmark}-{split}" / tracker_name / "data"
    )

    gt_split_out.mkdir(parents=True)
    seqmaps_dir.mkdir(parents=True)
    tracker_data_dir.mkdir(parents=True)

    for seq in seqs:
        (gt_split_out / seq).symlink_to((gt_split_dir / seq).resolve(), target_is_directory=True)
        (tracker_data_dir / f"{seq}.txt").symlink_to((preds_dir / f"{seq}.txt").resolve())

    seqmap_lines = ["name"] + seqs
    (seqmaps_dir / f"{benchmark}-{split}.txt").write_text("\n".join(seqmap_lines) + "\n")

    return work_root


def run_trackeval(work_root: Path, benchmark: str, split: str, tracker_name: str, out_dir: Path) -> None:
    venv_python = ROOT / ".venv" / "bin" / "python"
    script = ROOT / "vendor" / "trackeval" / "scripts" / "run_mot_challenge.py"
    gt_folder = (work_root / "gt" / "mot_challenge").resolve()
    trackers_folder = (work_root / "trackers" / "mot_challenge").resolve()

    cmd = [
        str(venv_python),
        str(script),
        "--GT_FOLDER", str(gt_folder),
        "--TRACKERS_FOLDER", str(trackers_folder),
        "--BENCHMARK", benchmark,
        "--SPLIT_TO_EVAL", split,
        "--TRACKERS_TO_EVAL", tracker_name,
        "--METRICS", "HOTA", "CLEAR", "Identity",
        "--USE_PARALLEL", "False",
        "--PLOT_CURVES", "False",
    ]

    log_path = out_dir / "trackeval.log"
    print(f"Running TrackEval: {shlex.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    log_path.write_text(result.stdout + result.stderr)

    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        die(f"TrackEval exited with status {result.returncode}; see {log_path}")

    print(f"TrackEval finished OK; full log at {log_path}")


def parse_detailed_csv(tracker_out_dir: Path) -> list[dict[str, str]]:
    detailed_csv = tracker_out_dir / "pedestrian_detailed.csv"
    if not detailed_csv.exists():
        die(f"Expected TrackEval output not found: {detailed_csv}")
    with detailed_csv.open() as f:
        rows = list(csv.DictReader(f))
    return rows


def build_per_sequence_rows(detailed_rows: list[dict[str, str]]) -> list[dict[str, object]]:
    normal = [r for r in detailed_rows if r["seq"] != "COMBINED"]
    combined = [r for r in detailed_rows if r["seq"] == "COMBINED"]
    ordered = sorted(normal, key=lambda r: r["seq"]) + combined

    out = []
    for row in ordered:
        entry: dict[str, object] = {"seq": row["seq"]}
        for out_col, csv_col in DETAILED_COLUMNS:
            entry[out_col] = round(float(row[csv_col]) * 100, 2)
        entry["IDSW"] = int(float(row["IDSW"]))
        out.append(entry)
    return out


def write_per_sequence_csv(rows: list[dict[str, object]], out_path: Path) -> None:
    fieldnames = ["seq", "HOTA", "DetA", "AssA", "LocA", "IDF1", "MOTA", "IDSW"]
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def installed_versions() -> str:
    import numpy
    import scipy

    return f"numpy=={numpy.__version__}, scipy=={scipy.__version__}"


def write_report(
    report_path: Path,
    tracker_name: str,
    benchmark: str,
    split: str,
    argv_str: str,
    rows: list[dict[str, object]],
    preds_dir: Path,
) -> None:
    lines = []
    lines.append(f"# MOT score: {tracker_name} on {benchmark}-{split}")
    lines.append("")
    lines.append(f"Date: {datetime.date.today().isoformat()}")
    lines.append("")
    lines.append(f"Command: `{argv_str}`")
    lines.append("")
    lines.append(f"TrackEval SHA: {TRACKEVAL_SHA}")
    lines.append("")
    lines.append(f"Python packages: {installed_versions()}")
    lines.append("")
    lines.append("## Per-sequence results")
    lines.append("")
    header = ["seq", "HOTA", "DetA", "AssA", "LocA", "IDF1", "MOTA", "IDSW"]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for row in rows:
        cells = [str(row[col]) for col in header]
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")

    lines.append("## Config echo")
    lines.append("")
    sidecars = sorted(preds_dir.glob("*.config.json"))
    if not sidecars:
        lines.append("No `<SeqName>.config.json` sidecars found in --preds.")
    else:
        for sidecar in sidecars:
            try:
                payload = json.loads(sidecar.read_text())
                pretty = json.dumps(payload, indent=2, sort_keys=True)
            except json.JSONDecodeError as e:
                pretty = f"<invalid JSON in {sidecar.name}: {e}>"
            lines.append(f"### {sidecar.name}")
            lines.append("")
            lines.append("```json")
            lines.append(pretty)
            lines.append("```")
            lines.append("")

    report_path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preds", type=Path, required=True, help="Dir of <SeqName>.txt tracker outputs")
    parser.add_argument("--tracker-name", required=True)
    parser.add_argument(
        "--gt-root",
        type=Path,
        default=Path("data/trackeval_gt/data/gt/mot_challenge"),
    )
    parser.add_argument("--benchmark", required=True, help="e.g. MOT17")
    parser.add_argument("--split", default="train")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()

    argv_str = "score.py " + shlex.join(sys.argv[1:])

    preds_dir: Path = args.preds
    if not preds_dir.is_dir():
        die(f"--preds is not a directory: {preds_dir}")

    # These become path components under data/work/ (and build_work_dir rmtree's
    # that dir), so refuse anything that could traverse out of it.
    for label, value in [
        ("--tracker-name", args.tracker_name),
        ("--benchmark", args.benchmark),
        ("--split", args.split),
    ]:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", value) or ".." in value:
            die(f"{label} must match [A-Za-z0-9._-]+ (got {value!r})")

    args.out.mkdir(parents=True, exist_ok=True)
    report_path = args.report if args.report is not None else args.out / "report.md"

    seqs = discover_sequences(preds_dir)
    gt_split_dir = verify_gt_present(args.gt_root, args.benchmark, args.split, seqs)

    work_root = ROOT / "data" / "work" / f"{args.tracker_name}-{args.benchmark}-{args.split}"
    build_work_dir(work_root, gt_split_dir, preds_dir, args.benchmark, args.split, args.tracker_name, seqs)

    run_trackeval(work_root, args.benchmark, args.split, args.tracker_name, args.out)

    tracker_out_dir = (
        work_root / "trackers" / "mot_challenge" / f"{args.benchmark}-{args.split}" / args.tracker_name
    )
    detailed_rows = parse_detailed_csv(tracker_out_dir)
    rows = build_per_sequence_rows(detailed_rows)
    write_per_sequence_csv(rows, args.out / "per_sequence.csv")

    summary_src = tracker_out_dir / "pedestrian_summary.txt"
    if summary_src.exists():
        shutil.copy(summary_src, args.out / "summary.txt")

    write_report(report_path, args.tracker_name, args.benchmark, args.split, argv_str, rows, preds_dir)

    print(f"Wrote {args.out / 'per_sequence.csv'}")
    print(f"Wrote {args.out / 'summary.txt'}")
    print(f"Wrote {report_path}")


if __name__ == "__main__":
    main()
