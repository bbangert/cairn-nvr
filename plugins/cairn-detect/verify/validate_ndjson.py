#!/usr/bin/env python3
"""Validate a plugin's ndjson stdout against docs/plugin-contract.md (v1).

Reads lines from --file, or stdin if omitted:

    some_plugin | tee raw.ndjson | ./validate_ndjson.py

Every line must be a JSON object carrying the protocol envelope
`"spec": "cairn.plugin"`, `"version": 1` and a `"type"`. Three types are
checked; any other type is counted as "ignored" rather than failed, because
forward compatibility is one-directional on the host too.

  "frame.objects"
      - "camera_id":    str, 1..256 bytes
      - "stream_epoch": str, non-empty
      - "sequence":     int, 0 <= n <= 2**62
      - "frame": object with
          - "pts": int, |pts| <= 2**62
          - "time_base": optional [num, den], both 1..1e9
          - "observed_at": RFC3339 with a UTC offset
      - "objects": list of at most 64 objects, each with:
          - "label": str, 1..64 bytes, no control characters
          - "score": number, 0 <= score <= 1
          - "bbox": [x, y, w, h], each 0 <= v <= 1 (small epsilon tolerated),
                    w and h greater than zero, and x + w <= 1.0001,
                    y + h <= 1.0001
          - "observation_kind": optional, and "tracked" when present. The
                    contract also allows "detected", but that is the default
                    the host reads an absent field as, so spelling it out is
                    bytes on every object of every line that say nothing --
                    the same reason this gate is stricter than the host about
                    an over-cap status field.
  "plugin.hello"
      - "hello" (or the envelope itself) with:
          - "name":    str, 1..64 bytes, no control characters
          - "version": optional, same rule as "name"
          - "supported_versions": list that includes 1
  "plugin.status"
      - "status" (or the envelope itself) with:
          - "state":  str, 1..32 bytes, no control characters
          - "detail": optional str, <= 256 bytes, no control characters
          - "fps":    optional number, 0..10000

The raw line must be <= 65536 bytes (UTF-8 encoded, excluding the trailing
newline) whatever its type -- the contract's framing bound, which is what
both host ports open a plugin with (`{:line, 65_536}`).

Note that the host drops an over-cap `detail`/`fps` as a *field* and keeps
the status, where this validator fails the line: a gate is stricter than the
host on purpose, so a plugin does not ship a field that silently vanishes.

A summary goes to stderr on EOF or SIGINT/SIGTERM: total/valid/invalid line
counts (with up to 5 sample errors), the hello and the last status seen, a
detection histogram by label, overall score min/mean/max, per-camera
sequence continuity, a pts monotonicity check (the contract doesn't
guarantee non-decreasing pts across a stream epoch change -- a *decrease* is
reported as a "wrap/reset" note, not an error), an effective sample rate
estimated from consecutive-pts deltas assuming the 90kHz RTP clock, and a
breakdown of what those lines cost in model passes.

That last one is bounded rather than exact, and the summary says so. Three
kinds of frame.objects line are distinguishable on the wire:

  seeded    every object carries "tracked": the plugin is re-reporting boxes
            it did not detect in this frame
  fresh     at least one object does not, so this frame was detected on
  empty     "objects": [] -- a model pass that found nothing, OR a skipped
            sample with nothing to re-report. **The wire cannot tell those
            apart**, and no field says: an empty line is the protocol's
            "alive, saw nothing" signal either way.

So the effective inference rate is reported as a range: the fresh-line rate
is its floor and the fresh+empty rate its ceiling. That reads a seeded line
as a model pass skipped, which is what cairn-detect's motion gate does and
what any no-change filter would; nothing in the contract stops a plugin from
predicting a box on a frame it did infer, and such a run would report a
ceiling below its real rate. On a run with the gate off the two bounds
collapse (nothing is seeded, every line is a model pass) and the range is
the emit rate.

Note that a plugin emits no frame.objects at all until it has been told a
stream epoch on stdin, so a run with no control line is expected to produce
only hello/status. See README.md for the recipe that feeds one.

Pass --min-score-json (the same JSON the plugin was launched with) and the
summary also reports the **sub-floor share**: what fraction of the emitted
detections carry a score below the floor of their own label. That band is
what cairn-detect's --track-floor-json puts on the wire for the host's
low-confidence association stage, so a run without the flag should report
close to nothing and a run with it reports what the flag bought. A label with
no entry falls back to "default", and a missing "default" to 0.5 -- which is
cairn-detect's own default, not something the contract says. Sub-floor
objects have always been legal in the protocol; this is a report, never a
reason to fail a run.

Read it as exactly what it measures, which is narrower than "the band":

  * the scores compared are the **rounded** ones on the wire, and a plugin
    decides what to emit from the score it had before rounding. Under a floor
    with more than three decimals the two can disagree inside a thousandth,
    so a flag-off run can report a share slightly above zero.
  * the floors compared against are the ones **handed to this tool**. A
    multiplexed capture carries several cameras whose min_score maps may
    differ, and one --min-score-json is applied to all of them; split the
    capture by camera_id, or read the share as approximate.

It reports separately how many sub-floor detections arrived on a **seeded**
line -- a count rather than a share, and one worth reading on its own: a seed
re-reports a sighting the host may act on, and there is no such sighting
below the evidence floor. For cairn-detect it is 0, and the line prints the
0 rather than going quiet, because the number is only a regression signal if
a reader can see it is still zero. The contract does not require it of every
plugin, so it is printed rather than enforced.

Exit code: 0 iff every line seen was valid AND at least one frame.objects
line was seen. Anything else is a nonzero exit -- this is meant to gate
CI/manual runs, not just report.
"""
import argparse
import json
import math
import re
import signal
import sys

MAX_LINE_BYTES = 65536
MAX_OBJECTS = 64
MAX_LABEL_BYTES = 64
MAX_CAMERA_ID_BYTES = 256
MAX_MAGNITUDE = 2**62
MAX_TIME_BASE = 1_000_000_000
MAX_HELLO_FIELD_BYTES = 64
MAX_STATUS_STATE_BYTES = 32
MAX_STATUS_DETAIL_BYTES = 256
MAX_STATUS_FPS = 10_000
EPS = 1e-4

# RFC3339 with an explicit offset; the host parses with DateTime.from_iso8601,
# which requires one.
RFC3339 = re.compile(
    r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"
)
# The only value worth putting on the wire: "detected" is what the host reads
# an absent field as, so a plugin that spells it out is paying for every object
# of every line to say the default. See the module docstring.
KINDS = ("tracked",)
# The host's @envelope_keys: routing/versioning, never part of a flat body.
ENVELOPE_KEYS = frozenset(
    ("spec", "version", "type", "camera_id", "stream_epoch", "sequence")
)


def fail(reason: str):
    raise ValueError(reason)


def is_number(v):
    # bool is a subclass of int; the host's is_number/1 does not admit it.
    # Neither can a NaN or an infinity reach the host -- strict JSON has no
    # literal for them, and Jason refuses the tokens. Python's json.loads
    # admits them as an extension, so refuse them here: a NaN is false in
    # every comparison, so it would pass each range check below and, as a
    # --min-score-json floor, read every detection as at-or-above it.
    return not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v)


def is_int(v):
    return not isinstance(v, bool) and isinstance(v, int)


def printable(s: str) -> bool:
    # str.isprintable() rejects control characters and every whitespace
    # character except the plain space, which is the host's rule too.
    return all(ch == " " or ch.isprintable() for ch in s)


def validate_bbox(bbox):
    if not isinstance(bbox, list) or len(bbox) != 4:
        fail(f"bbox must be a 4-element list, got {bbox!r}")
    for v in bbox:
        if not is_number(v):
            fail(f"bbox element not numeric: {v!r}")
        if v < -EPS or v > 1 + EPS:
            fail(f"bbox element out of 0..1 range: {v!r}")
    x, y, w, h = bbox
    if w <= 0 or h <= 0:
        fail(f"bbox has no area: {bbox!r}")
    if x + w > 1.0001:
        fail(f"bbox x+w > 1.0001: {bbox!r}")
    if y + h > 1.0001:
        fail(f"bbox y+h > 1.0001: {bbox!r}")


def validate_object(obj, idx):
    if not isinstance(obj, dict):
        fail(f"objects[{idx}] not an object: {obj!r}")
    label = obj.get("label")
    if not isinstance(label, str):
        fail(f"objects[{idx}].label missing/not str")
    if not 1 <= len(label.encode("utf-8")) <= MAX_LABEL_BYTES:
        fail(f"objects[{idx}].label is {len(label.encode('utf-8'))} bytes")
    if not printable(label):
        fail(f"objects[{idx}].label has control characters: {label!r}")
    score = obj.get("score")
    if not is_number(score):
        fail(f"objects[{idx}].score missing/not numeric")
    if score < -EPS or score > 1 + EPS:
        fail(f"objects[{idx}].score out of 0..1 range: {score!r}")
    if "bbox" not in obj:
        fail(f"objects[{idx}].bbox missing")
    validate_bbox(obj["bbox"])
    if "observation_kind" in obj and obj["observation_kind"] not in KINDS:
        fail(
            f"objects[{idx}].observation_kind is "
            f"{obj['observation_kind']!r}, expected one of {KINDS} or absent"
        )


def validate_frame(frame):
    if not isinstance(frame, dict):
        fail("frame missing/not an object")
    pts = frame.get("pts")
    if not is_number(pts):
        fail("frame.pts missing/not numeric")
    if abs(pts) > MAX_MAGNITUDE:
        fail(f"frame.pts out of the +-2^62 contract range: {pts!r}")
    if "time_base" in frame:
        tb = frame["time_base"]
        if not isinstance(tb, list) or len(tb) != 2 or not all(is_int(v) for v in tb):
            fail(f"frame.time_base must be [num, den] integers, got {tb!r}")
        if not all(1 <= v <= MAX_TIME_BASE for v in tb):
            fail(f"frame.time_base out of 1..1e9: {tb!r}")
    observed_at = frame.get("observed_at")
    if not isinstance(observed_at, str) or not RFC3339.match(observed_at):
        fail(f"frame.observed_at missing/not RFC3339 with an offset: {observed_at!r}")


def validate_objects_line(obj):
    camera_id = obj.get("camera_id")
    if not isinstance(camera_id, str):
        fail("camera_id missing/not str")
    if not 1 <= len(camera_id.encode("utf-8")) <= MAX_CAMERA_ID_BYTES:
        fail(f"camera_id is {len(camera_id.encode('utf-8'))} bytes")
    epoch = obj.get("stream_epoch")
    if not isinstance(epoch, str) or not epoch:
        fail("stream_epoch missing/empty")
    sequence = obj.get("sequence")
    if not is_int(sequence) or not 0 <= sequence <= MAX_MAGNITUDE:
        fail(f"sequence missing/not a 0..2^62 integer: {sequence!r}")
    validate_frame(obj.get("frame"))
    objects = obj.get("objects")
    if not isinstance(objects, list):
        fail("objects missing/not list")
    if len(objects) > MAX_OBJECTS:
        fail(f"objects has {len(objects)} entries, over the {MAX_OBJECTS} cap")
    for i, o in enumerate(objects):
        validate_object(o, i)


def payload(obj, key):
    """A hello/status body may be nested under its type's key or sent flat.

    The flat form drops the envelope's own routing/versioning fields first --
    the host's @envelope_keys -- so a protocol "version" of 1 is not read as
    the plugin's own version string.
    """
    nested = obj.get(key)
    if isinstance(nested, dict):
        return nested
    return {k: v for k, v in obj.items() if k not in ENVELOPE_KEYS}


def validate_bounded_str(value, field, low, high):
    """A printable string of low..high bytes, the host's rule for these."""
    if not isinstance(value, str):
        fail(f"{field} missing/not str: {value!r}")
    size = len(value.encode("utf-8"))
    if not low <= size <= high:
        fail(f"{field} is {size} bytes, outside {low}..{high}")
    if not printable(value):
        fail(f"{field} has control characters: {value!r}")


def validate_hello(obj):
    hello = payload(obj, "hello")
    # the host drops an over-cap name/version as a field and keeps the hello;
    # a plugin shipping one is still shipping a field nobody will ever see
    validate_bounded_str(hello.get("name"), "hello.name", 1, MAX_HELLO_FIELD_BYTES)
    if "version" in hello:
        validate_bounded_str(
            hello["version"], "hello.version", 1, MAX_HELLO_FIELD_BYTES
        )
    versions = hello.get("supported_versions")
    if not isinstance(versions, list) or 1 not in versions:
        fail(f"hello.supported_versions does not include 1: {versions!r}")


def validate_status(obj):
    status = payload(obj, "status")
    validate_bounded_str(
        status.get("state"), "status.state", 1, MAX_STATUS_STATE_BYTES
    )
    if "detail" in status:
        validate_bounded_str(
            status["detail"], "status.detail", 0, MAX_STATUS_DETAIL_BYTES
        )
    if "fps" in status:
        fps = status["fps"]
        if not is_number(fps):
            fail(f"status.fps not numeric: {fps!r}")
        if not 0 <= fps <= MAX_STATUS_FPS:
            fail(f"status.fps outside 0..{MAX_STATUS_FPS}: {fps!r}")


def validate_line(raw: bytes):
    """Returns (type, decoded object); raises ValueError on failure."""
    if len(raw) > MAX_LINE_BYTES:
        fail(f"line is {len(raw)} bytes, exceeds {MAX_LINE_BYTES}")
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        fail(f"invalid JSON: {e}")
    if not isinstance(obj, dict):
        fail(f"top-level JSON is not an object: {type(obj).__name__}")
    if obj.get("spec") != "cairn.plugin":
        fail(f"spec is not \"cairn.plugin\": {obj.get('spec')!r}")
    if obj.get("version") != 1:
        fail(f"version is not 1: {obj.get('version')!r}")
    kind = obj.get("type")
    if not isinstance(kind, str):
        fail("type missing/not str")

    if kind == "frame.objects":
        validate_objects_line(obj)
    elif kind == "plugin.hello":
        validate_hello(obj)
    elif kind == "plugin.status":
        validate_status(obj)
    return kind, obj


DEFAULT_MIN_SCORE = 0.5


def parse_min_scores(raw):
    """`--min-score-json` as a label -> floor table, or None if not given.

    Same shape the plugin is launched with: a JSON object of label to number,
    with an optional "default". Anything else is an argument error rather
    than a silently ignored one -- a mistyped floor map would report a
    sub-floor share measured against floors nothing ran under.
    """
    if raw is None:
        return None
    try:
        floors = json.loads(raw)
    except json.JSONDecodeError as e:
        raise argparse.ArgumentTypeError(f"not JSON: {e}") from None
    if not isinstance(floors, dict):
        raise argparse.ArgumentTypeError("must be a JSON object of label -> number")
    for label, floor in floors.items():
        if not is_number(floor):
            raise argparse.ArgumentTypeError(f"floor for {label!r} is not a number")
    return floors


class Stats:
    def __init__(self, min_scores=None):
        # label -> min_score, or None when the run was not told the floors and
        # the sub-floor share is unknowable from the wire alone
        self.min_scores = min_scores
        self.dets = 0
        self.sub_floor = 0
        self.sub_floor_seeded = 0
        self.total = 0
        self.valid = 0
        self.invalid = 0
        self.ignored = 0
        self.frames = 0
        self.errors = []  # (line_no, reason, sample)
        self.hello = None
        self.statuses = []
        self.label_counts = {}
        self.scores = []
        self.epochs = {}      # camera_id -> [epoch, ...] in order of appearance
        self.sequences = {}   # camera_id -> last sequence
        self.gaps = {}        # camera_id -> missing count
        self.pts_seen = {}    # camera_id -> [pts, ...]
        self.wraps = 0
        # frame.objects lines by what they cost in model passes; see the
        # module docstring for why "empty" is its own bucket
        self.seeded = 0
        self.fresh = 0
        self.empty = 0

    def record_error(self, line_no, reason, raw):
        self.invalid += 1
        if len(self.errors) < 5:
            sample = raw[:120].decode("utf-8", "replace")
            self.errors.append((line_no, reason, sample))

    def record_valid(self, kind, obj):
        self.valid += 1
        if kind == "plugin.hello":
            self.hello = payload(obj, "hello")
        elif kind == "plugin.status":
            self.statuses.append((obj.get("camera_id"), payload(obj, "status")))
        elif kind == "frame.objects":
            self.record_frame(obj)
        else:
            self.ignored += 1

    def record_frame(self, obj):
        self.frames += 1
        camera_id = obj["camera_id"]

        epochs = self.epochs.setdefault(camera_id, [])
        if not epochs or epochs[-1] != obj["stream_epoch"]:
            epochs.append(obj["stream_epoch"])

        sequence = obj["sequence"]
        last = self.sequences.get(camera_id)
        if last is not None and sequence > last + 1:
            self.gaps[camera_id] = self.gaps.get(camera_id, 0) + sequence - last - 1
        self.sequences[camera_id] = sequence

        pts = obj["frame"]["pts"]
        seen = self.pts_seen.setdefault(camera_id, [])
        if seen and pts < seen[-1]:
            self.wraps += 1
        seen.append(pts)

        objects = obj["objects"]
        if not objects:
            self.empty += 1
        elif all(det.get("observation_kind") == "tracked" for det in objects):
            self.seeded += 1
        else:
            self.fresh += 1

        for det in objects:
            self.label_counts[det["label"]] = self.label_counts.get(det["label"], 0) + 1
            self.scores.append(det["score"])
            self.dets += 1
            if self.min_scores is None:
                continue
            floor = self.min_scores.get(
                det["label"], self.min_scores.get("default", DEFAULT_MIN_SCORE)
            )
            if det["score"] < floor:
                self.sub_floor += 1
                if det.get("observation_kind") == "tracked":
                    self.sub_floor_seeded += 1

    def summary(self) -> str:
        lines = [
            f"lines: total={self.total} valid={self.valid} invalid={self.invalid} "
            f"frames={self.frames} ignored-types={self.ignored}"
        ]
        if self.errors:
            lines.append("first errors:")
            for line_no, reason, sample in self.errors:
                lines.append(f"  line {line_no}: {reason} | {sample!r}")

        if self.hello:
            lines.append(
                f"hello: {self.hello.get('name')} {self.hello.get('version')} "
                f"versions={self.hello.get('supported_versions')} "
                f"capabilities={self.hello.get('capabilities')}"
            )
        else:
            lines.append("hello: (none seen -- the contract wants one at startup)")

        if self.statuses:
            camera_id, status = self.statuses[-1]
            target = camera_id or "(all cameras)"
            lines.append(f"statuses: {len(self.statuses)}, last {target} -> {status}")
        else:
            lines.append("statuses: (none seen)")

        for camera_id in sorted(self.epochs):
            epochs = self.epochs[camera_id]
            gaps = self.gaps.get(camera_id, 0)
            lines.append(
                f"camera {camera_id}: {len(self.pts_seen[camera_id])} frame(s), "
                f"sequence 0..{self.sequences[camera_id]} "
                f"({'no gaps' if not gaps else f'{gaps} missing'}), "
                f"{len(epochs)} epoch(s): {', '.join(epochs)}"
            )

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
        lines.append(self.sub_floor_summary())

        emit_fps = None
        every_pts = [p for seen in self.pts_seen.values() for p in seen]
        if len(every_pts) >= 2:
            deltas = [
                b - a
                for seen in self.pts_seen.values()
                for a, b in zip(seen, seen[1:])
                if b >= a
            ]
            note = f", {self.wraps} decrease(s)/wrap(s) noted" if self.wraps else ""
            if deltas:
                mean_delta = sum(deltas) / len(deltas)
                emit_fps = 90000.0 / mean_delta if mean_delta > 0 else float("inf")
                lines.append(
                    f"pts monotonicity: {'non-decreasing' if self.wraps == 0 else 'has decreases'}{note}"
                )
                lines.append(
                    f"effective sample rate: mean pts delta={mean_delta:.1f} ticks "
                    f"(90kHz) ~= {emit_fps:.2f} fps over {len(deltas)} interval(s)"
                )
            else:
                lines.append(f"pts monotonicity: has decreases{note}; no forward deltas to estimate rate from")
        else:
            lines.append("pts monotonicity/sample rate: n/a (need >= 2 frame.objects lines)")

        lines.extend(self.inference_summary(emit_fps))
        return "\n".join(lines)

    def sub_floor_summary(self) -> str:
        """How much of what was emitted is below its label's min_score.

        The one measurement that reads a --track-floor-json run: near nothing
        without the flag, and with it the share of the wire the low-confidence
        band is taking. It needs the floors the plugin ran under, which are not
        on the wire -- hence the argument rather than an estimate. See the
        module docstring for the two ways it is approximate.

        The seeded count is printed whether or not it is zero. It is a
        regression signal, and a signal that only appears once it has already
        fired is one no reader can confirm is quiet.
        """
        if self.min_scores is None:
            return (
                "sub-floor share: n/a (pass --min-score-json to measure it; "
                "the floors a run used are not on the wire)"
            )
        if not self.dets:
            return "sub-floor share: n/a (no detections seen)"
        share = 100.0 * self.sub_floor / self.dets
        return (
            f"sub-floor share: {self.sub_floor} of {self.dets} detection(s) "
            f"({share:.1f}%) below their label's min_score, "
            f"{self.sub_floor_seeded} of them on seeded lines "
            "(a seed re-reports evidence: expect 0)"
        )

    def inference_summary(self, emit_fps):
        """What the run cost in model passes, as far as the wire can say.

        Every rate here is the emit rate scaled by a share of the lines,
        rather than a second estimate of its own: the emit rate is already
        measured from the pts deltas above, and one line is one sample.
        """
        if not self.frames:
            return ["line kinds/inference rate: n/a (no frame.objects lines seen)"]

        out = [
            f"line kinds: seeded={self.seeded} fresh-detection={self.fresh} "
            f"empty-objects={self.empty} of {self.frames} frame(s)"
        ]
        # `inf` is what a run of identical pts leaves behind; scaling it would
        # print inf/nan rather than say the rate is unknowable from these lines
        if emit_fps is None or emit_fps == float("inf"):
            out.append(
                "inference rate: n/a (no usable emit rate to scale -- need >= 2 "
                "frames with a forward pts delta)"
            )
            return out

        floor = emit_fps * self.fresh / self.frames
        ceiling = emit_fps * (self.fresh + self.empty) / self.frames
        out.append(
            f"emit rate: {emit_fps:.2f} fps (every line, seeded or not)"
        )
        out.append(
            f"effective inference rate: {floor:.2f}..{ceiling:.2f} fps "
            f"({100.0 * self.fresh / self.frames:.1f}% of lines carry a fresh "
            f"detection, {100.0 * self.empty / self.frames:.1f}% are empty and "
            "could be either)"
        )
        if self.seeded:
            out.append(
                f"gate: on -- {100.0 * self.seeded / self.frames:.1f}% of lines "
                "re-report an earlier frame's boxes instead of this frame's "
                "detections"
            )
        else:
            out.append(
                "gate: no seeded lines seen (a run with the gate off, or one "
                "that never gated with something to re-report)"
            )
        return out

    def ok(self) -> bool:
        return self.invalid == 0 and self.frames > 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--file", default=None, help="ndjson file to read (default: stdin)")
    ap.add_argument(
        "--min-score-json",
        type=parse_min_scores,
        default=None,
        help="the label -> min_score map the plugin was launched with; enables "
             "the sub-floor share report (default: not measured)",
    )
    args = ap.parse_args()

    stats = Stats(args.min_score_json)

    src = open(args.file, "rb") if args.file else sys.stdin.buffer

    def _finish(*_a):
        print(stats.summary(), file=sys.stderr)
        sys.exit(0 if stats.ok() else 1)

    signal.signal(signal.SIGINT, _finish)
    signal.signal(signal.SIGTERM, _finish)

    try:
        for line_no, raw in enumerate(src, start=1):
            raw = raw.rstrip(b"\n")
            stats.total += 1
            if not raw:
                # contract: one JSON object per line — a blank line is
                # non-contract stdout output, not ignorable whitespace
                stats.record_error(line_no, "empty line (not a JSON object)", raw)
                continue
            try:
                kind, obj = validate_line(raw)
            except ValueError as e:
                stats.record_error(line_no, str(e), raw)
                continue
            stats.record_valid(kind, obj)
    finally:
        if args.file:
            src.close()

    print(stats.summary(), file=sys.stderr)
    return 0 if stats.ok() else 1


if __name__ == "__main__":
    sys.exit(main())
