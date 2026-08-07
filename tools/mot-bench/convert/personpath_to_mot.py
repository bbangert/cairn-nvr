#!/usr/bin/env python3
"""Convert PersonPath22 per-video GluonCV-style JSON annotations to MOT gt trees.

KEYFRAME-REMAP CONTRACT: PersonPath22 only annotates ~5fps keyframes on the
native-fps frame grid, so `blob.frame_idx` values in the source JSON are
sparse (e.g. 0, 5, 10, 14, 19, 24, ...) rather than dense. This converter
remaps each video's distinct native frame_idx values to a dense 1..K MOT
frame axis (K = number of distinct annotated frames), in ascending order.
Any detection file that is meant to be scored against these gt sequences
(e.g. a detector run at native fps) MUST be put through the identical
native-frame -> dense-frame mapping before scoring, or frame numbers will not
line up. Use `keyframe_map()` below to get that mapping for a given
annotation JSON.

Output per video <stem> (stem = filename with the trailing ".mp4" stripped):
  <out>/<stem>/gt/gt.txt      MOT gt format: frame,id+1,x,y,w,h,1,1,1
  <out>/<stem>/seqinfo.ini    name/frameRate/seqLength/imWidth/imHeight
"""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

DEFAULT_ANNO_DIR = Path("data/personpath22/annotation/anno_visible_2022")
DEFAULT_OUT = Path("data/personpath22/mot")


def keyframe_map(anno_json: dict) -> dict[int, int]:
    """Return {native_frame_idx: dense_1_based_frame} for one annotation JSON.

    K = sorted distinct frame_idx values seen across all entities. Each native
    frame_idx maps to its 1-based position in K.
    """
    native_frames = sorted({e["blob"]["frame_idx"] for e in anno_json["entities"]})
    return {native: pos + 1 for pos, native in enumerate(native_frames)}


def _fmt(x: float) -> str:
    """Trim floats to a compact %g-style representation."""
    return f"{x:g}"


def convert_one(anno_path: Path, out_root: Path) -> None:
    with anno_path.open() as f:
        data = json.load(f)

    stem = anno_path.name
    if stem.endswith(".mp4.json"):
        stem = stem[: -len(".mp4.json")]
    elif stem.endswith(".json"):
        stem = stem[: -len(".json")]

    fmap = keyframe_map(data)
    native_frames = sorted(fmap.keys())
    k = len(native_frames)

    metadata = data["metadata"]
    native_fps = float(metadata["fps"])
    if k > 1:
        diffs = [b - a for a, b in zip(native_frames, native_frames[1:])]
        step = statistics.median(diffs)
        effective_fps = native_fps / step if step > 0 else native_fps
    else:
        effective_fps = native_fps

    rows = []
    for entity in data["entities"]:
        native_idx = entity["blob"]["frame_idx"]
        dense_frame = fmap[native_idx]
        track_id = entity["id"] + 1
        x, y, w, h = entity["bb"]
        rows.append((dense_frame, track_id, x, y, w, h))

    rows.sort(key=lambda r: (r[0], r[1]))

    seq_dir = out_root / stem
    gt_dir = seq_dir / "gt"
    gt_dir.mkdir(parents=True, exist_ok=True)

    with (gt_dir / "gt.txt").open("w") as f:
        for frame, tid, x, y, w, h in rows:
            f.write(
                f"{frame},{tid},{_fmt(x)},{_fmt(y)},{_fmt(w)},{_fmt(h)},1,1,1\n"
            )

    im_width = int(metadata["resolution"]["width"])
    im_height = int(metadata["resolution"]["height"])
    frame_rate = round(effective_fps)

    seqinfo = (
        "[Sequence]\n"
        f"name={stem}\n"
        "imDir=img1\n"
        f"frameRate={frame_rate}\n"
        f"seqLength={k}\n"
        f"imWidth={im_width}\n"
        f"imHeight={im_height}\n"
        "imExt=.jpg\n"
    )
    (seq_dir / "seqinfo.ini").write_text(seqinfo)

    print(
        f"{stem}: {len(rows)} boxes, K={k} frames, "
        f"native_fps={native_fps:.3f}, effective_fps={effective_fps:.3f} "
        f"(rounded frameRate={frame_rate})"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--anno-dir", type=Path, default=DEFAULT_ANNO_DIR)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--videos",
        nargs="*",
        default=None,
        help="Video stems to convert (default: all found in --anno-dir).",
    )
    args = parser.parse_args()

    anno_dir: Path = args.anno_dir
    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.videos:
        paths = [anno_dir / f"{stem}.mp4.json" for stem in args.videos]
        missing = [p for p in paths if not p.exists()]
        if missing:
            raise SystemExit(f"Missing annotation files: {missing}")
    else:
        paths = sorted(
            p for p in anno_dir.glob("*.mp4.json")
        )
        if not paths:
            raise SystemExit(f"No *.mp4.json files found in {anno_dir}")

    for p in paths:
        convert_one(p, out_dir)


if __name__ == "__main__":
    main()
