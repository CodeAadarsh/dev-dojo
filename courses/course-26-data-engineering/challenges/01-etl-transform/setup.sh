#!/usr/bin/env bash
# Plants the ETL Transform starter into the work directory.
# Idempotent — re-running regenerates the scaffold but preserves transform.py if it exists.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-etl-transform"
mkdir -p "$WORK/data" "$WORK/tests"

# ── data/raw.csv (fixed seed, do NOT regenerate) ────────────────────────────
cat > "$WORK/data/raw.csv" << 'CSVEOF'
id,user_name,amount_str,event_ts,category,status,_junk
1," alice","$1,200.50",2024-01-15T08:30:00,SALES,ACTIVE,
2,"bob  ","$340.00",2024-01-15T09:00:00, marketing ,ACTIVE,
3," carol ","$2,005.75",15/01/2024 10:15:00,SALES,DELETED,
4,"dave","$0.99",2024-01-15T11:00:00,support,ACTIVE,
5," eve","$12,500.00",15/01/2024 12:00:00, SALES ,ACTIVE,
6,"frank","$75.20",2024-01-16T08:00:00,MARKETING,ACTIVE,
7," grace","$999.99",2024-01-16T09:30:00,support,DELETED,
8,"heidi ","$3,400.10",16/01/2024 10:00:00,SALES,ACTIVE,
9," ivan","$88.00",2024-01-16T11:45:00, Marketing ,ACTIVE,
10,"judy","$250.50",2024-01-17T08:00:00,support,ACTIVE,
11," karl ","$4,321.00",17/01/2024 09:00:00,SALES,ACTIVE,
12,"linda","$19.99",2024-01-17T10:30:00,marketing,DELETED,
13," mike","$750.00",2024-01-17T11:00:00,Support,ACTIVE,
14,"nancy ","$1,000.00",17/01/2024 14:00:00, MARKETING ,ACTIVE,
15," oscar","$55.55",2024-01-18T08:00:00,sales,ACTIVE,
CSVEOF

# ── transform.py stub (only write if not present) ───────────────────────────
if [ ! -f "$WORK/transform.py" ]; then
cat > "$WORK/transform.py" << 'PYEOF'
# transform.py
# Implement run_transform() so it reads data/raw.csv and returns a cleaned
# pd.DataFrame matching the target schema described in brief.md.
import os
import pandas as pd


DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def run_transform() -> pd.DataFrame:
    """
    Read data/raw.csv, clean it, return a DataFrame with columns:
        id (int64), user_name (str), amount_usd (float64),
        event_date (datetime64[ns]), category (str)
    Rows where status == "DELETED" must be dropped.
    """
    # TODO: implement
    raise NotImplementedError("implement run_transform()")
PYEOF
fi

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_transform_visible.py" << 'PYEOF'
"""Visible sanity tests — pass these before running the verifier."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
from transform import run_transform


def test_returns_dataframe():
    df = run_transform()
    assert isinstance(df, pd.DataFrame), "run_transform() must return a pd.DataFrame"


def test_exact_columns():
    df = run_transform()
    assert list(df.columns) == ["id", "user_name", "amount_usd", "event_date", "category"], \
        f"columns mismatch: got {list(df.columns)}"


def test_no_deleted_rows():
    df = run_transform()
    # raw.csv has 15 rows, 3 with status==DELETED -> expect 12
    assert len(df) == 12, f"expected 12 rows after dropping DELETED, got {len(df)}"


def test_amount_usd_is_float():
    df = run_transform()
    assert str(df["amount_usd"].dtype) == "float64", \
        f"amount_usd must be float64, got {df['amount_usd'].dtype}"


def test_event_date_is_datetime():
    df = run_transform()
    assert str(df["event_date"].dtype).startswith("datetime64"), \
        f"event_date must be datetime64, got {df['event_date'].dtype}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement run_transform() in transform.py so the output"
echo "                 DataFrame matches the target schema (see brief.md)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest pandas"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-26-data-engineering/challenges/01-etl-transform/verify.sh"
