#!/usr/bin/env bash
# Plants the "Word Break" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-word-break-dp"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Word Break DP
# Implement BOTH forms. The verifier tests them independently.
# Do NOT share state between calls (no module-level mutable caches).


def word_break_memo(s: str, word_dict: list) -> bool:
    """Top-down DP: memoized recursion.
    State: can s[i:] be segmented using word_dict?
    """
    # TODO: implement with memoization
    return False


def word_break_tab(s: str, word_dict: list) -> bool:
    """Bottom-up DP: tabulation.
    State: dp[i] = True if s[:i] can be segmented using word_dict.
    """
    # TODO: implement with a dp table
    return False
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_word_break.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import word_break_memo, word_break_tab


def test_memo_simple_true():
    assert word_break_memo("leetcode", ["leet", "code"]) is True


def test_memo_simple_false():
    assert word_break_memo("catsandog", ["cats", "dog", "sand", "and", "cat"]) is False


def test_memo_reuse():
    assert word_break_memo("applepenapple", ["apple", "pen"]) is True


def test_memo_empty_string():
    assert word_break_memo("", ["a", "b"]) is True


def test_tab_simple_true():
    assert word_break_tab("leetcode", ["leet", "code"]) is True


def test_tab_simple_false():
    assert word_break_tab("catsandog", ["cats", "dog", "sand", "and", "cat"]) is False


def test_tab_reuse():
    assert word_break_tab("applepenapple", ["apple", "pen"]) is True


def test_tab_empty_string():
    assert word_break_tab("", ["a", "b"]) is True
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement word_break_memo AND word_break_tab in solution.py."
echo "                 Both must produce the same results; the verifier tests them independently."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-13-dsa-interviews/challenges/06-word-break-dp/verify.sh"
