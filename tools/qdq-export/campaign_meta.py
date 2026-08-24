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
import argparse
import hashlib
import json
import os
import re
import sys

# `(\S+)` cannot match a path containing spaces (or busybox's \-escaped
# names); no board path does today, and a miss fails closed (stale →
# retry) — but a writer change to spaced paths must revisit this.
_SHA_LINE = re.compile(r"^([0-9a-f]{64})\s+(\S+)$")
COMPLETION_MARKER = "frame.objects lines:"


def file_sha256(path):
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

    def __init__(self, text):
        # A meta can be truncated at ANY byte (killed ssh, full disk) —
        # every parse below must degrade to a missing field, never raise:
        # one crashing meta would abort the whole report instead of
        # grading that run SUSPECT.
        self.exists = text is not None
        self._text = text or ""
        self.lines = self._text.splitlines()
        self.shas = []  # (recorded path, sha) pairs, from sha256sum lines
        self.backend = None
        self.profile = None
        self.insize = None
        self.extra_args = None
        self.completion = False
        for line in self.lines:
            m = _SHA_LINE.match(line)
            if m:
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
            elif line.startswith(COMPLETION_MARKER):
                self.completion = True

    @classmethod
    def load(cls, run_dir):
        path = os.path.join(run_dir, "meta")
        if not os.path.exists(path):
            return cls(None)
        # errors="replace", same reasoning as the ndjson read: corrupt
        # bytes are bad EVIDENCE — the mangled text parses into missing
        # fields and grades SUSPECT/stale — never an exception that
        # aborts the report or reads as a broken guard (rc>=2).
        with open(path, errors="replace") as f:
            return cls(f.read())

    @property
    def records_script(self):
        """False on metas from before the methodology digest: script
        identity is unrecorded, not wrong — callers surface these rather
        than fail them; the campaign driver regenerates them.

        Any mention in the text counts, not just a well-formed sha line:
        a meta whose script sha line is malformed must stay in the
        STRICT lane (stale check enforced → STALE-EVIDENCE), because the
        legacy classification exists for absence, not corruption."""
        return "htp_content_test.sh" in self._text

    def has_sha(self, sha):
        return any(sha == s for _, s in self.shas)

    def has_backend(self, backend):
        """Bytes alone don't prove the leg: an ORT run misfiled under a
        *-qnn-* directory scores ~1.0 by construction and would serve as
        HTP proof."""
        return self.backend == backend

    def suspect_reason(self):
        """The content test's own verdict on its run.

        The board script records a non-EOF plugin exit and the feed's exit
        in meta and nowhere else. The completion marker is written only
        after both — absence of "run suspect" in a meta truncated by a
        killed ssh proves nothing, so no marker is itself suspect.
        """
        if not self.exists:
            return "no meta fetched"
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

    def stale_reason(self, expected_shas):
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


def records_script(run_dir):
    return RunMeta.load(run_dir).records_script


def _is_frame_line(line):
    """The analyzer's acceptance rule (htp_series): a parsed JSON message
    whose type is frame.objects. A corrupted line that merely CONTAINS
    the literal would satisfy a substring grep, mark the run current, and
    let the analyzer grade it NO-DATA forever."""
    if '"frame.objects"' not in line:
        return False
    try:
        return json.loads(line).get("type") == "frame.objects"
    except (json.JSONDecodeError, AttributeError):
        return False


def _current(args):
    """The retry guard: skip a rerun only on evidence of a SUCCESSFUL
    CURRENT run — emitted frames, a complete non-suspect meta, and shas
    tying it to today's script, flags, model, and clip bytes. A truncated
    run can emit a frame before dying, and an old run under the same tag
    can describe different bytes; both must retry."""
    try:
        # errors="replace": a binary-corrupted ndjson is bad EVIDENCE
        # (rerun, exit 1), not a broken guard — it must not escape as a
        # UnicodeDecodeError into the rc>=2 lane.
        with open(os.path.join(args.run_dir, "out.ndjson"), errors="replace") as f:
            if not any(_is_frame_line(line) for line in f):
                return False
    except OSError:
        return False
    meta = RunMeta.load(args.run_dir)
    if meta.suspect_reason() is not None:
        return False
    if not meta.has_sha(file_sha256(args.script)):
        return False
    if meta.extra_args != args.extra_args:
        return False
    # extra_args alone is not the run's identity: backend/profile/insize
    # arrive via the driver's env and argv, outside the hashed script —
    # a rung whose geometry changes must regenerate its evidence.
    for want, have in ((args.backend, meta.backend),
                       (args.profile, meta.profile),
                       (args.insize, meta.insize)):
        if want is not None and want != have:
            return False
    for path in (args.model, args.clip):
        if path and not meta.has_sha(file_sha256(path)):
            return False
    if args.require_sha and not meta.has_sha(args.require_sha):
        return False
    return True


def main():
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
    # rc contract: 1 = evidence not current (rerun it); >=2 = the GUARD
    # is broken (argparse 2, this catch-all 3, absent python3 127) — the
    # bash caller fatals on >=2 rather than silently rerunning an entire
    # board campaign behind a broken check.
    try:
        sys.exit(0 if _current(args) else 1)
    except Exception as e:  # noqa: BLE001 — anything here is guard breakage
        print(f"campaign_meta current: {e!r}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
