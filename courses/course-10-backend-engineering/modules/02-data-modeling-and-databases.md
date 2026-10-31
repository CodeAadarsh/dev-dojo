# Data Modeling & Databases

> **Module 02 · Course 10** — The query that scans 10 million rows on every page load was written in 20 seconds. The index that prevents it takes 10 minutes to reason about correctly. This module is about spending those 10 minutes.

You know SQL. This is about the decisions that separate "it works in staging" from "it survives Black Friday": normal forms that prevent anomalies (not just normalize for its own sake), index internals that explain why a composite index helps in one column order but not another, and isolation levels that let you sleep through the night.

---

## Relational Design & Normalization

### The anomaly problem

Normalization exists to prevent three anomalies:

| Anomaly | What it looks like | Normal form that eliminates it |
|---------|-------------------|-------------------------------|
| Insertion anomaly | Can't record a product until it belongs to an order | 1NF / 2NF |
| Update anomaly | Changing a customer's city requires updating N order rows | 2NF / 3NF |
| Deletion anomaly | Deleting the last order for a customer erases the customer record | 2NF |

**1NF:** Atomic values. No comma-separated IDs in a column, no repeating groups. A `tags TEXT` column storing `"backend,api,python"` violates 1NF. Enforce with a `tags` junction table or a `JSONB` column with a GIN index.

**2NF:** Every non-key column depends on the **whole** primary key. Violation: a table with composite key `(order_id, product_id)` that stores `customer_name` — `customer_name` depends only on `order_id`, not on the product. Fix: split into `orders(order_id, customer_name)` and `order_items(order_id, product_id, qty, unit_price)`.

**3NF:** No transitive dependencies among non-key columns. Violation: `orders(order_id, customer_id, customer_city)` — `customer_city` depends on `customer_id`, not directly on `order_id`. Fix: move `customer_city` into `customers`.

**BCNF (Boyce-Codd):** Every determinant is a candidate key. Tables satisfying 3NF almost always satisfy BCNF; exceptions require overlapping candidate keys (rare in practice, common in exams).

### Entity design rules that actually matter

```
Rule 1: Every entity gets a surrogate PK.
        BIGINT GENERATED ALWAYS AS IDENTITY (Postgres) unless you need globally unique IDs.
        UUID v4 fragments B-tree indexes — prefer UUID v7 (time-ordered) if you must use UUIDs.

Rule 2: Declare foreign keys. Always.
        The constraint gives referential integrity for free and hints the query planner.

Rule 3: Never store derived values you can compute in a query.
        Exception: expensive computed columns on very hot read paths, maintained in the
        same transaction that modifies the source data.

Rule 4: Timestamps in UTC, always.
        TIMESTAMPTZ in Postgres; DATETIME with an application-level UTC enforcement in MySQL.
        Always store both created_at and updated_at.

Rule 5: Never store money as FLOAT.
        Binary floating-point cannot represent 0.10 exactly.
        Store as BIGINT paise/cents and format in the application layer.
```

### Junction tables and many-to-many

```sql
CREATE TABLE order_items (
    order_id   BIGINT REFERENCES orders(id)   ON DELETE CASCADE,
    product_id BIGINT REFERENCES products(id) ON DELETE RESTRICT,
    qty        INT    NOT NULL CHECK (qty > 0),
    unit_price BIGINT NOT NULL,               -- paise; never FLOAT for money
    PRIMARY KEY (order_id, product_id)        -- natural composite PK is fine here
);
```

A natural composite PK on junction tables avoids a redundant surrogate key and doubles as the covering index for the most common lookup.

---

## Indexing: B-tree, Composite, Covering

### B-tree internals (the five facts that govern every index decision)

The default index in Postgres, MySQL, and SQLite — a balanced tree of sorted keys with leaf-level pointers to the heap row.

```
1. Equality and range queries both use the tree efficiently: O(log n) to reach
   the range boundary, then sequential leaf traversal.

2. The leftmost column of a composite index MUST appear in the WHERE clause for
   the index to be used. This is the single most common indexing mistake in code review.

3. Index scans read the index, then follow heap pointers to the actual row.
   A COVERING index eliminates the heap access entirely (look for "Index Only Scan"
   in EXPLAIN output).

4. High-cardinality columns are better targets: index on user_id (millions of values)
   not on status (3 values). A low-cardinality index on status alone is often ignored
   by the planner in favor of a seq scan.

5. Writes pay an index maintenance cost. A heavily-written column is more expensive to
   index; measure before adding indexes to write-hot tables.
```

### The leftmost-prefix rule — in detail

```sql
-- Composite index: (status, user_id, created_at)

-- Uses the index (status satisfies the leftmost prefix):
SELECT * FROM orders WHERE status = 'pending';
SELECT * FROM orders WHERE status = 'pending' AND user_id = 42;
SELECT * FROM orders WHERE status = 'pending' AND user_id = 42 AND created_at > '2025-01-01';

-- Does NOT use this composite index (leftmost column absent):
SELECT * FROM orders WHERE user_id = 42;
SELECT * FROM orders WHERE created_at > '2025-01-01';
```

Create indexes for your query patterns, not your schema shape. If `user_id` is frequently queried alone, it needs its own index even if a composite index covering `(status, user_id, ...)` also exists.

### Covering indexes

```sql
-- Hot query: render a paginated article list for a given author
SELECT id, title, created_at
FROM articles
WHERE author_id = 99
ORDER BY created_at DESC
LIMIT 20;

-- Non-covering: index on (author_id) → locate rows → heap fetch for id, title, created_at
-- Covering:     all accessed columns live in the index → heap never touched

CREATE INDEX articles_author_covering
    ON articles (author_id, created_at DESC)
    INCLUDE (id, title);   -- Postgres 11+ INCLUDE: extra columns in leaf only, not in key
```

`INCLUDE` keeps the extra columns off the B-tree key (avoids bloating the index for writes that change `title`) while still satisfying the covering requirement.

### Index types beyond B-tree

| Type | Use case | DB |
|------|----------|----|
| Hash | Equality-only lookups, slightly faster than B-tree for equality | Postgres |
| GIN | Full-text search (`tsvector`), JSONB containment (`@>`), array membership | Postgres |
| BRIN | Very large append-only tables where the indexed column correlates with physical write order (time-series, logs) | Postgres |
| Partial | Index a filtered subset of rows | Postgres, SQLite |

Partial indexes are chronically underused:

```sql
-- Only index active (non-deleted) users for the email uniqueness check
CREATE UNIQUE INDEX users_email_active
    ON users (email)
    WHERE deleted_at IS NULL;
-- Smaller index, faster writes, and correctly handles soft-deleted email reuse
```

---

## Transactions & Isolation Levels

### ACID — what "failure" actually looks like

| Property | Failure scenario |
|----------|-----------------|
| **A**tomicity | Payment debited but never credited — half-applied write |
| **C**onsistency | Row inserted violating a FK constraint — referential integrity broken |
| **I**solation | Two sessions read the same balance, both subtract, both write — lost update |
| **D**urability | Committed row vanishes after restart — WAL not flushed to disk |

### The four isolation levels

From weakest to strongest (Postgres names in parentheses):

```
READ UNCOMMITTED  — sees uncommitted writes (dirty reads). Not supported in Postgres;
                    MySQL MyISAM effectively behaves this way. Almost never use.

READ COMMITTED    — only sees committed data. Postgres default.
                    Vulnerable to: non-repeatable reads, phantom reads.

REPEATABLE READ   — re-reading the same row within a transaction always returns the
                    same result. MySQL InnoDB default.
                    Vulnerable to: phantom reads (a new row appearing in a range query).

SERIALIZABLE      — transactions behave as if they ran sequentially. Eliminates all
                    anomalies. Higher abort rate; application must retry on serialization
                    failure (SQLSTATE 40001).
```

### The three read anomalies

```
Dirty read:
  T1 reads a row T2 modified but hasn't committed.
  If T2 rolls back, T1 acted on data that never existed.
  Fix: READ COMMITTED or higher.

Non-repeatable read:
  T1 reads row R. T2 updates and commits R. T1 re-reads R — different value.
  Fix: REPEATABLE READ or higher.

Phantom read:
  T1 counts rows WHERE amount > 1000. T2 inserts a row with amount = 5000 and commits.
  T1 re-counts — different total.
  Fix: SERIALIZABLE, or lock the predicate range with SELECT ... FOR UPDATE.
```

### SELECT FOR UPDATE — the practical concurrency primitive

```sql
-- Debit a wallet without a race condition under concurrent requests
BEGIN;
SELECT balance FROM wallets WHERE user_id = 42 FOR UPDATE;
-- all other sessions trying to SELECT ... FOR UPDATE on this row block here
UPDATE wallets SET balance = balance - 5000 WHERE user_id = 42 AND balance >= 5000;
-- check rowcount = 1; if 0, the balance check failed — ROLLBACK and return 409
COMMIT;
```

`FOR UPDATE` acquires a row-level lock. Two concurrent debits serialize at the `SELECT`, so neither reads a stale balance. `FOR UPDATE SKIP LOCKED` is the queue-consumer variant: workers pull tasks without blocking each other.

### When to use SERIALIZABLE

Use it when transaction reads and writes are logically interdependent and you can't express the constraint as a row-level lock:

```sql
-- Doctor-on-call: at least one doctor must be on-call at all times.
-- With SERIALIZABLE, Postgres SSI detects two sessions each about to take
-- the last on-call doctor off the shift and aborts one (SQLSTATE 40001).
-- The application must catch 40001 and retry.

SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN;
SELECT COUNT(*) FROM oncall WHERE shift_id = $1;   -- reads the predicate
UPDATE oncall SET doctor_id = NULL WHERE doctor_id = $2 AND shift_id = $1;
COMMIT;
```

---

## SQL vs NoSQL

### Decision matrix

```
┌─────────────────────────┬──────────────────────────────┬──────────────────────────────┐
│ Need                    │ SQL (Postgres)                │ NoSQL / Alternative          │
├─────────────────────────┼──────────────────────────────┼──────────────────────────────┤
│ Strong consistency      │ Excellent (ACID)              │ Cassandra: eventual by default│
│ Complex joins           │ Native                       │ Document: denormalize/multi-  │
│                         │                              │ query. KV: impossible         │
│ Schema flexibility      │ Poor (migrations required)   │ Document: excellent           │
│ High write throughput   │ Moderate (WAL + index cost)  │ Wide-column/KV: very high     │
│ Time-series at scale    │ TimescaleDB extension        │ InfluxDB, Cassandra           │
│ Full-text search        │ Postgres GIN / tsvector      │ Elasticsearch (specialized)   │
│ Graph traversal         │ Recursive CTEs (limited)     │ Neo4j (native)                │
│ Cache / ephemeral       │ Overkill                     │ Redis (ideal)                 │
└─────────────────────────┴──────────────────────────────┴──────────────────────────────┘
```

**Document (MongoDB, DynamoDB):** Best when the data model is a single aggregate — all data for an entity in one document. An order with its items, shipping address, and status history is a document. A normalized relational model for the same entity hits 4 tables; a document hits one.

**Key-Value (Redis, DynamoDB in KV mode):** Pure key → value. No secondary index, no range query unless the key encodes the range. Best for sessions, cache, feature flags, rate-limit counters.

**Wide-column (Cassandra, HBase):** Designed for write throughput at massive scale. You design the table for your query pattern first, then reverse-engineer the entity model — the opposite of relational design. Excellent for IoT telemetry, event logs. Terrible for ad-hoc queries.

### CAP and PACELC in 30 seconds

```
CAP theorem: a distributed system provides at most two of:
  Consistency (all nodes see the same data simultaneously)
  Availability (every request gets a response)
  Partition tolerance (the system operates under network splits)

In practice: P is mandatory (network splits happen), so the real choice is
  CP — Postgres, HBase, ZooKeeper: consistent under partition, may reject requests
  AP — Cassandra, DynamoDB, CouchDB: available under partition, eventually consistent

PACELC extends this for the non-partition case:
  Cassandra: PA/EL — available under partition, low-latency (eventual) normally
  Cloud Spanner: PC/EC — consistent under partition, consistent (higher latency) normally
```

---

## When to Denormalize

Denormalization is a deliberate trade: accept write overhead and consistency risk to eliminate joins on the hot read path. Always measure before denormalizing.

### Patterns

**Materialized aggregate:** Store `comment_count` on `posts`.

```sql
-- Read: one column lookup, no COUNT query
-- Write: increment in the same transaction that inserts the comment
BEGIN;
INSERT INTO comments (post_id, body) VALUES ($1, $2);
UPDATE posts SET comment_count = comment_count + 1 WHERE id = $1;
COMMIT;
-- If the transaction aborts, both the insert and the increment roll back — no drift
```

**Temporal snapshot:** Store `customer_email` in the `orders` table.

This is not a normalization violation — it's a point-in-time snapshot. The email at order time is legally relevant even if the customer changes their email later. You are modeling a historical fact, not a current relationship.

**Event sourcing:** An append-only events table is the extreme case of denormalization. The "current state" is a derived view. Read models (projections) are explicitly denormalized read caches of the event stream.

### When not to denormalize

- When the source data changes frequently (every write must update N redundant copies)
- When you don't have a measured query performance problem (premature optimization)
- When a covering index would serve the same read pattern without duplication

---

## Debugging Data Modeling & Databases

The three slow-query categories that fill production post-mortems: the full table scan (no usable index), the deadlock, and the lost update under concurrent writes.

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Query suddenly slow after the table grows past ~1M rows | Missing index — was fast on small data, full-scans at scale | `EXPLAIN ANALYZE` to confirm Seq Scan, then `CREATE INDEX CONCURRENTLY` |
| Intermittent "deadlock detected" errors under load | Two transactions acquire locks on the same rows in opposite order | Ensure all transactions acquire locks in the same canonical order; use `SELECT FOR UPDATE SKIP LOCKED` for queue patterns |
| Concurrent balance updates result in incorrect totals | Lost update: both sessions read the same value, both write increments | Use an atomic `UPDATE wallets SET balance = balance - $1 WHERE ...` or `SELECT FOR UPDATE` |
| `ALTER TABLE` migration times out in production | `ADD COLUMN NOT NULL` on a large table acquires `ACCESS EXCLUSIVE` for the full rewrite | Add nullable column first, backfill async with `UPDATE ... WHERE id BETWEEN`, then `ALTER COLUMN SET NOT NULL` (Postgres validates without rewrite if constraint check can use an existing index) |
| `EXPLAIN` shows `rows=5000000` estimate but actual is 2 | Stale table statistics | `ANALYZE table_name;` or `VACUUM ANALYZE table_name;` |

### EXPLAIN ANALYZE — reading the output

```sql
-- Always use ANALYZE for real execution times and actual row counts
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, status, created_at
FROM orders
WHERE user_id = 42 AND status = 'pending'
ORDER BY created_at DESC
LIMIT 20;
```

Reading the smoking gun:

```
Seq Scan on orders  (cost=0.00..182400.00 rows=12 width=48)
                    (actual time=0.04..823.12 rows=12 loops=1)
  Filter: ((user_id = 42) AND (status = 'pending'))
  Rows Removed by Filter: 9999988
Buffers: shared hit=2400 read=50800
```

`Seq Scan` + `Rows Removed by Filter: 9999988` is the signature of a missing index. Fix:

```sql
CREATE INDEX CONCURRENTLY orders_user_status_time
    ON orders (user_id, status, created_at DESC);
```

`CONCURRENTLY` is critical in production: without it, Postgres holds an `ACCESS EXCLUSIVE` lock that blocks all writes for the duration of the build. The build takes longer but the table stays live.

### Diagnosing deadlocks

```sql
-- Live lock view (Postgres)
SELECT pid, wait_event_type, wait_event, query_start, state, left(query, 80) AS query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';

-- What's blocking what
SELECT
    blocked.pid        AS blocked_pid,
    left(blocked.query, 80) AS blocked_query,
    blocking.pid       AS blocking_pid,
    left(blocking.query, 80) AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));

-- Deadlock details in the server log
grep 'deadlock' /var/log/postgresql/postgresql-*.log | tail -20
```

Fix: identify the two transactions and the order in which they acquire locks. Ensure all transactions always lock resources in the same ascending-ID order — never one transaction locks `wallets` then `orders` while another locks `orders` then `wallets`.

### Diagnosing lost updates

```bash
# Reproduce with two concurrent psql sessions (or a load test):
# Session A: BEGIN; SELECT balance FROM wallets WHERE user_id=1 FOR UPDATE;
# Session B: BEGIN; SELECT balance FROM wallets WHERE user_id=1 FOR UPDATE; -- blocks
# Session A: UPDATE wallets SET balance = balance - 100 WHERE user_id=1; COMMIT;
# Session B: -- unblocks, re-reads, applies its own decrement safely

# Check for atomic updates vs read-modify-write in your code:
grep -rn 'balance.*=.*balance' ./src/
# Any pattern like: SET balance = :new_balance WHERE id = :id  is a lost-update candidate
# unless it's preceded by SELECT ... FOR UPDATE in the same transaction
```

> **War story.** A billing microservice at SAP started deadlocking intermittently under load. `EXPLAIN ANALYZE` was clean — queries were fast. But every ~20 minutes two concurrent batch jobs would each lock a `billing_runs` row and an `accounts` row, in opposite order. The fix was 3 lines: collect all `account` IDs needed for the job into a sorted array at the start, then lock them all with a single `SELECT id FROM accounts WHERE id = ANY($1) ORDER BY id FOR UPDATE` before touching `billing_runs`. Canonical ascending-ID lock order. Zero deadlocks in production since. Deadlocks are always a lock-ordering problem; the fix is always making the order canonical and explicit.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Identify the 2NF violation in: `invoices(invoice_id, line_item_id, customer_name, product_name, qty)`.
2. Explain why UUID v4 fragments B-tree indexes and what you'd use instead for a new schema.
3. Given `EXPLAIN ANALYZE` output showing a `Seq Scan` with 5M `Rows Removed by Filter`, write the `CREATE INDEX CONCURRENTLY` command that would fix it, and justify the column order.
4. Name two queries that a composite index on `(a, b, c)` cannot serve with an index scan.
5. Describe the lost-update problem and show the atomic `UPDATE` statement or `SELECT FOR UPDATE` pattern that prevents it.
6. Choose between Postgres and Cassandra for: (a) a financial ledger, (b) IoT telemetry at 50k writes/sec.
7. Explain what `SELECT FOR UPDATE SKIP LOCKED` does and name the pattern it enables.
8. Name one scenario where storing a redundant column is legally correct, not just a performance hack.

➡ Next up: **Caching & Performance** — Redis, TTLs, and the stampede that takes down your database the morning after a viral launch.
