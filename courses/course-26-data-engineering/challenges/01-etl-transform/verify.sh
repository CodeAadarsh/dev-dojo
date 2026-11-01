#!/usr/bin/env bash
# Verifier for "ETL Transform: Parse, Clean, Derive".
# Writes a hidden pytest file to a tempdir, runs it against the learner's
# transform.py, and prints the flag only when every assertion passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-etl-transform"
FLAG='KUBE{etl_transform_clean_schema}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/transform.py" ] || fail "transform.py not found in $WORK — run setup.sh first"
[ -f "$WORK/data/raw.csv" ] || fail "data/raw.csv not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas"
fi

TMPDIR_HIDDEN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_etl_hidden.py" << PYEOF
import sys, os
sys.path.insert(0, "$WORK")

import pandas as pd
from transform import run_transform


def test_row_count():
    df = run_transform()
    assert len(df) == 12, f"expected 12 rows (3 DELETED dropped), got {len(df)}"


def test_column_order():
    df = run_transform()
    assert list(df.columns) == ["id", "user_name", "amount_usd", "event_date", "category"], \
        f"column order wrong: {list(df.columns)}"


def test_id_dtype():
    df = run_transform()
    assert df["id"].dtype == "int64", f"id must be int64, got {df['id'].dtype}"


def test_amount_usd_dtype():
    df = run_transform()
    assert df["amount_usd"].dtype == "float64", f"amount_usd must be float64"


def test_event_date_dtype():
    df = run_transform()
    assert str(df["event_date"].dtype).startswith("datetime64"), \
        f"event_date must be datetime64, got {df['event_date'].dtype}"


def test_category_dtype():
    df = run_transform()
    assert pd.api.types.is_string_dtype(df["category"]), \
        f"category must be a string dtype, got {df['category'].dtype}"


def test_user_name_stripped():
    df = run_transform()
    for v in df["user_name"]:
        assert v == v.strip(), f"user_name '{v}' has leading/trailing whitespace"


def test_category_lowercase():
    df = run_transform()
    for v in df["category"]:
        assert v == v.strip().lower(), f"category '{v}' is not stripped+lowercase"


def test_amount_values():
    df = run_transform()
    # id=1 -> 1200.50, id=2 -> 340.00, id=5 -> 12500.00
    row1 = df[df["id"] == 1]["amount_usd"].iloc[0]
    assert abs(row1 - 1200.50) < 1e-6, f"id=1 amount_usd expected 1200.50, got {row1}"
    row5 = df[df["id"] == 5]["amount_usd"].iloc[0]
    assert abs(row5 - 12500.00) < 1e-6, f"id=5 amount_usd expected 12500.00, got {row5}"


def test_deleted_rows_absent():
    df = run_transform()
    # ids 3, 7, 12 were DELETED
    for bad_id in [3, 7, 12]:
        assert bad_id not in df["id"].values, f"id={bad_id} (DELETED) should not be in output"


def test_event_date_values():
    df = run_transform()
    import pandas as pd
    row1 = df[df["id"] == 1]["event_date"].iloc[0]
    expected = pd.Timestamp("2024-01-15 08:30:00")
    assert row1 == expected, f"id=1 event_date expected {expected}, got {row1}"
    # id=5 uses DD/MM/YYYY format
    row5 = df[df["id"] == 5]["event_date"].iloc[0]
    expected5 = pd.Timestamp("2024-01-15 12:00:00")
    assert row5 == expected5, f"id=5 event_date expected {expected5}, got {row5}"


def test_total_amount_sum():
    df = run_transform()
    # sum of all 12 non-deleted amounts
    # 1200.50+340.00+0.99+12500.00+75.20+3400.10+88.00+250.50+4321.00+750.00+1000.00+55.55
    expected_sum = 23981.84
    actual = round(df["amount_usd"].sum(), 2)
    assert abs(actual - expected_sum) < 0.01, \
        f"amount_usd sum expected {expected_sum}, got {actual}"


def test_no_junk_column():
    df = run_transform()
    assert "_junk" not in df.columns, "_junk column must be dropped"


def test_no_status_column():
    df = run_transform()
    assert "status" not in df.columns, "status column must be dropped"
PYEOF

if $PYTEST "$TMPDIR_HIDDEN/test_etl_hidden.py" -q 2>&1; then
    echo
    echo "All hidden assertions passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — review brief.md and retry"
fi
