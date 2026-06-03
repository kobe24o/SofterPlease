"""Small editdistance compatibility shim for Windows/Python 3.13."""

from __future__ import annotations

from collections.abc import Sequence


def eval(source: Sequence, target: Sequence) -> int:  # noqa: A001 - match package API
    """Return Levenshtein edit distance between two sequences."""
    if source == target:
        return 0
    if len(source) == 0:
        return len(target)
    if len(target) == 0:
        return len(source)

    previous = list(range(len(target) + 1))
    for i, source_item in enumerate(source, start=1):
        current = [i]
        for j, target_item in enumerate(target, start=1):
            insert_cost = current[j - 1] + 1
            delete_cost = previous[j] + 1
            replace_cost = previous[j - 1] + (0 if source_item == target_item else 1)
            current.append(min(insert_cost, delete_cost, replace_cost))
        previous = current
    return previous[-1]
