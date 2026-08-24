"""Verdict paths of the campaign analyzer, on synthetic evidence.

The reference/HTP series are handed to analyze_run directly, so every
defect signature the analyzer exists to see (cap, offset, collapse,
miss-as-zero, non-finite data) is pinned without models or clips."""
import json
import math

from campaign_meta import file_sha256
from htp_report import analyze_run, latency_table, paired_one_to_one

QNN_META = (
    "backend: qnn profile: yolox insize: 416 sample_fps: 10 min_score: 0.05\n"
    "feed exited 0\n"
    "frame.objects lines: 41\n"
)


def ndjson_line(t, person):
    return json.dumps({
        "type": "frame.objects",
        "frame": {"pts": int(round(t * 90000))},
        "objects": [{"label": "person", "score": person}],
    })


def write_run(tmp_path, emissions, meta=QNN_META):
    run = tmp_path / "run"
    run.mkdir()
    noise = "QAIRT graph prepare 50%\n"  # non-JSON stdout noise is expected
    (run / "out.ndjson").write_text(
        noise + "".join(ndjson_line(t, p) + "\n" for t, p in emissions)
    )
    (run / "meta").write_text(meta)
    return str(run)


def ref(values):
    """(t, person, best) at the 5/s reference cadence."""
    return [(i * 0.2, v, v) for i, v in enumerate(values)]


CONFIDENT = [0.95] * 41  # 8 s window, enough pairs to certify


def emissions(values, step=1):
    return [(i * 0.2, v) for i, v in enumerate(values)][::step]


def test_pass(tmp_path):
    run = write_run(tmp_path, emissions([0.93] * 41))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT), expected_backend="qnn")
    assert r["verdict"] == "PASS"
    assert r["paired"] == 41


def test_cap_plateau(tmp_path):
    # Defect-1 signature: scores plateau under the reference maximum.
    run = write_run(tmp_path, emissions([0.60] * 41))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "CAP"


def test_offset_uniform_depression(tmp_path):
    # Defect-2 signature: every score multiplied by the same factor.
    varying = [0.55 + i * 0.01 for i in range(41)]
    run = write_run(tmp_path, emissions([v * 0.7 for v in varying]))
    r = analyze_run(run, ref(varying), ref(varying))
    assert r["verdict"] == "OFFSET"


def test_collapse_no_emissions_in_window(tmp_path):
    run = write_run(tmp_path, [(50.0, 0.9)])
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "COLLAPSE"


def test_insufficient_pairs(tmp_path):
    short = [0.95] * 11
    run = write_run(tmp_path, emissions([0.93] * 11))
    r = analyze_run(run, ref(short), ref(short))
    assert r["verdict"] == "INSUFFICIENT"


def test_misses_count_as_zeros(tmp_path):
    # The whole point of pairing from the reference timeline: an
    # emission-anchored comparison would see 21 perfect ratios and PASS.
    run = write_run(tmp_path, emissions([0.95] * 41, step=2))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["paired"] == 41
    assert r["below_half"] == 20
    assert r["verdict"] == "FAIL"


def test_score_fidelity_only_grades_covered_instants(tmp_path):
    # The board CPU-EP control cannot emit densely enough; gaps are
    # throughput, graded instants are the fidelity check.
    run = write_run(
        tmp_path, emissions([0.95] * 41, step=2),
        meta=QNN_META.replace("backend: qnn", "backend: ort"),
    )
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT),
                    score_fidelity_only=True, expected_backend="ort")
    assert r["verdict"] == "PASS"
    assert r["coverage"] == "21/41"


def test_nan_scores_are_suspect_not_gradable(tmp_path):
    # json.loads accepts NaN; every threshold below would compare False
    # both ways. Non-numbers must refuse grading, not pick a verdict.
    run = write_run(tmp_path, emissions([0.93] * 40) + [(8.0, math.nan)])
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "non-finite score values in fetched ndjson"


def test_nan_reference_is_suspect(tmp_path):
    run = write_run(tmp_path, emissions([0.93] * 41))
    broken = ref(CONFIDENT[:-1] + [math.nan])
    r = analyze_run(run, broken, ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "non-finite values in reference series"


def test_stale_evidence_and_backend(tmp_path):
    run = write_run(tmp_path, emissions([0.93] * 41))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT),
                    expected_shas={"model": "0" * 64})
    assert r["verdict"] == "STALE-EVIDENCE"
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT), expected_backend="ort")
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "meta does not record backend ort"


def test_truncated_meta_is_suspect(tmp_path):
    run = write_run(tmp_path, emissions([0.93] * 41),
                    meta="backend: qnn profile: yolox\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert "completion marker" in r["why"]


def test_paired_one_to_one_consumes_each_emission_once():
    row = (0.1, 0.9, 0.9)
    out = paired_one_to_one([0.0, 0.2], [row])
    assert list(out.values()) == [row]
    assert len(out) == 1


def test_latency_table_marker_and_staleness(tmp_path):
    runs = tmp_path / "runs"
    run = runs / "bench-100"
    run.mkdir(parents=True)
    (run / "meta").write_text(
        "model: /data/cairn-bench/artifacts-fixed/foo.onnx backend: qnn\n"
    )
    (run / "latency").write_text(
        "infer latency: backend=qnn n=50 p50=10.5ms p95=12.0ms (total 55)\n"
    )
    marker = tmp_path / ".latency-start"

    # no marker file: nothing is current, historical runs are not reported
    assert latency_table(str(runs), start_marker=str(marker)) == {}
    # marker after the run: still nothing
    marker.write_text("200")
    assert latency_table(str(runs), start_marker=str(marker)) == {}
    # marker before the run: reported
    marker.write_text("50")
    rows = latency_table(str(runs), start_marker=str(marker))
    assert rows[("foo", "qnn")]["p50_ms"] == 10.5

    # bench ran different bytes than the current artifact -> stale
    art_dir = tmp_path / "artifacts"
    art_dir.mkdir()
    (art_dir / "foo.onnx").write_bytes(b"current-bytes")
    pushed = tmp_path / "pushed.sha256"
    pushed.write_text("0" * 64 + " /data/cairn-bench/artifacts-fixed/foo.onnx\n")
    rows = latency_table(str(runs), start_marker=str(marker),
                         pushed_file=str(pushed), art_dir=str(art_dir))
    assert "stale" in rows[("foo", "qnn")]
    pushed.write_text(
        file_sha256(str(art_dir / "foo.onnx"))
        + " /data/cairn-bench/artifacts-fixed/foo.onnx\n"
    )
    rows = latency_table(str(runs), start_marker=str(marker),
                         pushed_file=str(pushed), art_dir=str(art_dir))
    assert "stale" not in rows[("foo", "qnn")]
