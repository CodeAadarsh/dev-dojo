# Solution — JSONB + GIN: Index the Document

## Step 1: Confirm the problem (no index, seq scan)

```sql
-- List indexes on the table — there should be none on attrs yet.
\d ch05.products

-- Check the query plan before adding an index.
EXPLAIN SELECT * FROM ch05.products WHERE attrs @> '{"brand":"Nike"}';
```

Expected EXPLAIN output (no index):

```
Seq Scan on products  (cost=0.00..115.00 rows=5 width=...)
  Filter: (attrs @> '{"brand": "Nike"}'::jsonb)
```

A 5 000-row seq scan. Not catastrophic at this scale, but this pattern doesn't scale — at 5 000 000 rows the same query is still a full table scan.

---

## Step 2: Add the GIN index

```sql
CREATE INDEX idx_products_attrs_gin ON ch05.products USING gin(attrs);
```

Alternatively, using the `jsonb_path_ops` operator class (smaller index, `@>` only):

```sql
CREATE INDEX idx_products_attrs_gin ON ch05.products USING gin(attrs jsonb_path_ops);
```

**Why `jsonb_path_ops` is often better:**

`jsonb_ops` (the default) indexes every key and value separately, producing an entry for `"Nike"` alone, `"brand"` alone, and their combination. This supports `?` (key exists) and `?|` / `?&` operators. The index is larger.

`jsonb_path_ops` indexes only the full path from root to leaf: it stores hashes of paths like `{"brand":"Nike"}` not just `"Nike"`. It cannot answer `?` queries but produces a 20–40% smaller index and faster `@>` lookups because the hash is more selective. If you only run `@>` queries (which is common), use `jsonb_path_ops`.

For this challenge, either operator class passes the verifier.

---

## Step 3: Confirm the index is used

```sql
EXPLAIN SELECT * FROM ch05.products WHERE attrs @> '{"brand":"Nike"}';
```

Expected output after the index exists and ANALYZE has been run:

```
Bitmap Heap Scan on products  (cost=12.75..47.30 rows=1000 width=...)
  Recheck Cond: (attrs @> '{"brand": "Nike"}'::jsonb)
  ->  Bitmap Index Scan on idx_products_attrs_gin  (cost=0.00..12.50 rows=1000 width=0)
        Index Cond: (attrs @> '{"brand": "Nike"}'::jsonb)
```

The plan now has two nodes:

1. **Bitmap Index Scan** — GIN walks its posting lists for "Nike" (in `jsonb_ops`) or the hashed path `{"brand":"Nike"}` (in `jsonb_path_ops`), producing a bitmap of matching heap pages.
2. **Bitmap Heap Scan** — reads only the heap pages set in the bitmap, then rechecks the condition (since the bitmap works at page granularity, not tuple granularity).

The "Recheck Cond" line is normal for bitmap scans — it's not a second GIN lookup. It's a CPU-side predicate check on the already-loaded heap tuples to filter false positives from the page-level bitmap.

---

## Multi-key containment

The real power of GIN is multi-key containment. With the same index:

```sql
-- Finds products that are Nike AND red
EXPLAIN SELECT * FROM ch05.products
WHERE attrs @> '{"brand":"Nike","color":"red"}';
```

GIN intersects the posting lists for `"Nike"` and `"red"` (in `jsonb_ops`) before touching the heap. The result set is much smaller, and the index gets even more efficient as you add constraints to the JSON document.

---

## Checking which indexes exist

```sql
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'ch05' AND tablename = 'products';
```

---

## Run the verifier

```bash
bash courses/course-18-postgresql/challenges/05-jsonb-gin-search/verify.sh
```
