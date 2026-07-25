#!/usr/bin/env python3
"""Drift-tolerant parity comparison between two ndjson detection captures.

Meant for comparing two different plugins/models fed the *same* fixture
clip (e.g. via feed.py), each piped through validate_ndjson.py's `tee`
pattern to capture raw ndjson. This is NOT an exact diff -- two different
models will legitimately disagree on borderline scores and frame sampling
phase. It reports rates and rough temporal overlap so a human can judge
"close enough" rather than asserting equality.

Usage:
    ./compare_runs.py --a pythonplugin.ndjson --b rustplugin.ndjson
    ./compare_runs.py --a a.ndjson --b b.ndjson --labels-only
"""
import argparse
import json
import statistics
import sys

BUCKET_TICKS = 90000  # 1 second at the 90kHz RTP clock


def load(path):
    """Parse an ndjson capture. Malformed lines are skipped (not this
    tool's job to flag -- use validate_ndjson.py for that), but counted."""
    frames = []
    skipped = 0
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
                pts = int(obj["pts"])
                dets = obj["dets"]
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                skipped += 1
                continue
            frames.append((pts, dets))
    return frames, skipped


def analyze(frames):
    """Per-label: count (det instances), frame_hits (# frames with >=1 det
    of that label), scores (list), buckets (set of 1s pts buckets hit)."""
    total_frames = len(frames)
    by_label = {}
    for pts, dets in frames:
        seen_labels_this_frame = set()
        bucket = pts // BUCKET_TICKS
        for det in dets:
            label = det.get("label", "?")
            score = det.get("score")
            entry = by_label.setdefault(
                label, {"count": 0, "frame_hits": 0, "scores": [], "buckets": set()}
            )
            entry["count"] += 1
            # bool is a subclass of int — exclude it like validate_ndjson.py
            if not isinstance(score, bool) and isinstance(score, (int, float)):
                entry["scores"].append(float(score))
            entry["buckets"].add(bucket)
            seen_labels_this_frame.add(label)
        for label in seen_labels_this_frame:
            by_label[label]["frame_hits"] += 1
    return total_frames, by_label


def fmt_score(scores):
    if not scores:
        return "n/a"
    return f"{min(scores):.3f}/{statistics.median(scores):.3f}/{max(scores):.3f}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--a", required=True, help="ndjson capture, run A")
    ap.add_argument("--b", required=True, help="ndjson capture, run B")
    ap.add_argument("--labels-only", action="store_true",
                     help="print only the per-label count/rate table; skip score "
                          "distributions and the temporal-overlap section")
    args = ap.parse_args()

    frames_a, skipped_a = load(args.a)
    frames_b, skipped_b = load(args.b)
    total_a, by_label_a = analyze(frames_a)
    total_b, by_label_b = analyze(frames_b)

    print(f"run A: {args.a}  ({total_a} frames, {skipped_a} unparsable lines skipped)")
    print(f"run B: {args.b}  ({total_b} frames, {skipped_b} unparsable lines skipped)")
    print()

    labels = sorted(set(by_label_a) | set(by_label_b))
    if not labels:
        print("no detections in either run.")
        return 0

    # --- per-label counts/rates table ---
    header = f"{'label':<16} {'cnt_A':>7} {'rate_A':>8} {'cnt_B':>7} {'rate_B':>8}"
    print(header)
    print("-" * len(header))
    rates = {}
    for label in labels:
        a = by_label_a.get(label, {"count": 0, "frame_hits": 0, "scores": [], "buckets": set()})
        b = by_label_b.get(label, {"count": 0, "frame_hits": 0, "scores": [], "buckets": set()})
        rate_a = a["frame_hits"] / total_a if total_a else 0.0
        rate_b = b["frame_hits"] / total_b if total_b else 0.0
        rates[label] = (rate_a, rate_b)
        print(f"{label:<16} {a['count']:>7} {rate_a:>8.3f} {b['count']:>7} {rate_b:>8.3f}")
    print("(rate = frames-with-label / total-frames-in-run)")
    print()

    if not args.labels_only:
        # --- score distributions ---
        print(f"{'label':<16} {'score A (min/med/max)':<24} {'score B (min/med/max)':<24}")
        print("-" * 66)
        for label in labels:
            a = by_label_a.get(label, {"scores": []})
            b = by_label_b.get(label, {"scores": []})
            print(f"{label:<16} {fmt_score(a['scores']):<24} {fmt_score(b['scores']):<24}")
        print()

        # --- temporal overlap (1s buckets) ---
        print(f"{'label':<16} {'both':>6} {'only_A':>7} {'only_B':>7}")
        print("-" * 40)
        for label in labels:
            buckets_a = by_label_a.get(label, {"buckets": set()})["buckets"]
            buckets_b = by_label_b.get(label, {"buckets": set()})["buckets"]
            both = len(buckets_a & buckets_b)
            only_a = len(buckets_a - buckets_b)
            only_b = len(buckets_b - buckets_a)
            print(f"{label:<16} {both:>6} {only_a:>7} {only_b:>7}")
        print("(buckets = distinct 1s pts windows in which the label appeared at all)")
        print()

    # --- verdict heuristic ---
    flagged = []
    for label in labels:
        rate_a, rate_b = rates[label]
        lo, hi = min(rate_a, rate_b), max(rate_a, rate_b)
        if hi == 0:
            continue
        if lo == 0 or hi / lo > 3:
            flagged.append(label)
    if flagged:
        print(f"verdict: divergent rates (>3x) for: {', '.join(flagged)} -- inspect before trusting parity")
    else:
        print("verdict: no label shows >3x rate divergence between runs")

    return 0


if __name__ == "__main__":
    sys.exit(main())
