#!/usr/bin/env bash
# Plants the "Matrix Builds and Dependency Cache" starter project.
# Idempotent — re-running overwrites files.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-matrix-and-cache"
mkdir -p "$WORK/tests"
mkdir -p "$WORK/.github/workflows"

# ── statslib.py ───────────────────────────────────────────────────────────────
cat > "$WORK/statslib.py" << 'PYEOF'
import statistics
from typing import List


def mean(data: List[float]) -> float:
    if not data:
        raise ValueError("data must not be empty")
    return statistics.mean(data)


def stdev(data: List[float]) -> float:
    if len(data) < 2:
        raise ValueError("stdev requires at least 2 data points")
    return statistics.stdev(data)


def median(data: List[float]) -> float:
    if not data:
        raise ValueError("data must not be empty")
    return statistics.median(data)


def z_scores(data: List[float]) -> List[float]:
    mu = mean(data)
    sigma = stdev(data)
    return [(x - mu) / sigma for x in data]
PYEOF

# ── tests/test_statslib.py ────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_statslib.py" << 'PYEOF'
import pytest
from statslib import mean, stdev, median, z_scores


def test_mean_basic():
    assert mean([1.0, 2.0, 3.0]) == 2.0


def test_mean_empty_raises():
    with pytest.raises(ValueError):
        mean([])


def test_stdev_basic():
    result = stdev([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])
    assert abs(result - 2.0) < 1e-9


def test_stdev_too_few_raises():
    with pytest.raises(ValueError):
        stdev([1.0])


def test_median_odd():
    assert median([1.0, 3.0, 5.0]) == 3.0


def test_median_even():
    assert median([1.0, 2.0, 3.0, 4.0]) == 2.5


def test_z_scores_sum_to_zero():
    zs = z_scores([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])
    assert abs(sum(zs)) < 1e-9
PYEOF

# ── requirements-dev.txt ──────────────────────────────────────────────────────
cat > "$WORK/requirements-dev.txt" << 'PYEOF'
pytest==8.3.3
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : author .github/workflows/ci.yml inside the work directory."
echo "                 The workflow must have a matrix with >=2 entries and a"
echo "                 dependency cache step (actions/cache or setup-python with cache)."
echo
echo "Prerequisites  :"
echo "  pip install pyyaml   (used by verify.sh to parse your YAML)"
echo
echo "Verify + flag  : bash courses/course-25-cicd/challenges/03-matrix-and-cache/verify.sh"
