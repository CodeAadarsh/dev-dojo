# Storage Engines: B-tree vs LSM-tree

> **Module 01 · Course 20** — Before you can tune a database, pick the right one, or debug bizarre slowdowns, you need a mental model of what actually happens when a row becomes bytes on a spinning disk or an NVMe block device. This module builds that model from the page up, then shows exactly why two dominant storage engine families make opposite tradeoffs — and how to exploit that knowledge in production.

You already use PostgreSQL or MySQL at work. This module answers the question you have probably never had time to dig into: *why does Postgres slow down under heavy write load in ways that RocksDB doesn't, and why does RocksDB have such bizarre read-amplification stories on cold data?*

---

## How Rows Become Bytes on Disk

Every storage engine, regardless of its indexing strategy, operates on a fundamental unit: the **page** (also called a block). A page is the smallest unit of I/O between main memory and disk.

```
Disk address space (conceptual):
┌─────────────────────────────────────────────────────────────────┐
│  page 0  │  page 1  │  page 2  │  page 3  │  page 4  │  ...  │
│  8 KiB   │  8 KiB   │  8 KiB   │  8 KiB   │  8 KiB   │       │
└─────────────────────────────────────────────────────────────────┘
```

Postgres uses 8 KiB pages. InnoDB uses 16 KiB. SQLite defaults to 4 KiB. The OS has its own page size (typically 4 KiB) — the database page is chosen to be a multiple of that to avoid "torn pages" (a partial OS-level write that leaves a database page half-updated on crash).

The question is: given an 8 KiB page, how do you pack rows of variable length into it?

### Slotted-Page Layout

The canonical answer is the **slotted page**, used by virtually every row-store engine. It looks like this:

```
┌────────────────────────────── 8192 bytes (one Postgres page) ───────────────────────────────┐
│                                                                                              │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐                                  │
│  │  Header  │  Slot[0] │  Slot[1] │  Slot[2] │  Slot[3] │ ...free space...                 │
│  │  24 B    │  2+2 B   │  2+2 B   │  2+2 B   │  2+2 B   │                                  │
│  └──────────┴──────────┴──────────┴──────────┴──────────┘                                  │
│                                                                          ▼ grows down        │
│                                                          ┌────────────────────────────────┐  │
│                                                          │  tuple 3  │  tuple 2  │ tuple1 │  │
│                                                          └────────────────────────────────┘  │
│                                                                          ▲ grows up          │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Key ideas:

- The **header** stores the LSN (log sequence number, for WAL — Module 02), free-space pointers, and flags.
- The **slot array** grows from the start of the page toward the center. Each slot is a (offset, length) pair pointing into the page body.
- **Tuples** (rows) are packed from the end of the page backward.
- When you delete a row, its slot is zeroed (or flagged dead) but the space is not immediately reclaimed — Postgres calls this *tuple bloat*, and `VACUUM` reclaims it. This is why `COUNT(*)` on a heavily-deleted table can be slow: dead tuples still occupy page slots.
- When you update a row in Postgres (MVCC, see Module 04), the old version stays on the same page and a new version is appended. Both point to the same primary key index entry via a forwarding pointer called a **TID** (tuple ID = page number + slot number).

### The 8-KiB Arithmetic Problem

A row with 10 integer columns and a 200-byte text field costs roughly 8+8*10+200 = 288 bytes on Postgres (with 23-byte heap header overhead added per tuple). That means one page holds about 8192/288 ≈ 28 rows. A table with 10 million rows needs ~357,000 pages = ~2.8 GB just for the heap, before indexes.

Now you understand why `seq_scan_cost` in `pg_stat_user_tables` matters: a sequential scan reads every page in order (OS can prefetch), while an index scan on a non-clustered table does random I/O into those 357,000 pages. On NVMe the difference is 4–10x; on HDD it's 100x.

---

## B+tree: The Dominant OLTP Index Structure

The B+tree is not quite the same as the B-tree you learned in algorithms class. The key difference: **all values live in leaf nodes; internal nodes carry only keys used as routing guides.**

```
                        ┌─────────────┐
                        │  root node  │
                        │  [25 | 50]  │
                        └──┬───┬───┬──┘
                           │   │   │
              ┌────────────┘   │   └────────────┐
              ▼                ▼                 ▼
        ┌──────────┐     ┌──────────┐     ┌──────────┐
        │ internal │     │ internal │     │ internal │
        │ [10|15|20│     │ [30|40|45│     │ [55|60|75│
        └──┬─┬─┬─┬─┘     └──────────┘     └──────────┘
           │ │ │ │
    ┌──────┘ │ │ └──────┐
    ▼        ▼ ▼        ▼
 ┌──────┐ ┌──────┐   ┌──────┐
 │leaf  │⟷│leaf  │⟷ ─│leaf  │  ← leaves are a doubly-linked list
 │ rows │ │ rows │   │ rows │     enabling range scans
 └──────┘ └──────┘   └──────┘
```

The leaf nodes form a **doubly-linked list**, which is what makes range queries efficient: find the first matching leaf, then follow sibling pointers.

### Fanout and Tree Height

Fanout is the number of children per internal node. For a page of size 8 KiB with 8-byte keys and 8-byte child pointers:

```
fanout = floor(8192 / (8 + 8)) = floor(8192 / 16) = 512
```

With fanout 512:
- Height 1 (root only): 512 leaf pages → 512 × (8192 / row_size) rows
- Height 2: 512 × 512 leaves → 262,144 leaf pages
- Height 3: 512^3 = 134 million leaf pages

In practice, a B+tree for a 10-million-row table with an 8-byte integer primary key is **3 levels high**. Most reads touch 3 pages — and in a warm buffer pool (Module 02), internal nodes are almost always cached. *A point lookup on a properly indexed, warm OLTP table is effectively 1 page read.*

### Splits

When you insert a row and the target leaf is full, the leaf **splits**:

```
Before (leaf full, fanout = 4 for illustration):
┌─────────────────┐
│ leaf: [10,20,30,40] │
└─────────────────┘

Insert 25:
1. Leaf is full. Split at median (30).
2. Left leaf  → [10, 20, 25]
3. Right leaf → [30, 40]
4. Promote 30 to parent as separator key.

After:
        parent: [..., 30, ...]
               /            \
  [10, 20, 25]             [30, 40]
```

If the parent is also full, it splits too — splits can **cascade** up to the root. A root split increases tree height by one. Root splits are rare in steady-state but expensive: they require writing multiple dirty pages.

**Write amplification due to splits.** Each split dirtifies at least two leaf pages plus the parent. Because pages must be written to disk eventually, a write-heavy workload that repeatedly fills leaves generates far more page writes than the number of rows inserted. This is one reason B+tree engines (Postgres, MySQL/InnoDB) struggle with sustained append-heavy loads.

### Merges

When a row is deleted and a leaf falls below half-full, it can **merge** with a sibling. The separator key is pulled down from the parent. Merges are the inverse of splits. In practice, Postgres does not aggressively rebalance — it tolerates half-empty pages and reclaims them via `VACUUM`. InnoDB is similar.

---

## LSM-tree: Write-Optimized Structures

The **Log-Structured Merge-tree** (LSM-tree) inverts the trade. Instead of finding the right page and updating it in-place, *all* writes go to an in-memory buffer first. Reads pay the cost of consulting multiple levels. Compaction periodically merges levels to keep reads from spiraling.

### The Three Layers

```
┌────────────────────────────────────────────────────────────────────┐
│                        WRITE PATH                                  │
│                                                                    │
│  client write ──▶ WAL (sequential write to disk, crash safety)    │
│                 └──▶ MemTable (sorted in-memory buffer, ~64 MB)   │
│                          │                                         │
│                   (flush when full)                                │
│                          │                                         │
│                          ▼                                         │
│                ┌───────────────────┐                               │
│  disk          │  Level-0 SSTables │  (unsorted between files)    │
│                ├───────────────────┤                               │
│                │  Level-1 SSTables │  (~10 MB, key-sorted)        │
│                ├───────────────────┤                               │
│                │  Level-2 SSTables │  (~100 MB, key-sorted)       │
│                ├───────────────────┤                               │
│                │  Level-3 SSTables │  (~1 GB, key-sorted)         │
│                └───────────────────┘                               │
└────────────────────────────────────────────────────────────────────┘
```

**MemTable.** An in-memory sorted structure — typically a skip list or red-black tree. Every write (insert, update, delete) lands here first. A tombstone is used for deletions (a special "this key is dead" marker). The MemTable is also backed by a WAL so it survives crashes.

**SSTable (Sorted String Table).** When the MemTable is full it is flushed to disk as an immutable SSTable — a file of key-value pairs in sorted order, plus a Bloom filter (probabilistic skip for "definitely not here" key lookups) and an index block. Once written, SSTables are **never modified**. Updates produce new SSTables at higher levels.

**Compaction.** SSTables accumulate and must be merged to reclaim space from old versions and tombstones. There are two dominant strategies:

#### Leveled Compaction (RocksDB default, LevelDB)

```
L0:  [SST1] [SST2] [SST3] [SST4]           ← 4 files, unordered key ranges
L1:  [───────────L1 file────────────]       ← one sorted run, fixed size (e.g. 256 MB)
L2:  [────────────────L2 files──────────]  ← ten sorted runs, fixed ratio
```

When L0 reaches a threshold (typically 4 files), it is **merged** into L1: all L0 SSTables and any overlapping L1 SSTables are read, merged-sorted, and written back to L1 as new files. When L1 overflows (say, reaches 256 MB), the same process cascades into L2, and so on.

- **Space amplification:** at most ~1.1×. The compacted result replaces the inputs.
- **Write amplification:** high — a key written once can be rewritten ~L × fanout times (roughly 10–30× in a 7-level setup) as it moves from L0 to L7.
- **Read amplification:** low — a point lookup checks MemTable, then L0 files (Bloom filter per file), then one file per level. Bloom filters make the average-case read excellent.

#### Tiered / Size-Tiered Compaction (Cassandra default, ScyllaDB)

```
Tier 1:  [small SST] [small SST] [small SST] [small SST]
             │
         (when 4 collect)
             ▼
Tier 2:  [medium SST]   [medium SST]    ...
             │
         (when 4 collect)
             ▼
Tier 3:  [large SST]
```

Groups SSTables by size; when a tier accumulates N files of similar size, they are merged into one larger file at the next tier.

- **Write amplification:** lower than leveled (~10× vs ~30×). A key migrates fewer times.
- **Space amplification:** higher — at any given moment you have O(N) copies of recent writes spread across tiers, so live data can occupy 2–3× its logical size.
- **Read amplification:** worse — many SSTables may contain the key, and more Bloom-filter probes are needed.

---

## The Amplification Triangle

These three costs are in fundamental tension:

```
         Write Amplification
               /\
              /  \
             /    \
            /      \
           /  PICK  \
          /   TWO   \
         /__________\
Read Amp            Space Amp
```

| Engine / Policy     | Write Amp | Read Amp | Space Amp |
|---------------------|-----------|----------|-----------|
| B+tree (Postgres)   | Medium    | Very Low | Low       |
| LSM leveled (RocksDB)| High     | Low      | Very Low  |
| LSM tiered (Cassandra)| Low     | High     | High      |
| Heap file (no index)| Very Low  | Very High| Low       |

**Write amplification** (WA): bytes written to storage / bytes of user data. A WA of 30× means each 1 MB of user writes causes 30 MB of physical I/O — lethal on SSDs with limited write endurance.

**Read amplification** (RA): disk reads per logical read. A RA of 10 means a point lookup touches 10 files or pages.

**Space amplification** (SA): disk used / logical data size. SA of 3× means a 100 GB logical dataset uses 300 GB on disk.

---

## When Each Engine Wins

### Use B+tree (Postgres, MySQL/InnoDB, SQLite) when:

1. **Read-heavy OLTP** — point lookups and range scans with low latency requirements. The warm buffer pool nearly eliminates I/O for hot pages. A WA of ~3 is acceptable if writes are infrequent.
2. **Updates-in-place are common** — modifying a row in a customer record, updating a balance. B+tree finds the page and updates it; LSM always appends a new version.
3. **Secondary indexes matter** — B+tree secondary indexes are efficient. LSM secondary indexes are expensive because each update writes to every index.
4. **Strong consistency without tuning** — MVCC and B+tree together give serializable reads out of the box in Postgres.

### Use LSM-tree (RocksDB, Cassandra, LevelDB, TiKV) when:

1. **Write-heavy ingestion** — time-series, IoT metrics, audit logs, CDC pipelines writing millions of rows/second. Sequential writes to the MemTable and WAL saturate SSDs without the page-split overhead of B+tree.
2. **Wide column or sparse rows** — large key-value stores where rows have variable, sparse fields. SSTables compress well; B+trees waste space on sparse rows.
3. **Bulk compaction is tolerable** — if your workload has distinct write windows (e.g., ingest at night, read during business hours) compaction can be scheduled during the quiet window.
4. **Key-value semantics suffice** — RocksDB is a key-value store; complex SQL joins are not its native territory. Use it as a storage layer (TiKV, MyRocks, CockroachDB's Pebble) rather than directly from application code.

### The hybrid: MyRocks

Facebook's MyRocks replaces InnoDB's B+tree with a RocksDB LSM-tree while keeping the MySQL SQL layer. At Facebook, this reduced storage by 50% and improved write throughput for their UDB workload. You get the SQL interface with LSM internals — at the cost of needing a dedicated team to tune compaction.

---

## Worked Example: Tracking Write Amplification in Postgres

Run this on a fresh Postgres instance to see page splits in action:

```sql
-- Watch page count grow non-linearly under random inserts
CREATE TABLE wa_test (id BIGINT PRIMARY KEY, val TEXT);

-- A: Sequential inserts (low WA — splits happen at the end)
INSERT INTO wa_test SELECT g, repeat('x', 200) FROM generate_series(1, 100000) g;

-- B: Random inserts (high WA — splits happen throughout the tree)
TRUNCATE wa_test;
INSERT INTO wa_test
  SELECT (random() * 1000000)::BIGINT, repeat('x', 200)
  FROM generate_series(1, 100000);

-- Observe bloat: ratio > 1.0 means wasted space from splits
SELECT
  relname,
  pg_relation_size(oid) AS heap_bytes,
  relpages,
  n_live_tup,
  round(pg_relation_size(oid)::numeric / (n_live_tup * 228), 2) AS fill_ratio
FROM pg_class
JOIN pg_stat_user_tables USING (relname)
WHERE relname = 'wa_test';
```

After sequential inserts, `fill_ratio` will be near 1.0. After random inserts it will be lower — pages are partially filled because splits leave siblings half-empty. This is the *space amplification* side of B+tree under random write loads.

---

## Worked Example: Compaction Stall in RocksDB

RocksDB exposes internal metrics via its statistics and via `LOG` files. When compaction falls behind writes:

```
# In a RocksDB LOG file during a write stall:
[db/db_impl.cc:1024] Stall: 1 level0_slowdown_writes_trigger=20,
  level0_stop_writes_trigger=36, actual_level0_files=21
```

When L0 file count exceeds `level0_slowdown_writes_trigger`, RocksDB deliberately slows writes to let compaction catch up. When it hits `level0_stop_writes_trigger`, writes are *paused entirely*.

The knobs to tune:

```ini
# rocksdb options — raise compaction thread count and trigger
max_background_compactions = 8           # up from default 1
max_background_flushes = 4               # parallel MemTable flush threads
level0_slowdown_writes_trigger = 40      # more L0 files tolerated before slowdown
level0_stop_writes_trigger = 60          # higher ceiling before full stop
```

But higher trigger thresholds just delay the pain — the real fix is ensuring your compaction bandwidth (CPU + I/O) exceeds your write bandwidth before you hit steady state.

---

## Debugging Storage Engines

### Symptom: Unexplained write slowdown under sustained INSERT load (Postgres)

**Diagnosis path:**

1. Check for page splits in `pg_stat_bgwriter`:
   ```sql
   SELECT buffers_alloc, buffers_clean, maxwritten_clean, buffers_backend_fsync
   FROM pg_stat_bgwriter;
   ```
   High `buffers_backend_fsync` means application backends are doing their own fsync — the background writer cannot keep up, and the buffer pool is exhausted. This is a sign of write amplification causing excessive dirty pages.

2. Look at index fragmentation:
   ```sql
   -- pgstattuple extension
   SELECT avg_leaf_density, leaf_fragmentation
   FROM pgstatindex('my_table_pkey');
   ```
   `leaf_fragmentation` above 30% means pages are less than 70% full — splits have left lots of wasted space, and sequential reads now touch many more pages than necessary.

3. Workaround for write-heavy indexes: set `fillfactor` lower so leaves are pre-split:
   ```sql
   CREATE INDEX my_idx ON my_table (col) WITH (fillfactor = 70);
   ```
   Leaving 30% free means future updates can go in without immediate splits.

### Symptom: RocksDB read latency spikes on cold keys

**Cause:** High read amplification in tiered compaction. A cold key may exist in a tombstone at L0, a superseded value at L2, and the live value at L6 — three full SSTable reads plus Bloom-filter probes.

**Diagnosis:**
```
rocksdb.number.db.seek → high value means many iterators are being created
rocksdb.bloom.filter.useful → if this is low, Bloom filters are saturated
  (false-positive rate too high because bloom bits_per_key is too low)
```

**Fix:** Switch to leveled compaction for tables with frequent point reads; increase `bloom_locality` and `bits_per_key` (default 10, aim for 0.1% false-positive rate).

### Symptom: Compaction stalls causing p99 write latency spikes

This is the "compaction debt" problem. The write path is faster than compaction:

```
Steady state: write bandwidth 100 MB/s
Compaction throughput (single thread, all levels): 80 MB/s
→ L0 files accumulate, trigger hit, writes stall
```

**Diagnosis:** Check `db/compaction_picker_*` log lines, `rocksdb.estimate-pending-compaction-bytes` metric.

**Fix:** Increase `max_background_compactions`. On multi-core instances, RocksDB's default of 1 compaction thread is almost always the bottleneck. For a 16-core instance, 4–8 is a reasonable starting point.

---

## Checkpoint

You are ready to move on when you can, without looking anything up:

1. Draw a slotted-page layout from memory with the header, slot array, and tuple heap and explain what `VACUUM` reclaims.
2. Explain why B+tree internal nodes carry only keys, not values, and how this enables range scans via leaf sibling pointers.
3. Calculate the height of a B+tree for 10 million rows given an 8 KiB page and 8-byte keys.
4. Trace a write through an LSM-tree: WAL → MemTable → L0 SSTable → compaction.
5. State the three amplification metrics and rank B+tree leveled-LSM and tiered-LSM on each.
6. Explain in one sentence why random inserts into a B+tree cause more page splits than sequential inserts.
7. Name two situations where you would choose LSM over B+tree and two where you would choose B+tree.
8. Describe what a RocksDB write stall is and which two configuration triggers control it.

➡ Next: **Module 02 — Buffer Pool, WAL & Crash Recovery** — how the engine keeps all of this consistent when the power goes out.
