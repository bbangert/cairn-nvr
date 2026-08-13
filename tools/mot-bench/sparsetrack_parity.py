#!/usr/bin/env python3
"""Reference dump for the SparseTrack exact-match parity gate.

Drives the vendored SparseTrack reference (`vendor/sparsetrack`, hustvl @
499844f, MIT, patched by `vendor-patches/sparsetrack.patch`) over a MOT
sequence and writes the MOT prediction lines the Elixir core must reproduce
**byte for byte** — `test/membrane_mot_tracker/sparse_track_parity_test.exs`
compares its own run against these files with no tolerance at all.

Two things make that comparison meaningful rather than lucky:

  * Track ids are canonicalized to first-seen ordinals, exactly as
    `Cairn.MotBench` canonicalizes ULIDs. The reference's own counter is a
    process global that carries across sequences; ordinals are a property of
    the output alone, so both sides can be compared without either being
    reset correctly.
  * Coordinates are formatted with `Decimal(...).quantize(ROUND_HALF_UP)`,
    which is what Erlang's `float_to_binary(v, decimals: 2)` does. C's
    `printf("%.2f")` rounds exact halves to even instead and disagrees on
    roughly 9% of values — verified, not assumed.

The default sequence is SYNTHETIC and lives in the repo: MOT17 and MOT20 may
not be redistributed (OBLIGATIONS.md), so the committed fixture is generated
here instead. It is built to reach every branch that matters — crossings,
dropouts long enough to lose and re-find a track, low-score detections that
only the second stage can use, sub-`det_thresh` boxes that must never mint,
and a spread of bottom edges that splits into several depth sublevels.

Run it from `tools/mot-bench` with the venv python:

    .venv/bin/python sparsetrack_parity.py                  # regenerate fixtures
    .venv/bin/python sparsetrack_parity.py --seq data/mot17/train/MOT17-09-SDP \\
        --out /tmp/mot17-09.expected.txt --config mot17     # a real sequence

Every step is echoed and every output checksummed, so a run pasted into a
report is self-describing.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import sys
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "vendor"))

from sparsetrack.basetrack import BaseTrack  # noqa: E402
from sparsetrack.sparse_tracker import SparseTracker  # noqa: E402

REPO = ROOT.parent.parent
FIXTURES = REPO / "test/fixtures/sparsetrack"


class Args:
    """The reference's `args` object, at its published per-dataset values."""

    def __init__(self, **overrides):
        self.track_thresh = 0.6
        self.track_buffer = 30
        self.match_thresh = 0.75
        self.down_scale = 4
        self.depth_levels = 1
        self.depth_levels_low = 3
        self.confirm_thresh = 0.8
        self.mot20 = False
        # Not '_half.json', so det_thresh = track_thresh + 0.05.
        self.val_ann = ""
        self.__dict__.update(overrides)


# The published MOT17 config, plus one that cascades BOTH stages: with
# depth_levels 1 the first stage never splits, so the fixture would leave the
# cascade's own arithmetic (arange bounds, surplus levels, leftovers carried
# between levels) untested on the side that matters most.
CONFIGS = {
    "mot17": {},
    "deep": {"depth_levels": 4, "depth_levels_low": 4, "match_thresh": 0.8},
    # The published MOT20 config. `mot20=True` also switches the fused,
    # score-weighted cost off, which no other config exercises.
    "mot20": {
        "track_buffer": 60,
        "match_thresh": 0.6,
        "depth_levels_low": 8,
        "confirm_thresh": 0.7,
        "mot20": True,
    },
}


def synthetic_sequence():
    """A deterministic detection stream, in whole pixels.

    Whole pixels are load-bearing: the reference is fed `[x, y, x+w, y+h]` and
    recovers the width as `(x+w) - x`, which is exact only when the sum is.
    Integers keep the Elixir side from having to reproduce a rounding step
    that says nothing about tracking.
    """
    frames, width, height = 180, 1920, 1080
    # Each object: entry frame, exit frame, start x/y, per-frame drift, box
    # size, score, and the frames it is missing from (occlusion).
    objects = [
        dict(enter=1, leave=180, x=100, y=300, dx=7, dy=1, w=60, h=150, score=0.92, gap=()),
        dict(enter=1, leave=180, x=1500, y=320, dx=-6, dy=1, w=58, h=145, score=0.88, gap=()),
        dict(enter=1, leave=120, x=300, y=700, dx=5, dy=-2, w=110, h=260, score=0.75, gap=range(40, 55)),
        dict(enter=10, leave=180, x=900, y=180, dx=2, dy=0, w=32, h=80, score=0.65, gap=()),
        dict(enter=20, leave=160, x=1200, y=760, dx=-9, dy=0, w=120, h=280, score=0.45, gap=()),
        dict(enter=30, leave=180, x=200, y=520, dx=8, dy=0, w=70, h=180, score=0.55, gap=range(90, 96)),
        dict(enter=45, leave=140, x=1700, y=560, dx=-11, dy=0, w=72, h=185, score=0.35, gap=()),
        dict(enter=60, leave=180, x=600, y=880, dx=4, dy=-3, w=140, h=190, score=0.97, gap=()),
        dict(enter=70, leave=175, x=1000, y=420, dx=-3, dy=2, w=52, h=130, score=0.62, gap=range(100, 110)),
        # Below det_thresh (0.65) but above track_thresh: never mints, only
        # ever extends something that already exists.
        dict(enter=5, leave=180, x=500, y=240, dx=6, dy=0, w=40, h=100, score=0.63, gap=()),
        # Below low_thresh: the tracker must drop it outright.
        dict(enter=1, leave=180, x=1400, y=900, dx=0, dy=0, w=90, h=120, score=0.05, gap=()),
    ]

    # A crowd walking through itself in one narrow band. Sparse scenes make
    # every association obvious and every config agree; the depth cascade and
    # the score-weighted cost only decide anything where boxes overlap and
    # candidates compete, so the fixture has to contain a scrum.
    for k in range(8):
        objects.append(
            dict(
                enter=1 + k,
                leave=180,
                x=250 + k * 58,
                y=640 + (k % 3) * 14,
                dx=13 if k % 2 == 0 else -12,
                dy=(k % 2) * 2 - 1,
                w=76 + (k % 4) * 6,
                h=195 + (k % 3) * 10,
                score=0.42 + 0.06 * k,
                gap=range(120 + k, 124 + k),
            )
        )

    rows = []
    for frame in range(1, frames + 1):
        for index, obj in enumerate(objects):
            if not (obj["enter"] <= frame <= obj["leave"]) or frame in obj["gap"]:
                continue
            step = frame - obj["enter"]
            # A deterministic wobble, integral by construction: no PRNG to
            # agree on, and no fractions to round.
            wobble = (index * 7 + step * 13) % 25 - 12
            x = obj["x"] + obj["dx"] * step + wobble
            y = obj["y"] + obj["dy"] * step + (step % 3) - 1
            # Score varies per frame so the two stages both see traffic, and so
            # the fused cost is not constant down a column.
            score = round(min(0.99, max(0.02, obj["score"] + ((step * 17) % 11 - 5) / 100.0)), 3)
            rows.append((frame, x, y, obj["w"], obj["h"], score))
    return rows, dict(name="synthetic", frames=frames, width=width, height=height)


def write_sequence(out_dir: Path, rows, meta) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "seqinfo.ini").write_text(
        "[Sequence]\n"
        f"name={meta['name']}\n"
        "imDir=img1\n"
        "frameRate=30\n"
        f"seqLength={meta['frames']}\n"
        f"imWidth={meta['width']}\n"
        f"imHeight={meta['height']}\n"
        "imExt=.jpg\n"
    )
    det_dir = out_dir / "det"
    det_dir.mkdir(exist_ok=True)
    det_dir.joinpath("det.txt").write_text(
        "".join(f"{f},-1,{x},{y},{w},{h},{s},-1,-1,-1\n" for f, x, y, w, h, s in rows)
    )


def read_seqinfo(seq_dir: Path):
    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(seq_dir / "seqinfo.ini")
    s = config["Sequence"]
    return float(s["frameRate"]), int(s["seqLength"])


def dets_by_frame(seq_dir: Path):
    by_frame: dict[int, list[list[float]]] = {}
    with (seq_dir / "det" / "det.txt").open() as f:
        for line in f:
            if not line.strip():
                continue
            p = line.split(",")
            frame = int(float(p[0]))
            x, y, w, h, conf = (float(v) for v in p[2:7])
            by_frame.setdefault(frame, []).append(
                [x, y, x + w, y + h, min(max(conf, 0.0), 1.0)]
            )
    return by_frame


def fmt(value: float) -> str:
    """Erlang's `float_to_binary(v, decimals: 2)`: exact value, halves away."""
    return str(Decimal(value).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def run(seq_dir: Path, config: str, out: Path) -> None:
    fps, seq_length = read_seqinfo(seq_dir)
    frames = dets_by_frame(seq_dir)
    BaseTrack._count = 0
    tracker = SparseTracker(Args(**CONFIGS[config]), frame_rate=int(fps))

    ordinals: dict[int, int] = {}
    lines = []
    empty = np.zeros((0, 5), dtype=np.float64)
    for frame in range(1, seq_length + 1):
        dets = frames.get(frame)
        arr = np.asarray(dets, dtype=np.float64) if dets else empty
        for strack in tracker.update(arr):
            ordinal = ordinals.setdefault(strack.track_id, len(ordinals) + 1)
            x, y, w, h = strack.tlwh
            lines.append(
                f"{frame},{ordinal},{fmt(x)},{fmt(y)},{fmt(w)},{fmt(h)},1,-1,-1,-1\n"
            )

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(lines))
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(
        f"  {seq_dir.name} [{config}] -> {out.relative_to(REPO) if out.is_relative_to(REPO) else out}"
        f"  ({len(lines)} lines, {len(ordinals)} tracks, sha256 {digest[:16]})",
        flush=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seq", type=Path, help="MOT sequence dir (default: the synthetic fixture)")
    parser.add_argument("--out", type=Path, help="output file (required with --seq)")
    parser.add_argument("--config", choices=sorted(CONFIGS), default=None)
    args = parser.parse_args()

    print(f"numpy {np.__version__}; reference vendor/sparsetrack @ 499844f", flush=True)

    if args.seq:
        if not args.out:
            raise SystemExit("--out is required with --seq")
        print(f"Tracking {args.seq}", flush=True)
        run(args.seq, args.config or "mot17", args.out)
        return

    print("Generating the synthetic sequence", flush=True)
    rows, meta = synthetic_sequence()
    seq_dir = FIXTURES / "synthetic"
    write_sequence(seq_dir, rows, meta)
    print(f"  {len(rows)} detections over {meta['frames']} frames -> {seq_dir.relative_to(REPO)}", flush=True)

    for config in sorted(CONFIGS):
        run(seq_dir, config, FIXTURES / f"expected-{config}.txt")

    print("Checksums", flush=True)
    for path in sorted(FIXTURES.rglob("*")):
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            print(f"  {digest}  {path.relative_to(REPO)}", flush=True)
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
