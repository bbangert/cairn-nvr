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


def write_run(tmp_path, meta=None, ndjson='{"type":"frame.objects","pts":0,"objects":[]}\n'):
    run = tmp_path / "run"
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


@pytest.fixture(params=[sys.executable, "/usr/bin/python3"])
def interpreter(request):
    # The bash retry guard runs the SYSTEM python3 — stdlib-only is part
    # of the module's contract, so the CLI must pass under both.
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
    run = write_run(tmp_path, meta_text(**shas))
    assert current_cli(interpreter, run, str(script), "--other-flags", **ok) == 1
    # truncated run must retry even though frames were emitted
    run = write_run(tmp_path, meta_text(completion=None, **shas))
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    # rebuilt model bytes under the same name must retry
    model.write_bytes(b"rebuilt-bytes")
    run = write_run(tmp_path, meta_text(**shas))
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    model.write_bytes(b"model-bytes")
    # no emitted frames must retry
    run = write_run(tmp_path, meta_text(**shas), ndjson="noise\n")
    assert current_cli(interpreter, run, str(script), "--qnn-library x", **ok) == 1
    # pinned control bytes (no local artifact): wrong sha must retry
    run = write_run(tmp_path, meta_text(**shas))
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha="0" * 64) == 1
    assert current_cli(interpreter, run, str(script), "--qnn-library x",
                       clip=str(clip), require_sha=shas["model_sha"]) == 0
