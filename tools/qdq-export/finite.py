"""Fail-closed float predicates for the export gates.

NaN answers False to `<`, `>`, and `>=` alike, so an unguarded threshold
fails open or closed depending on how the author happened to phrase it —
three #138 review rounds were exactly that. Gates prove their numbers
finite with these first and fail explicitly, never trusting a
comparison's NaN direction. Stdlib only.
"""
from __future__ import annotations

import math
from collections.abc import Iterable
from typing import Any


def is_finite(v: Any) -> bool:
    """True only for a real, finite number. None, NaN, ±inf, and
    non-numeric values are all non-finite — closed by default."""
    # bool subclasses int and isfinite(True) is True — but a JSON `true`
    # where a score belongs is malformed evidence, not the number 1.
    if v is None or isinstance(v, bool):
        return False
    try:
        return math.isfinite(v)
    except (TypeError, OverflowError):
        # OverflowError: json.loads turns corrupted evidence into
        # arbitrary-precision ints that isfinite cannot convert — that is
        # a non-finite input, not an exception for the gate to leak.
        return False


def all_finite(*values: Any) -> bool:
    """For a handful of named scalars. Series and arrays go through
    all_finite_in — star-expansion would materialize them as one
    argument tuple."""
    return all(is_finite(v) for v in values)


def all_finite_in(iterable: Iterable[Any]) -> bool:
    return all(is_finite(v) for v in iterable)


def all_finite_or_none(*values: Any) -> bool:
    """For records with optional fields whose absence is judged
    elsewhere: None passes, anything present must be finite."""
    return all(v is None or is_finite(v) for v in values)
