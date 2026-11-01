#!/usr/bin/env bash
# Verifier for "Data Quality Gate".
# Plants a hidden pytest suite, runs it, prints flag only when all pass.
set -uo pipefail

SLUG="06-data-quality-gate"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{data_quality_gates_protect_downstream}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/validator.py" ] || fail "validator.py not found — run setup.sh first"
[ -f "$WORK/data/clean.csv" ]     || fail "clean.csv not found — run setup.sh first"
[ -f "$WORK/data/corrupted.csv" ] || fail "corrupted.csv not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pandas"
fi

# ── hidden test suite ────────────────────────────────────────────────────────
HIDDEN_DIR="$WORK/_verify_hidden"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pandas as pd
import pytest
from datetime import date
from validator import DataContract, ValidationReport, validate, run_pipeline, DataQualityError

# Fixed reference date — 31 days after BASE (2024-03-01), so MAX date 2024-03-28 is still fresh
# but any date seeded at BASE - 60 days (2024-01-01) is stale.
REF_DATE = date(2024, 4, 1)

DATA_DIR     = os.path.join(os.path.dirname(__file__), "..", "data")
CONTRACT_DIR = os.path.join(os.path.dirname(__file__), "..", "contracts")
CONTRACT_PATH = os.path.join(CONTRACT_DIR, "orders_contract.json")


@pytest.fixture(scope="module")
def contract():
    return DataContract.from_file(CONTRACT_PATH)

@pytest.fixture(scope="module")
def clean(contract):
    return pd.read_csv(os.path.join(DATA_DIR, "clean.csv"))

@pytest.fixture(scope="module")
def corrupted(contract):
    return pd.read_csv(os.path.join(DATA_DIR, "corrupted.csv"))


# ── clean dataset: all checks pass ───────────────────────────────────────────

def test_clean_report_passed(contract, clean):
    report = validate(clean, contract, REF_DATE)
    assert isinstance(report, ValidationReport), "validate must return a ValidationReport"
    assert report.passed is True, f"clean.csv must pass; violations: {report.violations}"

def test_clean_no_violations(contract, clean):
    report = validate(clean, contract, REF_DATE)
    assert report.violations == [], f"Expected no violations, got: {report.violations}"

def test_clean_run_pipeline_returns_df(contract, clean):
    result = run_pipeline(clean, contract, REF_DATE)
    assert isinstance(result, pd.DataFrame)
    assert len(result) == len(clean)


# ── corrupted dataset: specific checks fire ──────────────────────────────────

def test_corrupted_report_not_passed(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    assert report.passed is False

def test_corrupted_has_violations(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    assert len(report.violations) > 0

def test_corrupted_run_pipeline_raises(contract, corrupted):
    with pytest.raises(DataQualityError):
        run_pipeline(corrupted, contract, REF_DATE)

def _check_names(report):
    return {v["check"] for v in report.violations}


def test_null_violation_detected(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    names = _check_names(report)
    assert "non_null" in names or "unique" in names, \
        f"Expected non_null or unique violation for null order_id, got checks: {names}"

def test_range_violation_detected(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    names = _check_names(report)
    assert "range" in names, f"Expected range violation for out-of-bounds amount, got: {names}"

def test_allowed_values_violation_detected(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    names = _check_names(report)
    assert "allowed_values" in names, f"Expected allowed_values violation, got: {names}"

def test_freshness_violation_detected(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    names = _check_names(report)
    assert "freshness" in names, f"Expected freshness violation, got: {names}"


# ── schema check: missing column ─────────────────────────────────────────────

def test_missing_column_schema_violation(contract):
    df_missing = pd.DataFrame({"order_id": [1], "order_date": ["2024-03-15"],
                                "customer_id": ["C001"], "amount": [100.0]})
    # 'status' column is missing
    report = validate(df_missing, contract, REF_DATE)
    assert report.passed is False
    names = _check_names(report)
    assert "schema" in names, f"Expected schema violation for missing column, got: {names}"


# ── uniqueness: synthetic duplicate ──────────────────────────────────────────

def test_unique_violation_detected(contract):
    df_dup = pd.DataFrame({
        "order_id":    [1, 1, 2],
        "order_date":  ["2024-03-15", "2024-03-16", "2024-03-17"],
        "customer_id": ["C001", "C002", "C003"],
        "amount":      [100.0, 200.0, 300.0],
        "status":      ["confirmed", "pending", "shipped"],
    })
    report = validate(df_dup, contract, REF_DATE)
    assert report.passed is False
    names = _check_names(report)
    assert "unique" in names, f"Expected unique violation for duplicate order_id, got: {names}"


# ── freshness: stale reference date ──────────────────────────────────────────

def test_freshness_stale_reference(contract, clean):
    stale_ref = date(2025, 1, 1)   # far future — all 2024-03 dates are stale
    report = validate(clean, contract, stale_ref)
    assert report.passed is False
    names = _check_names(report)
    assert "freshness" in names, f"Expected freshness violation with stale reference, got: {names}"


# ── violation dict structure ──────────────────────────────────────────────────

def test_violation_has_check_and_detail_keys(contract, corrupted):
    report = validate(corrupted, contract, REF_DATE)
    for v in report.violations:
        assert "check" in v,  f"Violation missing 'check' key: {v}"
        assert "detail" in v, f"Violation missing 'detail' key: {v}"
        assert isinstance(v["check"], str)
        assert isinstance(v["detail"], str)
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
