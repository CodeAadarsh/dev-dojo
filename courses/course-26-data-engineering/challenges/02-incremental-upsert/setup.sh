#!/usr/bin/env bash
# Plants the Incremental Upsert starter into the work directory.
# Idempotent — re-running regenerates data and tests but preserves upsert.py if it exists.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-incremental-upsert"
mkdir -p "$WORK/data" "$WORK/tests"

# ── data/base.csv (initial table snapshot) ──────────────────────────────────
cat > "$WORK/data/base.csv" << 'CSVEOF'
id,name,amount,updated_at
1,alice,100.00,2024-01-01T00:00:00
2,bob,200.00,2024-01-01T00:00:00
3,carol,300.00,2024-01-01T00:00:00
4,dave,400.00,2024-01-01T00:00:00
5,eve,500.00,2024-01-01T00:00:00
6,frank,600.00,2024-01-01T00:00:00
7,grace,700.00,2024-01-01T00:00:00
8,heidi,800.00,2024-01-01T00:00:00
9,ivan,900.00,2024-01-01T00:00:00
10,judy,1000.00,2024-01-01T00:00:00
CSVEOF

# ── data/cdc_feed.csv (CDC operations) ──────────────────────────────────────
cat > "$WORK/data/cdc_feed.csv" << 'CSVEOF'
id,op,name,amount,updated_at
3,DELETE,carol,300.00,2024-01-02T00:00:00
5,UPDATE,eve-updated,550.00,2024-01-02T01:00:00
11,INSERT,karl,1100.00,2024-01-02T02:00:00
2,UPDATE,bob-v2,220.00,2024-01-02T03:00:00
7,DELETE,grace,700.00,2024-01-02T04:00:00
12,INSERT,linda,1200.00,2024-01-02T05:00:00
1,UPDATE,alice-prime,110.00,2024-01-02T06:00:00
9,DELETE,ivan,900.00,2024-01-02T07:00:00
CSVEOF

# ── upsert.py stub (only write if not present) ──────────────────────────────
if [ ! -f "$WORK/upsert.py" ]; then
cat > "$WORK/upsert.py" << 'PYEOF'
# upsert.py
# Implement apply_cdc_feed() so it is idempotent and handles the CDC
# operations described in brief.md.
import pandas as pd


def apply_cdc_feed(base_df: pd.DataFrame, feed_df: pd.DataFrame) -> pd.DataFrame:
    """
    Apply feed_df (CDC operations) to base_df and return the resulting table.

    Columns of base_df  : id, name, amount, updated_at
    Columns of feed_df  : id, op, name, amount, updated_at
    ops                 : INSERT | UPDATE | DELETE

    Rules:
    - INSERT/UPDATE -> upsert by id (last op per id wins if id appears twice)
    - DELETE        -> remove by id (no-op if id absent)
    - Return a DataFrame with columns [id, name, amount, updated_at],
      sorted by id ascending, index reset to 0..N-1.
    """
    # TODO: implement
    raise NotImplementedError("implement apply_cdc_feed()")
PYEOF
fi

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_upsert_visible.py" << 'PYEOF'
"""Visible sanity tests — pass these before running the verifier."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
from upsert import apply_cdc_feed

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")


def load():
    base = pd.read_csv(os.path.join(DATA, "base.csv"))
    feed = pd.read_csv(os.path.join(DATA, "cdc_feed.csv"))
    return base, feed


def test_returns_dataframe():
    base, feed = load()
    result = apply_cdc_feed(base, feed)
    assert isinstance(result, pd.DataFrame)


def test_deleted_ids_absent():
    base, feed = load()
    result = apply_cdc_feed(base, feed)
    # ids 3, 7, 9 are DELETED by the feed
    for did in [3, 7, 9]:
        assert did not in result["id"].values, f"id={did} should be deleted"


def test_inserted_ids_present():
    base, feed = load()
    result = apply_cdc_feed(base, feed)
    for iid in [11, 12]:
        assert iid in result["id"].values, f"id={iid} should be inserted"


def test_sorted_by_id():
    base, feed = load()
    result = apply_cdc_feed(base, feed)
    assert list(result["id"]) == sorted(result["id"]), "result must be sorted by id"


def test_no_status_or_op_column():
    base, feed = load()
    result = apply_cdc_feed(base, feed)
    assert "op" not in result.columns, "op column must not appear in result"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement apply_cdc_feed() in upsert.py so the CDC feed"
echo "                 is applied idempotently (see brief.md for rules)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest pandas"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-26-data-engineering/challenges/02-incremental-upsert/verify.sh"
