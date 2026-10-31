# Indexes, Deeply

> **Module 05 · Course 18** — An index is a data structure that trades write overhead and storage for faster reads. That's the bumper-sticker. This module goes deep: how each index type organises its pages internally, when the planner chooses one (or refuses to), how to design multicolumn and covering indexes, and how to detect and fix index bloat before it silently slows your cluster.

You already know that `CREATE INDEX` exists. This module is about knowing *which* index to reach for, *why* the planner sometimes ignores the one you built, and *what state* an index accumulates over time that destroys the gains you expected.

---

## A mental model for all index types

Every index type in Postgres is a separate access method registered in `pg_am`. They all answer the same question — "which rows satisfy this predicate?" — but with different internal structures optimised for different shapes of predicate.

```
┌───────────────────────────────────────────────────────────────────────┐
│  Heap (the actual table — unordered rows in 8 KB pages)               │
│  row(tid=0,1) row(tid=0,2) … row(tid=N,M)                            │
└────────────────────────┬──────────────────────────────────────────────┘
                         │ each index stores (key → tid) or (key → tids)
         ┌───────────────┼────────────────────────────────────┐
         │               │                                    │
    ┌────▼────┐     ┌────▼────┐     ┌─────▼──────┐    ┌──────▼──────┐
    │ B-tree  │     │  Hash   │     │  GIN/GiST  │    │    BRIN     │
    │ sorted  │     │ equality│     │ composite  │    │ range summary│
    └─────────┘     └─────────┘     └────────────┘    └─────────────┘
```

The TID (tuple identifier) is `(block_number, offset)` — a physical pointer into the heap. Every index maps search keys to TIDs, then Postgres fetches those pages from the heap (or skips the heap entirely for an index-only scan).

---

## B-tree — the default

B-tree is what you get with plain `CREATE INDEX`. It keeps its keys in sorted order across a balanced tree of pages. Sorted order is the superpower: it serves `=`, `<`, `>`, `BETWEEN`, `LIKE 'prefix%'`, and `ORDER BY` — any operator that maps to a directional comparison.

### Internal structure

```
                        ┌──────────────────┐
                        │  ROOT (internal) │
                        │  [200] [500]     │
                        └──┬──────┬────────┘
               ┌───────────┘      └───────────┐
        ┌──────▼──────┐                ┌──────▼──────┐
        │ INTERNAL    │                │ INTERNAL    │
        │ [80][120]   │                │ [310][430]  │
        └──┬──┬───────┘                └──┬──┬───────┘
      ┌────┘  └────┐                 ┌────┘  └────┐
   ┌──▼──┐      ┌──▼──┐           ┌──▼──┐      ┌──▼──┐
   │LEAF │      │LEAF │           │LEAF │      │LEAF │
   │←──→ │      │←──→ │           │←──→ │      │←──→ │
   └─────┘      └─────┘           └─────┘      └─────┘
     leaf pages are doubly-linked → supports range scans without going back to root
```

Leaf pages are doubly linked. A range scan (`WHERE id BETWEEN 100 AND 300`) descends once to the leftmost leaf matching 100, then follows the right-pointer chain through the leaves — it never has to re-traverse from the root. This is why B-trees handle `ORDER BY indexed_col LIMIT N` so efficiently: Postgres walks the linked leaf chain and stops as soon as it collects `N` rows.

### Index-only scans (IOS)

When all columns your query projects and filters on are present in the index, Postgres can answer the query without touching the heap at all — an **index-only scan**. The limiting factor is the **visibility map**: a bitmap, one bit per heap page, marking pages where *every* tuple is known visible to all transactions. If the VM bit is set, the IOS can skip the heap page entirely. If the bit is clear (the page has recently-dead or uncommitted tuples), Postgres must fetch the heap page to check visibility even during an IOS, degrading to a partial heap fetch.

```sql
-- Create a covering index so this query never touches the heap:
CREATE INDEX idx_users_email_status
    ON users (email)
    INCLUDE (status, created_at);

-- Query uses the index and the INCLUDE columns — no heap I/O
EXPLAIN (ANALYZE, BUFFERS)
SELECT status, created_at
FROM   users
WHERE  email = 'alice@example.com';
-- look for "Index Only Scan" and "Heap Fetches: 0"
```

`INCLUDE` columns are stored only in the leaf pages, not in internal nodes. They are not usable as search keys — you cannot filter on them — but they are free to project. This keeps internal nodes smaller (fewer columns, more keys per page), which reduces tree depth and speeds all searches.

> **Rule of thumb:** add columns to `INCLUDE` when they are frequently projected alongside an indexed key but are not useful as search predicates. Think `created_at`, `status`, `amount` paired with an indexed `user_id`.

### When the planner skips your B-tree

The most common surprise is a sequential scan on a table that has a relevant index. The planner performs a cost comparison. If the index scan cost exceeds the sequential scan cost it picks seq scan — and it is usually right. The cost model is covered in Module 06, but the intuition here:

- On a small table (< ~1000 pages), a sequential scan is cheaper because a single I/O pass fills the buffer pool efficiently with minimal seek overhead. Adding a B-tree index on a 50-row lookup table is noise.
- If the query selects more than roughly 5–20 % of the table's rows, the random-I/O pattern of following TIDs into the heap exceeds the sequential scan cost. Use a bitmap scan first (see Module 06) which batches and sorts TIDs before touching the heap.
- If statistics are stale (`ANALYZE` not run), the planner may underestimate selectivity and choose a worse plan.

---

## Hash indexes

A Hash index stores `hash(key) → TID`. It answers only `=` queries — it has no concept of ordering, so it cannot serve range queries or `ORDER BY`.

```sql
CREATE INDEX idx_sessions_token
    ON sessions USING HASH (session_token);
```

Prior to Postgres 10, Hash indexes were not WAL-logged and would corrupt on crash. Since Postgres 10 they are fully crash-safe and WAL-replicated. They can be faster than B-tree for pure equality lookups on high-cardinality columns because the hash comparison is cheaper than a multi-level tree descent, and the leaf pages are smaller (no ordering metadata). In practice, the difference is measurable only at very high QPS — for most workloads a B-tree on a high-cardinality column is indistinguishable in performance from a Hash, so the operational simplicity of a single index type wins.

**When to actually use Hash:** session tokens, UUIDs, content-addressed keys, JWT jti fields — any column where `=` is the only predicate you will ever write and cardinality is extremely high.

---

## GIN — Generalised Inverted Index

GIN indexes a *set of values* per row and builds an inverted posting list: `value → list of TIDs`. The canonical use cases are:

| Data type | Example predicate | GIN operator class |
|-----------|-------------------|-------------------|
| `text[]` (array) | `'{tag1,tag2}' && tags` | `gin__int_ops` (intarray ext.) |
| `jsonb` | `data @> '{"status":"active"}'` | `jsonb_ops` |
| Full-text `tsvector` | `to_tsvector(...) @@ query` | `tsvector_ops` |
| `hstore` | `attrs @> 'color=>red'` | `gin_hstore_ops` |

### How GIN works internally

```
For a posts table with a tags text[] column:
  row 1: tags = ['postgres','indexing']
  row 2: tags = ['postgres','mvcc']
  row 3: tags = ['indexing','vacuum']

GIN builds:
  "indexing" → {TID(1), TID(3)}
  "mvcc"     → {TID(2)}
  "postgres" → {TID(1), TID(2)}
  "vacuum"   → {TID(3)}
```

A query for `tags @> ARRAY['postgres','indexing']` intersects the posting lists for 'postgres' and 'indexing', returning TID(1) — the only row with both.

### GIN for JSONB

```sql
-- Default GIN (indexes every key and value path):
CREATE INDEX idx_events_data ON events USING GIN (data);

-- jsonb_path_ops (indexes only the containment path, smaller, faster @>):
CREATE INDEX idx_events_data_path ON events USING GIN (data jsonb_path_ops);
```

`jsonb_ops` (default) supports `?` (key exists), `?|`, `?&`, `@>` — full flexibility.
`jsonb_path_ops` supports only `@>` (containment) and `@?` / `@@` (JSONPath), but is significantly smaller and faster for pure containment queries.

### GIN for full-text search

```sql
-- Pre-compute the tsvector and index it:
ALTER TABLE articles ADD COLUMN fts_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))
    ) STORED;

CREATE INDEX idx_articles_fts ON articles USING GIN (fts_vector);

-- Search:
SELECT title
FROM   articles
WHERE  fts_vector @@ plainto_tsquery('english', 'distributed systems')
ORDER  BY ts_rank(fts_vector, plainto_tsquery('english', 'distributed systems')) DESC
LIMIT  20;
```

### GIN write amplification

GIN updates are expensive because every modified element in an array or document requires updating multiple posting lists. Postgres mitigates this with a **pending list** (controlled by `gin_pending_list_limit`, default 4 MB): fast inserts accumulate in a small unsorted list at the start of the index; a background worker or the next read merges them into the main structure. This means GIN reads on a freshly-inserted but unmerged set incur a merge cost — force a merge with `SELECT gin_clean_pending_list('idx_articles_fts')` or `VACUUM`.

---

## GiST — Generalised Search Tree

GiST is not a single index structure — it is a *framework* for building custom index types. The framework provides the tree skeleton; user-defined operator classes supply the key comparison and decomposition functions. This is how Postgres ships one index type that handles:

- **Geometric types** (`point`, `box`, `circle`, `polygon`) with operators `<<`, `>>`, `&&`, `@>`, `<->`
- **Range types** (`int4range`, `tsrange`, `daterange`) with `&&`, `@>`, `<@`
- **Full-text** (alternative to GIN, worse for large lexicons)
- **PostGIS** geometry (via `postgis` extension)

```sql
-- Index a geometry column for bounding-box overlaps (PostGIS):
CREATE INDEX idx_places_geom ON places USING GIST (location);

-- Index a daterange for containment / overlap:
CREATE INDEX idx_bookings_range ON bookings USING GIST (occupied);

-- Find bookings that overlap a requested window:
SELECT * FROM bookings
WHERE occupied && '[2024-06-01, 2024-06-07)'::daterange;
```

GiST uses a bounding-box abstraction internally: each internal node stores a bounding key that encompasses all keys below it. This allows fast pruning of subtrees that cannot contain matching rows. The trade-off is that bounding keys can overlap between subtrees (unlike B-tree where boundaries are exact), which means a search may need to descend into multiple subtrees — but the prune is still far cheaper than a sequential scan over millions of rows.

---

## BRIN — Block Range Index

BRIN (Block Range INdex) stores summary statistics (min, max) for a *range of contiguous heap pages* rather than individual row keys. It is extremely small — a few kilobytes for a billion-row table — but it is only useful when the physical ordering of rows correlates strongly with the indexed column.

```
Heap pages:
  pages  0–127:  timestamps 2024-01-01 … 2024-01-15
  pages 128–255: timestamps 2024-01-15 … 2024-02-01
  ...

BRIN stores:
  block range [0,127]:   min=2024-01-01, max=2024-01-15
  block range [128,255]: min=2024-01-15, max=2024-02-01
```

A query for `WHERE created_at > '2024-06-01'` consults the BRIN and skips any block range whose max is before that date — it may still need to scan a partial range, but the majority of the heap is bypassed.

```sql
-- Append-only event log with a sequential time column — perfect for BRIN:
CREATE INDEX idx_events_created_brin
    ON events USING BRIN (created_at)
    WITH (pages_per_range = 128);   -- default is 128
```

**Use BRIN when:**
- The table is huge (tens of millions of rows) and append-only (logs, events, time-series).
- The column value naturally increases with insert order (timestamps, auto-increment IDs).
- Storage is a concern — a BRIN on a billion-row table is a few hundred kilobytes vs a B-tree that could be gigabytes.

**Do not use BRIN when:**
- Rows are inserted out of order with respect to the indexed column.
- Cardinality of the range predicate is high (you need to scan most ranges anyway).
- You need `=` lookups (BRIN scans at block-range granularity, so it often returns many false positives that require heap rechecks).

---

## SP-GiST — Space-Partitioning GiST

SP-GiST implements space-partitioning trees: quadtrees, k-d trees, radix/Patricia tries. Where GiST divides space into potentially-overlapping bounding boxes, SP-GiST creates non-overlapping partitions. This makes it faster for high-dimensional or prefix-based queries.

Built-in operator classes:
- `point` — k-d tree for 2D nearest-neighbour (`<->` operator)
- `text` — Patricia trie for fast prefix matching (`LIKE 'prefix%'`, `^@` starts-with operator)
- `inet`/`cidr` — radix tree for IP prefix containment
- `range` types — quadtree for range overlaps (alternative to GiST)

```sql
-- Fast prefix text search — better than GIN for LIKE 'x%' patterns:
CREATE INDEX idx_products_sku_prefix ON products USING SPGIST (sku);
SELECT * FROM products WHERE sku ^@ 'SAP-ADC-';

-- IP prefix containment (useful for CIDR ACLs):
CREATE INDEX idx_network_ranges ON network_ranges USING SPGIST (cidr_block inet_ops);
SELECT * FROM network_ranges WHERE cidr_block >>= '10.20.30.40'::inet;
```

---

## Partial indexes — filter your index

A partial index covers only the rows that satisfy a `WHERE` clause. This is useful in three scenarios:

1. **Index only the interesting minority of rows** — a `status = 'pending'` column where 99 % of rows are `'done'`.
2. **Enforce a conditional unique constraint** — unique among active records.
3. **Make index-only scans viable on a busy column** — index just the range that queries actually hit.

```sql
-- Only index pending jobs — much smaller, faster for the queue worker:
CREATE INDEX idx_jobs_pending ON jobs (created_at)
WHERE status = 'pending';

-- Conditional unique: one active username per account, but allow multiple deleted:
CREATE UNIQUE INDEX idx_users_active_email ON users (email)
WHERE deleted_at IS NULL;

-- The planner will only use a partial index if the query's WHERE clause
-- implies the index predicate. This works:
EXPLAIN SELECT * FROM jobs WHERE status = 'pending' AND created_at < NOW() - INTERVAL '1h';

-- This does NOT use the index (predicate is not implied):
EXPLAIN SELECT * FROM jobs WHERE created_at < NOW() - INTERVAL '1h';
```

---

## Expression indexes — index a computation

You can index the *result* of an expression rather than a column value. Useful for case-insensitive search, normalised email matching, extracted JSON fields used frequently.

```sql
-- Case-insensitive email login without lowercasing every stored value:
CREATE INDEX idx_users_lower_email ON users (lower(email));

-- The query MUST use the same expression or the index is not used:
SELECT * FROM users WHERE lower(email) = lower('Alice@Example.com');

-- Extract a JSON field used in many queries:
CREATE INDEX idx_events_user_id ON events ((data->>'user_id'));

-- Partial + expression combined — index lower(email) only for active accounts:
CREATE INDEX idx_users_active_lower_email ON users (lower(email))
WHERE deleted_at IS NULL;
```

> **Pitfall:** if your application passes `WHERE email = 'alice@example.com'` (no `lower()`) and the index is on `lower(email)`, the index is invisible to the planner. The expression in the query must be identical (syntactically) to the expression in the index definition.

---

## Multicolumn indexes and column order

A multicolumn B-tree index on `(a, b, c)` is sorted first by `a`, then by `b` within each `a` value, then by `c`. This is the *leftmost prefix rule*:

- The index can serve queries filtering on `a`, `a + b`, or `a + b + c`.
- It **cannot** serve a query filtering only on `b` or only on `c` — there is no way to descend the tree without the leading key.
- It can serve a query on `a + c` (using `a` to narrow the range, then rechecking `c` via heap recheck — a partial skip scan, efficient only when `a` has low cardinality).

```
Index: (account_id, created_at, status)

Query 1: WHERE account_id = 42                          → uses index (leading key)
Query 2: WHERE account_id = 42 AND created_at > '2024'  → uses index (prefix match)
Query 3: WHERE account_id = 42 AND status = 'paid'      → partial use (a, then recheck c)
Query 4: WHERE created_at > '2024'                      → cannot use index (not a prefix)
Query 5: WHERE status = 'paid'                          → cannot use index
```

### Ordering columns for maximum re-use

Put the most *equality-filtered* column first. Equality on the leading column completely eliminates that dimension before the range scan begins. Range columns should come later.

```sql
-- Good: account_id is almost always equality-filtered; created_at is range
CREATE INDEX idx_orders ON orders (account_id, created_at DESC);

-- Bad: created_at range goes first, preventing account_id equality from leading
CREATE INDEX idx_orders_bad ON orders (created_at DESC, account_id);
```

For a compound `ORDER BY account_id ASC, created_at DESC`, the index direction on each column must match (or be fully reversed) for the planner to use the index without a sort step. Mix of ASC/DESC on the same index is supported in Postgres: `(a ASC, b DESC)`.

---

## When NOT to index

Every index has a cost:
- **Write amplification:** every `INSERT`, `UPDATE`, and `DELETE` must maintain each index. A row update that touches an indexed column rewrites the old index entry and inserts a new one.
- **Storage:** a B-tree index on a `bigint` column typically uses 30–50 % of the table size.
- **VACUUM overhead:** dead index tuples accumulate alongside dead heap tuples and must be cleaned by VACUUM.

Do not index:
- **Low-cardinality columns** — a boolean `is_deleted` where 98 % of rows are `false`. The planner prefers a seq scan because even a "small" result set means touching half the table's pages via random I/O. Use a **partial index** with `WHERE is_deleted = false` instead.
- **Tiny tables** — a seq scan on 500 rows is cheaper than B-tree descent + heap fetch. As a rough guide, tables under ~5,000 rows rarely benefit from additional indexes.
- **Write-heavy staging tables** — an ETL landing table that gets bulk-loaded and then truncated. The index slows the load and is never queried.
- **Columns used only with non-sargable predicates** — `WHERE lower(email) = ...` when the index is on `email`. Build an expression index instead.

---

## Index bloat and REINDEX

B-tree pages accumulate *dead tuples* (from updated and deleted rows) that are not immediately reclaimed. VACUUM marks these tuples as free space available for reuse but does not compact the pages or return them to the OS. Over time, especially after large batch deletes, a B-tree can have many pages that are mostly empty — this is **index bloat**.

### Detecting bloat

```sql
-- Quick estimate via pg_relation_size vs expected size:
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- More precise: pgstattuple extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstatindex('idx_orders_account_id');
-- avg_leaf_density < 60 % suggests meaningful bloat
```

A `pgstatindex` result with `avg_leaf_density` below ~60 % means index pages are on average less than 60 % full — a meaningfully bloated index.

### Rebuilding an index

```sql
-- Rebuilds in place; holds AccessShareLock only (blocks nothing but itself)
-- Postgres 12+: CONCURRENTLY supported for REINDEX
REINDEX INDEX CONCURRENTLY idx_orders_account_id;

-- Rebuild all indexes on a table:
REINDEX TABLE CONCURRENTLY orders;
```

`REINDEX` without `CONCURRENTLY` holds `AccessExclusiveLock` and blocks all reads and writes. Always use `CONCURRENTLY` in production. The trade-off: a concurrent reindex takes 2–3x as long and leaves a temporary invalid index visible in `pg_indexes` until the operation completes.

An alternative for severe bloat is a covering-index replacement:
```sql
-- Create new index first (concurrent, no lock on the old one):
CREATE INDEX CONCURRENTLY idx_orders_account_id_new ON orders (account_id, created_at);
-- Once complete, drop the old:
DROP INDEX CONCURRENTLY idx_orders_account_id_old;
-- Rename:
ALTER INDEX idx_orders_account_id_new RENAME TO idx_orders_account_id;
```

---

## Debugging: index not used

**Symptom:** `EXPLAIN` shows `Seq Scan` on a table with a relevant index.

**Step 1 — check planner statistics are current:**
```sql
SELECT relname, last_analyze, n_live_tup, n_dead_tup
FROM   pg_stat_user_tables
WHERE  relname = 'orders';
-- If last_analyze is weeks ago or n_dead_tup >> n_live_tup, run ANALYZE:
ANALYZE orders;
```

**Step 2 — check the cast or expression matches exactly:**
```sql
-- If the column is integer and you pass a string literal:
EXPLAIN SELECT * FROM orders WHERE account_id = '42';  -- implicit cast may break index
-- Use the correct type:
EXPLAIN SELECT * FROM orders WHERE account_id = 42;
```

**Step 3 — force index use to compare actual costs:**
```sql
-- Temporarily disable seq scan to force the index and check actual cost:
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE account_id = 42;
RESET enable_seqscan;
-- If the forced index plan is slower, the planner was right all along.
```

**Step 4 — check selectivity:**
```sql
SELECT histogram_bounds
FROM   pg_stats
WHERE  tablename = 'orders' AND attname = 'account_id';
-- If the value you're querying is in the most frequent bucket (> 10-15% of rows),
-- a seq scan will be cheaper than a random-I/O index scan.
```

---

## Debugging: wrong column order in a multicolumn index

**Symptom:** you have `(a, b)` indexed but queries on `b` alone are slow.

```sql
-- Check which indexes are being used:
SELECT indexname, idx_scan
FROM   pg_stat_user_indexes
WHERE  tablename = 'events';
-- An index with idx_scan = 0 after weeks of production traffic is likely unused.

-- Check what columns queries actually filter on:
SELECT query, calls, mean_exec_time
FROM   pg_stat_statements
WHERE  query ILIKE '%from events%'
ORDER  BY mean_exec_time DESC
LIMIT  10;
-- If you see queries filtering on b without a, add a separate index on (b).
```

---

## Debugging: bloated index

**Symptom:** index is large, queries are slower than expected, `pgstattuple` shows low leaf density.

```sql
SELECT * FROM pgstatindex('idx_orders_account_id');
-- avg_leaf_density: 38.2   ← severely bloated
```

Action: `REINDEX INDEX CONCURRENTLY idx_orders_account_id;`

Monitor progress:
```sql
SELECT phase, blocks_done, blocks_total, tuples_done, tuples_total
FROM   pg_stat_progress_create_index
WHERE  relid = 'orders'::regclass;
```

---

## Checkpoint

You are ready for the index challenges when you can, without looking anything up:

1. Explain why a B-tree index leaf pages are doubly-linked and how that enables range scans without re-traversing from the root.
2. State the single condition that prevents an index-only scan from being 100 % heap-free, and name the Postgres structure involved.
3. Name three data types or predicates for which GIN is the correct index type, and one for which Hash is more appropriate than B-tree.
4. Write the `CREATE INDEX` statement for a case-insensitive unique email constraint on active users only (deleted_at IS NULL).
5. Given an index on `(account_id, created_at, status)`, state which of the following queries can use the index and which cannot, and why: `WHERE account_id = 1`, `WHERE created_at > '2024'`, `WHERE account_id = 1 AND status = 'paid'`.
6. Explain why a partial index on a low-cardinality status column outperforms a full index on the same column.
7. Describe the trade-off between `REINDEX` and `REINDEX CONCURRENTLY` and when you must use the latter in production.
8. Identify two queries from `pg_stat_statements` and `pg_stat_user_indexes` that together tell you an index is unused and a candidate for removal.

➡ Next up: **Module 06 — The Planner & EXPLAIN ANALYZE** — understanding cost models, statistics, and how to read the full execution plan to find and fix bad plan choices.
