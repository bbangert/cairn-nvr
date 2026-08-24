"""Verdict paths of the campaign analyzer, on synthetic evidence.

The reference/HTP series are handed to analyze_run directly, so every
defect signature the analyzer exists to see (cap, offset, collapse,
miss-as-zero, non-finite data) is pinned without models or clips."""
import json
import math

import pytest

from campaign_meta import file_sha256
from htp_report import analyze_run, cpu_series, latency_table, model_digest, paired_one_to_one
from test_campaign_meta import meta_text

# Writer-shaped metas (test_campaign_meta.meta_text mirrors
# htp_content_test.sh line by line) so the analyzer is never tested
# against a meta no board could have written.
QNN_META = meta_text()


def ndjson_line(t, person):
    return json.dumps({
        "type": "frame.objects",
        "frame": {"pts": int(round(t * 90000))},
        "objects": [{"label": "person", "score": person}],
    })


def write_run(tmp_path, emissions, meta=None):
    run = tmp_path / "run"
    run.mkdir()
    noise = "QAIRT graph prepare 50%\n"  # non-JSON stdout noise is expected
    (run / "out.ndjson").write_text(
        noise + "".join(ndjson_line(t, p) + "\n" for t, p in emissions)
    )
    if meta is None:
        # the writer's count matches what it wrote; tests probing the
        # count cross-check pass an explicit meta
        meta = meta_text(frames=len(emissions))
    (run / "meta").write_text(meta)
    return str(run)


def ref(values):
    """(t, person, best) at the 5/s reference cadence."""
    return [(i * 0.2, v, v) for i, v in enumerate(values)]


# 41 instants = 8 s at the 5/s reference cadence — comfortably above
# MIN_PAIRED=20 so certification-path tests are not INSUFFICIENT.
CONFIDENT = [0.95] * 41


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
    # Defect-2 signature: every score multiplied by the same factor. The
    # ramp keeps the top-4 window std at ~0.0078 — above the 0.005
    # plateau threshold, so this cannot misread as CAP (ratio iqr is 0,
    # which is what selects OFFSET).
    varying = [0.55 + i * 0.01 for i in range(41)]
    run = write_run(tmp_path, emissions([v * 0.7 for v in varying]))
    r = analyze_run(run, ref(varying), ref(varying))
    assert r["verdict"] == "OFFSET"


def test_collapse_zero_person_in_all_paired_windows(tmp_path):
    # An emission far outside the person windows still pairs-as-zero at
    # every reference instant, landing in the htp_max <= 0 branch — the
    # one that keeps a dead detector from validating via plateau logic.
    run = write_run(tmp_path, [(50.0, 0.9)])
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "COLLAPSE"
    assert r["why"] == "no HTP person detection in any paired reference window"


def test_collapse_when_nothing_pairs(tmp_path):
    # No CPU reference rows near any confident instant -> zero pairs.
    run = write_run(tmp_path, emissions([0.93] * 41))
    r = analyze_run(run, [], ref(CONFIDENT))
    assert r["verdict"] == "COLLAPSE"
    assert r["why"] == "no HTP detections inside person windows"


def test_collapse_cpu_reference_all_zero(tmp_path):
    # fp32 confident but the artifact's own CPU-EP run reads zero on
    # every paired frame: the guard that keeps np.median off an empty
    # array, graded as a CPU-side artifact collapse.
    run = write_run(tmp_path, emissions([0.93] * 41))
    r = analyze_run(run, ref([0.0] * 41), ref(CONFIDENT))
    assert r["verdict"] == "COLLAPSE"
    assert r["why"].startswith("CPU-EP reference <= 0")


def test_mostly_zero_cpu_reference_is_insufficient(tmp_path):
    # MIN_PAIRED must bind the ratios the median runs on: 40 zero-
    # reference rows plus ONE positive would otherwise grade the rung on
    # a single lucky ratio — one match certifying nothing.
    run = write_run(tmp_path, emissions([0.93] * 41))
    r = analyze_run(run, ref([0.0] * 40 + [0.95]), ref(CONFIDENT))
    assert r["verdict"] == "INSUFFICIENT"
    assert "positive CPU reference" in r["why"]


def test_no_data_paths(tmp_path):
    run = tmp_path / "empty-run"
    run.mkdir()
    (run / "meta").write_text(QNN_META)
    r = analyze_run(str(run), ref(CONFIDENT), ref(CONFIDENT))
    assert r == {"verdict": "NO-DATA", "why": "no ndjson fetched"}
    # noise-only ndjson: fetched, but zero frame.objects lines
    run2 = write_run(tmp_path, [])
    r = analyze_run(run2, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "NO-DATA"
    assert r["why"] == "no frame.objects lines"


def test_insufficient_pairs(tmp_path):
    short = [0.95] * 11
    run = write_run(tmp_path, emissions([0.93] * 11))
    r = analyze_run(run, ref(short), ref(short))
    assert r["verdict"] == "INSUFFICIENT"


def test_misses_count_as_zeros(tmp_path):
    # The whole point of pairing from the reference timeline: an
    # emission-anchored comparison would see 21 perfect ratios and PASS.
    # step=2 emits at even instants only; the 20 odd instants are misses,
    # each a zero ratio -> below_half == 20.
    run = write_run(tmp_path, emissions([0.95] * 41, step=2))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["paired"] == 41
    assert r["below_half"] == 20
    assert r["verdict"] == "FAIL"


def test_score_fidelity_only_grades_covered_instants(tmp_path):
    # The board CPU-EP control cannot emit densely enough; gaps are
    # throughput, graded instants are the fidelity check.
    run = write_run(tmp_path, emissions([0.95] * 41, step=2),
                    meta=meta_text(backend="ort", frames=21))
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
    assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_malformed_pts_is_suspect_not_a_crash(tmp_path):
    # A boolean pts would become a finite float through /90000.0 and join
    # the pairing timeline; an overlarge int raises in the division.
    # Both must grade, matching the retry guard's rejection.
    for name, pts in (("boolpts", True), ("hugepts", 10 ** 400)):
        base = tmp_path / name
        base.mkdir()
        run = write_run(base, emissions([0.93] * 40))
        bad = json.dumps({"type": "frame.objects", "frame": {"pts": pts},
                          "objects": [{"label": "person", "score": 0.9}]})
        with open(f"{run}/out.ndjson", "a") as f:
            f.write(bad + "\n")
        r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
        assert r["verdict"] == "SUSPECT", name
        assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_nan_hidden_behind_max_is_still_suspect(tmp_path):
    # max(0.9, nan) keeps 0.9 — a poisoned frame whose NaN sits after a
    # clean score would reduce to a clean number and grade PASS if raw
    # values were not validated before reduction.
    run = write_run(tmp_path, emissions([0.93] * 41))
    bad = json.dumps({"type": "frame.objects", "frame": {"pts": 720000},
                      "objects": [{"label": "person", "score": 0.9},
                                  {"label": "person", "score": math.nan}]})
    with open(f"{run}/out.ndjson", "a") as f:
        f.write(bad + "\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"


def test_out_of_range_score_is_suspect(tmp_path):
    # 0..1 is the plugin contract; a 1.5 is corrupted evidence, not a
    # strong detection — unguarded it could even lift a verdict to PASS.
    run = write_run(tmp_path, emissions([0.93] * 41))
    bad = json.dumps({"type": "frame.objects", "frame": {"pts": 720000},
                      "objects": [{"label": "person", "score": 1.5}]})
    with open(f"{run}/out.ndjson", "a") as f:
        f.write(bad + "\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"


def test_frame_count_mismatch_is_suspect(tmp_path):
    # A complete meta beside an ndjson truncated mid-transfer: grading it
    # would count the missing tail as real misses (a FAIL verdict on
    # genuinely good evidence).
    run = write_run(tmp_path, emissions([0.93] * 41), meta=meta_text(frames=55))
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "41 frame messages in ndjson but meta recorded 55 (truncated fetch)"


def test_invalid_encoding_is_suspect_not_a_crash(tmp_path):
    # Bytes that don't decode are corrupted evidence — the strict read
    # must land in a verdict, not a UnicodeDecodeError aborting the
    # report; the retry guard rejects the same file as not-current.
    run = write_run(tmp_path, emissions([0.93] * 41))
    with open(f"{run}/out.ndjson", "ab") as f:
        f.write(b"\xff\xfe binary noise\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "invalid encoding in fetched ndjson"


def test_non_list_objects_is_suspect_not_an_empty_frame(tmp_path):
    # {"objects": {}} iterates zero times — unguarded, corruption reduces
    # to a valid empty frame and grades as a real miss.
    run = write_run(tmp_path, emissions([0.93] * 40))
    bad = json.dumps({"type": "frame.objects", "frame": {"pts": 720000},
                      "objects": {}})
    with open(f"{run}/out.ndjson", "a") as f:
        f.write(bad + "\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_bare_scalar_json_line_is_noise(tmp_path):
    # QAIRT noise can be a bare number, which json.loads happily parses;
    # it is stdout noise like any unparseable line, not frame evidence.
    run = write_run(tmp_path, emissions([0.93] * 41))
    with open(f"{run}/out.ndjson", "a") as f:
        f.write("5\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "PASS"


def test_mixed_type_scores_are_suspect_not_a_crash(tmp_path):
    # A frame mixing numeric and string scores makes max() raise inside
    # htp_series — before any finite check sees the values.
    run = write_run(tmp_path, emissions([0.93] * 40))
    bad = json.dumps({"type": "frame.objects", "frame": {"pts": 720000},
                      "objects": [{"label": "person", "score": 0.9},
                                  {"label": "person", "score": "bad"}]})
    with open(f"{run}/out.ndjson", "a") as f:
        f.write(bad + "\n")
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_boolean_score_is_suspect(tmp_path):
    # json `true` where a score belongs: bool subclasses int, so without
    # the explicit rejection it would grade numerically as 1.
    run = write_run(tmp_path, emissions([0.93] * 40) + [(8.0, True)])
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_overlarge_int_score_is_suspect(tmp_path):
    # json.loads yields a python int too large for float conversion;
    # the guard must grade it, not leak an OverflowError.
    run = write_run(tmp_path, emissions([0.93] * 40) + [(8.0, 10 ** 400)])
    r = analyze_run(run, ref(CONFIDENT), ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "malformed frame.objects message in fetched ndjson"


def test_nan_reference_is_suspect(tmp_path):
    # Backstop for series handed to analyze_run directly; the primary
    # gate is cpu_series aborting at the source (next test).
    run = write_run(tmp_path, emissions([0.93] * 41))
    broken = ref(CONFIDENT[:-1] + [math.nan])
    r = analyze_run(run, broken, ref(CONFIDENT))
    assert r["verdict"] == "SUSPECT"
    assert r["why"] == "non-finite values in reference series"


def test_poisoned_reference_cache_aborts_once(tmp_path):
    # A NaN in the LOCAL reference (model/runner breakage) must abort the
    # whole report naming the cache — not grade N board runs SUSPECT
    # while the poisoned cache silently survives regenerations.
    model = tmp_path / "m.onnx"
    model.write_bytes(b"model-bytes")
    frames = tmp_path / "frames-x"
    frames.mkdir()
    cache = tmp_path / f"m-{model_digest(str(model))}-frames-x-5.json"
    cache.write_text("[[0.0, NaN, 0.5]]")
    with pytest.raises(SystemExit, match="reference tooling failure"):
        cpu_series(str(model), str(frames), 5, str(tmp_path))


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
    # Verbatim writer formats: bench.sh's meta line carries trailing
    # fields, and the plugin always prints two decimals.
    (run / "meta").write_text(
        "model: /data/cairn-bench/artifacts-fixed/foo.onnx backend: qnn ncams: 1 secs: 60 sample_fps: 30\n"
    )
    (run / "latency").write_text(
        "infer latency: backend=qnn n=50 p50=10.50ms p95=12.00ms (total 55)\n"
    )
    marker = tmp_path / ".latency-start"

    # no marker file: nothing is current, historical runs are not reported
    assert latency_table(str(runs), start_marker=str(marker)) == {}
    # empty and garbage markers must fail CLOSED exactly like a missing
    # one — start=0 would publish every historical run as current
    marker.write_text("")
    assert latency_table(str(runs), start_marker=str(marker)) == {}
    marker.write_text("not-an-epoch")
    assert latency_table(str(runs), start_marker=str(marker)) == {}
    # undecodable marker bytes: same fail-closed answer, not an abort
    marker.write_bytes(b"\xff\xfe")
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
