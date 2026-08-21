#!/usr/bin/env python3
"""Route our fp32 sources through AI Hub's quantize service (plan 5.1).

Their published YOLOX-S w8a8 runs ~1.6x faster than our local export at
equal-or-worse score parity (htp-verification-20260821.md §4.2), so the
gap is export-side graph shaping, not quantization arithmetic — this
submits OUR raw-head sources (the plugin contract must survive, so
never their model-zoo definitions, which decode on-graph) to their
quantizer and pulls back QDQ ONNX for the same local gates + board leg
every artifact faces.

License boundary (Ben, 2026-08-21): AGPL sources ride the service for
LADDER TESTING ONLY — nothing that comes back enters git, images, or
packs. Auth comes from qualcomm.env's APITOKEN via `qai-hub configure`
(never committed; .gitignore covers the file).

  aihub_quantize.py submit   # upload calib datasets + submit jobs
  aihub_quantize.py fetch    # wait, download artifacts, write shas

State (dataset ids, job ids) checkpoints to aihub-ours/state.json so
either step can rerun without resubmitting; jobs are named after the
artifact they produce.
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out-20260820")
STATE_DIR = os.path.join(OUT, "aihub-ours")
STATE = os.path.join(STATE_DIR, "state.json")
ART_DIR = os.path.join(STATE_DIR, "artifacts")
CALIB = os.path.join(OUT, "calib")
CALIB_SAMPLES = 100

REPO_MODEL_DIR = os.path.normpath(
    os.path.join(HERE, "..", "..", "plugins", "cairn-detect", "model")
)
sys.path.insert(0, REPO_MODEL_DIR)
from quantize_model import describe, load_image_chw, preprocessing  # noqa: E402

import qai_hub as hub  # noqa: E402

# (source stem, activation widths). yolox holds a8 locally so both
# widths go; the yolov8-contract family gets a16 plus ONE a8 probe
# (yolo26n) — our a8 there is structurally dead (head Concat leaves 0
# score codes) and their published yolov8 w8a8 numbers are poor, so
# probing once answers "does their tooling handle it" without spending
# quota on four more likely-dead jobs.
MATRIX = [
    ("yolox_nano", ["a8", "a16"]),
    ("yolox_tiny", ["a8", "a16"]),
    ("yolox_s", ["a8", "a16"]),
    ("yolox_m", ["a8", "a16"]),
    ("yolo26n", ["a16", "a8"]),
    ("yolo26n-416", ["a16"]),
    ("yolo26s", ["a16"]),
    ("yolo26m", ["a16"]),
    ("yolov8n", ["a16"]),
]
DTYPE = {"a8": hub.QuantizeDtype.INT8, "a16": hub.QuantizeDtype.INT16}


def load_state():
    if os.path.exists(STATE):
        with open(STATE) as f:
            return json.load(f)
    return {"datasets": {}, "jobs": {}}


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(state, f, indent=1)


def calib_frames():
    import glob
    paths = sorted(glob.glob(os.path.join(CALIB, "*.png")))
    if not paths:
        raise SystemExit(f"no calibration frames in {CALIB}")
    if len(paths) <= CALIB_SAMPLES:
        return paths
    # Even spacing, not a floor-divided stride: a stride of 1 would upload
    # the first CALIB_SAMPLES sorted files and calibrate on part of the
    # clip-grouped corpus.
    n = CALIB_SAMPLES
    indices = [round(i * (len(paths) - 1) / (n - 1)) for i in range(n)]
    return [paths[i] for i in sorted(set(indices))]


def calib_digest(paths):
    """Identity of the SELECTED calibration inputs: file names and bytes.

    Without it, adding/removing/replacing a PNG reuses the previously
    uploaded dataset — and the job fingerprint downstream would then
    claim the calibration changed when it had not actually been
    re-uploaded."""
    import hashlib

    h = hashlib.sha256()
    for path in paths:
        h.update(os.path.basename(path).encode())
        with open(path, "rb") as f:
            h.update(f.read())
    return h.hexdigest()[:16]


def dataset_for(state, info, input_name):
    """Upload (once per distinct input set) the calibration dataset for a
    family x geometry."""
    frames = calib_frames()
    key = f"{info['layout']}-{info['width']}-{calib_digest(frames)}"
    if key in state["datasets"]:
        return hub.get_dataset(state["datasets"][key])
    prof = preprocessing(info["layout"])
    tensors = [
        load_image_chw(p, info["width"], info["height"],
                       prof["encoding"], prof["resize"], prof["pad"])
        for p in frames
    ]
    print(f"uploading dataset {key}: {len(tensors)} x {tensors[0].shape}")
    ds = hub.upload_dataset({input_name: [t.astype(np.float32) for t in tensors]},
                            name=f"cairn-calib-{key}-20260820")
    state["datasets"][key] = ds.dataset_id
    save_state(state)
    return ds


def sanitize(src, stem):
    """AI Hub's checker enforces IR strictness ORT does not: ultralytics
    exports list `output0` in value_info AND graph outputs, which fails
    every job server-side ("Tensors {'output0'} occur in value_info but
    also in model IO"). Strip value_info entries that duplicate IO
    names — a metadata-only change, the graph is untouched."""
    import onnx
    model = onnx.load(src)
    io_names = {i.name for i in model.graph.input} | {o.name for o in model.graph.output}
    dupes = [vi for vi in model.graph.value_info if vi.name in io_names]
    if not dupes:
        return src, model
    for vi in dupes:
        model.graph.value_info.remove(vi)
    out_dir = os.path.join(STATE_DIR, "sources-sanitized")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{stem}.onnx")
    onnx.save(model, path)
    return path, model


def submit():
    import onnxruntime as _  # noqa: F401  (fail early if env is broken)
    state = load_state()
    for stem, widths in MATRIX:
        src = os.path.join(OUT, "sources", f"{stem}.onnx")
        info = describe(src)
        src, model = sanitize(src, stem)
        input_name = model.graph.input[0].name
        ds = dataset_for(state, info, input_name)
        for width in widths:
            name = f"{stem}-aihub-{width}"
            # The job's identity is its INPUTS, not its name: a changed
            # source graph, calibration dataset or width must resubmit
            # rather than silently reuse a job quantized from old bytes.
            import hashlib
            with open(src, "rb") as f:
                src_sha = hashlib.sha256(f.read()).hexdigest()[:16]
            fingerprint = f"{src_sha}:{ds.dataset_id}:{width}"
            recorded = state["jobs"].get(name)
            if isinstance(recorded, dict) and recorded.get("fingerprint") == fingerprint:
                print(f"{name}: already submitted ({recorded['job_id']})")
                continue
            if recorded is not None:
                print(f"{name}: inputs changed — resubmitting")
            job = hub.submit_quantize_job(
                src, ds,
                weights_dtype=hub.QuantizeDtype.INT8,
                activations_dtype=DTYPE[width],
                name=name,
            )
            state["jobs"][name] = {"job_id": job.job_id, "fingerprint": fingerprint}
            save_state(state)
            print(f"{name}: submitted {job.job_id}")


def fetch():
    state = load_state()
    os.makedirs(ART_DIR, exist_ok=True)
    results = {}
    for name, recorded in state["jobs"].items():
        job_id = recorded["job_id"] if isinstance(recorded, dict) else recorded
        # Targets download as a zip (model.onnx + external model.data,
        # like the published assets); normalize to artifacts/<name>/.
        target_dir = os.path.join(ART_DIR, name)
        job_marker = os.path.join(target_dir, ".job")
        # The artifact is only "already fetched" if it came from THIS job:
        # a resubmit (changed inputs) records a new job id, and the bytes
        # downloaded for the superseded job must not satisfy it.
        if os.path.exists(os.path.join(target_dir, "model.onnx")):
            fetched_from = open(job_marker).read().strip() if os.path.exists(job_marker) else None
            if fetched_from == job_id:
                results[name] = "already fetched"
                continue
            results[name] = f"refetching (was {fetched_from or 'unrecorded'})"
            import shutil as _shutil
            _shutil.rmtree(target_dir)
        job = hub.get_job(job_id)
        status = job.wait()
        if not status.success:
            results[name] = f"FAILED: {status.message}"
            continue
        import glob as _glob
        import shutil
        import zipfile
        zip_path = job.download_target_model(os.path.join(ART_DIR, f"{name}.onnx"))
        tmp = os.path.join(ART_DIR, f"{name}-tmp")
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp)
        os.makedirs(target_dir, exist_ok=True)
        for f in _glob.glob(os.path.join(tmp, "*", "model.*")):
            shutil.move(f, os.path.join(target_dir, os.path.basename(f)))
        shutil.rmtree(tmp)
        os.remove(zip_path)
        with open(job_marker, "w") as f:
            f.write(job_id)
        results[name] = results.get(name) or "fetched"
    for name, r in sorted(results.items()):
        print(f"{name}: {r}")
    import glob as _glob
    import subprocess
    members = sorted(
        os.path.relpath(p, ART_DIR)
        for p in _glob.glob(os.path.join(ART_DIR, "*", "model.*"))
    )
    if members:
        sha = subprocess.run(["sha256sum", *members], cwd=ART_DIR,
                             capture_output=True, text=True).stdout
        with open(os.path.join(STATE_DIR, "artifacts.sha256"), "w") as f:
            f.write(sha)


if __name__ == "__main__":
    {"submit": submit, "fetch": fetch}[sys.argv[1]]()
