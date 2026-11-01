# Data Quality Gate

A Slack alert fires at 03:14: *"Revenue report is wrong. Finance already sent the board deck."* Root cause: the ETL ingested a corrupted CSV with null `order_id` values and amounts outside any valid range. The pipeline had no quality checks — it loaded and propagated garbage silently.

Data contracts are the industry's answer: before any transformation or load step, assert that the incoming data meets a declared specification. If it doesn't, **fail the pipeline loudly** so downstream consumers never touch bad data.

Your job is to implement the gate that teams like Netflix's Datahub, Databricks' Delta Expectations, and Great Expectations all encode: a schema-driven validator that returns a structured pass/fail report and raises on violation.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/06-data-quality-gate/
├── validator.py             # stub — one class + one function to implement
├── data/
│   ├── clean.csv            # 100 rows passing all checks
│   └── corrupted.csv        # 100 rows with injected violations
├── contracts/
│   └── orders_contract.json # data-contract spec (schema, rules)
└── tests/
    └── test_sample.py       # visible smoke tests
```

## Mission

Implement `validator.py`:

### `DataContract` (dataclass or plain class)

Loaded from a JSON spec with this shape:

```json
{
  "name": "orders",
  "columns": [
    {"name": "order_id",    "dtype": "int",    "nullable": false, "unique": true},
    {"name": "order_date",  "dtype": "date",   "nullable": false},
    {"name": "customer_id", "dtype": "str",    "nullable": false},
    {"name": "amount",      "dtype": "float",  "nullable": false, "min": 0.01, "max": 50000.0},
    {"name": "status",      "dtype": "str",    "nullable": false,
     "allowed_values": ["pending", "confirmed", "shipped", "delivered", "cancelled"]}
  ],
  "freshness": {
    "column": "order_date",
    "max_age_days": 30
  }
}
```

### `validate(df, contract, reference_date) -> ValidationReport`

Runs every declared check and returns a `ValidationReport`:

```python
@dataclass
class ValidationReport:
    passed: bool                   # True iff zero violations
    violations: list[dict]         # one dict per failed check
```

Each violation dict must contain at least `"check"` (str) and `"detail"` (str).

### Checks to implement

| Check | Trigger |
|-------|---------|
| **schema** | A required column is missing from `df` |
| **non_null** | `nullable: false` column contains any nulls |
| **unique** | `unique: true` column contains duplicate values |
| **dtype** | Column cannot be coerced to declared type (`int`/`float`/`date`/`str`) |
| **range** | `min` or `max` declared and a value falls outside it |
| **allowed_values** | A value not in `allowed_values` list appears |
| **freshness** | `max(order_date) < reference_date - max_age_days` |

### `run_pipeline(df, contract, reference_date) -> pd.DataFrame`

Calls `validate`. If `report.passed` is `False`, raises `DataQualityError` (your custom exception) with a message listing the violations. If passed, returns `df` unchanged.

## Conditions checked by the verifier

| Dataset | Expected outcome |
|---------|-----------------|
| `clean.csv` against the contract | `report.passed == True`, `run_pipeline` returns the DataFrame |
| `corrupted.csv` against the contract | `report.passed == False`, specific checks in `report.violations`, `run_pipeline` raises `DataQualityError` |
| Contract with missing column | schema violation present in report |
| Null in non-nullable column | non_null violation present |
| Duplicate unique-key value | unique violation present |
| Out-of-range amount | range violation present |
| Invalid status value | allowed_values violation present |
| Stale date (> max_age_days old) | freshness violation present |

## Why this matters

Every modern data platform enforces contracts at ingestion time. The pattern here — load spec as data, run checks, return a structured report, raise on failure — is exactly what `great_expectations.validate()`, Delta Lake's `DeltaTable.merge()` constraints, and dbt tests implement. Understanding the core makes tuning thresholds and writing custom expectations trivial instead of opaque.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/06-data-quality-gate/verify.sh
```

All tests green → flag printed.
