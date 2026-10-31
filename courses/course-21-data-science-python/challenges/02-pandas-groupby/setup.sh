#!/usr/bin/env bash
# Plants the "Pandas GroupBy" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="02-pandas-groupby"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── generate messy sales_data.csv ────────────────────────────────────────────
python3 -I - "$WORK" << 'PYEOF'
import sys, csv, random, math

random.seed(20241101)

REGIONS_RAW = ["north", "North", "NORTH", "south", "South", "SOUTH",
               "east",  "East",  "EAST",  "west",  "West",  "WEST"]
REGIONS_CLEAN = {"north": "North", "south": "South", "east": "East", "west": "West"}

rows = []
for i in range(1, 501):
    region = random.choice(REGIONS_RAW)
    amount = round(random.uniform(10.0, 5000.0), 2)
    quantity = random.randint(1, 100)
    date_str = f"2024-{random.randint(1,12):02d}-{random.randint(1,28):02d}"

    # Inject dirt
    order_id_val = str(i)
    amount_val = str(amount)

    dice = random.random()
    if dice < 0.06:                          # ~6% bad order_id
        order_id_val = "N/A"
    elif dice < 0.10:                        # ~4% dollar+comma format
        amount_val = f"${amount:,.2f}"
    elif dice < 0.13:                        # ~3% comma-only format
        amount_val = f"{amount:,.2f}"

    rows.append([order_id_val, region, amount_val, quantity, date_str])

out_path = sys.argv[1] + "/sales_data.csv"
with open(out_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["order_id", "region", "amount", "quantity", "date"])
    w.writerows(rows)

print(f"Wrote {len(rows)} rows to {out_path}")
PYEOF

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — pandas clean-and-aggregate challenge
#
# The CSV at sales_data.csv has messy data:
#   - order_id: some rows contain "N/A" (drop those rows)
#   - region:   mixed case ("north", "North", "NORTH" — all same region)
#   - amount:   some cells have "$" prefix and/or commas (e.g. "$1,234.50")
#   - quantity: int, but may need casting after dirty rows are dropped
#   - date:     stored as "YYYY-MM-DD" strings
#
# Implement clean() and aggregate() below. Do NOT modify the function signatures.

import pandas as pd


def clean(df: pd.DataFrame) -> pd.DataFrame:
    """Return a cleaned copy of df.

    Cleaning contract (the verifier asserts all of these):
    - Drop rows where order_id cannot be parsed as an integer (e.g. "N/A").
    - order_id  -> int64
    - region    -> str, title-cased ("north" -> "North")
    - amount    -> float64 (strip leading "$" and embedded commas first)
    - quantity  -> int64
    - date      -> datetime64[ns]
    """
    # TODO: implement cleaning
    raise NotImplementedError("implement clean()")


def aggregate(df: pd.DataFrame) -> pd.DataFrame:
    """Given a cleaned DataFrame, return a regional summary.

    Returns a DataFrame with columns:
        region, total_amount, total_quantity, order_count
    sorted ascending by region, index reset to 0-based integer.
    """
    # TODO: implement aggregation
    raise NotImplementedError("implement aggregate()")
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
from solution import clean, aggregate

CSV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sales_data.csv")


def test_dtypes_after_clean():
    df = pd.read_csv(CSV)
    cleaned = clean(df)
    assert str(cleaned["order_id"].dtype) == "int64",   "order_id must be int64"
    assert str(cleaned["amount"].dtype)   == "float64", "amount must be float64"
    assert str(cleaned["quantity"].dtype) == "int64",   "quantity must be int64"
    assert str(cleaned["date"].dtype).startswith("datetime"), "date must be datetime"


def test_aggregate_shape():
    df = pd.read_csv(CSV)
    cleaned = clean(df)
    agg = aggregate(cleaned)
    assert set(agg.columns) >= {"region", "total_amount", "total_quantity", "order_count"}, \
        f"missing columns: {set(agg.columns)}"
    assert len(agg) == 4, f"expected 4 regions (N/S/E/W), got {len(agg)}"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement clean() and aggregate() in solution.py"
echo "                   so all hidden tests pass."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas numpy"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
