#!/usr/bin/env python3
"""The one reader of a content run's `meta` file.

htp_content_test.sh writes meta on the board; its sha IS the methodology
digest, so the writer never changes here — changing it voids all fetched
evidence. Everything that later judges a run reads meta through this
module: the analyzer's suspect/stale grading (htp_report.py) and the
campaign driver's retry guard (`campaign_meta.py current`, called from
run_htp_campaign.sh). #138's review churn came from this logic drifting
between ad-hoc greps in bash and python; one implementation is the fix.

Stdlib only: the bash caller runs the system python3, which has no venv.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections.abc import Iterable

from finite import is_finite

# `(\S+)` cannot match a path containing spaces (or busybox's \-escaped
# names); no board path does today, and a miss fails closed (stale →
# retry) — but a writer change to spaced paths must revisit this.
_SHA_LINE = re.compile(r"^([0-9a-f]{64})\s+(\S+)$")
# The FULL line the writer emits, not its prefix: a meta truncated right
# after "frame.objects lines:" is an incomplete run wearing the marker.
# The count is kept, not reduced to a boolean — fetch() cannot read scp's
# rc, so a complete meta beside an ndjson truncated mid-transfer is a
# real shape, and the recorded count is the only witness.
_COMPLETION_LINE = re.compile(r"^frame\.objects lines: (\d+)$")


def file_sha256(path: str) -> str:
    """Full sha256 of a file's bytes — matched against the sha256sum
    lines the board script recorded in meta."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class RunMeta:
    """Parsed meta plus the verdicts over it. `RunMeta(None)` is a run
    whose meta was never fetched — distinct from an empty file."""

    def __init__(self, text: str | None, corrupt: bool = False) -> None:
        # A meta can be truncated at ANY byte (killed ssh, full disk) —
        # every parse below must degrade to a missing field, never raise:
        # one crashing meta would abort the whole report instead of
        # grading that run SUSPECT.
        self.exists = text is not None
        self.corrupt = corrupt
        self._text = text or ""
        self.lines = self._text.splitlines()
        self.shas: list[tuple[str, str]] = []  # (recorded path, sha) pairs
        self.backend: str | None = None
        self.profile: str | None = None
        self.insize: str | None = None
        self.extra_args: str | None = None
        self.completion = False
        self.frames: int | None = None
        for line in self.lines:
            if m := _SHA_LINE.match(line):
                self.shas.append((m.group(2), m.group(1)))
            elif line.startswith("backend: "):
                # "backend: X profile: Y insize: Z ..." — key/value token
                # pairs; zip degrades a truncated line to missing fields.
                parts = line.split()
                fields = dict(zip(parts[0::2], parts[1::2]))
                self.backend = fields.get("backend:")
                self.profile = fields.get("profile:")
                self.insize = fields.get("insize:")
            elif line.startswith("extra_args:"):
                rest = line[len("extra_args:"):]
                self.extra_args = rest[1:] if rest.startswith(" ") else rest
            elif m := _COMPLETION_LINE.match(line):
                self.completion = True
                self.frames = int(m.group(1))

    @classmethod
    def load(cls, run_dir: str) -> RunMeta:
        path = os.path.join(run_dir, "meta")
        if not os.path.exists(path):
            return cls(None)
        # Strict decoding, flagged not raised: replace-decoding would hide
        # corruption that lands in a line nothing parses (the governor
        # line, trailing noise) and accept the meta wholesale, while an
        # exception would abort the report / read as a broken guard.
        # Corrupt bytes are bad EVIDENCE — they grade suspect.
        with open(path, "rb") as f:
            raw = f.read()
        try:
            return cls(raw.decode())
        except UnicodeDecodeError:
            return cls("", corrupt=True)

    @property
    def records_script(self) -> bool:
        """False on metas from before the methodology digest: script
        identity is unrecorded, not wrong — callers surface these rather
        than fail them; the campaign driver regenerates them.

        Any mention in the text counts, not just a well-formed sha line:
        a meta whose script sha line is malformed must stay in the
        STRICT lane (stale check enforced → STALE-EVIDENCE), because the
        legacy classification exists for absence, not corruption."""
        return "htp_content_test.sh" in self._text

    def has_sha(self, sha: str) -> bool:
        return any(sha == s for _, s in self.shas)

    def has_backend(self, backend: str) -> bool:
        """Bytes alone don't prove the leg: an ORT run misfiled under a
        *-qnn-* directory scores ~1.0 by construction and would serve as
        HTP proof."""
        return self.backend == backend

    def suspect_reason(self) -> str | None:
        """The content test's own verdict on its run.

        The board script records a non-EOF plugin exit and the feed's exit
        in meta and nowhere else. The completion marker is written only
        after both — absence of "run suspect" in a meta truncated by a
        killed ssh proves nothing, so no marker is itself suspect.
        """
        if not self.exists:
            return "no meta fetched"
        if self.corrupt:
            return "meta contains undecodable bytes"
        for line in self.lines:
            if "run suspect" in line:
                return line.strip()
            if line.startswith("feed exited") and not line.rstrip().endswith(" 0"):
                return line.strip()
        if not self.completion:
            return (
                "meta lacks completion marker "
                "(run truncated before shutdown states were recorded)"
            )
        return None

    def stale_reason(self, expected_shas: dict[str, str | None] | None) -> str | None:
        """Evidence under the right directory name but from different
        bytes must not be graded against today's references. Keys are
        labels ("model", "clip", "script"), values full shas; falsy values
        skip the check."""
        if not expected_shas:
            return None
        if not self.exists:
            return "no meta fetched"
        for label, sha in expected_shas.items():
            if not sha:
                continue
            if label == "script" and not self.records_script:
                continue
            if not self.has_sha(sha):
                return f"meta does not record the current {label} sha ({sha[:12]}…)"
        return None


def records_script(run_dir: str) -> bool:
    return RunMeta.load(run_dir).records_script


def _gradable_frame_count(lines: Iterable[str]) -> int | None:
    """Number of frame.objects messages, or None if ANY is ungradable by
    the analyzer's rule (htp_series): parseable JSON carrying the exact
    fields it consumes, finite pts, scores inside the plugin's 0..1
    sigmoid contract. Current-but-ungradable is the trap in every
    direction — a corrupted line that merely CONTAINS the literal, or one
    valid frame vouching for a poisoned tail, would let the guard
    permanently skip a run the analyzer refuses. The count feeds the
    truncated-transfer check against meta's recorded total."""
    count = 0
    for line in lines:
        if '"frame.objects"' not in line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return None
        if not isinstance(msg, dict) or msg.get("type") != "frame.objects":
            continue
        try:
            pts = msg["frame"]["pts"] if "frame" in msg else msg["pts"]
            fields = [(o["label"], o["score"]) for o in msg["objects"]]
        except (KeyError, TypeError):
            return None
        if not is_finite(pts) or not all(
            is_finite(s) and 0.0 <= s <= 1.0 for _, s in fields
        ):
            return None
        count += 1
    return count


def run_is_current(
    run_dir: str,
    script: str,
    extra_args: str,
    *,
    model: str | None = None,
    clip: str | None = None,
    require_sha: str | None = None,
    backend: str | None = None,
    profile: str | None = None,
    insize: str | None = None,
) -> bool:
    """The retry guard: skip a rerun only on evidence of a SUCCESSFUL
    CURRENT run — a complete non-suspect meta, exactly as many gradable
    frames as it recorded, and shas/identity tying the run to today's
    script, flags, geometry, model, and clip. A truncated run can emit a
    frame before dying, an interrupted fetch can truncate the ndjson
    beside a complete meta, and an old run under the same tag can
    describe different bytes; all must retry."""
    meta = RunMeta.load(run_dir)
    if meta.suspect_reason() is not None:
        return False
    try:
        # Strict decoding, like the analyzer's own read: invalid UTF-8
        # anywhere is corrupted evidence — rerun (rc 1), never rc>=2, and
        # never "current" for a file htp_series will refuse to decode.
        with open(os.path.join(run_dir, "out.ndjson")) as f:
            frames = _gradable_frame_count(f)
    except (OSError, UnicodeDecodeError):
        return False
    if not frames or frames != meta.frames:
        return False
    if not meta.has_sha(file_sha256(script)):
        return False
    if meta.extra_args != extra_args:
        return False
    # extra_args alone is not the run's identity: backend/profile/insize
    # arrive via the driver's env and argv, outside the hashed script —
    # a rung whose geometry changes must regenerate its evidence.
    for want, have in ((backend, meta.backend),
                       (profile, meta.profile),
                       (insize, meta.insize)):
        if want is not None and want != have:
            return False
    for path in (model, clip):
        if path and not meta.has_sha(file_sha256(path)):
            return False
    return not (require_sha and not meta.has_sha(require_sha))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    cur = sub.add_parser(
        "current", help="exit 0 iff the fetched run is current evidence"
    )
    cur.add_argument("run_dir")
    cur.add_argument("--script", required=True, help="local htp_content_test.sh")
    # Callers must pass this as --extra-args=<flags>: the recorded value
    # itself starts with "--" (QNN flags), and argparse refuses an
    # option-like token as a separate-argument value.
    cur.add_argument("--extra-args", default="", help="exact extra_args the run must record (use --extra-args=...)")
    cur.add_argument("--model", help="local artifact whose bytes the run must record")
    cur.add_argument("--clip", help="local clip whose bytes the run must record")
    cur.add_argument("--require-sha", help="literal sha the meta must record (pinned controls)")
    cur.add_argument("--backend", help="backend the run must record")
    cur.add_argument("--profile", help="model profile the run must record")
    cur.add_argument("--insize", help="input size the run must record")
    args = ap.parse_args()
    # rc contract: 0 = current, 4 = evidence not current (rerun it),
    # anything else = the GUARD is broken — the bash caller fatals on
    # every other status rather than silently rerunning an entire board
    # campaign behind a broken check. "Not current" gets its own code
    # because 1 is NOT ours to use: the interpreter exits 1 for import
    # and syntax failures before this try block ever runs (argparse owns
    # 2, the catch-all here 3, an absent python3 127).
    try:
        current = run_is_current(
            args.run_dir, args.script, args.extra_args,
            model=args.model, clip=args.clip, require_sha=args.require_sha,
            backend=args.backend, profile=args.profile, insize=args.insize,
        )
        sys.exit(0 if current else 4)
    except Exception as e:  # noqa: BLE001 — anything here is guard breakage
        print(f"campaign_meta current: {e!r}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
