# Data Quality & Governance

> **Module 07 · Course 26** — Your pipeline runs green, your DAG shows all-success. Your stakeholders just filed a P1 because the weekly revenue number is 12% off. Data quality failures are silent by default — they produce no stacktrace, no alert, no red dashboard. Governance is the system you build so that silence stops being acceptable.

This module covers how to make data quality an explicit, testable, observable property of a pipeline — not an assumption.

---

## Data Contracts

A **data contract** is a formal, versioned agreement between a data producer and a data consumer about the shape, semantics, and reliability of a dataset. It answers:

- What columns exist, and what are their types and constraints?
- What is the expected row count range per load interval?
- What is the maximum acceptable lateness (freshness SLA)?
- Who owns this dataset, and what is the change notification process?

Without a contract, you have an implicit contract: consumers assume the schema never changes, nulls never appear in non-null columns, and freshness is "whenever the pipeline runs." Every one of those implicit assumptions gets violated eventually.

```yaml
# data_contract_orders_v1.yaml  (example schema — many formats exist)
contract:
  id: orders-daily
  version: "1.3.0"
  owner: data-platform@company.com
  dataset: warehouse.fact_orders
  schedule: "0 4 * * *"          # expected at 04:00 UTC daily
  freshness_sla_hours: 2          # data older than 6h past schedule = violation

schema:
  - name: order_id
    type: bigint
    nullable: false
    unique: true
  - name: customer_id
    type: bigint
    nullable: false
  - name: revenue
    type: float
    nullable: false
    min: 0.0
  - name: order_date
    type: date
    nullable: false

volume:
  min_rows_per_day: 5000
  max_rows_per_day: 500000
```

Contracts live in Git. When a producer changes the schema, they bump the version and notify consumers. Without this process, breaking schema changes are discovered in production by angry stakeholders.

---

## Validation: Schema, Distribution, Nulls, Uniqueness

**Schema validation** catches structural breaks: wrong column type after a migration, a dropped column, a renamed field.

**Statistical validation** catches semantic breaks: the revenue column is `float` and non-null (schema valid), but today's average is $0.03 (vs historical $42.50). Schema checks pass; the data is garbage.

### The four validation layers

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 1: Schema                                                     │
│   - Column names present                                            │
│   - Dtypes match contract                                           │
│   - No unexpected NEW columns (breaking change indicator)          │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 2: Completeness / Nulls                                       │
│   - Null rate per column ≤ max_null_pct from contract               │
│   - NOT NULL columns have 0 nulls                                   │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 3: Uniqueness                                                 │
│   - Primary key or business key has zero duplicates                 │
│   - Compound key (order_id, line_item_id) is unique                 │
├─────────────────────────────────────────────────────────────────────┤
│ Layer 4: Distribution / Value ranges                                │
│   - Numeric columns: mean, stddev, min, max within expected range   │
│   - Categorical columns: known set of values; no unexpected         │
│     categories; counts per category roughly stable                  │
│   - Row count: within [min_rows, max_rows] per interval             │
└─────────────────────────────────────────────────────────────────────┘
```

### Implementing validation in Python (Great Expectations style)

You don't need the full GX framework to implement these checks. The patterns are simple pandas/pyarrow operations:

```python
import pandas as pd
import pyarrow.parquet as pq
from dataclasses import dataclass, field
from typing import List, Optional

@dataclass
class ValidationResult:
    check: str
    passed: bool
    detail: str

def validate_orders(path: str, ds: str) -> List[ValidationResult]:
    df = pq.read_table(path).to_pandas()
    results = []

    # Layer 1: Schema
    expected = {"order_id", "customer_id", "revenue", "order_date"}
    missing = expected - set(df.columns)
    results.append(ValidationResult(
        "schema_columns_present",
        len(missing) == 0,
        f"missing: {missing}" if missing else "ok",
    ))

    # Layer 2: Nulls
    for col in ["order_id", "customer_id", "revenue"]:
        null_rate = df[col].isna().mean()
        results.append(ValidationResult(
            f"not_null_{col}",
            null_rate == 0.0,
            f"null_rate={null_rate:.4f}" if null_rate > 0 else "ok",
        ))

    # Layer 3: Uniqueness
    dup_count = df["order_id"].duplicated().sum()
    results.append(ValidationResult(
        "unique_order_id",
        dup_count == 0,
        f"duplicates={dup_count}" if dup_count > 0 else "ok",
    ))

    # Layer 4: Distribution
    row_count = len(df)
    results.append(ValidationResult(
        "row_count_in_range",
        5_000 <= row_count <= 500_000,
        f"row_count={row_count}",
    ))

    mean_rev = df["revenue"].mean()
    results.append(ValidationResult(
        "revenue_mean_plausible",
        10.0 <= mean_rev <= 200.0,
        f"mean_revenue={mean_rev:.2f}",
    ))

    return results


def fail_on_errors(results: List[ValidationResult]) -> None:
    failures = [r for r in results if not r.passed]
    if failures:
        for f in failures:
            print(f"FAIL [{f.check}]: {f.detail}")
        raise ValueError(f"{len(failures)} validation checks failed")
    print(f"All {len(results)} checks passed")
```

The important pattern: **validation is a task in the DAG, upstream of the load task.** If validation fails, the load never runs — no bad data touches the downstream tables.

```
extract → validate → load → notify
          ↓ (on failure)
          alert_on_call
```

### Anomaly detection beyond fixed thresholds

Fixed thresholds break on seasonal data (weekends have lower order counts; Q4 has higher). Use a **statistical baseline**: compare today's metric against the rolling 4-week same-day-of-week average.

```python
def check_row_count_anomaly(
    current_count: int,
    historical_counts: List[int],   # same weekday, last 4 weeks
    z_threshold: float = 3.0,
) -> ValidationResult:
    import statistics
    if len(historical_counts) < 2:
        return ValidationResult("row_count_anomaly", True, "not enough history")
    mean = statistics.mean(historical_counts)
    stdev = statistics.stdev(historical_counts)
    if stdev == 0:
        return ValidationResult("row_count_anomaly", True, "zero stdev")
    z_score = abs(current_count - mean) / stdev
    return ValidationResult(
        "row_count_anomaly",
        z_score <= z_threshold,
        f"z={z_score:.2f}, current={current_count}, mean={mean:.0f}",
    )
```

---

## Freshness & Volume SLAs

Freshness SLA: "this table should have data as of no more than N hours ago." Volume SLA: "this table should have at least M rows for date D within T hours of the schedule."

Both are monitored *after* the pipeline, not just during. An SLA is violated even if the pipeline runs — it's violated if the pipeline runs *late* or produces insufficient rows.

```sql
-- Freshness check: find tables where the latest loaded date is stale
SELECT
    table_name,
    max(loaded_at)                                  AS last_loaded,
    now() - max(loaded_at)                          AS age,
    max(loaded_at) < now() - INTERVAL '6 hours'    AS freshness_violated
FROM data_quality.load_audit
GROUP BY table_name
ORDER BY freshness_violated DESC, age DESC;
```

```python
# Volume check in a DAG task
def check_volume(**context):
    ds = context["ds"]
    conn = get_db_conn()
    count = conn.execute(
        "SELECT count(*) FROM fact_orders WHERE order_date = %s", [ds]
    ).fetchone()[0]
    if count < 5_000:
        raise ValueError(
            f"Volume SLA violated: fact_orders for {ds} has {count} rows (min 5000)"
        )
```

Airflow's `on_failure_callback` can route SLA misses to PagerDuty or Slack:

```python
def alert_slack(context):
    ti = context["task_instance"]
    msg = f"Data quality failure: {ti.dag_id}.{ti.task_id} on {ti.execution_date}"
    # post to webhook

PythonOperator(
    task_id="check_volume",
    python_callable=check_volume,
    on_failure_callback=alert_slack,
)
```

---

## Lineage

Data lineage is the directed graph of how data flows between systems: from source table → transformation → target table → dashboard. It answers "if this upstream table has bad data, what is affected?" and "who is consuming this table before I change its schema?"

```
kafka.events_raw
    → dbt.stg_events
        → dbt.fct_sessions
            → dashboard: Daily Active Users
            → ml_model: churn_prediction (training)
        → dbt.fct_purchases
            → dashboard: Revenue by Region
```

**Column-level lineage** goes further: it tracks which specific column in the output derives from which specific column in the input. This is critical for PII propagation — if `user_email` appears in column `A` of `raw_events`, column-level lineage tells you every derived column in every downstream table that carries email data.

dbt exposes lineage automatically via its `manifest.json` (the compiled DAG). OpenLineage is the open standard for emitting lineage events from pipelines (supported by Airflow, Spark, dbt, and others), and Marquez / OpenMetadata collect and query them.

---

## PII & Access Control

PII (Personally Identifiable Information) in a data platform needs:

1. **Discovery:** know which columns contain PII (email, phone, name, IP, device ID). Tag at ingestion, not retroactively.
2. **Classification:** bucket by risk — direct identifiers (email) vs quasi-identifiers (age + zip code + gender can uniquely identify 87% of Americans).
3. **Access control:** column-level or row-level access policy so analysts see only what they need.
4. **Masking / tokenization:** replace PII with a reversible or irreversible token for non-prod environments.

```sql
-- BigQuery column-level access policy (concept)
CREATE ROW ACCESS POLICY email_restricted
ON fact_users
GRANT TO ("group:pii-approved@company.com")
FILTER USING (TRUE);   -- other users see rows with email masked

-- Snowflake Dynamic Data Masking
CREATE OR REPLACE MASKING POLICY mask_email AS
  (val STRING) RETURNS STRING ->
    CASE
      WHEN CURRENT_ROLE() IN ('PII_ANALYST') THEN val
      ELSE SHA2(val, 256)    -- irreversible hash for non-PII roles
    END;

ALTER TABLE fact_users MODIFY COLUMN email
  SET MASKING POLICY mask_email;
```

**In practice at SAP:** the AI Core logs pipeline strips `user_id` before writing to the long-term archive (tokenized to a pseudonym at ingest). The token-to-identity mapping lives in a separate, strictly access-controlled store. Queries on the archive never see raw user IDs — only pseudonyms. GDPR right-to-erasure is then a delete from the token map, not a full-table rewrite.

---

## Observability of Pipelines

Operational observability = you know a pipeline is broken before your stakeholders do. The three signals:

| Signal | What to capture | Tool |
|--------|-----------------|------|
| **Availability** | Did the DAG run? Did all tasks succeed? | Airflow task_instance state → metrics → Prometheus/Grafana |
| **Latency** | How late is the data? Is today's load slower than yesterday's? | `loaded_at - scheduled_at`; wall-clock duration per task |
| **Quality** | How many rows? Are distributions stable? Are nulls creeping up? | Validation task results → metrics table |

Emit these as structured events from your tasks:

```python
# write a quality audit record at the end of every load
def emit_audit(table: str, ds: str, row_count: int, checks_passed: int,
               checks_total: int, load_duration_s: float):
    conn.execute(
        """
        INSERT INTO data_quality.load_audit
          (table_name, ds, row_count, checks_passed, checks_total,
           load_duration_s, loaded_at)
        VALUES (%s, %s, %s, %s, %s, %s, now())
        ON CONFLICT (table_name, ds) DO UPDATE SET
          row_count = EXCLUDED.row_count,
          checks_passed = EXCLUDED.checks_passed,
          loaded_at = EXCLUDED.loaded_at
        """,
        [table, ds, row_count, checks_passed, checks_total, load_duration_s],
    )
```

Then build a single dashboard: every table, last 30 days, colored green/yellow/red by freshness and quality score. When that dashboard is all-green and you have alerts on red, you've operationalized data quality.

---

## Debugging Data Quality & Governance

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Revenue metric is correct in the source but wrong in the warehouse, and all pipeline tasks show success | Silent type coercion (e.g. Parquet `float32` read as `float64`, losing precision on large values) or silent division by zero promoted to NULL | Add a distribution check (mean, stddev, p99) as a validation task; compare against a rolling baseline; add a `NOT NULL` constraint on the result column |
| A new column appeared in the source JSON feed; downstream dbt models are `None` / silently NULL everywhere | No contract check on NEW columns; consumers assume schema stability | Add a schema drift check: `assert set(expected_cols) == set(actual_cols)`; bump the contract version and notify consumers before deploying |
| Data lineage shows `NULL` or `UNKNOWN` for a table that definitely has upstream dependencies | The pipeline that writes the table doesn't emit OpenLineage events, or uses a raw SQL connection (not a tracked engine) | Instrument the write task with OpenLineage `OutputDataset` events; use dbt or an OpenLineage-aware runner instead of raw psycopg2 |
| GDPR erasure request filed 6 months ago; user's data still appears in the analytics table | Erasure pipeline deletes from OLTP but has no mechanism to find/rewrite Parquet partitions in the lake | Build an erasure task that: finds all partition paths containing the user (via lineage + column index), rewrites those partitions excluding the target ID, and records the completion in an audit log |
| Validation passes in staging; fails in production because the row count is always below the minimum threshold | Staging uses a sample dataset; minimum threshold is calibrated for production volume | Parameterize thresholds per environment (env var or config table); staging threshold ≈ 1% of production minimum |
| Dashboard shows "data unavailable" for the last 2 hours; pipeline shows all-success in Airflow | Freshness SLA check is not monitoring the *consumption* endpoint — the pipeline wrote to a staging table, not the final mart, or the dbt run failed silently | Monitor freshness on the *consumer-facing* table, not the staging table; add a dbt run success check (exit code) as a DAG task |

### Tracing silent data corruption

```
Step 1: Find when it started
  SELECT ds, avg(revenue), count(*), max(loaded_at)
  FROM fact_orders
  WHERE ds BETWEEN '2024-01-01' AND '2024-01-31'
  GROUP BY ds ORDER BY ds;
  → find the first ds where avg(revenue) is anomalous

Step 2: Diff source vs warehouse for that ds
  SELECT count(*) FROM raw.orders WHERE order_date = '2024-01-15';  -- source count
  SELECT count(*) FROM fact_orders WHERE order_date = '2024-01-15'; -- warehouse count
  → if counts differ, look for duplicates or drops

Step 3: Find the pipeline change
  git log --oneline --since="2024-01-14" dags/ dbt/models/

Step 4: Check the transform logic
  SELECT order_id, count(*) n FROM fact_orders
  WHERE order_date = '2024-01-15'
  GROUP BY order_id HAVING n > 1;
  → duplicates = non-idempotent transform retry
```

> **War story.** An ML team at a payments company trained a transaction fraud model on `fact_transactions.amount`. Six weeks after a "non-breaking schema change" (the pipeline team renamed `amount_usd` to `amount` and added a `currency` column), the model's precision started drifting — slowly, imperceptibly. The column was still called `amount`, still `float`, still non-null. The change was that the pipeline now wrote `amount` in *local currency* when `currency != 'USD'`, not USD-normalized. Schema checks passed. Distribution checks passed (amounts look like amounts). The bug was semantic: the column's *meaning* had changed without a contract version bump. It was caught only when a data scientist happened to re-train the model and noticed the feature distribution had shifted. The fix: add a mean-stability check (`z_score(today_mean, rolling_4w_mean) < 2.5`), enforce strict contract versioning for any column semantic change, and add a `_currency_normalized: bool` flag to the contract. The lesson: **schema validation is necessary but not sufficient. Distribution checks catch semantic drift that schema checks miss entirely.**

---

## Checkpoint

You're solid on data quality and governance when you can, without looking anything up:

1. A pipeline runs successfully every day, but the `revenue` metric is wrong three times a month. What categories of validation checks would catch this, and at what stage of the pipeline (pre-load, post-load, or monitoring) should each live?
2. Explain the difference between schema validation and distribution validation. Give a concrete example where one passes and the other fails.
3. A producer wants to rename `amount_usd` to `amount` in a dataset that 12 dashboards and 3 ML models consume. Walk through the data contract process: what changes, who is notified, and how do consumers protect themselves?
4. What is column-level lineage, and why is it specifically important for GDPR compliance (not just schema documentation)?
5. You have a freshness SLA of 2 hours. The Airflow DAG shows all-success. The consumer dashboard shows "stale data." What are the two most likely explanations, and how do you diagnose each?
6. Design a data quality audit table schema that lets you plot, for any table, the last 30 days of row count and quality check pass rate as a time series.
7. Explain the z-score anomaly detection approach for row count: why does a fixed minimum threshold fail for seasonal datasets, and what data do you need to compute a meaningful baseline?

➡ You've completed the core modules. The challenges for this course put these concepts into running Python code — deterministic, pytest-judged, no external dependencies.
