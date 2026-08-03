#!/usr/bin/env python3
"""Drift-tolerant parity comparison between two ndjson detection captures.

Meant for comparing two runs fed the *same* fixture clip (e.g. via feed.py),
each piped through validate_ndjson.py's `tee` pattern to capture raw ndjson
— two models, FP32 against INT8, a decoder backend against software. This is
NOT an exact diff: two models will legitimately disagree on borderline
scores and frame sampling phase. It reports rates and rough temporal overlap
so a human can judge "close enough" rather than asserting equality.

Reads protocol v1 `frame.objects` lines; every other message type is skipped
without counting against either run.

It also reports, per run, how many **duplicate pairs** each run emitted: two
objects in one frame with the same label overlapping at more than --dup-iou.
That number is not a parity measure -- it says something about one run on its
own -- and it is here because this is where a run's frames are already
parsed. Two things read it:

  - a seeding regression. A motion gate re-reports an earlier frame's boxes
    ("observation_kind": "tracked"), and cairn-detect emits a line that is
    either entirely seeded or entirely detected -- never a mix -- so a seed
    landing beside a live detection of the same object is a thing that
    cannot happen today. That is exactly what makes a count here a signal:
    a seed drifting onto its own object would leave the host deciding which
    of two boxes is the object, and this is the only place it would show.
  - suppression retirement. The host drops a same-label box overlapping a
    live track at @duplicate_suppression_iou (lib/cairn/tracker.ex), which
    exists because detectors emit near-duplicate boxes. Retiring that per
    profile means first knowing what each profile actually emits.

Usage:
    ./compare_runs.py --a fp32.ndjson --b int8.ndjson
    ./compare_runs.py --a a.ndjson --b b.ndjson --labels-only
    ./compare_runs.py --a a.ndjson --b b.ndjson --dup-iou 0.8
"""
import argparse
import json
import statistics
import sys

BUCKET_TICKS = 90000  # 1 second at the 90kHz RTP clock


def number(value):
    """A JSON number. `bool` is a subclass of `int` -- exclude it, as
    validate_ndjson.py does."""
    return not isinstance(value, bool) and isinstance(value, (int, float))


def load(path):
    """Parse the frame.objects lines of an ndjson capture. hello/status lines
    are not frames and are passed over silently; a malformed line is skipped
    and counted (not this tool's job to flag -- use validate_ndjson.py).

    Tolerance runs one level deeper than the line, because everything below
    reads fields off each object: an `objects` element that is not a JSON
    object is dropped from its frame and counted separately, leaving the rest
    of the line usable. Both counts are printed. Without this the readers
    below raise AttributeError halfway through a report, which is the wrong
    answer for a tool `iou` documents as pointed at captures nothing
    validated.
    """
    frames = []
    skipped = 0
    dropped_objects = 0
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
                if obj.get("type") != "frame.objects":
                    continue
                pts = int(obj["frame"]["pts"])
                objects = obj["objects"]
                if not isinstance(objects, list):
                    raise TypeError("objects is not a list")
            except (json.JSONDecodeError, AttributeError, KeyError, TypeError, ValueError):
                skipped += 1
                continue
            usable = [det for det in objects if isinstance(det, dict)]
            dropped_objects += len(objects) - len(usable)
            frames.append((pts, usable))
    return frames, skipped, dropped_objects


def label_of(det):
    """The detection's label as a table key: its string, else "?".

    "?" covers a missing label and a non-string one (null, a number) alike.
    `load()` only guarantees each object is a dict, and a `.get` default only
    covers the missing case — an explicit `"label": null` would otherwise
    become a None key that crashes the sorted union of two runs' tables,
    where the sentinel just prints as itself.
    """
    label = det.get("label")
    return label if isinstance(label, str) else "?"


def analyze(frames):
    """Per-label: count (det instances), frame_hits (# frames with >=1 det
    of that label), scores (list), buckets (set of 1s pts buckets hit)."""
    total_frames = len(frames)
    by_label = {}
    for pts, objects in frames:
        seen_labels_this_frame = set()
        bucket = pts // BUCKET_TICKS
        for det in objects:
            label = label_of(det)
            score = det.get("score")
            entry = by_label.setdefault(
                label, {"count": 0, "frame_hits": 0, "scores": [], "buckets": set()}
            )
            entry["count"] += 1
            if number(score):
                entry["scores"].append(float(score))
            entry["buckets"].add(bucket)
            seen_labels_this_frame.add(label)
        for label in seen_labels_this_frame:
            by_label[label]["frame_hits"] += 1
    return total_frames, by_label


def iou(a, b):
    """Intersection over union of two [x, y, w, h] boxes.

    0.0 for a box without positive area rather than a ZeroDivisionError:
    failing a run over one is validate_ndjson.py's job, and this tool is
    routinely pointed at captures nothing validated.
    """
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    if aw <= 0 or ah <= 0 or bw <= 0 or bh <= 0:
        return 0.0
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    overlap = ix * iy
    union = aw * ah + bw * bh - overlap
    return overlap / union if union > 0 else 0.0


def duplicate_pairs(frames, threshold):
    """Same-label pairs within one frame overlapping above `threshold`.

    Returns (total pairs, {label: pairs}). Every unordered pair is counted,
    so three mutually overlapping boxes of one label are three pairs -- the
    quantity being measured is how much redundant geometry one frame carries,
    not how many objects it is really about.

    An object whose `bbox` is not four numbers is not pairable and is passed
    over, the same as one carrying no `bbox` at all: `iou` below would raise
    on it, and this tool reports what a capture holds rather than judging it.
    """
    total = 0
    by_label = {}
    for _pts, objects in frames:
        by_label_boxes = {}
        for det in objects:
            box = det.get("bbox")
            if isinstance(box, list) and len(box) == 4 and all(map(number, box)):
                by_label_boxes.setdefault(label_of(det), []).append(box)
        for label, boxes in by_label_boxes.items():
            for i in range(len(boxes)):
                for j in range(i + 1, len(boxes)):
                    if iou(boxes[i], boxes[j]) > threshold:
                        total += 1
                        by_label[label] = by_label.get(label, 0) + 1
    return total, by_label


def fmt_dups(by_label, top=3):
    if not by_label:
        return "-"
    ranked = sorted(by_label.items(), key=lambda kv: (-kv[1], kv[0]))[:top]
    return ", ".join(f"{label}:{count}" for label, count in ranked)


def fmt_score(scores):
    if not scores:
        return "n/a"
    return f"{min(scores):.3f}/{statistics.median(scores):.3f}/{max(scores):.3f}"


def iou_threshold(value):
    """`--dup-iou` as an IoU, which is a fraction in (0, 1].

    Outside that the duplicate-pair table is nonsense that still looks like a
    measurement: at or below 0 every same-label pair in a frame counts,
    disjoint ones included (`0.0 > -0.1`), and above 1 nothing can ever count.
    Both print a number a reader would take for a finding.
    """
    try:
        threshold = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {value!r}") from None
    if not 0.0 < threshold <= 1.0:
        raise argparse.ArgumentTypeError(f"must be in (0, 1], got {value!r}")
    return threshold


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--a", required=True, help="ndjson capture, run A")
    ap.add_argument("--b", required=True, help="ndjson capture, run B")
    ap.add_argument("--dup-iou", type=iou_threshold, default=0.9,
                     help="IoU above which two same-label boxes in one frame count "
                          "as a duplicate pair, in (0, 1] (default: 0.9)")
    ap.add_argument("--labels-only", action="store_true",
                     help="skip the score distributions and the temporal-overlap "
                          "section; the label table and the duplicate-pair table "
                          "are always printed")
    args = ap.parse_args()

    frames_a, skipped_a, dropped_a = load(args.a)
    frames_b, skipped_b, dropped_b = load(args.b)
    total_a, by_label_a = analyze(frames_a)
    total_b, by_label_b = analyze(frames_b)

    for name, path, total, skipped, dropped in (
        ("A", args.a, total_a, skipped_a, dropped_a),
        ("B", args.b, total_b, skipped_b, dropped_b),
    ):
        note = f", {dropped} malformed object(s) dropped" if dropped else ""
        print(f"run {name}: {path}  ({total} frames, {skipped} unparsable lines skipped{note})")
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

    # --- duplicate pairs, per run ---
    dups_a, dup_labels_a = duplicate_pairs(frames_a, args.dup_iou)
    dups_b, dup_labels_b = duplicate_pairs(frames_b, args.dup_iou)
    print(f"duplicate pairs (same label, one frame, IoU > {args.dup_iou:.2f})")
    header = f"{'run':<5} {'pairs':>7} {'per frame':>10}  top labels"
    print(header)
    print("-" * len(header))
    for name, dups, dup_labels, total in (
        ("A", dups_a, dup_labels_a, total_a),
        ("B", dups_b, dup_labels_b, total_b),
    ):
        rate = dups / total if total else 0.0
        print(f"{name:<5} {dups:>7} {rate:>10.3f}  {fmt_dups(dup_labels)}")
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
