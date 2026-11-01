#!/usr/bin/env bash
# Plants the "Write a CI Workflow" starter project into the work directory.
# Idempotent — re-running overwrites files but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-write-a-ci-workflow"
mkdir -p "$WORK/tests"
mkdir -p "$WORK/.github/workflows"

# ── app.py ────────────────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
def add(a: float, b: float) -> float:
    return a + b


def greet(name: str) -> str:
    if not name:
        raise ValueError("name must not be empty")
    return f"Hello, {name}!"
PYEOF

# ── tests/test_app.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_app.py" << 'PYEOF'
import pytest
from app import add, greet


def test_add_positive():
    assert add(2, 3) == 5.0


def test_add_negative():
    assert add(-4, 4) == 0.0


def test_add_floats():
    assert abs(add(0.1, 0.2) - 0.3) < 1e-9


def test_greet_basic():
    assert greet("Dojo") == "Hello, Dojo!"


def test_greet_empty_raises():
    with pytest.raises(ValueError):
        greet("")


def test_greet_whitespace():
    assert greet("  ") == "Hello,   !"
PYEOF

# ── requirements-dev.txt ──────────────────────────────────────────────────────
cat > "$WORK/requirements-dev.txt" << 'PYEOF'
pytest==8.3.3
ruff==0.6.9
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : author .github/workflows/ci.yml inside the work directory."
echo "                 The workflow must trigger on push + pull_request and contain"
echo "                 steps for: checkout, python setup, lint, and test."
echo
echo "Prerequisites  :"
echo "  pip install pyyaml   (used by verify.sh to parse your YAML)"
echo
echo "Verify + flag  : bash courses/course-25-cicd/challenges/01-write-a-ci-workflow/verify.sh"
