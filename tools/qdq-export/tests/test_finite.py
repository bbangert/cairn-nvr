import math

import numpy as np

from finite import all_finite, all_finite_or_none, is_finite


def test_is_finite_accepts_real_numbers():
    assert is_finite(0)
    assert is_finite(-3.5)


def test_is_finite_closed_by_default():
    for v in (None, math.nan, math.inf, -math.inf, "0.9", [1.0]):
        assert not is_finite(v)


def test_all_finite():
    assert all_finite(1, 2.0, 0)
    assert not all_finite(1, math.nan)
    assert not all_finite(1, None)


def test_numpy_scalars():
    # The production callers pass numpy scalars (score_parity maxima,
    # ratio arrays); a rewrite to an isinstance(int, float) check would
    # silently reject them all.
    assert is_finite(np.float32(0.5))
    assert is_finite(np.float64(1.0))
    assert not is_finite(np.float32("nan"))
    assert not all_finite(*np.array([1.0, np.inf]))


def test_all_finite_or_none_tolerates_absence_only():
    assert all_finite_or_none(1.0, None, 2.0)
    assert not all_finite_or_none(1.0, None, math.nan)
    assert not all_finite_or_none(math.inf, None)
