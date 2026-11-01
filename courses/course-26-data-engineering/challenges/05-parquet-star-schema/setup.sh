#!/usr/bin/env bash
# Plants the "Parquet Star Schema" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="05-parquet-star-schema"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/data" "$WORK/tests"

# ── seeded dataset (200 rows, fixed RNG = deterministic) ─────────────────────
python3 - << 'PYSEED'
import random, csv, os

random.seed(42)

customers = [
    (f"C{i:03d}", f"Customer_{i}", f"c{i}@example.com",
     random.choice(["IN", "US", "DE", "SG", "GB"]))
    for i in range(1, 21)
]
products = [
    (f"P{i:02d}", f"Product_{i}",
     random.choice(["Electronics", "Clothing", "Books", "Food", "Tools"]),
     round(random.uniform(5, 500), 2))
    for i in range(1, 11)
]
dates = [f"2024-01-{d:02d}" for d in range(1, 8)]

rows = []
for order_id in range(1, 201):
    c = random.choice(customers)
    p = random.choice(products)
    qty = random.randint(1, 10)
    rows.append({
        "order_id": order_id,
        "order_date": random.choice(dates),
        "customer_id": c[0],
        "customer_name": c[1],
        "customer_email": c[2],
        "customer_country": c[3],
        "product_id": p[0],
        "product_name": p[1],
        "product_category": p[2],
        "product_unit_price": p[3],
        "quantity": qty,
        "total_amount": round(p[3] * qty, 2),
    })

work = os.path.expanduser("~/.kube-dojo-work/05-parquet-star-schema")
out = os.path.join(work, "data", "orders_raw.csv")
fields = ["order_id","order_date","customer_id","customer_name","customer_email",
          "customer_country","product_id","product_name","product_category",
          "product_unit_price","quantity","total_amount"]
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(f"Wrote {len(rows)} rows to {out}")
PYSEED

# ── transform.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/transform.py" << 'PYEOF'
# transform.py — star schema + partitioned Parquet
# Implement the four functions. Do NOT change their signatures.
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from pathlib import Path


def build_dim_customers(df: pd.DataFrame) -> pd.DataFrame:
    """Extract customer dimension: one row per unique customer_id.

    Columns: customer_id, customer_name, customer_email, customer_country.
    """
    raise NotImplementedError("implement build_dim_customers")


def build_dim_products(df: pd.DataFrame) -> pd.DataFrame:
    """Extract product dimension: one row per unique product_id.

    Columns: product_id, product_name, product_category, product_unit_price.
    """
    raise NotImplementedError("implement build_dim_products")


def build_fact_orders(df: pd.DataFrame) -> pd.DataFrame:
    """Build fact table: one row per order, foreign keys only (no attributes).

    Columns: order_id, order_date, customer_id, product_id, quantity, total_amount.
    order_date must be dtype datetime64 (not str).
    """
    raise NotImplementedError("implement build_fact_orders")


def write_partitioned(fact_df: pd.DataFrame, output_dir: str) -> None:
    """Write fact_df to Parquet partitioned by order_date under output_dir/fact_orders/.

    Partition layout:
        output_dir/fact_orders/order_date=YYYY-MM-DD/*.parquet
    """
    raise NotImplementedError("implement write_partitioned")
PYEOF

# ── tests/test_sample.py (visible smoke harness) ─────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
import pytest
from transform import build_dim_customers, build_dim_products, build_fact_orders, write_partitioned

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "orders_raw.csv")

@pytest.fixture(scope="module")
def raw():
    return pd.read_csv(DATA)

def test_dim_customers_no_duplicates(raw):
    dim = build_dim_customers(raw)
    assert dim["customer_id"].nunique() == len(dim)

def test_dim_products_no_duplicates(raw):
    dim = build_dim_products(raw)
    assert dim["product_id"].nunique() == len(dim)

def test_fact_row_count_matches_raw(raw):
    fact = build_fact_orders(raw)
    assert len(fact) == len(raw)

def test_fact_date_is_datetime(raw):
    fact = build_fact_orders(raw)
    assert pd.api.types.is_datetime64_any_dtype(fact["order_date"]), \
        "order_date must be datetime64, not string"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the four functions in transform.py so the"
echo "                 pytest harness passes and fact_orders/ is partitioned."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest pandas pyarrow"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-26-data-engineering/challenges/$SLUG/verify.sh"
