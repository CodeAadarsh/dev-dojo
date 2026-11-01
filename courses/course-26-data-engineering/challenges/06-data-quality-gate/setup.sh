#!/usr/bin/env bash
# Plants the "Data Quality Gate" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="06-data-quality-gate"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/data" "$WORK/contracts" "$WORK/tests"

# ── seed data (deterministic, fixed RNG) ──────────────────────────────────────
python3 - << 'PYSEED'
import random, csv, os
from datetime import date, timedelta

random.seed(99)

STATUSES = ["pending", "confirmed", "shipped", "delivered", "cancelled"]
BASE = date(2024, 3, 1)

def make_row(order_id, corrupt=False):
    od = BASE + timedelta(days=random.randint(0, 27))
    amt = round(random.uniform(5.0, 4999.0), 2)
    cust = f"C{random.randint(1, 50):03d}"
    status = random.choice(STATUSES)
    if corrupt:
        # inject one violation type per row, cycling
        vtype = order_id % 6
        if vtype == 0:
            order_id = None        # null unique key
        elif vtype == 1:
            amt = -5.0             # below min
        elif vtype == 2:
            amt = 99999.0          # above max
        elif vtype == 3:
            status = "UNKNOWN"     # bad allowed value
        elif vtype == 4:
            od = BASE - timedelta(days=60)  # stale date
        # vtype == 5: duplicate order_id (handled below)
    return {
        "order_id": order_id,
        "order_date": str(od),
        "customer_id": cust,
        "amount": amt,
        "status": status,
    }

work = os.path.expanduser("~/.kube-dojo-work/06-data-quality-gate")
fields = ["order_id", "order_date", "customer_id", "amount", "status"]

# clean: 100 rows, all valid
clean_rows = [make_row(i) for i in range(1, 101)]
with open(os.path.join(work, "data", "clean.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(clean_rows)

# corrupted: 100 rows with injected violations
corrupt_rows = [make_row(i, corrupt=True) for i in range(1, 101)]
# additionally inject a duplicate order_id at position 10
corrupt_rows[10]["order_id"] = corrupt_rows[5]["order_id"]
with open(os.path.join(work, "data", "corrupted.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(corrupt_rows)

print("Wrote clean.csv and corrupted.csv")
PYSEED

# ── contract JSON ─────────────────────────────────────────────────────────────
cat > "$WORK/contracts/orders_contract.json" << 'JSONEOF'
{
  "name": "orders",
  "columns": [
    {"name": "order_id",    "dtype": "int",   "nullable": false, "unique": true},
    {"name": "order_date",  "dtype": "date",  "nullable": false},
    {"name": "customer_id", "dtype": "str",   "nullable": false},
    {"name": "amount",      "dtype": "float", "nullable": false, "min": 0.01, "max": 50000.0},
    {"name": "status",      "dtype": "str",   "nullable": false,
     "allowed_values": ["pending", "confirmed", "shipped", "delivered", "cancelled"]}
  ],
  "freshness": {
    "column": "order_date",
    "max_age_days": 30
  }
}
JSONEOF

# ── validator.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/validator.py" << 'PYEOF'
# validator.py — data-contract validation engine
# Implement DataContract, ValidationReport, validate(), and run_pipeline().
# Do NOT change the public signatures; the verifier imports them.
from __future__ import annotations
import json
from dataclasses import dataclass, field
from datetime import date
import pandas as pd


class DataQualityError(Exception):
    """Raised by run_pipeline when the validation report has violations."""


@dataclass
class ValidationReport:
    passed: bool
    violations: list[dict] = field(default_factory=list)


class DataContract:
    """Loaded from a JSON spec file. See orders_contract.json for the schema."""

    def __init__(self, spec: dict):
        # parse spec into whatever attributes you need
        raise NotImplementedError("implement DataContract.__init__")

    @classmethod
    def from_file(cls, path: str) -> "DataContract":
        with open(path) as f:
            return cls(json.load(f))


def validate(df: pd.DataFrame, contract: DataContract, reference_date: date) -> ValidationReport:
    """Run all checks declared in contract against df.

    reference_date: the date to compare against for freshness checks (inject
    it rather than using date.today() so tests are deterministic).

    Returns a ValidationReport. Never raises — violations go in the report.
    """
    raise NotImplementedError("implement validate")


def run_pipeline(df: pd.DataFrame, contract: DataContract, reference_date: date) -> pd.DataFrame:
    """Call validate; raise DataQualityError on any violation, else return df."""
    raise NotImplementedError("implement run_pipeline")
PYEOF

# ── tests/test_sample.py (visible smoke) ─────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
import pytest
from datetime import date
from validator import DataContract, validate, run_pipeline, DataQualityError

CONTRACTS = os.path.join(os.path.dirname(__file__), "..", "contracts", "orders_contract.json")
CLEAN     = os.path.join(os.path.dirname(__file__), "..", "data", "clean.csv")
CORRUPTED = os.path.join(os.path.dirname(__file__), "..", "data", "corrupted.csv")

REF_DATE = date(2024, 4, 1)   # within 30 days of BASE=2024-03-01

def test_clean_passes():
    contract = DataContract.from_file(CONTRACTS)
    df = pd.read_csv(CLEAN)
    report = validate(df, contract, REF_DATE)
    assert report.passed, f"clean.csv should pass; violations: {report.violations}"

def test_corrupted_fails():
    contract = DataContract.from_file(CONTRACTS)
    df = pd.read_csv(CORRUPTED)
    report = validate(df, contract, REF_DATE)
    assert not report.passed, "corrupted.csv should produce violations"

def test_run_pipeline_raises_on_corruption():
    contract = DataContract.from_file(CONTRACTS)
    df = pd.read_csv(CORRUPTED)
    with pytest.raises(DataQualityError):
        run_pipeline(df, contract, REF_DATE)
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement DataContract, validate(), and run_pipeline()"
echo "                 in validator.py so the test suite passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest pandas"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-26-data-engineering/challenges/$SLUG/verify.sh"
