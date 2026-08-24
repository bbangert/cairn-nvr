"""The meta contract, pinned. Every case here was a real #138 review
finding class: truncated metas grading as complete, stale bytes grading
as current, legacy metas failing instead of surfacing."""
import os
import subprocess
import sys

import pytest

from campaign_meta import RunMeta, file_sha256, is_legacy

SCRIPT_SHA = "a" * 64
MODEL_SHA = "b" * 64
CLIP_SHA = "c" * 64

TOOL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(TOOL_DIR, "campaign_meta.py")


_AUTO = "auto"


def meta_text(
    backend="qnn",
    model_sha=MODEL_SHA,
    clip_sha=CLIP_SHA,
    script_sha=SCRIPT_SHA,
    extra_args="--qnn-library x",
    feed="feed exited 0",
    plugin_line=None,
    frames=1,
    completion=_AUTO,
):
    if completion is _AUTO:
        # match the default single-frame ndjson unless a test overrides
        completion = f"frame.objects lines: {frames}"
    lines = [
        "governor: performance",
        f"backend: {backend} profile: yolox insize: 416 sample_fps: 10 min_score: 0.05",
        "model: /data/m.onnx",
        f"{model_sha}  /data/m.onnx",
        "clip: /data/clip.mp4",
        f"{clip_sha}  /data/clip.mp4",
    ]
    if script_sha:
        lines.append(f"{script_sha}  /data/cairn-bench/htp_content_test.sh")
    lines += [f"extra_args: {extra_args}", "up after ~5s"]
    if feed:
        lines.append(feed)
    if plugin_line:
        lines.append(plugin_line)
    if completion:
        lines.append(completion)
    return "\n".join(lines) + "\n"


def write_run(tmp_path, meta=None, ndjson='{"type":"frame.objects","pts":0,"objects":[]}\n',
              name="run"):
    # Callers exercising several cases in one test pass distinct names —
    # a reused dir would let a case inherit the previous case's files.
    run = tmp_path / name
    run.mkdir(exist_ok=True)
    if meta is not None:
        (run / "meta").write_text(meta)
    if ndjson is not None:
        (run / "out.ndjson").write_text(ndjson)
    return str(run)


def test_complete_meta_is_not_suspect(tmp_path):
    meta = RunMeta.load(write_run(tmp_path, meta_text()))
    assert meta.suspect_reason() is None
    assert meta.has_backend("qnn")
    assert not meta.has_backend("ort")
    assert meta.profile == "yolox"
    assert meta.insize == "416"
    assert meta.extra_args == "--qnn-library x"
    assert meta.records_script


def test_unfetched_meta_is_suspect(tmp_path):
    meta = RunMeta.load(write_run(tmp_path, meta=None))
    assert meta.suspect_reason() == "no meta fetched"
    assert meta.stale_reason({"model": MODEL_SHA}) == "no meta fetched"


def test_feed_failure_is_suspect(tmp_path):
    text = meta_text(feed="feed exited 1 — run suspect")
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.suspect_reason() == "feed exited 1 — run suspect"


def test_plugin_exit_is_suspect(tmp_path):
    text = meta_text(plugin_line="plugin exited 9 (expected 3, stdin EOF) — run suspect")
    meta = RunMeta.load(write_run(tmp_path, text))
    assert "run suspect" in meta.suspect_reason()


def test_truncated_meta_is_suspect(tmp_path):
    # A meta cut off by a killed ssh never wrote its suspect lines; the
    # absence of the completion marker is what must convict it.
    meta = RunMeta.load(write_run(tmp_path, meta_text(completion=None)))
    assert meta.suspect_reason() == (
        "meta lacks completion marker "
        "(run truncated before shutdown states were recorded)"
    )


def test_meta_truncated_mid_line_never_crashes():
    # A meta can end at ANY byte. `backend: ` (field name, no value) once
    # raised IndexError in the constructor and killed the whole report.
    meta = RunMeta("governor: performance\nbackend: ")
    assert meta.backend is None
    assert not meta.has_backend("qnn")
    assert "completion marker" in meta.suspect_reason()
    # a dangling key at the cut point degrades to a missing field
    meta = RunMeta("backend: qnn profile:")
    assert meta.backend == "qnn"
    assert meta.profile is None


def test_corruption_in_an_ignored_line_is_still_suspect(tmp_path):
    # Replace-decoding would hide invalid UTF-8 that lands in a line
    # nothing parses (the governor line, trailing noise) — every field
    # would read intact and corrupted evidence would be accepted.
    run = tmp_path / "run"
    run.mkdir()
    (run / "meta").write_bytes(meta_text().encode() + b"governor: \xff\xfe\n")
    meta = RunMeta.load(str(run))
    assert meta.suspect_reason() == "meta contains undecodable bytes"


def test_frame_count_must_match_meta(tmp_path, interpreter, local_files):
    # An interrupted fetch can truncate out.ndjson beside a complete
    # meta; the recorded count is the only witness.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    run = write_run(tmp_path, meta_text(frames=5, **shas))
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       model=str(model), clip=str(clip)) == 4


def test_completion_marker_prefix_is_not_completion(tmp_path):
    # A meta cut right after the marker's prefix (before the count) is a
    # truncated run wearing the marker — only the writer's full numeric
    # line counts.
    meta = RunMeta.load(write_run(tmp_path, meta_text(completion="frame.objects lines:")))
    assert not meta.completion
    assert "completion marker" in meta.suspect_reason()


def test_malformed_script_sha_line_is_stale_not_legacy(tmp_path):
    # Legacy = the script sha is ABSENT (pre-digest meta). A meta that
    # mentions the script but whose sha line is corrupt must stay in the
    # strict lane and grade STALE-EVIDENCE, not slip through as legacy.
    text = meta_text(script_sha=None) + "XXXX  /data/cairn-bench/htp_content_test.sh\n"
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.records_script
    assert meta.stale_reason({"script": SCRIPT_SHA}) is not None


def test_conflicting_shas_for_one_path_are_suspect(tmp_path):
    # The writer truncates meta at start and records one sha per file:
    # two DIFFERENT hashes for one path is ambiguous/corrupt evidence —
    # any-match would let stale checks validate old AND new bytes.
    text = meta_text() + f"{'d' * 64}  /data/m.onnx\n"
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.suspect_reason() == "meta records conflicting shas for /data/m.onnx"
    # the SAME hash repeated is benign repetition, not a conflict
    text = meta_text() + f"{MODEL_SHA}  /data/m.onnx\n"
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.suspect_reason() is None
    assert meta.has_sha(MODEL_SHA)


def test_overlong_frame_count_is_corrupt_marker_not_a_crash(tmp_path):
    # py3.11 caps decimal-to-int at ~4300 digits; the regex accepts an
    # unbounded count. An absurd count must grade as a truncated/corrupt
    # marker (suspect), never raise into the report or the rc-3 lane.
    text = meta_text(completion="frame.objects lines: " + "9" * 5000)
    meta = RunMeta.load(write_run(tmp_path, text))
    assert not meta.completion
    assert "completion marker" in meta.suspect_reason()


def test_stale_and_current_shas(tmp_path):
    meta = RunMeta.load(write_run(tmp_path, meta_text()))
    current = {"model": MODEL_SHA, "clip": CLIP_SHA, "script": SCRIPT_SHA}
    assert meta.stale_reason(current) is None
    stale = dict(current, model="0" * 64)
    assert meta.stale_reason(stale) == (
        f"meta does not record the current model sha ({'0' * 12}…)"
    )
    assert meta.stale_reason({}) is None
    assert meta.stale_reason({"model": None}) is None


def test_legacy_meta_skips_script_not_model(tmp_path):
    # Pre-digest metas record no script sha: unrecorded, not wrong. The
    # same leniency must never extend to model/clip bytes.
    run = write_run(tmp_path, meta_text(script_sha=None))
    assert is_legacy(run)
    meta = RunMeta.load(run)
    assert meta.stale_reason({"script": SCRIPT_SHA}) is None
    assert meta.stale_reason({"model": "0" * 64}) is not None


def test_legacy_requires_a_real_non_suspect_meta(tmp_path):
    # Missing, undecodable, or SUSPECT metas are NOT legacy — the
    # report's legacy note says "bytes verified", which nobody verified
    # for those.
    run = tmp_path / "nometa"
    run.mkdir()
    assert not is_legacy(str(run))
    (run / "meta").write_bytes(b"\xff\xfe corrupt")
    assert not is_legacy(str(run))
    # truncated (no completion marker) pre-digest meta: suspect, not legacy
    (run / "meta").write_text(meta_text(script_sha=None, completion=None))
    assert not is_legacy(str(run))
    # feed-failed pre-digest meta: suspect, not legacy
    (run / "meta").write_text(
        meta_text(script_sha=None, feed="feed exited 1 — run suspect"))
    assert not is_legacy(str(run))


# The bash retry guard runs the SYSTEM python3 — stdlib-only is part of
# the module's contract, so the CLI must pass under both interpreters.
# Paths, not inodes, define the environments: a venv python resolves to
# the system binary, but site-packages follow the invoked path. The
# dedup below is only for pytest itself running AS /usr/bin/python3
# (then there is one environment, and one leg is the honest count).
_INTERPRETERS = [sys.executable] + (
    ["/usr/bin/python3"] if sys.executable != "/usr/bin/python3" else []
)


@pytest.fixture(params=_INTERPRETERS)
def interpreter(request):
    if not os.path.exists(request.param):
        pytest.skip(f"{request.param} not present")
    return request.param


def current_cli(interpreter, run_dir, script, extra_args, **opts):
    # = form throughout: extra_args values start with "--" (QNN flags)
    # and argparse refuses option-like tokens as separate values.
    cmd = [interpreter, CLI, "current", run_dir, f"--script={script}",
           f"--extra-args={extra_args}"]
    cmd += [f"--{flag.replace('_', '-')}={val}" for flag, val in opts.items()]
    return subprocess.run(cmd).returncode


@pytest.fixture
def local_files(tmp_path):
    script = tmp_path / "htp_content_test.sh"
    script.write_text("#!/bin/sh\n")
    model = tmp_path / "m.onnx"
    model.write_bytes(b"model-bytes")
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"clip-bytes")
    return script, model, clip


def test_current_cli_accepts_a_current_run(tmp_path, interpreter, local_files):
    script, model, clip = local_files
    run = write_run(tmp_path, meta_text(
        script_sha=file_sha256(str(script)),
        model_sha=file_sha256(str(model)),
        clip_sha=file_sha256(str(clip)),
    ))
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       model=str(model), clip=str(clip)) == 0


def test_current_cli_rejects_drift(tmp_path, interpreter, local_files):
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    ok = dict(model=str(model), clip=str(clip))

    # changed flags must retry
    run = write_run(tmp_path, meta_text(**shas), name="r1")
    assert current_cli(interpreter, run, str(script), "--other-flags", **ok) == 4
    # truncated run must retry even though frames were emitted
    run = write_run(tmp_path, meta_text(completion=None, **shas), name="r2")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 4
    # rebuilt model bytes under the same name must retry
    model.write_bytes(b"rebuilt-bytes")
    run = write_run(tmp_path, meta_text(**shas), name="r3")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 4
    model.write_bytes(b"model-bytes")
    # no emitted frames must retry
    run = write_run(tmp_path, meta_text(**shas), ndjson="noise\n", name="r4")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 4
    # pinned control bytes (no local artifact): wrong sha must retry
    run = write_run(tmp_path, meta_text(**shas), name="r5")
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha="0" * 64) == 4
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha=shas["model_sha"]) == 0


def test_current_cli_checks_invocation_identity(tmp_path, interpreter, local_files):
    # backend/profile/insize arrive via the driver's env and argv, not
    # the hashed script: a rung whose geometry changes must regenerate
    # its evidence, and a wrong backend must not wait for the analyzer.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    run = write_run(tmp_path, meta_text(**shas))
    base = dict(model=str(model), clip=str(clip))
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       backend="qnn", profile="yolox", insize="416", **base) == 0
    for drift in (dict(backend="ort", profile="yolox", insize="416"),
                  dict(backend="qnn", profile="yolov8", insize="416"),
                  dict(backend="qnn", profile="yolox", insize="640")):
        assert current_cli(interpreter, run, str(script), "--qnn-library x",
                           **drift, **base) == 4


def test_current_cli_requires_parseable_frame_line(tmp_path, interpreter, local_files):
    # A corrupted line that merely CONTAINS the literal is not an
    # emitted frame — the analyzer would grade the run NO-DATA while the
    # guard kept skipping it forever.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    run = write_run(tmp_path, meta_text(**shas),
                    ndjson='garbage "frame.objects" garbage\n', name="corrupt")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 4
    run = write_run(
        tmp_path, meta_text(**shas),
        ndjson='QAIRT noise\n{"type":"frame.objects","pts":0,"objects":[]}\n',
        name="okline")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 0


def test_current_cli_rejects_partially_poisoned_ndjson(tmp_path, interpreter, local_files):
    # One valid frame must not vouch for a file whose later frames the
    # analyzer will refuse — that run needs a rerun, not a permanent skip.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    good = '{"type":"frame.objects","pts":0,"objects":[{"label":"person","score":0.9}]}\n'
    cases = {
        "nanframe": good + '{"type":"frame.objects","pts":90000,"objects":[{"label":"person","score":NaN}]}\n',
        "boolframe": good + '{"type":"frame.objects","pts":90000,"objects":[{"label":"person","score":true}]}\n',
        "fieldless": good + '{"type":"frame.objects","pts":90000}\n',
        "cutline": good + '{"type":"frame.objects","pts":90000,"obj',
        "rangeframe": good + '{"type":"frame.objects","pts":90000,"objects":[{"label":"person","score":1.5}]}\n',
        "dictobjects": good + '{"type":"frame.objects","pts":90000,"objects":{}}\n',
        "strobjects": good + '{"type":"frame.objects","pts":90000,"objects":""}\n',
        # escape-encoded type: no literal in the raw line, but it parses
        # to a real frame — the guard must count it like the analyzer
        # does (count 2 vs meta's 1 -> not current), never skip it on a
        # textual prefilter and disagree with the analyzer forever.
        "escapedtype": good + '{"type":"\\u0066rame.objects","pts":90000,"objects":[{"label":"person","score":0.9}]}\n',
    }
    for name, ndjson in cases.items():
        run = write_run(tmp_path, meta_text(**shas), ndjson=ndjson, name=name)
        assert current_cli(interpreter, run, str(script), "--qnn-library x") == 4, name
    # invalid UTF-8 in a NOISE line still poisons: the analyzer reads
    # strictly and could not decode this file at all
    run = write_run(tmp_path, meta_text(**shas), ndjson=None, name="binnoise")
    with open(tmp_path / "binnoise" / "out.ndjson", "wb") as f:
        f.write(good.encode() + b"\xff\xfe binary noise\n")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 4
    # a non-frame message merely EMBEDDING the literal is analyzer-ignored
    # noise, not poison
    run = write_run(
        tmp_path, meta_text(**shas),
        ndjson='{"frame.objects": 1, "type": "log"}\n' + good,
        name="embedded")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 0


def test_binary_corrupted_meta_grades_not_crashes(tmp_path):
    # Invalid UTF-8 in a fetched meta is corrupt EVIDENCE: strict decode
    # flags it (corrupt -> suspect), never raising into the analyzer or
    # the CLI's guard-broken lane.
    run = tmp_path / "run"
    run.mkdir()
    (run / "meta").write_bytes(b"\xff\xfegovernor: \xba\xad\nbackend: ")
    meta = RunMeta.load(str(run))
    assert meta.exists
    assert meta.suspect_reason() is not None


def test_current_cli_rc_contract(tmp_path, interpreter, local_files):
    # rc 4 = evidence not current (rerun that run); any other nonzero =
    # the guard ITSELF is broken — the bash caller fatals instead of
    # blind-rerunning a whole board campaign behind a broken check.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    # binary-corrupted ndjson is bad EVIDENCE: rerun (4), not guard breakage
    run = write_run(tmp_path, meta_text(**shas), ndjson=None, name="bin")
    (tmp_path / "bin" / "out.ndjson").write_bytes(b"\xff\xfe\x00garbage")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 4
    # binary-corrupted meta likewise: evidence (4), not breakage
    run = write_run(tmp_path, meta=None, name="binmeta")
    (tmp_path / "binmeta" / "meta").write_bytes(b"\xff\xfegovernor: \xba\xad")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 4
    # a missing local script file is guard breakage: 3, never 4
    run = write_run(tmp_path, meta_text(**shas), name="noscript")
    assert current_cli(interpreter, run, str(tmp_path / "absent.sh"),
                       "--qnn-library x") == 3
