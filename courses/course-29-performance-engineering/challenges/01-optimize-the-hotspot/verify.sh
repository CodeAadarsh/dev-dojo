#!/usr/bin/env bash
# Verifier for "Optimize the Hotspot".
# Runs a hidden pytest suite that checks correctness AND algorithmic complexity
# via a _CountedList proxy — no timing, no flakiness, purely structural.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-optimize-the-hotspot"
FLAG='KUBE{hotspot_from_o_n2_to_o_n}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/hotspot.py" ] || fail "hotspot.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPTEST="$(mktemp /tmp/test_hotspot_hidden_XXXXXX.py)"
trap 'rm -f "$TMPTEST"' EXIT

cat > "$TMPTEST" << 'PYEOF'
import sys
import os
import random

_work = os.path.expanduser("~/.kube-dojo-work/01-optimize-the-hotspot")
sys.path.insert(0, _work)
from hotspot import find_common_endpoints


class _CountedList:
    """
    A list-like that counts every element yielded across ALL iterations and
    every __contains__ scan. An O(n) solution iterates log_b once (n counts).
    An O(n²) solution iterates it n times (n² counts).
    """
    def __init__(self, data):
        self._data = list(data)
        self.accesses = 0

    def __len__(self):
        return len(self._data)

    def __getitem__(self, idx):
        self.accesses += 1
        return self._data[idx]

    def __iter__(self):
        for item in self._data:
            self.accesses += 1
            yield item

    def __contains__(self, item):
        for x in self._data:
            self.accesses += 1
            if x == item:
                return True
        return False


def test_basic_correctness():
    assert find_common_endpoints(
        ["/api/users", "/api/orders", "/health"],
        ["/api/orders", "/api/products", "/health"],
    ) == {"/api/orders", "/health"}


def test_no_overlap():
    assert find_common_endpoints(["/a", "/b"], ["/c", "/d"]) == set()


def test_both_empty():
    assert find_common_endpoints([], []) == set()


def test_one_empty():
    assert find_common_endpoints([], ["/health"]) == set()
    assert find_common_endpoints(["/health"], []) == set()


def test_duplicates_in_log_a():
    a = ["/api/users", "/api/users", "/health"]
    b = ["/health", "/api/orders"]
    assert find_common_endpoints(a, b) == {"/health"}


def test_duplicates_in_both():
    a = ["/x", "/y", "/x", "/z"]
    b = ["/y", "/y", "/z", "/w"]
    assert find_common_endpoints(a, b) == {"/y", "/z"}


def test_algorithmic_complexity():
    """
    Complexity proxy: log_b is wrapped in a _CountedList that tracks how many
    elements are accessed (via iteration OR __contains__ OR __getitem__).

    O(n) solution:   builds set(log_b) once  -> accesses == n
    O(n²) solution:  iterates log_b per ep   -> accesses == n * m

    Threshold: 10 * n.  O(n) yields n accesses (well under 10n).
    O(n²) with n=m=5000 yields 25_000_000 (far over 50_000).
    """
    random.seed(42)
    n = 5000
    pool = [f"/endpoint/{i}" for i in range(n)]
    log_a = random.choices(pool[:3500], k=n)
    log_b_raw = random.choices(pool[1500:], k=n)
    log_b_cl = _CountedList(log_b_raw)

    expected = set(log_a) & set(log_b_raw)
    result = find_common_endpoints(log_a, log_b_cl)

    assert result == expected, (
        f"Result mismatch on n={n} input: "
        f"got {len(result)} endpoints, expected {len(expected)}"
    )

    max_accesses = 10 * n   # 50_000
    assert log_b_cl.accesses <= max_accesses, (
        f"log_b accessed {log_b_cl.accesses:,} times for n={n}; "
        f"O(n) needs ≤{max_accesses:,}; "
        f"O(n²) would need ~{n * n:,} — eliminate the nested loop"
    )
PYEOF

if "$PYTEST" "$TMPTEST" -v 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "checks failed — fix your implementation and retry"
fi
