#!/usr/bin/env python3
"""Validate a plugin's ndjson stdout against docs/plugin-contract.md.

Reads lines from --file, or stdin if omitted:

    some_plugin | tee raw.ndjson | ./validate_ndjson.py

Each line must be:
  - valid JSON, a top-level object
  - "camera_id": str
  - "pts": int, >= 0                              (RTP timestamp, 90kHz)
  - "dets": list, each element an object with:
      - "label": str
      - "score": number, 0 <= score <= 1
      - "bbox": [x, y, w, h], each 0 <= v <= 1 (small epsilon tolerated),
                and x + w <= 1.0001, y + h <= 1.0001
  - the raw line must be <= 8192 bytes (UTF-8 encoded, excluding the
    trailing newline)

A summary goes to stderr on EOF or SIGINT/SIGTERM: total/valid/invalid line
counts (with up to 5 sample errors), a detection histogram by label, overall
score min/mean/max, a pts monotonicity check (contract doesn't guarantee
non-decreasing pts across a plugin restart -- a *decrease* is reported as a
"wrap/reset" note, not an error), and an effective sample rate estimated
from consecutive-pts deltas assuming the 90kHz RTP clock.

Exit code: 0 iff every line seen was valid AND at least one line was seen.
Any invalid line, or zero lines, is a nonzero exit -- this is meant to gate
CI/manual runs, not just report.
"""
import argparse
import json
import signal
import sys

MAX_LINE_BYTES = 8192
EPS = 1e-4


def fail(reason: str):
    raise ValueError(reason)


def validate_bbox(bbox):
    if not isinstance(bbox, list) or len(bbox) != 4:
        fail(f"bbox must be a 4-element list, got {bbox!r}")
    for v in bbox:
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            fail(f"bbox element not numeric: {v!r}")
        if v < -EPS or v > 1 + EPS:
            fail(f"bbox element out of 0..1 range: {v!r}")
    x, y, w, h = bbox
    if x + w > 1.0001:
        fail(f"bbox x+w > 1.0001: {bbox!r}")
    if y + h > 1.0001:
        fail(f"bbox y+h > 1.0001: {bbox!r}")


def validate_det(det, idx):
    if not isinstance(det, dict):
        fail(f"dets[{idx}] not an object: {det!r}")
    if "label" not in det or not isinstance(det["label"], str):
        fail(f"dets[{idx}].label missing/not str")
    if "score" not in det or isinstance(det["score"], bool) or not isinstance(det["score"], (int, float)):
        fail(f"dets[{idx}].score missing/not numeric")
    score = det["score"]
    if score < -EPS or score > 1 + EPS:
        fail(f"dets[{idx}].score out of 0..1 range: {score!r}")
    if "bbox" not in det:
        fail(f"dets[{idx}].bbox missing")
    validate_bbox(det["bbox"])


def validate_line(raw: bytes):
    """Returns the decoded JSON object on success; raises ValueError on failure."""
    if len(raw) > MAX_LINE_BYTES:
        fail(f"line is {len(raw)} bytes, exceeds {MAX_LINE_BYTES}")
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        fail(f"invalid JSON: {e}")
    if not isinstance(obj, dict):
        fail(f"top-level JSON is not an object: {type(obj).__name__}")
    if "camera_id" not in obj or not isinstance(obj["camera_id"], str):
        fail("camera_id missing/not str")
    if "pts" not in obj or isinstance(obj["pts"], bool) or not isinstance(obj["pts"], int):
        fail("pts missing/not int")
    if obj["pts"] < 0:
        fail(f"pts negative: {obj['pts']}")
    if "dets" not in obj or not isinstance(obj["dets"], list):
        fail("dets missing/not list")
    for i, det in enumerate(obj["dets"]):
        validate_det(det, i)
    return obj


class Stats:
    def __init__(self):
        self.total = 0
        self.valid = 0
        self.invalid = 0
        self.errors = []  # (line_no, reason, sample)
        self.label_counts = {}
        self.scores = []
        self.pts_seen = []
        self.wraps = 0

    def record_error(self, line_no, reason, raw):
        self.invalid += 1
        if len(self.errors) < 5:
            sample = raw[:120].decode("utf-8", "replace")
            self.errors.append((line_no, reason, sample))

    def record_valid(self, obj):
        self.valid += 1
        pts = obj["pts"]
        if self.pts_seen and pts < self.pts_seen[-1]:
            self.wraps += 1
        self.pts_seen.append(pts)
        for det in obj["dets"]:
            self.label_counts[det["label"]] = self.label_counts.get(det["label"], 0) + 1
            self.scores.append(det["score"])

    def summary(self) -> str:
        lines = []
        lines.append(f"lines: total={self.total} valid={self.valid} invalid={self.invalid}")
        if self.errors:
            lines.append("first errors:")
            for line_no, reason, sample in self.errors:
                lines.append(f"  line {line_no}: {reason} | {sample!r}")
        if self.label_counts:
            lines.append("det histogram by label:")
            for label, count in sorted(self.label_counts.items(), key=lambda kv: -kv[1]):
                lines.append(f"  {label}: {count}")
        else:
            lines.append("det histogram by label: (no detections seen)")
        if self.scores:
            lines.append(
                f"score min/mean/max: {min(self.scores):.4f} / "
                f"{sum(self.scores) / len(self.scores):.4f} / {max(self.scores):.4f}"
            )
        else:
            lines.append("score min/mean/max: n/a (no detections seen)")
        if len(self.pts_seen) >= 2:
            deltas = [b - a for a, b in zip(self.pts_seen, self.pts_seen[1:]) if b >= a]
            note = f", {self.wraps} decrease(s)/wrap(s) noted" if self.wraps else ""
            if deltas:
                mean_delta = sum(deltas) / len(deltas)
                fps = 90000.0 / mean_delta if mean_delta > 0 else float("inf")
                lines.append(
                    f"pts monotonicity: {'non-decreasing' if self.wraps == 0 else 'has decreases'}{note}"
                )
                lines.append(
                    f"effective sample rate: mean pts delta={mean_delta:.1f} ticks "
                    f"(90kHz) ~= {fps:.2f} fps over {len(deltas)} interval(s)"
                )
            else:
                lines.append(f"pts monotonicity: has decreases{note}; no forward deltas to estimate rate from")
        else:
            lines.append("pts monotonicity/sample rate: n/a (need >= 2 valid lines)")
        return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--file", default=None, help="ndjson file to read (default: stdin)")
    args = ap.parse_args()

    stats = Stats()

    src = open(args.file, "rb") if args.file else sys.stdin.buffer

    def _finish(*_a):
        print(stats.summary(), file=sys.stderr)
        sys.exit(0 if (stats.invalid == 0 and stats.total > 0) else 1)

    signal.signal(signal.SIGINT, _finish)
    signal.signal(signal.SIGTERM, _finish)

    try:
        for line_no, raw in enumerate(src, start=1):
            raw = raw.rstrip(b"\n")
            if not raw:
                continue
            stats.total += 1
            try:
                obj = validate_line(raw)
            except ValueError as e:
                stats.record_error(line_no, str(e), raw)
                continue
            stats.record_valid(obj)
    finally:
        if args.file:
            src.close()

    print(stats.summary(), file=sys.stderr)
    return 0 if (stats.invalid == 0 and stats.total > 0) else 1


if __name__ == "__main__":
    sys.exit(main())
