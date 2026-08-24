import numpy as np

from score_parity import PERSON, scores


def test_yolox_scores_multiply_objectness():
    # The plugin's decode multiplies obj * cls; a comparison that skipped
    # it would grade a tensor nobody consumes.
    out = np.zeros((1, 2, 85), np.float32)
    out[0, 0, 4] = 0.8          # objectness
    out[0, 0, 5 + PERSON] = 0.9
    out[0, 1, 4] = 0.5
    out[0, 1, 5 + 7] = 0.6      # some other class
    best, person = scores(out, "yolox")
    assert np.allclose(best, [0.72, 0.30])
    assert np.allclose(person, [0.72, 0.0])


def test_yolov8_scores_have_no_objectness():
    out = np.zeros((1, 84, 3), np.float32)
    out[0, 4 + PERSON, 0] = 0.9
    out[0, 4 + 7, 1] = 0.6
    best, person = scores(out, "yolov8")
    assert np.allclose(best, [0.9, 0.6, 0.0])
    assert np.allclose(person, [0.9, 0.0, 0.0])
