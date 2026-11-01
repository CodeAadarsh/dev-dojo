#!/usr/bin/env bash
# Verifier for "Parquet Star Schema".
# Plants a hidden pytest suite, runs it, prints flag only when all pass.
set -uo pipefail

SLUG="05-parquet-star-schema"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{star_schema_tells_the_story}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/transform.py" ] || fail "transform.py not found — run setup.sh first"
[ -f "$WORK/data/orders_raw.csv" ] || fail "orders_raw.csv not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas pyarrow"
fi

# ── hidden test suite ────────────────────────────────────────────────────────
HIDDEN_DIR="$WORK/_verify_hidden"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
import sys, os, shutil, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
import pyarrow.parquet as pq
import pytest
from pathlib import Path
from transform import (
    build_dim_customers,
    build_dim_products,
    build_fact_orders,
    write_partitioned,
)

DATA = os.path.join(
    os.path.dirname(__file__), "..", "data", "orders_raw.csv"
)

FACT_COLS  = {"order_id", "order_date", "customer_id", "product_id", "quantity", "total_amount"}
CUST_COLS  = {"customer_id", "customer_name", "customer_email", "customer_country"}
PROD_COLS  = {"product_id", "product_name", "product_category", "product_unit_price"}


@pytest.fixture(scope="module")
def raw():
    return pd.read_csv(DATA)


@pytest.fixture(scope="module")
def dims(raw):
    return build_dim_customers(raw), build_dim_products(raw)


@pytest.fixture(scope="module")
def fact(raw):
    return build_fact_orders(raw)


# ── dim_customers ─────────────────────────────────────────────────────────────

def test_dim_customers_columns(raw):
    dim = build_dim_customers(raw)
    assert set(dim.columns) >= CUST_COLS, f"Missing columns: {CUST_COLS - set(dim.columns)}"

def test_dim_customers_unique_ids(raw):
    dim = build_dim_customers(raw)
    assert dim["customer_id"].nunique() == len(dim), "Duplicate customer_id rows"

def test_dim_customers_row_count(raw):
    dim = build_dim_customers(raw)
    expected = raw["customer_id"].nunique()
    assert len(dim) == expected, f"Expected {expected} customer rows, got {len(dim)}"

def test_dim_customers_no_nulls(raw):
    dim = build_dim_customers(raw)
    assert dim[list(CUST_COLS)].isnull().sum().sum() == 0


# ── dim_products ──────────────────────────────────────────────────────────────

def test_dim_products_columns(raw):
    dim = build_dim_products(raw)
    assert set(dim.columns) >= PROD_COLS

def test_dim_products_unique_ids(raw):
    dim = build_dim_products(raw)
    assert dim["product_id"].nunique() == len(dim)

def test_dim_products_row_count(raw):
    dim = build_dim_products(raw)
    expected = raw["product_id"].nunique()
    assert len(dim) == expected, f"Expected {expected} product rows, got {len(dim)}"


# ── fact_orders ───────────────────────────────────────────────────────────────

def test_fact_columns(fact):
    assert set(fact.columns) == FACT_COLS, \
        f"Fact table must have exactly {FACT_COLS}, got {set(fact.columns)}"

def test_fact_row_count(raw, fact):
    assert len(fact) == len(raw), f"Fact row count must equal raw ({len(raw)}), got {len(fact)}"

def test_fact_order_id_unique(fact):
    assert fact["order_id"].nunique() == len(fact), "order_id must be unique in fact table"

def test_fact_date_dtype(fact):
    assert pd.api.types.is_datetime64_any_dtype(fact["order_date"]), \
        "order_date must be datetime64"


# ── partitioned Parquet ───────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def parquet_dir(raw, fact):
    tmp = tempfile.mkdtemp()
    write_partitioned(fact, tmp)
    yield tmp
    shutil.rmtree(tmp, ignore_errors=True)


def test_partition_directories_exist(raw, parquet_dir):
    fact_root = Path(parquet_dir) / "fact_orders"
    assert fact_root.is_dir(), "fact_orders/ directory not found under output_dir"
    date_dirs = [d for d in fact_root.iterdir() if d.is_dir() and d.name.startswith("order_date=")]
    assert len(date_dirs) > 0, "No order_date= partition directories found"
    expected_dates = pd.read_csv(DATA)["order_date"].unique()
    assert len(date_dirs) == len(expected_dates), \
        f"Expected {len(expected_dates)} partition dirs, found {len(date_dirs)}"


def test_parquet_round_trip_row_count(raw, parquet_dir):
    fact_root = Path(parquet_dir) / "fact_orders"
    ds = pq.ParquetDataset(str(fact_root))
    recovered = ds.read().to_pandas()
    assert len(recovered) == len(raw), \
        f"Round-trip row count mismatch: expected {len(raw)}, got {len(recovered)}"


def test_parquet_join_reproduces_total_amount(raw, parquet_dir):
    """Join fact + dims and check total_amount sum matches raw (±0.01 for float rounding)."""
    fact_root = Path(parquet_dir) / "fact_orders"
    fact_rt = pq.ParquetDataset(str(fact_root)).read().to_pandas()
    raw_sum = raw["total_amount"].sum()
    fact_sum = fact_rt["total_amount"].sum()
    assert abs(fact_sum - raw_sum) < 0.01, \
        f"total_amount sum mismatch: raw={raw_sum:.2f}, fact={fact_sum:.2f}"
PYEOF

if $PYTEST "$HIDDEN_DIR/test_hidden.py" -q 2>&1; then
    rm -rf "$HIDDEN_DIR"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "$HIDDEN_DIR"
    fail "test suite has failures — fix your implementation and retry"
fi
