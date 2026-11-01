#!/usr/bin/env bash
# Verifier for "Incremental Upsert: Idempotent CDC Merge".
# Applies the feed twice and asserts exact final state both times.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-incremental-upsert"
FLAG='KUBE{upsert_idempotent_cdc_merge}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/upsert.py" ] || fail "upsert.py not found — run setup.sh first"
[ -f "$WORK/data/base.csv" ] || fail "data/base.csv not found — run setup.sh first"
[ -f "$WORK/data/cdc_feed.csv" ] || fail "data/cdc_feed.csv not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas"
fi

TMPDIR_HIDDEN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_upsert_hidden.py" << PYEOF
import sys, os
sys.path.insert(0, "$WORK")

import pandas as pd
from upsert import apply_cdc_feed

DATA = "$WORK/data"
BASE = pd.read_csv(os.path.join(DATA, "base.csv"))
FEED = pd.read_csv(os.path.join(DATA, "cdc_feed.csv"))


def load_fresh():
    return (
        pd.read_csv(os.path.join(DATA, "base.csv")),
        pd.read_csv(os.path.join(DATA, "cdc_feed.csv")),
    )


def test_column_set():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    assert set(result.columns) == {"id", "name", "amount", "updated_at"}, \
        f"unexpected columns: {set(result.columns)}"


def test_deleted_ids_removed():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    for did in [3, 7, 9]:
        assert did not in result["id"].values, f"id={did} must be deleted"


def test_inserted_ids_present():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    assert 11 in result["id"].values, "id=11 (INSERT karl) must be present"
    assert 12 in result["id"].values, "id=12 (INSERT linda) must be present"


def test_updated_values():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    # id=5 updated: eve-updated, 550.00
    row5 = result[result["id"] == 5].iloc[0]
    assert row5["name"] == "eve-updated", f"id=5 name expected 'eve-updated', got '{row5['name']}'"
    assert abs(row5["amount"] - 550.00) < 1e-6, f"id=5 amount expected 550.00, got {row5['amount']}"
    # id=2 updated: bob-v2, 220.00
    row2 = result[result["id"] == 2].iloc[0]
    assert row2["name"] == "bob-v2", f"id=2 name expected 'bob-v2', got '{row2['name']}'"
    # id=1 updated: alice-prime, 110.00
    row1 = result[result["id"] == 1].iloc[0]
    assert row1["name"] == "alice-prime", f"id=1 expected alice-prime"


def test_unchanged_rows_intact():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    # id=4,6,8,10 not touched
    for unchanged_id, name, amt in [(4, "dave", 400.0), (6, "frank", 600.0),
                                     (8, "heidi", 800.0), (10, "judy", 1000.0)]:
        row = result[result["id"] == unchanged_id].iloc[0]
        assert row["name"] == name, f"id={unchanged_id} name changed unexpectedly"
        assert abs(row["amount"] - amt) < 1e-6, f"id={unchanged_id} amount changed"


def test_row_count():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    # base=10, delete 3 (ids 3,7,9), insert 2 (ids 11,12) -> 9
    assert len(result) == 9, f"expected 9 rows, got {len(result)}"


def test_sorted_by_id():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    ids = list(result["id"])
    assert ids == sorted(ids), f"result must be sorted by id, got {ids}"


def test_no_duplicates():
    base, feed = load_fresh()
    result = apply_cdc_feed(base, feed)
    assert result["id"].nunique() == len(result), "duplicate ids found in result"


def test_idempotent_first_application():
    """Applying the feed twice to the original base gives the same result as once."""
    base, feed = load_fresh()
    result_once = apply_cdc_feed(base.copy(), feed.copy())
    result_twice = apply_cdc_feed(result_once.copy(), feed.copy())
    result_once_sorted = result_once.sort_values("id").reset_index(drop=True)
    result_twice_sorted = result_twice.sort_values("id").reset_index(drop=True)
    pd.testing.assert_frame_equal(
        result_once_sorted,
        result_twice_sorted,
        check_like=False,
        obj="idempotency check: apply_cdc_feed(result, feed) must equal apply_cdc_feed(base, feed)",
    )


def test_idempotent_insert_no_duplicates():
    """A second pass must not re-insert rows that are already present."""
    base, feed = load_fresh()
    result = apply_cdc_feed(base.copy(), feed.copy())
    result2 = apply_cdc_feed(result.copy(), feed.copy())
    assert len(result2) == len(result), \
        f"second pass changed row count: {len(result)} -> {len(result2)} (likely double-inserts)"


def test_idempotent_delete_no_op():
    """A second pass must not fail or change state when deleting already-absent ids."""
    base, feed = load_fresh()
    result = apply_cdc_feed(base.copy(), feed.copy())
    # ids 3,7,9 are already gone; a second pass must leave the frame identical
    result2 = apply_cdc_feed(result.copy(), feed.copy())
    assert 3 not in result2["id"].values
    assert 7 not in result2["id"].values
    assert 9 not in result2["id"].values
PYEOF

if $PYTEST "$TMPDIR_HIDDEN/test_upsert_hidden.py" -q 2>&1; then
    echo
    echo "All hidden assertions passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — review brief.md and retry"
fi
