#!/usr/bin/env python3
"""Subsample PersonPath22 public detections onto the annotated keyframe grid.

The public FCOS detections (`fetch.py --dataset personpath22-det`) are dense
MOT det files at native video rate, 1-based: det frame f corresponds to
annotation `frame_idx` f-1 (verified against video/anno/det frame extents).
Ground truth from `personpath_to_mot.py` lives on the ~5 fps keyframe grid,
renumbered densely to 1..K. Detections fed to the tracker must go through the
SAME native→dense mapping or every prediction lands between gt frames.

Writes `det/det.txt` into the per-video seq dirs `personpath_to_mot.py`
created, so each `<out>/<stem>/` becomes a complete tracker-ready MOT
sequence (seqinfo.ini + gt/gt.txt + det/det.txt).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from personpath_to_mot import keyframe_map  # noqa: E402


def convert_video(anno_path: Path, det_path: Path, seq_dir: Path) -> tuple[int, int]:
    anno = json.loads(anno_path.read_text())
    mapping = keyframe_map(anno)

    kept = total = 0
    out_lines = []
    for line in det_path.read_text().splitlines():
        if not line.strip():
            continue
        total += 1
        fields = line.split(",")
        native_fi = int(fields[0]) - 1
        dense = mapping.get(native_fi)
        if dense is None:
            continue
        kept += 1
        out_lines.append(",".join([str(dense)] + fields[1:]))

    out_lines.sort(key=lambda l: int(l.split(",", 1)[0]))
    det_dir = seq_dir / "det"
    det_dir.mkdir(parents=True, exist_ok=True)
    (det_dir / "det.txt").write_text("\n".join(out_lines) + "\n" if out_lines else "")
    return kept, total


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--anno-dir", type=Path, default=Path("data/personpath22/annotation/anno_visible_2022")
    )
    parser.add_argument(
        "--det-dir", type=Path, default=Path("data/personpath22/det_mot/mot_format")
    )
    parser.add_argument("--out", type=Path, default=Path("data/personpath22/mot"))
    parser.add_argument("--videos", nargs="*", help="video stems (default: all with dets)")
    args = parser.parse_args()

    stems = args.videos or sorted(p.stem for p in args.det_dir.glob("uid_vid_*.txt"))
    for stem in stems:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", stem):
            raise SystemExit(f"video stem must match [A-Za-z0-9._-]+ (got {stem!r})")
    missing = []
    for stem in stems:
        anno_path = args.anno_dir / f"{stem}.mp4.json"
        det_path = args.det_dir / f"{stem}.txt"
        seq_dir = args.out / stem
        if not anno_path.exists() or not det_path.exists() or not seq_dir.exists():
            missing.append(stem)
            continue
        kept, total = convert_video(anno_path, det_path, seq_dir)
        print(f"{stem}: kept {kept}/{total} det lines on {seq_dir.name}'s keyframe grid")

    if missing:
        raise SystemExit(
            f"{len(missing)} videos missing annotation, detections, or gt seq dir "
            f"(run fetch.py and personpath_to_mot.py first): {missing[:5]}..."
        )


if __name__ == "__main__":
    main()
