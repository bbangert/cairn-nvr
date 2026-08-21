#!/usr/bin/env python3
"""HTP-leg verdicts from fetched campaign evidence (phase 3.2/3.3).

The acceptance bar is HTP ~= CPU: the local CPU-EP parity numbers are
the reference (phase 2.3 already proved artifact-vs-fp32 there), so a
healthy rung's on-board score distribution must match its own CPU-EP
distribution on the same clip content. The two defect signatures this
exists to see:

  - a hard cap (defect 1, baked calibration ceiling): scores plateau at
    a value below the reference maximum;
  - a uniform multiplicative depression (defect 2, EP qparam rewrite
    disagreeing with the graph): ratios tightly clustered below 1.

Reference series are built locally: frames extracted from the pulled
clips at a fixed rate, run through fp32 + artifact on the CPU EP. The
HTP series comes from the fetched ndjson; pts is stream-anchored, so
pts/90000 is clip time directly (see htp_series — the feed played
once; on a looped feed pts wrap and this mapping would be garbage,
which is why the content test never loops).

  htp_report.py [--campaign-dir .../htp] [--ref-fps 5]
"""
import argparse
import collections
import glob
import json
import os
import re
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from score_parity import REPORTABLE, scores  # noqa: E402

REPO_MODEL_DIR = os.path.normpath(
    os.path.join(HERE, "..", "..", "plugins", "cairn-detect", "model")
)
sys.path.insert(0, REPO_MODEL_DIR)
from quantize_model import describe, load_image_chw, preprocessing  # noqa: E402

import onnxruntime as ort  # noqa: E402

# The shipped defective nano, byte-for-byte (same pin as
# run_htp_campaign.sh): the sensitivity control demonstrates the defect
# only if these exact bytes produced the evidence.
OLD_NANO_SHA = "e4bb2552c6f3c810ae6fc40686f6b4cac5e21eab885b868e6469a2c87098627d"

# rung -> (fp32 source stem, layout). Sources carry the family geometry;
# describe() reads the real input size from each model.
RUNGS = {
    "yolox_nano-qdq-a16": "yolox_nano",
    "yolox_tiny-qdq-a16": "yolox_tiny",
    "yolox_tiny-qdq-a8": "yolox_tiny",
    "yolox_s-qdq-a16": "yolox_s",
    "yolox_s-qdq-a8": "yolox_s",
    "yolox_m-qdq-a16": "yolox_m",
    "yolox_m-qdq-a8": "yolox_m",
    "yolo26n-qdq-a16": "yolo26n",
    "yolo26n-416-qdq-a16": "yolo26n-416",
    "yolo26s-qdq-a16": "yolo26s",
    "yolo26m-qdq-a16": "yolo26m",
    "yolov8n-qdq-a16": "yolov8n",
}
PAIR_TOLERANCE_S = 0.35
WINDOW_DILATE_S = 0.5


def extract_frames(clip_path, out_dir, fps):
    # The marker, not the jpgs, is what says extraction finished: an
    # interrupted ffmpeg leaves frames a bare glob would accept, and a
    # truncated reference timeline would then certify runs against part
    # of a clip. No marker -> wipe and redo.
    marker = os.path.join(out_dir, ".complete")
    if os.path.exists(marker):
        return
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", clip_path,
         "-vf", f"fps={fps}", "-qscale:v", "2",
         os.path.join(out_dir, "f_%05d.jpg")],
        check=True,
    )
    with open(marker, "w") as f:
        f.write(f"{clip_path} @ {fps} fps\n")


def file_sha256(path):
    """Full sha256 of a file's bytes — matched verbatim against the
    board meta's sha256sum lines."""
    import hashlib

    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def model_digest(model_path):
    """Twelve hex chars of the artifact's bytes — the cache's identity.

    The stem alone is a trap this campaign is specifically about: an
    artifact REBUILT under the same filename must never inherit the old
    bytes' scores from a warm cache.
    """
    import hashlib

    h = hashlib.sha256()
    with open(model_path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def cpu_series(model_path, frame_dir, fps, cache_dir):
    """Per-frame (t, person max, best max) on the CPU EP, cached."""
    stem = os.path.splitext(os.path.basename(model_path))[0]
    cache = os.path.join(
        cache_dir,
        f"{stem}-{model_digest(model_path)}-{os.path.basename(frame_dir)}-{fps:g}.json",
    )
    if os.path.exists(cache):
        with open(cache) as f:
            return json.load(f)
    info = describe(model_path)
    layout, w, h = info["layout"], info["width"], info["height"]
    prof = preprocessing(layout)
    sess = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    series = []
    for i, path in enumerate(sorted(glob.glob(os.path.join(frame_dir, "*.jpg")))):
        tensor = load_image_chw(path, w, h, prof["encoding"], prof["resize"], prof["pad"])
        out = sess.run(None, {name: tensor})[0]
        best, person = scores(out, layout)
        series.append((i / fps, float(person.max()), float(best.max())))
    with open(cache, "w") as f:
        json.dump(series, f)
    return series


def htp_series(ndjson_path):
    """(t, person max, best max) per frame.objects line.

    pts is already stream-anchored (verified on-board: the person's first
    frame lands at 4.999s exactly where the fp32 reference has them at
    5.0s), so pts/90000 IS clip time. Do NOT p0-normalize on the first
    emitted line: frames without objects emit nothing, so on a clip with
    an empty head that anchor is the first detection, not the stream
    start, and every window comparison lands ~5s early.

    Non-JSON lines are expected, not tolerated-just-in-case: QAIRT's
    graph-prepare progress prints to the plugin's stdout between the
    ndjson lines on QNN runs.
    """
    series = []
    with open(ndjson_path) as f:
        for line in f:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("type") != "frame.objects":
                continue
            pts = msg["frame"]["pts"] if "frame" in msg else msg["pts"]
            objs = msg["objects"]
            person = max((o["score"] for o in objs if o["label"] == "person"), default=0.0)
            best = max((o["score"] for o in objs), default=0.0)
            series.append((pts / 90000.0, person, best))
    return series


def person_windows(fp32_series):
    """Merged, dilated t-ranges where fp32 person clears the floor."""
    spans = []
    for t, person, _ in fp32_series:
        if person >= REPORTABLE:
            lo, hi = t - WINDOW_DILATE_S, t + WINDOW_DILATE_S
            if spans and lo <= spans[-1][1]:
                spans[-1][1] = hi
            else:
                spans.append([lo, hi])
    return spans


def in_windows(t, spans):
    return any(lo <= t <= hi for lo, hi in spans)


def nearest(t, series):
    if not series:
        return None
    best = min(series, key=lambda row: abs(row[0] - t))
    return best if abs(best[0] - t) <= PAIR_TOLERANCE_S else None


# A PASS below this many paired frames certifies nothing: one lucky match
# in a truncated run must read as an incomplete run, not a healthy rung.
MIN_PAIRED = 20


def run_suspect(run_dir):
    """The content test's own verdict on its run, from the fetched meta.

    htp_content_test.sh records a non-EOF plugin exit and the feed's exit
    there and nowhere else — an analyzer that never reads it would grade
    truncated runs as if they were complete.
    """
    meta = os.path.join(run_dir, "meta")
    if not os.path.exists(meta):
        return "no meta fetched"
    for line in open(meta):
        if "run suspect" in line:
            return line.strip()
        if line.startswith("feed exited") and not line.rstrip().endswith(" 0"):
            return line.strip()
    return None


def stale_evidence(run_dir, expected_shas):
    """The board script wrote the model's and clip's sha256 into meta;
    evidence under the right directory name but from different bytes
    must not be graded against today's references."""
    if not expected_shas:
        return None
    meta = os.path.join(run_dir, "meta")
    if not os.path.exists(meta):
        return "no meta fetched"
    text = open(meta).read()
    for label, sha in expected_shas.items():
        if sha and sha not in text:
            return f"meta does not record the current {label} sha ({sha[:12]}…)"
    return None


def analyze_run(run_dir, ref_cpu, ref_fp32, expected_shas=None):
    """Verdict for one content run against its two reference series."""
    nd = os.path.join(run_dir, "out.ndjson")
    if not os.path.exists(nd):
        return {"verdict": "NO-DATA", "why": "no ndjson fetched"}
    suspect = run_suspect(run_dir)
    if suspect:
        return {"verdict": "SUSPECT", "why": suspect}
    stale = stale_evidence(run_dir, expected_shas)
    if stale:
        return {"verdict": "STALE-EVIDENCE", "why": stale}
    htp = htp_series(nd)
    if not htp:
        return {"verdict": "NO-DATA", "why": "no frame.objects lines"}
    spans = person_windows(ref_fp32)
    if not spans:
        return {"verdict": "NO-WINDOW", "why": "fp32 never confident on this clip"}

    # Paired from the REFERENCE timeline, not the HTP's: the content
    # format emits nothing for an empty frame, so an artifact that MISSES
    # the person outright leaves no HTP row to pair — iterating HTP
    # emissions would silently drop every miss from the median. A
    # ref-confident instant with no HTP emission nearby is a zero, which
    # is what a miss is.
    pairs = []  # (htp person, cpu-ref person, fp32 person)
    for t, f_person, _ in ref_fp32:
        if f_person < REPORTABLE:
            continue
        c = nearest(t, ref_cpu)
        if not c:
            continue
        h = nearest(t, htp)
        pairs.append((h[1] if h else 0.0, c[1], f_person))
    window_htp = [p for p, _, _ in pairs]
    result = {
        "windows_s": round(sum(hi - lo for lo, hi in spans), 1),
        "paired": len(pairs),
        "htp_all_max": round(max(p for _, p, _ in htp), 3),
    }
    if not pairs:
        # The subject was there (fp32 saw it) and the HTP emitted nothing
        # pairable — that is Ben's return walk, not a tooling gap.
        result.update({"verdict": "COLLAPSE", "why": "no HTP detections inside person windows"})
        return result

    ratios_cpu = np.array([p / c for p, c, _ in pairs if c > 0])
    if ratios_cpu.size == 0:
        # fp32 confident but the artifact's own CPU-EP run has nothing —
        # a CPU-side collapse (the score_parity gate's territory); grade
        # it as such rather than let np.median run on an empty array.
        result.update({"verdict": "COLLAPSE",
                       "why": "CPU-EP reference <= 0 on every paired frame (artifact collapse, not an HTP defect)"})
        return result
    med = float(np.median(ratios_cpu))
    iqr = float(np.subtract(*np.percentile(ratios_cpu, [75, 25])))
    below_half = int((ratios_cpu < 0.5).sum())
    htp_max = max(window_htp)
    ref_max = max(c for _, c, _ in pairs)
    top = sorted(window_htp)[-max(3, len(window_htp) // 10):]
    plateau = float(np.std(top)) < 0.005 and htp_max < 0.93 * ref_max

    result.update({
        "htp_band": f"{min(window_htp):.3f}-{max(window_htp):.3f}",
        "ref_band": f"{min(c for _, c, _ in pairs):.3f}-{ref_max:.3f}",
        "median_ratio_vs_cpu": round(med, 3),
        "ratio_iqr": round(iqr, 3),
        "below_half": below_half,
    })
    if len(pairs) < MIN_PAIRED:
        result["verdict"] = "INSUFFICIENT"
        result["why"] = f"only {len(pairs)} paired frames (< {MIN_PAIRED})"
    elif htp_max <= 0.0:
        # An all-zero person series has a zero-std top and would satisfy
        # the plateau test — and CAP is exactly what the sensitivity
        # control must grade, so a dead detector could otherwise
        # validate the campaign.
        result["verdict"] = "COLLAPSE"
        result["why"] = "no HTP person detection in any paired reference window"
    elif med >= 0.9 and below_half <= len(pairs) // 10 and not plateau:
        result["verdict"] = "PASS"
    elif plateau:
        result["verdict"] = "CAP"
        result["why"] = f"plateau at {htp_max:.3f} vs ref max {ref_max:.3f} (defect-1 signature)"
    elif med < 0.9 and iqr < 0.1:
        result["verdict"] = "OFFSET"
        result["why"] = f"uniform x{med:.2f} depression (defect-2 signature)"
    else:
        result["verdict"] = "FAIL"
        result["why"] = f"median ratio {med:.2f}, {below_half}/{len(pairs)} below 0.5x"
    return result


def latency_table(runs_dir):
    rows = {}
    line_re = re.compile(
        r"infer latency: backend=(\S+) n=\d+ p50=([\d.]+)ms p95=([\d.]+)ms \(total (\d+)\)"
    )
    for run in sorted(glob.glob(os.path.join(runs_dir, "*"))):
        model, backend = None, None
        meta = os.path.join(run, "meta")
        if os.path.exists(meta):
            for line in open(meta):
                m = re.match(r"model: (\S+) backend: (\S+)", line)
                if m:
                    model = os.path.splitext(os.path.basename(m.group(1)))[0]
                    backend = m.group(2)
        last = None
        lat = os.path.join(run, "latency")
        if os.path.exists(lat):
            for line in open(lat):
                m = line_re.search(line)
                if m:
                    last = m
        if model and last:
            rows[(model, backend)] = {
                "p50_ms": float(last.group(2)),
                "p95_ms": float(last.group(3)),
                "runs": int(last.group(4)),
            }
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--campaign-dir", default=os.path.join(HERE, "out-20260820", "htp"))
    ap.add_argument("--ref-fps", type=float, default=5.0)
    args = ap.parse_args()
    htp_dir = args.campaign_dir
    out_root = os.path.dirname(htp_dir)
    clips_dir = os.path.join(out_root, "clips")
    ref_dir = os.path.join(htp_dir, "ref")
    os.makedirs(ref_dir, exist_ok=True)

    clip_names = [
        os.path.splitext(os.path.basename(p))[0].replace("clip-", "")
        for p in sorted(glob.glob(os.path.join(clips_dir, "clip-*.mp4")))
    ]
    if not clip_names:
        # Without the reference corpus every loop below runs zero times and
        # an empty report would exit green — the exact hollow success this
        # analyzer exists to refuse.
        raise SystemExit(f"no clip-*.mp4 in {clips_dir} — nothing to analyze against")

    clip_shas = {
        c: file_sha256(os.path.join(clips_dir, f"clip-{c}.mp4")) for c in clip_names
    }

    def frames_dir(c):
        # fps AND the clip's content digest in the name: frames from a
        # previous --ref-fps or from different clip bytes under the same
        # filename must not serve this run — the CPU caches inherit the
        # same identity through the dirname.
        return os.path.join(
            ref_dir, f"frames-{c}-{clip_shas[c][:12]}-{args.ref_fps:g}"
        )

    for c in clip_names:
        extract_frames(
            os.path.join(clips_dir, f"clip-{c}.mp4"), frames_dir(c), args.ref_fps,
        )

    content = os.path.join(htp_dir, "content")
    report = [
        "# HTP verification report",
        "",
        "Acceptance: HTP ~= the artifact's own CPU-EP distribution on the",
        "same content (median per-frame person ratio >= 0.9 in the fp32",
        "person windows, no cap plateau, no uniform depression).",
        "",
        "| rung | clip | paired | HTP band | CPU-ref band | med ratio | verdict |",
        "|---|---|---|---|---|---|---|",
    ]
    verdicts = collections.defaultdict(list)
    for rung, src in RUNGS.items():
        art = os.path.join(out_root, "artifacts", f"{rung}.onnx")
        fp32 = os.path.join(out_root, "sources", f"{src}.onnx")
        art_sha = file_sha256(art) if os.path.exists(art) else None
        for c in clip_names:
            run_dir = os.path.join(content, f"{rung}-qnn-{c}")
            if not os.path.isdir(run_dir):
                # An unfetched run must cost the rung its clean sweep — a
                # silently skipped clip lets a partial fetch read as PASS,
                # and a wholly missing rung would vanish from the report.
                verdicts[rung].append("NO-DATA")
                report.append(f"| {rung} | {c} | - | - | - | - | **NO-DATA** — run not fetched |")
                continue
            frames = frames_dir(c)
            r = analyze_run(
                run_dir,
                cpu_series(art, frames, args.ref_fps, ref_dir),
                cpu_series(fp32, frames, args.ref_fps, ref_dir),
                expected_shas={"model": art_sha, "clip": clip_shas[c]},
            )
            verdicts[rung].append(r["verdict"])
            report.append(
                f"| {rung} | {c} | {r.get('paired', 0)} | {r.get('htp_band', '-')} "
                f"| {r.get('ref_band', '-')} | {r.get('median_ratio_vs_cpu', '-')} "
                f"| **{r['verdict']}**{' — ' + r['why'] if 'why' in r else ''} |"
            )

    report += ["", "## Controls", ""]
    controls_missing = []
    controls_invalid = []
    ort_ctl = os.path.join(content, "yolox_nano-qdq-a16-ort-ac86")
    if not os.path.isdir(ort_ctl):
        controls_missing.append("board CPU-EP control")
        report.append("- board CPU-EP control: **NO-DATA** — run missing; nothing ties board decode+sampling to the local reference.")
    if os.path.isdir(ort_ctl):
        frames = frames_dir("ac86")
        art = os.path.join(out_root, "artifacts", "yolox_nano-qdq-a16.onnx")
        fp32 = os.path.join(out_root, "sources", "yolox_nano.onnx")
        r = analyze_run(ort_ctl, cpu_series(art, frames, args.ref_fps, ref_dir),
                        cpu_series(fp32, frames, args.ref_fps, ref_dir),
                        expected_shas={"model": file_sha256(art) if os.path.exists(art) else None,
                                       "clip": clip_shas.get("ac86")})
        if r["verdict"] != "PASS":
            controls_invalid.append(
                f"board CPU-EP control graded {r['verdict']} (must PASS)"
            )
        report.append(
            f"- board CPU-EP control (nano-a16, ac86): **{r['verdict']}** "
            f"{r.get('htp_band', '')} vs ref {r.get('ref_band', '')} — this run "
            "ties board decode+sampling to the local reference; anything but "
            "PASS is a methodology problem, not a model problem."
        )
    old_ctl = os.path.join(content, "control-old-nano-a16-qnn-ac86")
    if not os.path.isdir(old_ctl):
        controls_missing.append("defective-nano sensitivity control")
        report.append("- defective-nano sensitivity control: **NO-DATA** — run missing; the test's ability to SEE the defect class is unproven.")
    if os.path.isdir(old_ctl):
        frames = frames_dir("ac86")
        art = os.path.join(out_root, "artifacts", "yolox_nano-qdq-a16.onnx")
        fp32 = os.path.join(out_root, "sources", "yolox_nano.onnx")
        # The defective control's bytes are pinned, not derived from a
        # local file: only the shipped defective nano demonstrates the
        # defect, and different bytes at the board path (or stale
        # evidence) must void the CAP, not satisfy it.
        r = analyze_run(old_ctl, cpu_series(art, frames, args.ref_fps, ref_dir),
                        cpu_series(fp32, frames, args.ref_fps, ref_dir),
                        expected_shas={"model": OLD_NANO_SHA,
                                       "clip": clip_shas.get("ac86")})
        # The control is valid ONLY if it reproduces the known defect's
        # signature. "Anything but PASS" would let NO-DATA / SUSPECT /
        # STALE-EVIDENCE / INSUFFICIENT — a broken or truncated control
        # run — count as the test demonstrably seeing the defect class.
        if r["verdict"] != "CAP":
            controls_invalid.append(
                f"defective-nano control graded {r['verdict']} "
                "(expected CAP — the known defect signature was not reproduced)"
            )
        report.append(
            f"- shipped defective nano (sensitivity control): **{r['verdict']}** "
            f"{r.get('htp_band', '')} {r.get('why', '')} — must grade CAP "
            "(the baked-ceiling signature); anything else means the test did "
            "not demonstrably see the defect class."
        )

    lat = latency_table(os.path.join(htp_dir, "runs"))
    if lat:
        report += ["", "## Latency (bench.sh, 1 cam, governor pinned)", "",
                   "| rung | backend | p50 ms | p95 ms | runs/60s |", "|---|---|---|---|---|"]
        for (model, backend), row in sorted(lat.items()):
            report.append(
                f"| {model} | {backend} | {row['p50_ms']} | {row['p95_ms']} | {row['runs']} |"
            )

    if controls_missing or controls_invalid:
        problems = [f"missing {c}" for c in controls_missing] + controls_invalid
        report.append(
            "- **CAMPAIGN NOT CERTIFIABLE**: " + "; ".join(problems)
            + " — rung verdicts above stand on an unvalidated methodology."
        )

    report += ["", "## Per-rung verdicts", ""]
    for rung, vs in verdicts.items():
        agg = "PASS" if all(v == "PASS" for v in vs) else "/".join(vs)
        report.append(f"- {rung}: {agg}")

    out = os.path.join(htp_dir, "report.md")
    with open(out, "w") as f:
        f.write("\n".join(report) + "\n")
    print("\n".join(report))
    print(f"\nwritten: {out}")


if __name__ == "__main__":
    main()
