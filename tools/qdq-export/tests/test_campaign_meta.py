"""The meta contract, pinned. Every case here was a real #138 review
finding class: truncated metas grading as complete, stale bytes grading
as current, legacy metas failing instead of surfacing."""
import os
import subprocess
import sys

import pytest

from campaign_meta import RunMeta, file_sha256, records_script

SCRIPT_SHA = "a" * 64
MODEL_SHA = "b" * 64
CLIP_SHA = "c" * 64

TOOL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(TOOL_DIR, "campaign_meta.py")


def meta_text(
    backend="qnn",
    model_sha=MODEL_SHA,
    clip_sha=CLIP_SHA,
    script_sha=SCRIPT_SHA,
    extra_args="--qnn-library x",
    feed="feed exited 0",
    plugin_line=None,
    completion="frame.objects lines: 42",
):
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


def test_malformed_script_sha_line_is_stale_not_legacy(tmp_path):
    # Legacy = the script sha is ABSENT (pre-digest meta). A meta that
    # mentions the script but whose sha line is corrupt must stay in the
    # strict lane and grade STALE-EVIDENCE, not slip through as legacy.
    text = meta_text(script_sha=None) + "XXXX  /data/cairn-bench/htp_content_test.sh\n"
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.records_script
    assert meta.stale_reason({"script": SCRIPT_SHA}) is not None


def test_duplicate_sha_paths_all_match(tmp_path):
    # Two sha lines for the same path (e.g. a writer rerun appending):
    # every recorded sha must stay matchable — dropping one would grade
    # genuinely current evidence stale.
    text = meta_text() + f"{'d' * 64}  /data/m.onnx\n"
    meta = RunMeta.load(write_run(tmp_path, text))
    assert meta.has_sha(MODEL_SHA)
    assert meta.has_sha("d" * 64)


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
    assert not records_script(run)
    meta = RunMeta.load(run)
    assert meta.stale_reason({"script": SCRIPT_SHA}) is None
    assert meta.stale_reason({"model": "0" * 64}) is not None


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
    assert current_cli(interpreter, run, str(script), "--other-flags", **ok) == 1
    # truncated run must retry even though frames were emitted
    run = write_run(tmp_path, meta_text(completion=None, **shas), name="r2")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    # rebuilt model bytes under the same name must retry
    model.write_bytes(b"rebuilt-bytes")
    run = write_run(tmp_path, meta_text(**shas), name="r3")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    model.write_bytes(b"model-bytes")
    # no emitted frames must retry
    run = write_run(tmp_path, meta_text(**shas), ndjson="noise\n", name="r4")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    # pinned control bytes (no local artifact): wrong sha must retry
    run = write_run(tmp_path, meta_text(**shas), name="r5")
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha="0" * 64) == 1
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha=shas["model_sha"]) == 0


def test_binary_corrupted_meta_grades_not_crashes(tmp_path):
    # Invalid UTF-8 in a fetched meta is corrupt EVIDENCE: it must parse
    # (replacement chars -> missing fields -> suspect), never raise into
    # the analyzer or the CLI's guard-broken lane.
    run = tmp_path / "run"
    run.mkdir()
    (run / "meta").write_bytes(b"\xff\xfegovernor: \xba\xad\nbackend: ")
    meta = RunMeta.load(str(run))
    assert meta.exists
    assert meta.suspect_reason() is not None


def test_current_cli_rc_contract(tmp_path, interpreter, local_files):
    # rc 1 = evidence not current (rerun that run); rc >= 2 = the guard
    # ITSELF is broken — the bash caller fatals instead of blind-rerunning
    # a whole board campaign behind a broken check.
    script, model, clip = local_files
    shas = dict(script_sha=file_sha256(str(script)),
                model_sha=file_sha256(str(model)),
                clip_sha=file_sha256(str(clip)))
    # binary-corrupted ndjson is bad EVIDENCE: rerun (1), not guard breakage
    run = write_run(tmp_path, meta_text(**shas), ndjson=None, name="bin")
    (tmp_path / "bin" / "out.ndjson").write_bytes(b"\xff\xfe\x00garbage")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 1
    # binary-corrupted meta likewise: evidence (1), not breakage
    run = write_run(tmp_path, meta=None, name="binmeta")
    (tmp_path / "binmeta" / "meta").write_bytes(b"\xff\xfegovernor: \xba\xad")
    assert current_cli(interpreter, run, str(script), "--qnn-library x") == 1
    # a missing local script file is guard breakage: 3, never 1
    run = write_run(tmp_path, meta_text(**shas), name="noscript")
    assert current_cli(interpreter, run, str(tmp_path / "absent.sh"),
                       "--qnn-library x") == 3
