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
import os
import re
import sys

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
        self.exists = text is not None
        self.lines = text.splitlines() if text else []
        self.shas = {}  # recorded path -> sha, from sha256sum output lines
        self.backend = None
        self.extra_args = None
        self.completion = False
        for line in self.lines:
            m = _SHA_LINE.match(line)
            if m:
                self.shas[m.group(2)] = m.group(1)
            elif line.startswith("backend: "):
                self.backend = line.split()[1]
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
        with open(path) as f:
            return cls(f.read())

    @property
    def records_script(self):
        """False on metas from before the methodology digest: script
        identity is unrecorded, not wrong — callers surface these rather
        than fail them; the campaign driver regenerates them."""
        return any(
            os.path.basename(p) == "htp_content_test.sh" for p in self.shas
        )

    def has_sha(self, sha):
        return sha in self.shas.values()

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


def _current(args):
    """The retry guard: skip a rerun only on evidence of a SUCCESSFUL
    CURRENT run — emitted frames, a complete non-suspect meta, and shas
    tying it to today's script, flags, model, and clip bytes. A truncated
    run can emit a frame before dying, and an old run under the same tag
    can describe different bytes; both must retry."""
    try:
        with open(os.path.join(args.run_dir, "out.ndjson")) as f:
            if '"frame.objects"' not in f.read():
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
    args = ap.parse_args()
    sys.exit(0 if _current(args) else 1)


if __name__ == "__main__":
    main()
