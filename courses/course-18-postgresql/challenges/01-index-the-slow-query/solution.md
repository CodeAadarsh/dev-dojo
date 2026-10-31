# Solution — Index the Slow Query

## The Answer

Two statements applied to the `orders` table:

```sql
CREATE INDEX idx_orders_user_id ON orders (user_id);
ANALYZE orders;
```

That's it. The flag is yours once verify.sh confirms the planner switched to an Index Scan.

---

## Why This Index, This Column

The slow query is:

```sql
SELECT * FROM orders WHERE user_id = 7777;
```

The only filter is `user_id`. A B-tree index on `user_id` allows the planner to perform a binary search to the leaf nodes that hold pointers to rows where `user_id = 7777`, then fetch only those heap pages. Without the index, the planner has no alternative except reading every row in the table.

The index name (`idx_orders_user_id`) follows the conventional `idx_<table>_<columns>` pattern. PostgreSQL doesn't care about the name — use whatever your team's convention is.

---

## The ANALYZE Step

PostgreSQL stores per-column statistics in `pg_statistic` (visible via `pg_stats`). The planner uses these statistics to estimate how many rows each plan step will return. Without running `ANALYZE`, the planner may not know the index was just created, or may be working off stale row-count estimates that make a seq scan look cheaper.

```bash
docker exec dojo-pg psql -U postgres -d dojo \
  -c "ANALYZE orders;"
```

`autovacuum` runs `ANALYZE` automatically in the background after a threshold of row changes. In a lab environment (single insert, then queries), autovacuum may not have fired yet. Always run `ANALYZE` manually after seeding test data.

---

## Reading EXPLAIN Output

Before the index:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 7777;
```

```
Seq Scan on orders  (cost=0.00..2155.00 rows=10 width=65)
                    (actual time=0.058..21.453 rows=10 loops=1)
  Filter: (user_id = 7777)
  Rows Removed by Filter: 99990
  Buffers: shared hit=655
```

`Rows Removed by Filter: 99990` — the planner examined 100 000 rows and discarded all but 10.

After the index:

```
Index Scan using idx_orders_user_id on orders
            (cost=0.29..26.50 rows=10 width=65)
            (actual time=0.042..0.081 rows=10 loops=1)
  Index Cond: (user_id = 7777)
  Buffers: shared hit=13
```

`Buffers: shared hit=13` — only 13 buffer pages accessed versus 655. This is the key metric in real production tuning: buffer hits map directly to I/O load.

The cost drop from `2155` to `26.50` is the planner's estimate of "how many abstract work units this plan takes". Lower is cheaper.

---

## Index Types and When to Use Which

PostgreSQL ships multiple index access methods. The default (`CREATE INDEX`) always creates a **B-tree**:

| Type | Use case | Example |
|------|----------|---------|
| **B-tree** | `=`, `<`, `>`, `<=`, `>=`, `BETWEEN`, `IN`, `LIKE 'prefix%'`, `ORDER BY` | `WHERE user_id = 7777` |
| **Hash** | Only `=`, slightly faster than B-tree for equality-only; not WAL-logged before PG10 | `WHERE session_id = 'abc'` |
| **GIN** | Full-text search (`tsvector`, `jsonb` key/value), array containment (`@>`) | `WHERE doc @@ 'search term'` |
| **GiST** | Geometric types, range types, nearest-neighbour | `WHERE location <-> point < 1.0` |
| **BRIN** | Very large tables where the physical order correlates with the index column (e.g., a timestamp inserted in order); tiny index, coarse | `WHERE created_at > ...` on an append-only log table |

For `WHERE user_id = 7777` on a random integer column, B-tree is always the right choice.

---

## Composite Indexes and Column Order

If queries filter by multiple columns, a composite index can cover both:

```sql
CREATE INDEX idx_orders_user_status ON orders (user_id, status);
```

Column order in a composite index matters:

- `WHERE user_id = 7777` — the index is used (leading column).
- `WHERE user_id = 7777 AND status = 'pending'` — the index is used (both columns).
- `WHERE status = 'pending'` — the index is **NOT** used efficiently (non-leading column). You'd need a separate index on `status` or reverse the column order.

A composite index on `(user_id, status)` also allows an **Index-Only Scan** for `SELECT user_id, status FROM orders WHERE user_id = 7777` — the planner can serve the entire query from the index without touching the heap at all, because both projected columns are in the index. This is the most efficient plan possible.

---

## Partial Indexes

If only a subset of rows is ever queried via a specific predicate, a partial index is smaller and faster to maintain:

```sql
-- Only index orders that aren't yet delivered — the hot query path
CREATE INDEX idx_orders_pending ON orders (user_id)
WHERE status IN ('pending', 'processing');
```

This index only contains rows where status is 'pending' or 'processing'. If most orders are 'delivered', this index could be 5–10× smaller than a full index on `user_id`, fitting more of it in `shared_buffers`. The planner will use it only when the query's WHERE clause is compatible with the partial index predicate.

---

## Debugging Index Non-Use

The planner will not use an index in several situations:

- **No index exists** — obvious, but `pg_indexes` is the truth.
- **Stale statistics** — run `ANALYZE <table>`.
- **Low selectivity** — `WHERE status = 'delivered'` on a table where 80% of rows are delivered. The planner correctly prefers a seq scan because an index scan would touch almost every heap page anyway.
- **Type mismatch** — `WHERE user_id = '7777'` (string literal vs integer column) can suppress index use in some contexts. Always match types.
- **Function on column** — `WHERE lower(email) = 'foo@bar.com'` does not use an index on `email`. Use a functional index: `CREATE INDEX idx_email_lower ON users (lower(email))`.
- **`enable_indexscan = off`** — someone disabled index scans for debugging and forgot to re-enable it. Check: `SHOW enable_indexscan;`.

---

## Checkpoint

After applying the solution, run the full diagnostic:

```bash
docker exec dojo-pg psql -U postgres -d dojo -c "
  \d orders
  SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'orders';
  EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 7777;
"
```

You should see `idx_orders_user_id` in `pg_indexes` and `Index Scan` (or `Bitmap Index Scan`) in the EXPLAIN output.
