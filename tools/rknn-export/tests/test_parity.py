import numpy as np
import pytest
from pytest import approx

import parity

NA = 84  # S=64: 64 anchors at stride 8, 16 at stride 16, 4 at stride 32


def yolox(pos, base=0.1):
    """pos: anchor -> (obj, cls_idx, cls_val, box4); everything else is base/base."""
    t = np.zeros((1, NA, 85))
    t[0, :, 4] = base
    t[0, :, 5:] = base
    for a, (obj, c, v, box) in pos.items():
        t[0, a, 4] = obj
        t[0, a, 5:] = base
        t[0, a, 5 + c] = v
        t[0, a, :4] = box
    return [t.astype(np.float32)]


Z = (0, 0, 0, 0)
REF = {3: (0.9, 0, 0.9, Z), 70: (0.8, 5, 0.9, Z), 82: (0.7, 0, 0.8, Z)}
SIM = {3: (0.8, 0, 0.9, (0.5, 0, 0, 0)),          # person, 0.5 cell off in x at stride 8
       70: (0.1, 5, 0.9, (0, 0.25, 0, 0)),         # non-person, missed
       82: (0.5, 0, 0.8, (0, 0, np.log(2), 0)),    # person, w doubled at stride 32
       10: (0.85, 1, 0.8, Z)}                      # sim-only false positive


def test_yolox_single_frame():
    a = parity.Acc("yolox")
    a.add("g", yolox(SIM), yolox(REF))
    r = a.result()["g"]
    assert r["score"]["n_ref"] == 3
    assert r["score"]["recall"] == approx(2 / 3)
    assert r["score"]["mean_abs_dscore"] == approx((0.09 + 0.63 + 0.16) / 3)
    assert r["score"]["n_sim"] == 3
    assert r["score"]["max_ref"] == approx(0.81)
    assert r["score"]["max_sim"] == approx(0.72)
    assert r["person"]["n_ref"] == 2
    assert r["person"]["recall"] == 1.0
    assert r["person"]["mean_abs_dscore"] == approx(0.125)
    assert r["person"]["n_sim"] == 2
    # 0.5 cell x 8px, 0.25 cell y x 16px, |2-1| x 32px, over 3 anchors x 4 terms
    assert r["box_err_px"] == approx((4 + 4 + 32) / 12)
    assert r["score_step"] == approx(0.05)
    assert r["cos"]["out0"] < 1


def test_yolox_identical_is_perfect():
    a = parity.Acc("yolox")
    a.add("g", yolox(REF), yolox(REF))
    r = a.result()["g"]
    assert r["cos"]["out0"] == approx(1) and r["score"]["recall"] == 1 and r["box_err_px"] == 0


def test_pooled_not_averaged_and_groups_separate():
    one = {3: (0.9, 0, 0.9, Z)}
    three = {3: (0.9, 0, 0.9, Z), 20: (0.9, 0, 0.9, Z), 30: (0.9, 0, 0.9, Z)}
    miss = {3: (0.9, 0, 0.9, Z)}  # sim finds only the first of the three
    a = parity.Acc("yolox")
    a.add("A", yolox(one), yolox(one))
    a.add("B", yolox(miss), yolox(three))
    r = a.result()
    assert r["A"]["score"]["recall"] == 1
    assert r["B"]["score"]["recall"] == approx(1 / 3)
    assert r["all"]["score"]["n_ref"] == 4
    assert r["all"]["score"]["recall"] == approx(2 / 4)  # per-frame means would give 2/3
    assert r["all"]["n_frames"] == 2 and r["A"]["n_frames"] == 1


def split(g_pos, reg_max=16, nc=3):
    """g_pos: stride index -> (y, x, cls, score, box_bin, shift); baseline score 0.05."""
    out = []
    for k in range(3):
        g = 8 >> k
        box = np.zeros((1, 4 * reg_max, g, g), np.float32)
        cls = np.full((1, nc, g, g), 0.05, np.float32)
        if reg_max == 1:
            box[:] = 1.0
        for y, x, c, v, b, sh in g_pos.get(k, []):
            cls[0, :, y, x] = 0.05
            cls[0, c, y, x] = v
            if reg_max == 1:
                box[0, 0, y, x] = 1.0 + sh
            else:
                box[0, :16, y, x] = -20
                box[0, b + sh, y, x] = 20
                box[0, 16:, y, x] = 0
        out += [box, cls, cls.sum(1, keepdims=True)]
    return out


def test_split_per_stride_and_pooled():
    ref = split({0: [(2, 3, 0, 0.9, 4, 0)], 1: [(1, 1, 2, 0.8, 4, 0)], 2: [(0, 1, 0, 0.7, 4, 0)]})
    sim = split({0: [(2, 3, 0, 0.85, 4, 2), (5, 5, 1, 0.75, 4, 0)],
                 1: [(1, 1, 2, 0.2, 4, 3)],
                 2: [(0, 1, 0, 0.6, 4, 1)]})
    a = parity.Acc("split")
    a.add("g", sim, ref)
    r = a.result()["g"]
    s = r["strides"]
    assert [s[k]["score"]["n_ref"] for k in ("8", "16", "32")] == [1, 1, 1]
    assert [s[k]["score"]["recall"] for k in ("8", "16", "32")] == [1, 0, 1]
    assert s["16"]["person"]["recall"] is None and s["16"]["person"]["n_ref"] == 0
    assert s["8"]["score"]["mean_abs_dscore"] == approx(0.05)
    assert s["8"]["score"]["n_sim"] == 2
    # a k-bin DFL shift on one of the four sides is k x stride px, over 4 terms
    assert s["8"]["box_err_px"] == approx(2 * 8 / 4, abs=1e-4)
    assert s["16"]["box_err_px"] == approx(3 * 16 / 4, abs=1e-4)
    assert s["32"]["box_err_px"] == approx(1 * 32 / 4, abs=1e-4)
    assert r["box_err_px"] == approx((16 + 48 + 32) / 12, abs=1e-4)
    assert r["score"]["n_ref"] == 3 and r["score"]["recall"] == approx(2 / 3)
    assert r["score"]["mean_abs_dscore"] == approx((0.05 + 0.6 + 0.1) / 3)
    assert r["score"]["n_sim"] == 3
    assert r["person"]["n_ref"] == 2 and r["person"]["recall"] == 1
    assert r["person"]["mean_abs_dscore"] == approx(0.075)
    assert r["person"]["n_sim"] == 2
    assert r["score"]["max_ref"] == approx(0.9) and r["score"]["max_sim"] == approx(0.85)
    assert len(r["cos"]) == 9 and r["cos"]["out4"] < 1 and r["cos"]["out1"] < 1


def test_split_ltrb_head_is_not_softmaxed():
    ref = split({1: [(1, 1, 0, 0.9, 0, 0)]}, reg_max=1)
    sim = split({1: [(1, 1, 0, 0.9, 0, 0.5)]}, reg_max=1)
    a = parity.Acc("split")
    a.add("g", sim, ref)
    assert a.result()["g"]["strides"]["16"]["box_err_px"] == approx(0.5 * 16 / 4)


def test_box_err_pooled_over_frames_and_strides():
    # per-frame means would give (2+0)/2; a mean of per-stride means gives (0+16)/2
    a = parity.Acc("yolox")
    a.add("g", yolox({3: (0.9, 0, 0.9, (1, 0, 0, 0))}), yolox({3: (0.9, 0, 0.9, Z)}))
    three = {3: (0.9, 0, 0.9, Z), 20: (0.9, 0, 0.9, Z), 30: (0.9, 0, 0.9, Z)}
    a.add("g", yolox(three), yolox(three))
    assert a.result()["g"]["box_err_px"] == approx(8 / 16)
    pos = [(2, 3, 0, 0.9, 4, 0), (3, 3, 0, 0.9, 4, 0), (4, 4, 0, 0.9, 4, 0)]
    ref = split({0: pos, 1: [(1, 1, 0, 0.9, 4, 0)]})
    sim = split({0: pos, 1: [(1, 1, 0, 0.9, 4, 4)]})
    b = parity.Acc("split")
    b.add("g", sim, ref)
    assert b.result()["g"]["box_err_px"] == approx(4 * 16 / 16)


def test_multi_frame_cos_max_and_step_across_frames():
    weak = yolox({3: (0.9, 0, 0.4, Z)})
    a = parity.Acc("yolox")
    a.add("g", yolox(SIM), yolox(REF))   # sim max 0.72, ref max 0.81, step 0.05
    a.add("g", yolox(REF), yolox(REF))   # 0.81, 0.81, step 0.1
    a.add("g", yolox(SIM), weak)         # 0.72, 0.36
    r = a.result()["g"]
    assert r["cos"]["out0"] == approx((parity.cos(yolox(SIM)[0], yolox(REF)[0]) + 1 + parity.cos(yolox(SIM)[0], weak[0])) / 3)
    assert r["score"]["max_sim"] == approx(0.81) and r["score"]["max_ref"] == approx(0.81)
    assert r["score_step"] == approx(0.05)


def test_group_named_all_is_not_double_counted():
    a = parity.Acc("yolox")
    a.add("all", yolox(REF), yolox(REF))
    r = a.result()["all"]
    assert r["n_frames"] == 1 and r["score"]["n_ref"] == 3


def test_dfl_is_the_softmax_expectation():
    # half the mass on bin 2, half on bin 4: expectation 3, an argmax decode says 2 or 4
    ref = split({1: [(1, 1, 0, 0.9, 0, 0)]})
    sim = split({1: [(1, 1, 0, 0.9, 0, 0)]})
    sim[3][0, :16, 1, 1] = -20
    sim[3][0, [2, 4], 1, 1] = 0
    a = parity.Acc("split")
    a.add("g", sim, ref)
    assert a.result()["g"]["strides"]["16"]["box_err_px"] == approx(3 * 16 / 4, abs=1e-4)


def test_no_ref_positives_gives_none_not_zero():
    a = parity.Acc("yolox")
    a.add("g", yolox({}), yolox({}))
    r = a.result()["g"]
    assert r["box_err_px"] is None and r["score"]["recall"] is None


def test_empty_acc_raises():
    with pytest.raises(ValueError):
        parity.Acc("yolox").result()


def test_frame_stats_rejects_mismatched_outputs():
    t = yolox(REF)[0]
    with pytest.raises(ValueError):
        parity.frame_stats("yolox", [t], [t, t])
    with pytest.raises(ValueError):
        parity.frame_stats("yolox", [t], [t.reshape(1, 85, NA)])  # same size: ravel would pair them silently


def test_shared_sources():
    fr = lambda *names: [{"src": n} for n in names]
    assert parity.shared_sources(fr("a_1785_01.png", "b_1785_01.png"), fr("a_1785_02.jpg", "b_1999_01.png")) == ["a_1785"]
    assert parity.shared_sources(fr("a_01.png"), fr("b_01.png")) == []


@pytest.mark.parametrize("bad", ["sim", "ref"])
def test_frame_stats_rejects_non_finite(bad):
    t = yolox(REF)[0]
    x = t.copy(); x[0, 3, 4] = np.nan if bad == "sim" else np.inf
    pair = ([x], [t]) if bad == "sim" else ([t], [x])
    with pytest.raises(ValueError, match="non-finite"):
        parity.frame_stats("yolox", *pair)
