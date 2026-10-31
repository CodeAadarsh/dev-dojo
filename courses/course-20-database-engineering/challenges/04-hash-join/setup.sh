#!/usr/bin/env bash
# Plants the "Hash Join" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="04-hash-join"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — hash join
#
# Implement hash_join so that for every pair of rows where
# left_row[left_key] == right_row[right_key], the merged dict
# {**left_row, **right_row} is included in the return value.
#
# Contract:
#   - Build phase: hash the SMALLER relation (by len) into a dict[key -> list[row]].
#   - Probe phase: iterate the LARGER relation, look up each row's join key.
#   - Duplicate keys: N left rows matching M right rows → N*M output rows.
#   - Output order is not required to be deterministic.
#   - Empty relations → return [].
from __future__ import annotations
from typing import Any


def hash_join(
    left: list[dict],
    right: list[dict],
    left_key: str,
    right_key: str,
) -> list[dict]:
    # TODO: implement this function.
    # Step 1 — decide which relation is "build" (smaller) and which is "probe".
    # Step 2 — build phase: iterate the build relation and group rows by their
    #          join key value into a dict[Any, list[dict]].
    # Step 3 — probe phase: iterate the probe relation; for each row, look up
    #          its join key in the hash table; for every matching build row,
    #          emit {**left_row, **right_row}.
    raise NotImplementedError
PYEOF

# ── tests/test_sample.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import hash_join


def test_basic_two_rows():
    left  = [{'l_id': 1, 'name': 'alice'}, {'l_id': 2, 'name': 'bob'}]
    right = [{'r_id': 1, 'score': 90},     {'r_id': 2, 'score': 75}]
    got = hash_join(left, right, 'l_id', 'r_id')
    assert len(got) == 2
    names = {r['name'] for r in got}
    assert names == {'alice', 'bob'}


def test_no_matches_returns_empty():
    left  = [{'id': 1, 'v': 'a'}]
    right = [{'id': 9, 'v': 'b'}]
    assert hash_join(left, right, 'id', 'id') == []


def test_many_to_many_count():
    # 2 left rows × 3 right rows all sharing k=1 → 6 output rows
    left  = [{'k': 1, 'lv': 'A'}, {'k': 1, 'lv': 'B'}]
    right = [{'k': 1, 'rv': 'X'}, {'k': 1, 'rv': 'Y'}, {'k': 1, 'rv': 'Z'}]
    got = hash_join(left, right, 'k', 'k')
    assert len(got) == 6, f"expected 6 rows, got {len(got)}"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement hash_join() in solution.py"
echo "                   so all tests pass (3 visible + hidden edge cases)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
