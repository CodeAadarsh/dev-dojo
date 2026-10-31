# Storage: Pages, TOAST & HOT

> **Module 03 · Course 18** — MVCC explains *what* Postgres stores; this module explains *where* it stores it and *how* those storage decisions affect query performance, update throughput, and operational cost. The 8 KB page, the TOAST threshold, fillfactor, and HOT updates are not tuning knobs you can safely ignore — they're the difference between a table that VACUUM finishes in seconds and one that bloats to ten times its logical size.

PostgreSQL stores all data — heap rows, index entries, sequences, system catalogs — in fixed-size pages of exactly 8 192 bytes. Every read and every write is a multiple of this page size. The page layout, the decisions around HOT (Heap-Only Tuple) updates, and the TOAST compression mechanism all follow from this constraint. Mastering this layer makes you effective at diagnosing and fixing performance and bloat problems that are otherwise mysterious.

---

## The 8 KB Page: Structure and Tuple Layout

Every relation file (heap, index, free-space map, visibility map) is divided into 8 192-byte blocks called **pages**. The internal layout of a heap page:

```
  8192-byte heap page
  ┌───────────────────────────────────────────────────────────────────┐
  │ PageHeaderData (24 bytes)                                         │
  │   pd_lsn      (8 bytes) — LSN of last WAL record touching page   │
  │   pd_checksum (2 bytes) — optional data checksum (pg_checksum)   │
  │   pd_flags    (2 bytes) — has_free_lines, all_visible, etc.      │
  │   pd_lower    (2 bytes) — offset to start of free space          │
  │   pd_upper    (2 bytes) — offset to end of free space            │
  │   pd_special  (2 bytes) — start of special area (indexes use it) │
  │   pd_pagesize_version (2 bytes) — 8192 + layout version          │
  ├───────────────────────────────────────────────────────────────────┤
  │ ItemId array (line pointer array, grows downward from pd_lower)   │
  │   ItemId[1]: offset=7040, length=48  → tuple 1                   │
  │   ItemId[2]: offset=6992, length=48  → tuple 2                   │
  │   ItemId[3]: lp_flags=LP_DEAD        → dead (can be reclaimed)   │
  │   …                                                               │
  ├───────────────────────────────────────────────────────────────────┤
  │  F R E E    S P A C E                                             │
  │  (between pd_lower and pd_upper — where new tuples are placed)   │
  ├───────────────────────────────────────────────────────────────────┤
  │ Tuples (grow upward toward pd_lower from pd_upper)                │
  │   HeapTupleHeader (23 bytes) + alignment padding + data          │
  │   HeapTupleHeader contains:                                       │
  │     t_xmin   (4 bytes) — creating XID                            │
  │     t_xmax   (4 bytes) — deleting XID (0 = live)                 │
  │     t_infomask  — hint bits (XMIN_COMMITTED, XMAX_INVALID, …)    │
  │     t_infomask2 — number of attributes, HOT-updated flag         │
  │     t_ctid   (6 bytes) — self-ctid, or forward pointer for HOT   │
  │     t_hoff   (1 byte)  — offset to actual data start             │
  │     [null bitmap, if any nullable columns]                        │
  │     [attribute data, aligned per type]                            │
  └───────────────────────────────────────────────────────────────────┘
```

Key observations:

- **pd_lower and pd_upper** — the free space is the gap between these two pointers. pd_lower grows down (more ItemId entries), pd_upper grows up (more tuple data). When pd_lower meets pd_upper, the page is full.
- **ItemId (line pointers)** — these are 4-byte entries that record the byte offset and length of each tuple within the page. A ctid like `(7, 3)` means block 7, ItemId[3]. Once an ItemId is allocated, its index never changes for the life of the tuple — this stability is what HOT exploits.
- **Tuple alignment** — every column is aligned to its natural alignment (int4 on a 4-byte boundary, int8 on 8-byte, etc.). A table with alternating int4 and int8 columns wastes alignment padding; column-order matters for storage efficiency.

### Tuple size calculation

The minimum tuple overhead is 23 bytes (HeapTupleHeader) + alignment. A simple row with two int4 columns:

```
23 bytes (header) + 1 byte (alignment to 4 bytes) + 4 bytes (col1) + 4 bytes (col2) = 32 bytes
```

Add 24 bytes of page header amortized, plus 4 bytes per ItemId, and the real per-row overhead in a dense page is roughly 28-30 bytes. For narrow tables (UUID primary keys, a few int4 columns), the header overhead is a significant fraction of total storage.

You can inspect tuple overhead with `pageinspect`:

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- look at tuples in block 0 of the orders table
SELECT t_ctid, t_infomask, t_infomask2, t_hoff, t_data
FROM heap_page_items(get_raw_page('orders', 0))
LIMIT 10;

-- pd_lower, pd_upper for the page
SELECT lower, upper, special, pagesize
FROM page_header(get_raw_page('orders', 0));
```

---

## fillfactor

**fillfactor** controls what percentage of a page Postgres fills when initially writing data. Newly inserted rows fill pages up to `fillfactor`; the remaining space is held in reserve for future updates.

```
fillfactor = 100 (default for heap tables):
  ┌─────────────────────────────────────┐
  │ header │ ItemIds │  FREE  │ tuples  │  ← page completely full
  └─────────────────────────────────────┘
  On UPDATE: no free space → new version goes to a DIFFERENT page
             → index must be updated to point to new ctid
             → index bloat + more I/O

fillfactor = 70:
  ┌─────────────────────────────────────┐
  │ header │ ItemIds │ RESERVE │ tuples │  ← 30% reserved
  └─────────────────────────────────────┘
  On UPDATE: new version fits on the SAME page (if small enough)
             → HOT update is possible → no index update needed
```

fillfactor is set per-table:
```sql
ALTER TABLE orders SET (fillfactor = 70);
-- takes effect for new pages written; does not rewrite existing ones
-- to see the effect immediately: VACUUM FULL or CLUSTER (rewrites the table)

-- check current fillfactor
SELECT reloptions FROM pg_class WHERE relname = 'orders';
-- {fillfactor=70}
```

Guidelines for fillfactor:
- **100 (default)**: Insert-only or append-only tables (event logs, time-series, immutable records). No wasted space.
- **70–80**: OLTP tables with heavy UPDATE patterns. Enables HOT updates (see below).
- **50–60**: Hot-spot rows updated very frequently (counters, queue status columns). More reserve means more HOT chains before bloat.
- **Indexes default to 90**: leaves 10% for insertions without page splits, which cascade through the B-tree. Leave at 90 unless you have a specific reason.

---

## HOT Updates (Heap-Only Tuples)

The most important Postgres-specific performance feature for OLTP workloads. HOT is the mechanism that allows an UPDATE to bypass index updates entirely when the update does not change any indexed column and the new tuple version fits on the same page as the old one.

### The problem HOT solves

Without HOT, every UPDATE generates index work:
1. Write the new tuple version to the heap (possibly a different page)
2. Update every index that covers any column of this table to point to the new ctid
3. Mark the old tuple version as dead

If a table has 10 indexes and you update a non-indexed column, Postgres without HOT must update all 10 indexes. For a frequently-updated table (order status changes, row counters) this is 10× the write amplification.

### HOT conditions

A HOT update is possible when both conditions are true:
1. **The updated column is not covered by any index** (otherwise the index entries must reflect the new value)
2. **The new tuple version fits on the same heap page as the old one** (fillfactor must leave room)

When HOT applies:
```
BEFORE HOT UPDATE (both tuples on same page):
page 7:
  ItemId[1] → old tuple: xmin=100 xmax=200 ctid=(7,1) amount=75  ← dead
  ItemId[2] → new tuple: xmin=200 xmax=0   ctid=(7,2) amount=80  ← live

  The old tuple's t_ctid field is set to (7,2) — forward pointer to new version.
  B-tree index entry still points to (7,1) — the ItemId, not the tuple directly.
```

When Postgres follows an index scan and lands on ItemId[1] (the old, dead tuple), it checks `t_ctid` and follows the chain to ItemId[2] — the live version — without any index update.

```
  B-tree index: key=3 → ctid=(7,1)
                                   │
                                   ▼  (HOT chain traversal)
  heap page 7:  ItemId[1] → old dead tuple → t_ctid=(7,2)
                ItemId[2] → new live tuple
```

### HOT pruning

When a page is accessed and Postgres sees dead tuple slots with no live readers (all snapshots that could see the dead version have moved past the dead tuple's xmax), it can **prune** the HOT chain: mark the dead tuple's ItemId as LP_DEAD (reusable) and redirect the ItemId pointer directly to the live tuple. This reclaims space within the page without calling VACUUM.

VACUUM then marks the LP_DEAD slots as LP_UNUSED (fully empty), making their space available for new tuples.

### Checking HOT effectiveness

```sql
-- per-table HOT update ratio
SELECT relname,
       n_tup_upd                                         AS total_updates,
       n_tup_hot_upd                                     AS hot_updates,
       round(n_tup_hot_upd::numeric / nullif(n_tup_upd, 0) * 100, 1) AS hot_pct
FROM pg_stat_user_tables
ORDER BY n_tup_upd DESC
LIMIT 20;
```

A HOT percentage of 0% on a heavily-updated table is a red flag: either all updates touch indexed columns (acceptable — you can't avoid index updates in that case), or the fillfactor is 100 and new versions never fit on the same page (actionable — lower fillfactor).

A HOT percentage of 80-95% on an OLTP table with a thoughtfully set fillfactor is normal and good.

---

## TOAST (The Oversized-Attribute Storage Technique)

A single Postgres page is 8 192 bytes. A heap tuple must fit within one page — Postgres does not support row values spanning multiple pages natively in the heap. But text, bytea, jsonb, and other variable-length types can easily exceed 8 KB.

TOAST solves this: when a row's variable-length column would exceed the threshold (approximately 2 KB by default), Postgres automatically:
1. Compresses the value (using LZ4 or pglz depending on the `COMPRESSION` setting)
2. If still too large, chops the compressed value into 2 KB chunks and stores them in a separate **TOAST table** associated with the main table
3. Replaces the column value in the main table row with an 18-byte "TOAST pointer" (OID reference into the TOAST table)

```
main table heap:
  ┌─────────────────────────────────────────────────────────┐
  │  id=1, created_at=…, body=<TOAST pointer OID=99, 28KB> │
  └─────────────────────────────────────────────────────────┘

pg_toast_NNNN (automatically created TOAST table):
  ┌─────────────────────────────────────────────────────────┐
  │ chunk_id=99, chunk_seq=0, chunk_data=<2KB compressed>   │
  │ chunk_id=99, chunk_seq=1, chunk_data=<2KB compressed>   │
  │ chunk_id=99, chunk_seq=2, chunk_data=<1.3KB compressed> │
  └─────────────────────────────────────────────────────────┘
```

### TOAST storage strategies per column

Each variable-length column has a storage strategy:

| Strategy  | SQL keyword      | Behaviour |
|-----------|------------------|-----------|
| `EXTENDED`| default          | Compress first; move to TOAST if still > page threshold |
| `MAIN`    | `SET STORAGE MAIN` | Compress, prefer to keep inline (move out only if necessary) |
| `EXTERNAL`| `SET STORAGE EXTERNAL` | Store out-of-line uncompressed (fast for random access into the data, e.g. large jsonb you substring into) |
| `PLAIN`   | `SET STORAGE PLAIN` | Never compress, never TOAST (for short fixed-length types like int, bool) |

```sql
-- check current storage strategy per column
SELECT attname, attstorage
FROM pg_attribute
WHERE attrelid = 'documents'::regclass AND attnum > 0;

-- change strategy (only affects future inserts/updates, not existing rows)
ALTER TABLE documents ALTER COLUMN body SET STORAGE EXTERNAL;
```

### TOAST and performance implications

**Reads:** If you SELECT a column that was TOASTed, Postgres must fetch each chunk from the TOAST table — additional random I/O per row. Columns you never need but SELECT via `SELECT *` still incur this I/O. Always select only the columns you need when a table has large TOAST columns.

**Compression:** The default `pglz` compressor is CPU-efficient but not aggressive. LZ4 (available since PG 14 with `ALTER TABLE t ALTER COLUMN c SET COMPRESSION lz4`) is faster for compress/decompress but slightly less compression ratio. For write-heavy workloads with large JSON bodies, LZ4 is usually the right choice.

**TOAST table bloat:** Updating a TOASTed column creates new TOAST chunks and leaves the old ones as dead tuples in the TOAST table. The TOAST table has its own autovacuum settings. You can inspect it:

```sql
-- find the TOAST table for a relation
SELECT reltoastrelid::regclass AS toast_table,
       pg_size_pretty(pg_relation_size(reltoastrelid)) AS toast_size
FROM pg_class
WHERE relname = 'documents';

-- size breakdown
SELECT
  pg_size_pretty(pg_relation_size('documents'))                  AS heap,
  pg_size_pretty(pg_relation_size(reltoastrelid))                AS toast,
  pg_size_pretty(pg_indexes_size('documents'))                   AS indexes,
  pg_size_pretty(pg_total_relation_size('documents'))            AS total
FROM pg_class WHERE relname = 'documents';
```

**UPDATE amplification from TOAST:** An UPDATE that changes a TOASTed column always writes all-new TOAST chunks, even if only one byte changed. For documents that are updated frequently and are large, consider storing deltas rather than full replacements, or partitioning large immutable BLOBs from small frequently-updated metadata.

---

## The Free Space Map (FSM)

The free space map (`$PGDATA/base/NNNN/TTTT_fsm`) tracks, per page, how much free space is available. When Postgres needs to insert a row, it consults the FSM to find a page with enough room rather than scanning the entire heap.

The FSM uses a two-level summary tree: each page gets a 1-byte entry (0–255, representing 0–100% free space in increments). The tree can be queried:

```sql
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;

-- average free space across all pages of a table
SELECT count(*) AS pages,
       round(avg(avail)) AS avg_free_bytes
FROM pg_freespace('orders');

-- distribution
SELECT avail, count(*)
FROM pg_freespace('orders')
GROUP BY avail
ORDER BY avail;
```

The FSM is updated by VACUUM. After a VACUUM pass reclaims dead tuple slots, it updates the FSM with the new free-space figures so future inserts can use that space. If VACUUM never runs, the FSM doesn't know about reclaimed space and Postgres extends the relation file instead of reusing dead-tuple space — this is table bloat.

---

## The Visibility Map (VM)

The visibility map (`$PGDATA/base/NNNN/TTTT_vm`) tracks two bits per page:
1. **All-visible** — every tuple on this page is visible to all current and future transactions (no dead tuples, no in-progress XIDs)
2. **All-frozen** — every tuple on this page has had its XID frozen (important for wraparound prevention)

The visibility map enables two major optimizations:

**Index-Only Scans:** If an index covers all the columns needed by a query, Postgres can return results from the index alone, skipping the heap entirely — but only if the heap page is marked all-visible (to guarantee no dead or invisible tuples lurk there). Without VM, every index-only scan would have to re-check the heap for visibility.

```sql
-- force index-only scan eligibility by ensuring visibility map is up to date:
VACUUM orders;
-- then:
EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM orders WHERE created_at > now() - interval '1 day';
-- look for "Index Only Scan" and "Heap Fetches: 0" — that means zero heap I/O
```

**Aggressive VACUUM / FREEZE:** VACUUM can skip all-frozen pages entirely, making VACUUM runs much faster on tables where most data hasn't changed.

The visibility map is updated by VACUUM. If VACUUM is lagging, the VM is stale, Index-Only Scans become regular Index Scans (with heap fetches), and VACUUM runs slower (more pages to scan).

---

## Table and Index Bloat

Bloat is dead space in heap pages or index pages that hasn't been reclaimed. It has two primary causes:

1. **Dead tuples** — MVCC row versions that are no longer visible to any transaction. VACUUM reclaims their ItemId slots.
2. **Deleted/updated index entries** — B-tree indexes accumulate dead entries pointing to dead heap tuples. VACUUM cleans these up too.

### The high-water mark problem

VACUUM reclaims space **within** pages (marking ItemIds as reusable). It does NOT shrink the file — the disk space used by the table does not decrease. To actually reduce the file size, you need `VACUUM FULL` (rewrites the entire table into a new file, requires an ACCESS EXCLUSIVE lock) or `pg_repack` (online table rewrite, no exclusive lock for most of the operation).

```
After many updates without VACUUM FULL:
  file on disk: [page0][page1][page2][page3][page4][page5]
  actual live data: half of the pages contain mostly dead tuples
  pg_relation_size('orders') = 6 × 8192 bytes
  actual useful data: could fit in 3 pages
  → bloat factor = 2×
```

### Estimating bloat

Without extensions:
```sql
-- dead tuple ratio per table
SELECT
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
  pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS heap_size,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

With `pgstattuple` extension (more accurate — actually reads pages):
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstattuple('orders');
-- tuple_len, dead_tuple_len, free_space, free_percent
-- bloat % = (dead_tuple_len + free_space) / table_len * 100
```

### Index bloat

Index bloat can be worse than heap bloat because B-tree pages are harder to reclaim. VACUUM marks dead index entries but doesn't compact B-tree pages unless they become entirely empty (then they're removed from the tree).

```sql
-- index bloat estimation (approximate, based on pg_stats)
SELECT
  schemaname,
  tablename,
  indexname,
  pg_size_pretty(pg_relation_size(schemaname||'.'||indexname)) AS idx_size
FROM pg_indexes
JOIN pg_class ON relname = indexname
WHERE schemaname = 'public'
ORDER BY pg_relation_size(schemaname||'.'||indexname) DESC;

-- with pgstattuple:
SELECT * FROM pgstatindex('orders_pkey');
-- leaf_fragmentation is the key metric; > 50% means rebuild may help
```

Rebuild an index without downtime (PG 12+):
```sql
REINDEX INDEX CONCURRENTLY orders_status_idx;
-- blocks only briefly at start and end; safe in production
```

---

## Debugging: Storage, Bloat & TOAST

### Bloat growing faster than VACUUM can clear it

Symptom: `n_dead_tup` keeps rising, `last_autovacuum` is minutes ago or null, table file size grows unboundedly.

**Step 1: Is autovacuum running?**
```sql
SELECT pid, datname, relid::regclass, phase,
       heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count
FROM pg_stat_progress_vacuum;
```

If nothing appears, autovacuum isn't running for this table. Check:
```sql
-- is autovacuum globally disabled? (should be false)
SHOW autovacuum;

-- table-level override that disables it
SELECT reloptions FROM pg_class WHERE relname = 'orders';
-- if you see {autovacuum_enabled=false}, that's your culprit
ALTER TABLE orders RESET (autovacuum_enabled);
```

**Step 2: Is autovacuum losing the race?**

If autovacuum IS running but dead tuples accumulate faster than it can remove them, increase the aggressiveness:

```sql
-- per-table: reduce the cost delay and increase the scale factor threshold
ALTER TABLE orders SET (
  autovacuum_vacuum_cost_delay = 2,       -- default 2ms; lower = less throttling
  autovacuum_vacuum_scale_factor = 0.01,  -- trigger at 1% dead rows instead of 20%
  autovacuum_vacuum_threshold = 1000      -- also trigger if > 1000 dead rows absolute
);
```

**Step 3: Is a long-running transaction blocking VACUUM?**

VACUUM cannot remove a dead tuple if any active snapshot could still see it:
```sql
SELECT pid, now() - xact_start AS age, state, left(query, 80)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 5;
```

If the oldest transaction is hours old, investigate and terminate it if appropriate.

### TOAST overhead

If a table has large variable-length columns, check whether TOAST is actually helping:

```sql
-- compare heap size to total size (difference = toast + indexes)
SELECT
  pg_size_pretty(pg_relation_size('documents'))              AS heap,
  pg_size_pretty(pg_relation_size(
    (SELECT reltoastrelid FROM pg_class WHERE relname = 'documents')
  ))                                                         AS toast,
  pg_size_pretty(pg_indexes_size('documents'))               AS indexes;
```

If TOAST is larger than the heap and the table is write-heavy, the TOAST table may be bloated:
```sql
-- get TOAST table name
SELECT reltoastrelid::regclass FROM pg_class WHERE relname = 'documents';
-- e.g. pg_toast.pg_toast_16789

VACUUM VERBOSE pg_toast.pg_toast_16789;
```

For SELECT-heavy workloads where the application rarely needs the large columns, consider:
```sql
-- Set STORAGE EXTERNAL to skip compression (faster decompress-on-read if rarely accessed)
ALTER TABLE documents ALTER COLUMN body SET STORAGE EXTERNAL;

-- Or move large columns to a separate table (manual TOAST with application control):
CREATE TABLE document_bodies (doc_id int PRIMARY KEY REFERENCES documents(id), body text);
```

### Bad fillfactor (HOT rate near 0% on updated table)

If a heavily-updated table shows near-zero HOT updates:

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric / nullif(n_tup_upd, 0) * 100, 1) AS hot_pct,
       reloptions
FROM pg_stat_user_tables
JOIN pg_class ON relname = pg_class.relname
WHERE n_tup_upd > 10000
ORDER BY n_tup_upd DESC;
```

If `hot_pct` is near 0 and `reloptions` is null or has `fillfactor=100`:

```sql
-- lower fillfactor to reserve update space
ALTER TABLE orders SET (fillfactor = 75);

-- fillfactor only affects pages written after the change;
-- rewrite the table to apply immediately:
CLUSTER orders USING orders_pkey;   -- rewrites and clusters by the PK index
-- or:
VACUUM FULL orders;                 -- rewrites with new fillfactor

-- reset stats to measure hot_pct from a clean baseline:
SELECT pg_stat_reset_single_table_counters('orders'::regclass);
```

Wait 15 minutes and re-query — you should see hot_pct climb toward 60-80%.

---

## Checkpoint

Solidify your understanding before moving on:

1. Sketch the internal layout of an 8 KB heap page. Where does free space live, and in which direction do the ItemId array and the tuple area grow?
2. What are the two conditions that must both be true for a HOT update to occur?
3. A table has `n_tup_upd = 1,000,000` and `n_tup_hot_upd = 0`. You have 12 indexes on the table. Name two distinct causes for the zero HOT rate and the fix for each.
4. Describe the TOAST process step by step. At what size does TOAST kick in by default?
5. What are the four TOAST storage strategies? When would you choose EXTERNAL over EXTENDED?
6. What does the visibility map store, and which two VACUUM-powered optimizations does it enable?
7. VACUUM reclaims dead tuple space. What does `VACUUM FULL` do that VACUUM alone cannot? What is the operational cost?
8. A table's `pg_relation_size` is 10 GB but `pgstattuple` shows only 3 GB of live data. What is the bloat factor and what are your options to reclaim the space, ordered by operational disruption?
9. Index-Only Scans show "Heap Fetches: 50,000" in EXPLAIN ANALYZE even though the index covers all queried columns. What does this mean and how do you fix it?
10. What happens to TOAST chunks when you UPDATE a large text column? Does VACUUM reclaim the old TOAST chunks automatically?

➡ Next: **WAL, Recovery & Replication** — how Postgres ensures durability and how the write-ahead log enables streaming replication and crash recovery.
