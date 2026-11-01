#!/usr/bin/env bash
# Plants the "Optimize the Hotspot" starter project into the work directory.
# Idempotent — re-running overwrites hotspot.py and visible test but not .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-optimize-the-hotspot"
mkdir -p "$WORK/tests"

# ── hotspot.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/hotspot.py" << 'PYEOF'
"""
Log analysis pipeline: given two request logs, return the set of API endpoints
that appear in BOTH logs.

Current implementation is correct but slow — O(n * m) nested loops.
The nightly batch job runs against production logs of 500 000 entries each
and is now taking 8 hours. Your mission: reimplement find_common_endpoints
so it runs in O(n + m).

Rules:
  - Keep the function name and signature exactly as shown.
  - The return type must remain set.
  - Duplicate entries in either log are fine — set semantics apply.
"""


def find_common_endpoints(log_a: list, log_b: list) -> set:
    """Return the set of endpoint strings that appear in BOTH log_a and log_b."""
    result = set()
    for endpoint in log_a:
        for other in log_b:          # O(n * m) — this is the hotspot
            if endpoint == other:
                result.add(endpoint)
    return result
PYEOF

# ── tests/test_hotspot_visible.py ────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_hotspot_visible.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hotspot import find_common_endpoints


def test_basic_overlap():
    a = ["/api/users", "/api/orders", "/health"]
    b = ["/api/orders", "/api/products", "/health"]
    assert find_common_endpoints(a, b) == {"/api/orders", "/health"}


def test_no_overlap():
    assert find_common_endpoints(["/a", "/b"], ["/c", "/d"]) == set()


def test_one_empty():
    assert find_common_endpoints([], ["/health"]) == set()
    assert find_common_endpoints(["/health"], []) == set()


def test_duplicates_in_log_a():
    a = ["/api/users", "/api/users", "/health"]
    b = ["/health", "/api/orders"]
    assert find_common_endpoints(a, b) == {"/health"}
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : reimplement find_common_endpoints in hotspot.py"
echo "                 from O(n²) to O(n+m) — keep results identical."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run smoke tests: cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-29-performance-engineering/challenges/01-optimize-the-hotspot/verify.sh"
