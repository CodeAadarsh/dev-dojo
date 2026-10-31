# Query Processing & Optimization

> **Module 05 · Course 20** — The distance between "I know SQL" and "I understand what the database actually does" is the query processing pipeline. This module goes end-to-end: from the moment you press Enter to the row arriving in your client, with a stop at every place the database makes a decision — and every place that decision can be catastrophically wrong.

You're at an SDE-2 level when you can look at a query plan and know, without running the query, whether it will table-scan a billion rows or nail it with a 3-level B-tree descent. That's what this module builds.

---

## The Four-Phase Pipeline

Every SQL statement travels through four phases before a single row is returned. Understanding each phase tells you *where* to look when something is slow.

```
SQL text
   │
   ▼
┌──────────────────────────────────┐
│  1. PARSE                        │
│  Lexer → tokens                  │
│  Parser → parse tree (AST)       │
│  Semantic check: names exist?    │
│  Privileges: can you read this?  │
└──────────────────────┬───────────┘
                       │  parse tree
                       ▼
┌──────────────────────────────────┐
│  2. REWRITE                      │
│  View expansion                  │
│  Subquery → join / CTE flattening│
│  Predicate pushdown (logical)    │
│  Constant folding                │
└──────────────────────┬───────────┘
                       │  rewritten query tree
                       ▼
┌──────────────────────────────────┐
│  3. PLAN (Optimizer)             │
│  Enumerate plan candidates       │
│  Cost each candidate             │
│  Pick cheapest → query plan      │
└──────────────────────┬───────────┘
                       │  physical query plan
                       ▼
┌──────────────────────────────────┐
│  4. EXECUTE                      │
│  Iterator model (volcano)        │
│  Read pages, evaluate predicates │
│  Sort, hash, aggregate           │
│  Return rows to client           │
└──────────────────────────────────┘
```

Phases 1 and 2 are nearly instant for normal queries. Phase 3 can dominate for queries over many tables (join-order explosion, covered below). Phase 4 is where wall-clock time goes.

---

## Phase 1: Parse

The parser turns text into an abstract syntax tree (AST). Every token is categorized — keyword, identifier, literal, operator — and the grammar checks that the structure is legal SQL.

```sql
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE o.status = 'paid'
GROUP BY u.name;
```

After parsing:

```
SelectStmt
├── targetList: [FieldRef(u.name), FuncCall(COUNT, FieldRef(o.id))]
├── fromClause:
│   └── JoinExpr(INNER)
│       ├── RangeVar(users, alias=u)
│       ├── RangeVar(orders, alias=o)
│       └── ON: OpExpr(=, FieldRef(u.id), FieldRef(o.user_id))
├── whereClause: OpExpr(=, FieldRef(o.status), Const('paid'))
└── groupClause: [FieldRef(u.name)]
```

The semantic check resolves column references (does `users.name` exist?), applies implicit casts (is `'paid'` compatible with `status`'s type?), and checks permissions. If any of these fail, you get an error *before* any data is touched — the database didn't even think about execution.

---

## Phase 2: Rewrite

The rewriter applies algebraic transformations that are *always* correct regardless of data. It doesn't look at statistics; it just rearranges the tree using relational algebra rules.

### View Expansion

A view is a stored query. When your query references a view, the rewriter substitutes the view's definition inline. From the optimizer's perspective, views are transparent — there is no "view scan" node in a plan. This matters: a view that contains an aggregation and is then filtered by the outer query will push the filter inside only if the optimizer can see through the view (PostgreSQL's `SECURITY BARRIER` views block this on purpose).

### Predicate Pushdown

Moving filters closer to the data source reduces the number of rows that flow through subsequent operators. The rewriter can often do this purely structurally:

```sql
-- original
SELECT * FROM orders
WHERE order_date > '2024-01-01'
  AND status = 'paid';

-- after pushdown (conceptual)
-- both predicates now live as early as possible in the scan node
```

For joins:

```sql
SELECT * FROM users u JOIN orders o ON u.id = o.user_id
WHERE u.country = 'IN';
```

The rewriter can push `u.country = 'IN'` down onto the `users` scan, so the join sees only Indian users rather than all users. This is free cardinality reduction before the join.

### Subquery Flattening

Correlated subqueries are expensive because they re-execute per row. The rewriter tries to convert them to joins:

```sql
-- correlated subquery: runs once per user row
SELECT * FROM users u
WHERE EXISTS (
  SELECT 1 FROM orders o
  WHERE o.user_id = u.id AND o.total > 1000
);

-- after flattening → semi-join (conceptually)
SELECT DISTINCT u.* FROM users u
JOIN orders o ON u.id = o.user_id
WHERE o.total > 1000;
```

Not all subqueries can be flattened — CTEs with side effects, `NOT EXISTS` with NULLs, scalar subqueries referencing outer-query aliases. When flattening fails, the optimizer must treat it as a correlated loop — a performance cliff you'll hit at scale.

---

## Phase 3: The Optimizer

This is the most intellectually rich part of the system. The optimizer's job is to find the cheapest physical query plan from an astronomically large search space.

### Logical vs Physical Plans

The rewriter produces a **logical plan** — a tree of relational algebra operators (Scan, Filter, Join, Aggregate, Project) that describes *what* to compute, not *how*.

The optimizer transforms this into a **physical plan** — each logical node is replaced by a concrete algorithm with a specific cost.

```
Logical Plan                        Physical Plan
─────────────────────────────       ──────────────────────────────────────
Aggregate(GROUP BY u.name)          HashAggregate
└─ Join(u.id = o.user_id)     →    └─ Hash Join  (build: users, probe: orders)
   ├─ Filter(country='IN')             ├─ Seq Scan users (Filter: country='IN')
   │  └─ Scan(users)                   └─ Index Scan orders.idx_user_id
   └─ Scan(orders)
```

Every leaf operator (Scan) has at least two physical choices: **Sequential Scan** or **Index Scan** (possibly more — see Access Paths below). Every Join has three: Nested Loop, Hash Join, Merge Join. Every Aggregate has two: Hash Aggregate or Sort + Group Aggregate. The optimizer must choose, and it uses a **cost model** to do so.

### The Cost Model

Cost is a unitless number proportional to disk I/Os and CPU cycles. PostgreSQL's model:

```
cost = (pages_read × seq_page_cost)
     + (random_pages_read × random_page_cost)
     + (rows_processed × cpu_tuple_cost)
     + (rows_qualified × cpu_operator_cost)
```

Default costs:
- `seq_page_cost = 1.0` (baseline)
- `random_page_cost = 4.0` (random I/O is 4× harder than sequential — on SSD, drop this to ~1.1)
- `cpu_tuple_cost = 0.01`

> **`random_page_cost` tuning matters.** If your PostgreSQL runs on NVMe SSD, `random_page_cost = 4.0` makes the optimizer *over-estimate* the cost of index scans and reach for sequential scans on small-to-medium result sets. `ALTER SYSTEM SET random_page_cost = 1.1; SELECT pg_reload_conf();` fixes a large class of "why isn't it using my index" complaints.

The optimizer estimates the cost of every candidate plan using this model, picks the minimum, and that becomes the query plan. The critical input is **row counts** — and those come from statistics.

---

## Access Paths

Given a table, the optimizer must decide how to read rows that satisfy a predicate. Here are the four main access paths in PostgreSQL (other engines use equivalent concepts):

### Sequential Scan

Read every page of the table in order. Linear I/O — the most cache-friendly operation on disk. Efficient for:
- Predicates that match a large fraction of rows (>10–20% as a rule of thumb)
- Tables that fit in the buffer pool
- OLAP full-table analytics

```
EXPLAIN SELECT * FROM orders WHERE status = 'cancelled';

Seq Scan on orders  (cost=0.00..18324.00 rows=89123 width=48)
  Filter: (status = 'cancelled')
```

The "Filter" is evaluated per row *after* reading it — all pages are touched.

### Index Scan

Traverse the B-tree to the qualifying leaf pages, then fetch the actual heap pages (one random I/O per qualifying row). Efficient for:
- High-selectivity predicates (tiny fraction of rows)
- Range scans on a leading index column

```
EXPLAIN SELECT * FROM orders WHERE id = 42;

Index Scan using orders_pkey on orders  (cost=0.43..8.45 rows=1 width=48)
  Index Cond: (id = 42)
```

The cost is dominated by the B-tree traversal (typically 3–4 levels for 10–100M rows) plus one heap fetch. Very fast.

### Index-Only Scan

If every column the query needs is present in the index (either as a key column or an `INCLUDE`d column), the heap page is never touched. This is called a **covering index**.

```sql
-- index: CREATE INDEX idx_orders_user_status ON orders(user_id, status);
-- query:
SELECT user_id, status FROM orders WHERE user_id = 101;

Index Only Scan using idx_orders_user_status on orders
  Index Cond: (user_id = 101)
  Heap Fetches: 0
```

`Heap Fetches: 0` is the tell — pure index I/O, no heap pages read. For read-heavy workloads, a carefully designed covering index is one of the highest-leverage tuning actions available.

### Bitmap Heap Scan

Used when the optimizer estimates a *medium* number of qualifying rows — too many for an index scan (random I/Os would exceed the sequential-scan cost) but few enough to avoid a full seq scan.

```
Phase 1: Bitmap Index Scan → bitset of qualifying pages
Phase 2: Bitmap Heap Scan  → read only those pages, in physical order
```

```
Bitmap Heap Scan on orders  (cost=842..9102 rows=4200 width=48)
  Recheck Cond: (user_id = 101)
  ->  Bitmap Index Scan on idx_orders_user_id
        Index Cond: (user_id = 101)
```

The two-phase approach converts the random access pattern into semi-sequential reads — much cheaper than one random I/O per row. The "Recheck Cond" handles pages that were in a lossy bitmap (bit represents a page, not a row).

---

## Join Algorithms

Joins are the most expensive operation in relational queries, and the optimizer has three algorithms to choose from. Understanding *when* each wins is critical for both writing fast queries and reading plans.

### Nested Loop Join

```
for each row R in outer_table:
    for each row S in inner_table where S.key = R.key:
        emit (R, S)
```

```
Outer (users, 10,000 rows)
│
└─► for each user, scan orders filtered by user_id
    │
    └─► Inner (orders, 1,000,000 rows)
        → index scan on orders(user_id) per outer row
```

**Complexity:** O(outer × cost_of_inner_lookup). If the inner lookup is an index scan: O(N × log M).

**Best when:**
- Outer relation is small (a few hundred to a few thousand rows)
- Inner has a selective index on the join key
- The loop terminates early (LIMIT + ORDER BY)

**Bad when:** outer is large AND inner has no index — degenerates to O(N×M), the full cross product. This is the "accidentally quadratic" join that makes pages at 3 AM.

### Hash Join

```
Phase 1 (Build):   scan smaller relation, build hash table on join key
Phase 2 (Probe):   scan larger relation, probe hash table for matches
```

```
    Build side: users → hash table keyed on user_id
    ┌────────────────────────┐
    │ user_id │ name │ ...   │
    │   101   │ Alice│       │
    │   102   │ Bob  │       │
    │   ...   │      │       │
    └────────────────────────┘
         ▲
         probe: for each order, look up hash[order.user_id]
```

**Complexity:** O(N + M). Linear in both input sizes.

**Best when:**
- Large joins where neither side has a useful index
- Equi-joins (hash can only do equality; no range, no LIKE)
- The build side fits in `work_mem`

**Memory cliff:** If the build side doesn't fit in `work_mem`, PostgreSQL spills to disk in **batches** — performance falls off sharply. Watch for `Batches: N` in EXPLAIN ANALYZE where N > 1.

```sql
-- see if hashes are spilling
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- look for: Hash  (cost=... rows=...)
--             Batches: 8  Memory Usage: 4096kB  Disk Usage: 12288kB
```

Setting `work_mem` higher helps (it's per-sort/per-hash, per connection — be careful with 100 concurrent connections all running analytical queries).

### Sort-Merge Join (Merge Join)

```
Phase 1: Sort both relations on the join key
Phase 2: Merge — advance two pointers simultaneously
```

```
users (sorted by user_id):   1, 2, 3, 4, 5, ...
orders (sorted by user_id):  1, 1, 2, 3, 3, 3, 4, ...

Merge:
  u_ptr=1, o_ptr=1 → emit match, advance o_ptr
  u_ptr=1, o_ptr=1 → emit match, advance o_ptr
  u_ptr=2, o_ptr=2 → emit match, ...
  ...
```

**Complexity:** O(N log N + M log M) for the sort, then O(N + M) for the merge. If inputs are *already* sorted (an index scan delivers rows in order), the sort cost vanishes and it's pure O(N + M).

**Best when:**
- Both inputs deliver sorted data (index scans on the join key)
- The join produces a large fraction of both inputs (merge scans are cache-friendly)
- Range join conditions (e.g., `BETWEEN`)

**Bad when:** Both inputs need to be explicitly sorted and are large — two full sorts before the merge starts.

### Choosing Joins — Quick Mental Model

```
┌─────────────────────┬──────────────────────────────────────────────┐
│ Situation           │ Likely winner                                 │
├─────────────────────┼──────────────────────────────────────────────┤
│ Small outer + index │ Nested Loop                                   │
│ Large, no index     │ Hash Join                                     │
│ Both sorted/indexed │ Merge Join                                    │
│ LIMIT 1/10/100      │ Nested Loop (short-circuit wins)              │
│ Memory constrained  │ Merge Join (streams; never builds in-memory)  │
│ Non-equi join       │ Nested Loop or Merge (hash requires equality) │
└─────────────────────┴──────────────────────────────────────────────┘
```

---

## Cost-Based Optimization: Statistics & Histograms

The optimizer picks the cheapest plan — but *cheapest* is based on estimated row counts. Wrong estimates → wrong plan → bad performance. This is the single biggest source of production query performance problems.

### What Statistics the Optimizer Has

PostgreSQL's `pg_statistic` (readable via `pg_stats`) stores, per column:

| Statistic | What it is | Used for |
|-----------|------------|----------|
| `n_distinct` | Distinct value count (or fraction if negative) | Estimating GROUP BY cardinality |
| `most_common_vals` | Top-N most frequent values | Point lookups on skewed columns |
| `most_common_freqs` | Frequency of each MCV | Cardinality after = predicate |
| `histogram_bounds` | Bucket boundaries for non-MCV values | Range predicates |
| `correlation` | Physical vs logical order correlation | Whether index scan beats seq scan |
| `null_frac` | Fraction of NULLs | Filter selectivity |

The `ANALYZE` command populates these. The autovacuum daemon runs `ANALYZE` automatically, but it reacts to changed-row-count thresholds (`autovacuum_analyze_threshold + autovacuum_analyze_scale_factor × reltuples`) — there's a window after a large bulk load where the statistics are stale.

### Histograms

For range predicates, the optimizer uses histogram buckets. With the default `default_statistics_target = 100`, PostgreSQL collects 100 buckets per column. Each bucket boundary divides the value range into equal-frequency parts.

```
Column: order_date
Buckets: 100
Values span: 2020-01-01 to 2024-12-31

Histogram (illustrative):
  ─┬──────────────────────────────────────────┬──
   │ 2020-01-01 ... 2020-05-01 ... 2024-12-31 │
   │     ↑bucket boundary every ~18 days       │
  ─┴──────────────────────────────────────────┴──

Predicate: order_date > '2024-06-01'
Estimate: fraction of buckets above that bound × row count
```

Histograms work well for *uniform* distributions. They break down for:
- **Highly skewed data:** a column where 80% of rows have one value and the other 20% spread across a million values. The histogram buckets compress the 80% into too few entries.
- **Correlated predicates:** `WHERE city = 'Mumbai' AND zip = '400001'` — the optimizer assumes independence and multiplies selectivities, getting a gross underestimate for India's most-populated city.
- **Out-of-range values:** predicates referencing values beyond the histogram bounds get a best-guess (often the minimum selectivity). For `NOW()` on a recently-populated timestamp column, the optimizer may have no histogram bucket for today's date and underestimate wildly.

### Extended Statistics (PostgreSQL 10+)

PostgreSQL 10 added `CREATE STATISTICS` to capture *multi-column* statistics:

```sql
-- capture correlation between city and zip
CREATE STATISTICS idx_city_zip ON city, zip FROM addresses;
ANALYZE addresses;
```

This generates cross-column MCV lists and ndistinct counts. Use it when you have correlated columns in frequent WHERE conditions and EXPLAIN shows cardinality wildly off.

---

## Cardinality Estimation: Why It Goes Wrong

Cardinality estimation is the hardest part of query optimization. A factor-of-10 miss on a small table might change a plan from nested-loop to hash; a factor-of-1000 miss on a large table can turn a 100ms query into a 10-minute one.

### The Independence Assumption

The optimizer assumes predicates on different columns are statistically independent. For `WHERE country = 'IN' AND city = 'Mumbai'`, it computes:

```
sel(country='IN') × sel(city='Mumbai') × total_rows
= 0.20 × 0.001 × 10,000,000
= 2,000
```

But Mumbai *is* in India, so almost every Mumbai row satisfies both conditions — the real count is closer to 10,000. The optimizer underestimates by 5× and chooses a nested loop that's too aggressive.

### Join Cardinality: Multiplied Errors

Cardinality errors compound across joins. A three-way join:

```
Table A × Table B × Table C
Est A = 1,000 rows (actual: 10,000) — 10× error
Est A⋈B = 500 rows (actual: 100,000) — 200× error after multiplication
Est A⋈B⋈C = 100 rows (actual: 10,000,000) — 100,000× error
```

This is **join-order explosion** in a different sense: the explosion isn't in plan candidates, it's in estimation error. An optimizer that's 10× wrong on each of five joins produces a plan that's 10^5 = 100,000× wrong on the final cardinality. The wrong join order (and wrong join algorithm) follow directly.

### Function Wrapping Destroys Statistics

```sql
-- bad: strips the statistics from the column
WHERE UPPER(email) = 'USER@EXAMPLE.COM';

-- good: use case-insensitive collation or a functional index
WHERE email = 'user@example.com';
-- or
CREATE INDEX idx_email_lower ON users (LOWER(email));
WHERE LOWER(email) = 'user@example.com';
```

When you wrap a column in a function, the optimizer cannot use the column's statistics to estimate selectivity (it doesn't know what UPPER does to the distribution). It falls back to a generic guess, often 1/100 or similar, which is usually wrong.

---

## EXPLAIN and EXPLAIN ANALYZE — Reading Plans

`EXPLAIN` shows the plan with cost estimates. `EXPLAIN ANALYZE` actually runs the query and shows real vs estimated row counts. The gap is your cardinality estimation error.

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE o.status = 'paid'
GROUP BY u.name;
```

Reading the output (bottom-up, innermost nodes first):

```
HashAggregate  (cost=12000..12050 rows=500 width=40)
               (actual time=892..904 rows=4832 loops=1)
               ← ESTIMATE: 500, ACTUAL: 4832  → 10× underestimate!
  ->  Hash Join  (cost=1850..11500 rows=100000 width=32)
                 (actual time=44..811 rows=948234 loops=1)
        Hash Cond: (o.user_id = u.id)
        Buffers: shared hit=9823 read=1204
        ->  Seq Scan on orders  (cost=0..8300 rows=245000 width=20)
                                (actual time=0.1..320 rows=245000 loops=1)
              Filter: (status = 'paid')
              Rows Removed by Filter: 755000
        ->  Hash  (cost=1100..1100 rows=60000 width=20)
                  (actual time=42..42 rows=60000 loops=1)
              Buckets: 65536  Batches: 1  Memory Usage: 3841kB
              ->  Seq Scan on users  (cost=0..1100 rows=60000 width=20)
                                     (actual time=0.1..18 rows=60000 loops=1)
```

Key signals to look for:
- **Rows estimate vs actual:** more than 10× off anywhere → run `ANALYZE` on the involved tables, or create extended statistics
- **Buffers: read=N:** pages read from disk (not cache) — `shared hit` is from buffer pool
- **Batches > 1 in Hash:** memory spill — raise `work_mem` or check if you can reduce the build-side row count
- **Loops=N on inner node:** N is the outer relation's row count — if N is large and there's no index, that's your nested-loop O(N×M) bomb

---

## Debugging Query Plans

### Bad Plan from Stale Statistics

**Symptom:** A query that was fast for months suddenly takes 10× longer after a large import.

**Diagnosis:**

```sql
-- check when ANALYZE last ran
SELECT schemaname, tablename, last_analyze, last_autoanalyze, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE tablename = 'orders';

-- check if estimated vs actual row counts diverge
EXPLAIN ANALYZE SELECT COUNT(*) FROM orders;
-- if cost= estimate is wildly below actual rows, stats are stale
```

**Fix:**

```sql
-- manual ANALYZE on just the affected table
ANALYZE orders;

-- or increase statistics resolution for a skewed column
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 500;
ANALYZE orders;

-- verify: pg_stats now has more histogram buckets
SELECT tablename, attname, n_distinct, array_length(histogram_bounds, 1) AS bucket_count
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';
```

**Prevention:** After any bulk load (`COPY`, mass `INSERT`), run `ANALYZE` explicitly before the first query. Don't trust autovacuum's threshold — it may not have fired yet.

### Join-Order Explosions: The Optimizer Can't Search Everything

For N-way joins, the number of join orderings is N! (factorial). PostgreSQL's default `join_collapse_limit = 8` means for more than 8 tables it switches to a greedy strategy rather than exhaustive dynamic programming. The greedy strategy can pick a wrong join order.

**Symptom:** A query joining 10+ tables takes forever despite all tables having good indexes. EXPLAIN shows a join order that materializes a large intermediate result early.

**Diagnosis and Fix:**

```sql
-- temporarily force exhaustive search (only for debugging; never in prod)
SET join_collapse_limit = 20;
SET from_collapse_limit = 20;
EXPLAIN SELECT ...;

-- compare plans; if the exhaustive plan is dramatically better,
-- consider rewriting the query to hint the join order manually:
-- move the most selective table first in FROM

-- alternatively, materialize the selective subquery explicitly
WITH small_paid_orders AS MATERIALIZED (
  SELECT user_id FROM orders WHERE status = 'paid' AND total > 10000
)
SELECT u.name FROM users u JOIN small_paid_orders spo ON u.id = spo.user_id;
```

The `MATERIALIZED` hint (PostgreSQL 12+) tells the optimizer to execute the CTE once and cache it, preventing it from being merged into the outer query and losing the cardinality reduction.

### The "Disabled Path" Anti-Pattern

Never do this in production:

```sql
SET enable_seqscan = off;  -- forced to index scan
SET enable_hashjoin = off; -- forced to merge/nested join
```

Disabling access paths hides the real problem (stale stats, missing index, bad `random_page_cost`) and creates new surprises when the disabled path would have been the right choice for a different query. Fix the statistics or add the index; don't paper over it.

### Tracking Slow Queries

```sql
-- enable in postgresql.conf / as superuser
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
-- restart required, then:
CREATE EXTENSION pg_stat_statements;

-- find the slowest queries by total time
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

`pg_stat_statements` is the single most useful tool for production query tuning. It shows normalized query patterns (literals replaced by `$1`) with aggregate timing across all executions — so a query called 100,000 times that's individually fast but slow in aggregate appears.

---

## Checkpoint

You're solid on this module when you can:

1. Describe what happens in each of the four phases (parse, rewrite, plan, execute) and name one thing that can fail or be slow in each.
2. Given a query and a table size, predict whether the optimizer is likely to choose a sequential scan or an index scan — and state the `random_page_cost` tuning that changes this on SSD.
3. Name the three join algorithms, state the complexity of each, and give a concrete scenario where each one wins.
4. Explain why wrapping a column in `UPPER()` in a WHERE clause destroys cardinality estimation.
5. Read an `EXPLAIN ANALYZE` output and identify: which node's estimate is most wrong, whether a hash join is spilling to disk, and how many actual loops a nested-loop inner node ran.
6. Walk through the full debugging flow for "query suddenly got slow after a data import" — the exact SQL commands to run, in order.
7. Explain why join-order estimation errors compound multiplicatively across five joins and what the consequence is for a 10-table query.
8. Use `pg_stat_statements` to find the top-5 queries by total execution time and know what `mean_exec_time` vs `total_exec_time` tells you about whether to optimize a query.

➡ Next: **Replication & Partitioning** — once you understand how queries execute on one node, the next layer is what happens when data lives on multiple nodes and how reads and writes stay consistent across them.
