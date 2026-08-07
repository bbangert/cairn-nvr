#!/usr/bin/env python3
"""Download, checksum-verify, and extract the MOT accuracy harness datasets.

Stdlib-only. Downloads land in data/downloads/, get verified against
CHECKSUMS.sha256, then get extracted into data/<name>/.

Most datasets here are label/annotation/detection zips for tracker-only MOT
scoring (no pixels). `mot17-img` is the exception: the phase-6 E2E harness
(tools/mot-bench/e2e.py) needs real frames to re-encode into video, so that
one dataset is the full images+labels MOT17.zip (~5.5GB) rather than just
labels. PersonPath22 raw video remains out of scope — no upstream tooling
for it here yet.
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOWNLOADS = ROOT / "data" / "downloads"
CHECKSUMS_FILE = ROOT / "CHECKSUMS.sha256"

CONNECT_TIMEOUT = 60

# dataset -> (list of candidate URLs in try-order, zip filename)
DATASETS = {
    "mot17": (
        [
            "https://motchallenge.net/data/MOT17Labels.zip",
            "https://web.archive.org/web/2023id_/https://motchallenge.net/data/MOT17Labels.zip",
        ],
        "MOT17Labels.zip",
    ),
    "mot20": (
        [
            "https://motchallenge.net/data/MOT20Labels.zip",
            "https://web.archive.org/web/2023id_/https://motchallenge.net/data/MOT20Labels.zip",
        ],
        "MOT20Labels.zip",
    ),
    "trackeval-gt": (
        ["https://omnomnom.vision.rwth-aachen.de/data/TrackEval/data.zip"],
        "trackeval_data.zip",
    ),
    "personpath22-anno": (
        ["https://tracking-dataset-eccv-2022.s3.amazonaws.com/dataset/annotation/anno_visible.zip"],
        "pp22_anno_visible.zip",
    ),
    "personpath22-det": (
        [
            "https://aws-cv-sci-motion-public.s3.us-west-2.amazonaws.com/PersonPath22/public_detection_fcos/mot_format.zip"
        ],
        "pp22_public_det_mot.zip",
    ),
    # Full images+labels zip (~5.5GB), for the phase-6 E2E harness. Distinct
    # from "mot17" above (MOT17Labels.zip, labels only, no img1/ frames).
    "mot17-img": (
        [
            "https://motchallenge.net/data/MOT17.zip",
            "https://web.archive.org/web/2023id_/https://motchallenge.net/data/MOT17.zip",
        ],
        "MOT17.zip",
    ),
}

LABELS_GROUP = ["mot17", "mot20", "trackeval-gt", "personpath22-anno"]

CHOICES = list(DATASETS.keys()) + ["labels"]


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_checksums() -> dict[str, str]:
    """Parse CHECKSUMS.sha256 (sha256sum -c format) into {relpath: hash}."""
    result: dict[str, str] = {}
    if not CHECKSUMS_FILE.exists():
        return result
    for line in CHECKSUMS_FILE.read_text().splitlines():
        line = line.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        # "<hash>  <path>" (sha256sum uses two spaces for binary mode, one is
        # also tolerated).
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        digest, relpath = parts
        result[relpath.strip()] = digest.strip()
    return result


def record_checksum(relpath: str, digest: str) -> None:
    with CHECKSUMS_FILE.open("a") as f:
        f.write(f"{digest}  {relpath}\n")
    print(f"Recorded checksum for {relpath} in {CHECKSUMS_FILE}")


def download(urls: list[str], dest: Path) -> None:
    if dest.exists():
        print(f"SKIP download (already present): {dest}")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    last_err: Exception | None = None
    for url in urls:
        try:
            print(f"Trying {url} ...")
            req = urllib.request.Request(url, headers={"User-Agent": "mot-bench-fetch/1.0"})
            with urllib.request.urlopen(req, timeout=CONNECT_TIMEOUT) as resp, tmp.open("wb") as out:
                shutil.copyfileobj(resp, out)
            tmp.rename(dest)
            print(f"Downloaded from {url} -> {dest}")
            return
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            print(f"  failed: {e}")
            last_err = e
            if tmp.exists():
                tmp.unlink()
            continue
    raise SystemExit(f"All download URLs failed for {dest.name}: {last_err}")


def verify(dest: Path, record: bool) -> None:
    relpath = str(dest.relative_to(ROOT))
    checksums = load_checksums()
    got = sha256_of(dest)
    expected = checksums.get(relpath)
    if expected is None:
        if record:
            record_checksum(relpath, got)
            return
        raise SystemExit(
            f"No checksum entry for {relpath} in {CHECKSUMS_FILE}.\n"
            f"Computed sha256: {got}\n"
            f"Re-run with --record to append this checksum, if you trust the download."
        )
    if got != expected:
        raise SystemExit(
            f"Checksum MISMATCH for {relpath}\n"
            f"  expected: {expected}\n"
            f"  got:      {got}"
        )
    print(f"Checksum OK: {relpath}")


def safe_target(out_dir: Path, name: str) -> Path:
    """Resolve a zip member path, refusing traversal outside out_dir (zip slip)."""
    target = (out_dir / name).resolve()
    if not target.is_relative_to(out_dir.resolve()):
        raise SystemExit(f"Refusing zip member escaping the extract dir: {name!r}")
    return target


def extract_plain(zip_path: Path, out_dir: Path) -> None:
    """Extract a zip as-is (no prefix stripping)."""
    if out_dir.exists():
        print(f"SKIP extract (already exists): {out_dir}")
        return
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.infolist():
            target = safe_target(out_dir, member.filename)
            if member.is_dir() or member.filename.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
    print(f"Extracted {zip_path.name} -> {out_dir}")


def extract_stripping_prefix(zip_path: Path, out_dir: Path, prefix: str) -> None:
    """Extract a zip, stripping a leading path component (e.g. MOT20Labels/)."""
    if out_dir.exists():
        print(f"SKIP extract (already exists): {out_dir}")
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.infolist():
            name = member.filename
            if name.startswith(prefix):
                name = name[len(prefix):]
            if not name:
                continue
            target = safe_target(out_dir, name)
            if member.is_dir() or name.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
    print(f"Extracted {zip_path.name} -> {out_dir} (stripped '{prefix}')")


def process(dataset: str, record: bool) -> None:
    urls, zip_name = DATASETS[dataset]
    zip_path = DOWNLOADS / zip_name
    download(urls, zip_path)
    verify(zip_path, record)

    if dataset == "mot17":
        extract_plain(zip_path, ROOT / "data" / "mot17")
    elif dataset == "mot20":
        extract_stripping_prefix(zip_path, ROOT / "data" / "mot20", "MOT20Labels/")
    elif dataset == "trackeval-gt":
        extract_plain(zip_path, ROOT / "data" / "trackeval_gt")
    elif dataset == "personpath22-anno":
        extract_plain(zip_path, ROOT / "data" / "personpath22" / "annotation")
    elif dataset == "personpath22-det":
        extract_plain(zip_path, ROOT / "data" / "personpath22" / "det_mot")
    elif dataset == "mot17-img":
        # Layout unverified: as of writing, no MOT17.zip has finished
        # downloading here to inspect (a partial download was in progress —
        # see CHECKSUMS.sha256's placeholder comment for that file). Going
        # with extract_plain on the assumption its entries are already
        # rooted at "train/"/"test/" like MOT17Labels.zip's (no wrapping
        # "MOT17/" directory) rather than MOT20Labels.zip's, which does wrap
        # and needs extract_stripping_prefix. Re-check against the real zip
        # before relying on this path.
        extract_plain(zip_path, ROOT / "data" / "mot17_img")
    else:
        raise AssertionError(dataset)

    print(f"== {dataset}: done ==")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, choices=CHOICES)
    parser.add_argument(
        "--record",
        action="store_true",
        help="If a downloaded file has no CHECKSUMS.sha256 entry, append its computed sha256 instead of failing.",
    )
    args = parser.parse_args()

    datasets = LABELS_GROUP if args.dataset == "labels" else [args.dataset]
    for ds in datasets:
        process(ds, args.record)


if __name__ == "__main__":
    main()
