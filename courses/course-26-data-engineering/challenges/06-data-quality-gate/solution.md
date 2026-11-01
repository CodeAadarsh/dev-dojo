# Solution — Data Quality Gate

The complete `validator.py`. Key decisions below.

```python
from __future__ import annotations
import json
from dataclasses import dataclass, field
from datetime import date, timedelta
import pandas as pd


class DataQualityError(Exception):
    """Raised by run_pipeline when the validation report has violations."""


@dataclass
class ValidationReport:
    passed: bool
    violations: list[dict] = field(default_factory=list)


@dataclass
class _ColumnSpec:
    name: str
    dtype: str
    nullable: bool = True
    unique: bool = False
    min: float | None = None
    max: float | None = None
    allowed_values: list[str] | None = None


class DataContract:
    def __init__(self, spec: dict):
        self.name = spec["name"]
        self.columns = [_ColumnSpec(**col) for col in spec["columns"]]
        self.freshness = spec.get("freshness")

    @classmethod
    def from_file(cls, path: str) -> "DataContract":
        with open(path) as f:
            return cls(json.load(f))


def validate(df: pd.DataFrame, contract: DataContract, reference_date: date) -> ValidationReport:
    violations: list[dict] = []

    for col_spec in contract.columns:
        col = col_spec.name

        # schema: column present?
        if col not in df.columns:
            violations.append({"check": "schema", "detail": f"column '{col}' missing"})
            continue   # can't run further checks on an absent column

        series = df[col]

        # non_null
        null_count = series.isnull().sum()
        if not col_spec.nullable and null_count > 0:
            violations.append({
                "check": "non_null",
                "detail": f"column '{col}' has {null_count} null values",
            })

        # unique
        if col_spec.unique:
            non_null = series.dropna()
            dup_count = int(non_null.duplicated().sum())
            if dup_count > 0:
                violations.append({
                    "check": "unique",
                    "detail": f"column '{col}' has {dup_count} duplicate values",
                })

        # dtype coercion check
        try:
            if col_spec.dtype == "int":
                pd.to_numeric(series.dropna(), errors="raise").astype(int)
            elif col_spec.dtype == "float":
                pd.to_numeric(series.dropna(), errors="raise")
            elif col_spec.dtype == "date":
                pd.to_datetime(series.dropna(), errors="raise")
            # str: anything coerces to str, skip
        except Exception:
            violations.append({
                "check": "dtype",
                "detail": f"column '{col}' cannot be coerced to {col_spec.dtype}",
            })

        # range
        if col_spec.min is not None or col_spec.max is not None:
            numeric = pd.to_numeric(series, errors="coerce")
            if col_spec.min is not None:
                below = int((numeric < col_spec.min).sum())
                if below > 0:
                    violations.append({
                        "check": "range",
                        "detail": f"column '{col}' has {below} values below min={col_spec.min}",
                    })
            if col_spec.max is not None:
                above = int((numeric > col_spec.max).sum())
                if above > 0:
                    violations.append({
                        "check": "range",
                        "detail": f"column '{col}' has {above} values above max={col_spec.max}",
                    })

        # allowed_values
        if col_spec.allowed_values is not None:
            bad = series.dropna()[~series.dropna().isin(col_spec.allowed_values)]
            if len(bad) > 0:
                violations.append({
                    "check": "allowed_values",
                    "detail": f"column '{col}' has {len(bad)} values not in {col_spec.allowed_values}",
                })

    # freshness
    if contract.freshness:
        fcol = contract.freshness["column"]
        max_age = contract.freshness["max_age_days"]
        if fcol in df.columns:
            max_date = pd.to_datetime(df[fcol], errors="coerce").max()
            if pd.notna(max_date):
                threshold = reference_date - timedelta(days=max_age)
                if max_date.date() < threshold:
                    violations.append({
                        "check": "freshness",
                        "detail": (
                            f"column '{fcol}' max date {max_date.date()} "
                            f"is older than threshold {threshold} "
                            f"(max_age_days={max_age})"
                        ),
                    })

    return ValidationReport(passed=len(violations) == 0, violations=violations)


def run_pipeline(df: pd.DataFrame, contract: DataContract, reference_date: date) -> pd.DataFrame:
    report = validate(df, contract, reference_date)
    if not report.passed:
        details = "; ".join(v["detail"] for v in report.violations)
        raise DataQualityError(f"Data quality check failed: {details}")
    return df
```

## Why each piece is correct

**`continue` after a schema violation.**
If a column is absent, every downstream check for that column will crash with a `KeyError` or produce misleading results. Skipping the remaining checks for a missing column is the right defensive move — you want one clean violation per problem, not a cascade of confusing errors.

**`dropna()` before uniqueness check.**
`duplicated()` on a series that contains `NaN` values would flag all nulls as duplicates of each other (pandas considers `NaN == NaN` for `duplicated` purposes). We check non-null separately under the `non_null` rule; the uniqueness rule should only fire for actual duplicate keys.

**`reference_date` as a parameter, not `date.today()`.**
Using the wall clock in a validator makes it non-deterministic: a test suite that passes at 23:59 fails at 00:01 if a freshness threshold crosses midnight. Injecting `reference_date` is the dependency-inversion pattern — the caller (the test) controls time, so every run against the same data produces the same report.

**Structured violations dict.**
Returning `{"check": "range", "detail": "..."}` instead of plain strings lets the caller filter by check type, aggregate counts, and route to alerting systems (e.g. "escalate all `freshness` violations to the SLA oncall, ignore `allowed_values`"). Great Expectations does exactly this with its `ExpectationValidationResult` objects.

**`DataQualityError` vs returning `False`.**
Raising rather than returning a falsy value forces callers to handle the failure explicitly. A `try/except DataQualityError` in an orchestrator (e.g. your DAG from challenge 04) maps cleanly to a failed task — which then skips downstream load steps via the skip-propagation mechanism you just built.

## The check taxonomy in the real world

| This implementation | Great Expectations | Delta Lake | dbt tests |
|---|---|---|---|
| schema | `expect_column_to_exist` | table schema | `not_null` column block |
| non_null | `expect_column_values_to_not_be_null` | `NOT NULL` constraint | `not_null` |
| unique | `expect_column_values_to_be_unique` | `UNIQUE` constraint | `unique` |
| range | `expect_column_values_to_be_between` | `CHECK` constraint | custom test |
| allowed_values | `expect_column_values_to_be_in_set` | — | `accepted_values` |
| freshness | `expect_table_row_count_to_be_between` (indirect) | — | `freshness` block |
