#!/usr/bin/env bash
# Plants the "Pipeline Gates" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not touch installed tools.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-pipeline-gates"
mkdir -p "$WORK/tests"
mkdir -p "$WORK/dist"

# ── app.py — has a bug (return a - b instead of a + b) ───────────────────────
cat > "$WORK/app.py" << 'PYEOF'
def add(a: float, b: float) -> float:
    # BUG: should return a + b
    return a - b


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))
PYEOF

# ── tests/test_app.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_app.py" << 'PYEOF'
from app import add, clamp


def test_add():
    assert add(2, 3) == 5.0, f"expected 5.0, got {add(2, 3)}"


def test_add_negative():
    assert add(-1, 1) == 0.0


def test_clamp_below():
    assert clamp(-5.0, 0.0, 10.0) == 0.0


def test_clamp_above():
    assert clamp(15.0, 0.0, 10.0) == 10.0


def test_clamp_within():
    assert clamp(5.0, 0.0, 10.0) == 5.0
PYEOF

# ── Makefile — test gate is broken (|| true); no ci target ───────────────────
cat > "$WORK/Makefile" << 'MAKEFILE'
.PHONY: lint test build ci

lint:
	python3 -m py_compile app.py
	@echo "lint ok"

test:
	pytest tests/ -q || true

build:
	mkdir -p dist
	cp app.py dist/app.py
	@echo "build ok — dist/app.py"
MAKEFILE

echo
echo "Work directory : $WORK"
echo
echo "What is broken:"
echo "  1. app.py has a bug (run 'pytest tests/ -v' to see it)"
echo "  2. Makefile 'test' target uses '|| true' — failures are silently swallowed"
echo "  3. Makefile has no 'ci' target"
echo
echo "Your tasks:"
echo "  1. Fix the bug in app.py"
echo "  2. Fix the 'test' target to propagate failures"
echo "  3. Add a 'ci: lint test build' target"
echo
echo "Prerequisites  :"
echo "  pip install pytest"
echo
echo "Verify + flag  : bash courses/course-25-cicd/challenges/02-pipeline-gates/verify.sh"
