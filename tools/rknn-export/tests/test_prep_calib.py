import pytest

import prep_calib


@pytest.mark.parametrize("w, h, size, want", [
    (1000, 562, 640, (640, 358)),  # 359.68 floors to 359, forced even
    (1920, 1080, 416, (416, 234)),
    (2560, 1920, 640, (640, 480)),
])
def test_letterbox_content_follows_the_detector_rule(w, h, size, want):
    r = min(size / w, size / h)
    assert (prep_calib.scaled_dim(w, r, size), prep_calib.scaled_dim(h, r, size)) == want


@pytest.mark.parametrize("side, ratio, limit, want", [
    (7, 0.5, 640, 2),   # 3 -> even 2
    (1, 0.1, 640, 2),   # 0 -> floor of 2
    (5, 1.0, 1, 1),     # clamped to limit 1, even 0, raised to 2, capped at 1
    (9, 1.0, 8, 8),     # limit wins over 9 -> 8
])
def test_scaled_dim_even_and_clamp(side, ratio, limit, want):
    assert prep_calib.scaled_dim(side, ratio, limit) == want
