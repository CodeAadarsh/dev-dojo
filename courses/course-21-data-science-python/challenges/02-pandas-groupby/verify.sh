#!/usr/bin/env bash
# Verifier for "Pandas GroupBy — Clean and Aggregate".
# Regenerates the seeded CSV (identical to setup.sh), writes a hidden pytest
# suite, runs it, and prints the flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-pandas-groupby"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{pandas_groupby_aggregation}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]             || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"
[ -f "$WORK/sales_data.csv" ] || fail "sales_data.csv not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas numpy"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
import numpy as np
from solution import clean, aggregate

CSV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sales_data.csv")


# ── fixtures ──────────────────────────────────────────────────────────────────

def _raw():
    return pd.read_csv(CSV)


def _cleaned():
    return clean(_raw())


def _agg():
    return aggregate(_cleaned())


# ── clean() contracts ─────────────────────────────────────────────────────────

def test_clean_drops_na_order_ids():
    raw = _raw()
    cleaned = clean(raw)
    # pandas reads "N/A" from CSV as NaN (it's in pandas' default na_values list),
    # so the raw column is already float with NaN entries rather than the string "N/A".
    na_count = int(raw["order_id"].isna().sum())
    assert len(cleaned) == len(raw) - na_count, \
        f"expected {len(raw) - na_count} rows after dropping N/A, got {len(cleaned)}"


def test_clean_order_id_dtype():
    assert str(_cleaned()["order_id"].dtype) == "int64", "order_id must be int64"


def test_clean_region_title_case():
    regions = set(_cleaned()["region"].unique())
    assert regions == {"North", "South", "East", "West"}, \
        f"expected title-cased regions {{North,South,East,West}}, got {regions}"


def test_clean_amount_dtype():
    assert str(_cleaned()["amount"].dtype) == "float64", "amount must be float64"


def test_clean_amount_no_dollar():
    cleaned = _cleaned()
    assert not any("$" in str(v) for v in cleaned["amount"]), \
        "amount column still contains '$' — strip it"


def test_clean_amount_no_comma():
    cleaned = _cleaned()
    assert not any("," in str(v) for v in cleaned["amount"]), \
        "amount column still contains ',' — strip commas"


def test_clean_amount_positive():
    cleaned = _cleaned()
    assert (cleaned["amount"] > 0).all(), "all amounts should be positive after cleaning"


def test_clean_quantity_dtype():
    assert str(_cleaned()["quantity"].dtype) == "int64", "quantity must be int64"


def test_clean_date_dtype():
    dt = str(_cleaned()["date"].dtype)
    assert dt.startswith("datetime"), f"date must be datetime64, got {dt}"


def test_clean_no_nulls():
    cleaned = _cleaned()
    nulls = cleaned.isnull().sum().sum()
    assert nulls == 0, f"cleaned DataFrame still has {nulls} null value(s)"


# ── aggregate() contracts ──────────────────────────────────────────────────────

def test_agg_has_four_regions():
    agg = _agg()
    assert len(agg) == 4, f"expected 4 regions, got {len(agg)}: {list(agg['region'])}"


def test_agg_required_columns():
    agg = _agg()
    for col in ("region", "total_amount", "total_quantity", "order_count"):
        assert col in agg.columns, f"missing column '{col}' in aggregate result"


def test_agg_sorted_by_region():
    agg = _agg()
    regions = list(agg["region"])
    assert regions == sorted(regions), \
        f"aggregate must be sorted ascending by region, got {regions}"


def test_agg_index_reset():
    agg = _agg()
    assert list(agg.index) == list(range(len(agg))), \
        "aggregate index must be reset to 0-based integer (call .reset_index())"


def test_agg_total_amount_values():
    cleaned = _cleaned()
    agg = _agg()
    # compute expected from the cleaned data directly
    expected = (
        cleaned.groupby("region")["amount"]
        .sum()
        .sort_index()
        .reset_index()
        .rename(columns={"amount": "total_amount"})
    )
    for _, exp_row in expected.iterrows():
        region = exp_row["region"]
        got_row = agg[agg["region"] == region]
        assert len(got_row) == 1, f"region '{region}' not found in aggregate"
        got_val = got_row["total_amount"].iloc[0]
        assert abs(got_val - exp_row["total_amount"]) < 0.01, \
            f"{region} total_amount: expected {exp_row['total_amount']:.2f}, got {got_val:.2f}"


def test_agg_total_quantity_values():
    cleaned = _cleaned()
    agg = _agg()
    expected = (
        cleaned.groupby("region")["quantity"]
        .sum()
        .sort_index()
        .reset_index()
        .rename(columns={"quantity": "total_quantity"})
    )
    for _, exp_row in expected.iterrows():
        region = exp_row["region"]
        got_row = agg[agg["region"] == region]
        got_val = int(got_row["total_quantity"].iloc[0])
        assert got_val == int(exp_row["total_quantity"]), \
            f"{region} total_quantity: expected {exp_row['total_quantity']}, got {got_val}"


def test_agg_order_count_values():
    cleaned = _cleaned()
    agg = _agg()
    expected = (
        cleaned.groupby("region")
        .size()
        .sort_index()
        .reset_index(name="order_count")
    )
    for _, exp_row in expected.iterrows():
        region = exp_row["region"]
        got_row = agg[agg["region"] == region]
        got_val = int(got_row["order_count"].iloc[0])
        assert got_val == int(exp_row["order_count"]), \
            f"{region} order_count: expected {exp_row['order_count']}, got {got_val}"
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
