#!/usr/bin/env python3
"""Explicit frame-rate downsampling for a MOT sequence directory.

TrackEval does NOT auto-map frame rates between a tracker's output and gt: it
assumes both already share the same frame axis. If you want to evaluate a
tracker that only sees every Nth frame (e.g. to emulate a lower-fps pipeline)
against a full-rate gt sequence, you must make that mismatch explicit by
resampling the gt (and/or det) to the same reduced frame axis first. That is
what this tool does.

Keeps rows where (frame - 1) % N == 0, remaps frame -> (frame - 1)//N + 1,
copies every other field verbatim. Rewrites seqinfo.ini with
frameRate = old_frameRate / N and seqLength = ceil(old_seqLength / N).
"""
from __future__ import annotations

import argparse
import configparser
import math
import shutil
from pathlib import Path


def resample_mot_file(src: Path, dst: Path, keep_every: int) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    with src.open() as fin, dst.open("w") as fout:
        for line in fin:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(",")
            frame = int(float(fields[0]))
            if (frame - 1) % keep_every != 0:
                continue
            new_frame = (frame - 1) // keep_every + 1
            fields[0] = str(new_frame)
            fout.write(",".join(fields) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seq", type=Path, required=True, help="MOT seq dir with seqinfo.ini")
    parser.add_argument("--keep-every", type=int, required=True, help="Keep every Nth frame")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    seq_dir: Path = args.seq
    out_dir: Path = args.out
    n: int = args.keep_every

    if n < 1:
        raise SystemExit(f"--keep-every must be >= 1, got {n}")

    if out_dir.exists():
        raise SystemExit(f"Refusing to run: output dir already exists: {out_dir}")

    seqinfo_path = seq_dir / "seqinfo.ini"
    if not seqinfo_path.exists():
        raise SystemExit(f"No seqinfo.ini found in {seq_dir}")

    config = configparser.ConfigParser()
    config.optionxform = str  # preserve camelCase keys (frameRate, imWidth, ...)
    config.read(seqinfo_path)
    section = config["Sequence"]

    old_frame_rate = float(section["frameRate"])
    old_seq_length = int(section["seqLength"])

    out_dir.mkdir(parents=True)

    for name in ("det/det.txt", "gt/gt.txt"):
        src = seq_dir / name
        if src.exists():
            resample_mot_file(src, out_dir / name, n)

    new_frame_rate = old_frame_rate / n
    new_seq_length = math.ceil(old_seq_length / n)

    section["frameRate"] = f"{new_frame_rate:g}"
    section["seqLength"] = str(new_seq_length)

    with (out_dir / "seqinfo.ini").open("w") as f:
        config.write(f, space_around_delimiters=False)

    print(
        f"Resampled {seq_dir} -> {out_dir}: keep_every={n}, "
        f"frameRate {old_frame_rate:g} -> {new_frame_rate:g}, "
        f"seqLength {old_seq_length} -> {new_seq_length}"
    )


if __name__ == "__main__":
    main()
