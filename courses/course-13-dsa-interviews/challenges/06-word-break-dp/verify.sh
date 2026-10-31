#!/usr/bin/env bash
# Verifier for "Word Break".
# Tests both word_break_memo and word_break_tab with a hidden suite.
# Prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-word-break-dp"
FLAG='KUBE{memoize_then_tabulate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# ── hidden test suite ────────────────────────────────────────────────────────
HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/test_hidden_word_break.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import word_break_memo, word_break_tab


def _both(s, d):
    """Run both implementations and assert they agree."""
    m = word_break_memo(s, d)
    t = word_break_tab(s, d)
    assert m == t, (
        f"memo={m} but tab={t} for s={s!r}, dict={d} — "
        "both implementations must agree"
    )
    return m


def test_single_word_match():
    assert _both("dog", ["dog"]) is True


def test_single_word_no_match():
    assert _both("dog", ["cat"]) is False


def test_multiple_splits_possible():
    assert _both("cars", ["car", "ca", "rs"]) is True


def test_long_string_true():
    assert _both("aaaaaaa", ["a", "aa", "aaa"]) is True


def test_adversarial_false():
    # designed to trick naive recursion without memoization into TLE
    s = "a" * 30 + "b"
    d = ["a" * i for i in range(1, 10)]
    assert _both(s, d) is False


def test_word_reuse_many():
    assert _both("aaaaab", ["a", "aa"]) is False


def test_full_dict_used():
    assert _both("thequickbrownfox", ["the", "quick", "brown", "fox"]) is True


def test_no_memo_pollution():
    # Calling multiple times with different inputs must not pollute state
    assert word_break_memo("a", ["a"]) is True
    assert word_break_memo("b", ["a"]) is False
    assert word_break_memo("a", ["a"]) is True   # cached from call 1 must still work


def test_tab_returns_bool_not_truthy():
    result = word_break_tab("abc", ["abc"])
    assert result is True, f"must return True (bool), got {result!r}"
    result2 = word_break_tab("abc", ["x"])
    assert result2 is False, f"must return False (bool), got {result2!r}"
PYEOF

if $PYTEST "$HIDDEN_DIR/" tests/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
