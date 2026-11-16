import hashlib
import json
import os
import subprocess
import sys

import pytest

import conftest

sha = lambda b: hashlib.sha256(b).hexdigest()


def run(tmp_path, **over):
    rungs, build = tmp_path / "rungs", tmp_path / "build"
    rungs.mkdir(); build.mkdir()
    (rungs / "yolox_s.onnx").write_bytes(b"twin")
    (rungs / "yolox_s_640_i8.rknn").write_bytes(b"rknn")
    j = {"steps": {"load": "ok", "export": "ok"}, "rknn_sha256": sha(b"rknn"), "source_sha256": sha(b"twin"),
         "toolkit": "2.3.2", "target_platform": "rk3566", "mode": "i8", "quantized_algorithm": "normal",
         "calib_set_id": "c", "calib_policy": "lb640_bgr"} | over
    j = {k: v for k, v in j.items() if v is not None}
    (build / "yolox_s_640_i8.json").write_text(json.dumps(j))
    p = subprocess.run([sys.executable, os.path.join(conftest.TOOL_DIR, "manifest.py"), str(rungs), str(build)],
                       capture_output=True, text=True)
    return p, sorted(f.name for f in rungs.iterdir() if f.name.startswith("MANIFEST"))


def test_matching_hash_writes_both_outputs(tmp_path):
    p, written = run(tmp_path)
    assert p.returncode == 0, p.stderr
    assert written == ["MANIFEST.json", "MANIFEST.sha256"]
    assert (tmp_path / "rungs/MANIFEST.sha256").read_text() == f"{sha(b'twin')}  yolox_s.onnx\n{sha(b'rknn')}  yolox_s_640_i8.rknn\n"


@pytest.mark.parametrize("over", [{"rknn_sha256": "0" * 64}, {"rknn_sha256": None},
                                  {"steps": {"load": "ok", "export": "ERR boom"}}, {"sim_outputs": "ERR boom"}])
def test_json_that_does_not_vouch_for_the_file_writes_nothing(tmp_path, over):
    p, written = run(tmp_path, **over)
    assert p.returncode != 0 and "yolox_s_640_i8.rknn" in p.stderr
    assert written == []
