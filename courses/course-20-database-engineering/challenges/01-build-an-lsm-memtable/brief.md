# Build an LSM Memtable

The ticket reads: *"RocksDB is overkill for the telemetry sidecar — write a tiny log-structured store so the team understands the invariants before we configure compaction."*

You are implementing the write path and point-lookup of an LSM (Log-Structured Merge-Tree) storage engine from scratch. LSM trees power RocksDB, Cassandra, LevelDB, and ClickHouse's MergeTree. Understanding how their write path works — and why they are faster for write-heavy workloads than B-trees — is a prerequisite for tuning any of them in production.

## How an LSM write path works

```
   ┌──────────────────────────────────────────────────┐
   │  WRITE PATH                                      │
   │                                                  │
   │  put("x", "v")  ──→  memtable  (in-memory dict) │
   │  delete("x")    ──→  memtable  (tombstone entry) │
   │  flush()        ──→  sstable-000001.json  (disk) │
   │  flush()        ──→  sstable-000002.json  (disk) │
   │  flush()        ──→  sstable-000003.json  (disk) │
   └──────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────┐
   │  READ PATH (get)                                 │
   │                                                  │
   │  1. check memtable   (always freshest)           │
   │  2. sstable-000003   (newest flush)              │
   │  3. sstable-000002                               │
   │  4. sstable-000001   (oldest flush)              │
   │  → first match wins; TOMBSTONE ⟹ return None    │
   └──────────────────────────────────────────────────┘
```

Key insight: an LSM **never updates in place**. A `delete` writes a *tombstone* (a sentinel value like `"__TOMBSTONE__"`) into the memtable. On lookup, seeing that sentinel is the signal to return `None` even if an older SSTable still has the key.

This is why LSM trees are faster than B-trees for writes: every write is a sequential append to an in-memory structure, then occasionally a sequential file write on flush. No random I/O until compaction — which happens asynchronously and is outside the scope of this challenge.

## Context

`setup.sh` plants a starter project:

```
~/.kube-dojo-work/01-build-an-lsm-memtable/
├── lsm.py            # LSMTree + SSTable skeleton — implement the TODOs
└── tests/
    └── test_sample.py  # visible sample tests (3 cases)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-build-an-lsm-memtable
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement the four stubbed methods in `lsm.py`:

| Method | What it must do |
|--------|-----------------|
| `LSMTree.put(key, value)` | Write `key → value` into `self._memtable` |
| `LSMTree.delete(key)` | Write `key → TOMBSTONE` into `self._memtable` |
| `LSMTree.flush()` | Serialise `self._memtable` to a new JSON file in `self.data_dir`, prepend the new `SSTable` object to `self._sstables` (newest-first), clear `self._memtable`, return the file path |
| `LSMTree.get(key)` | Search memtable first; if not found, walk `self._sstables` newest→oldest; if the found value equals `TOMBSTONE`, return `None`; if not found anywhere, return `None` |

The constants `TOMBSTONE` and the `SSTable` helper class (which lazy-loads a JSON file) are already wired up for you. The `SSTable.__contains__` method lets you write `if key in sst:` cleanly.

### Flush naming contract

Each flush must produce a file named `sstable-{seq:06d}.json` where `seq` increments from 0. This keeps files sortable lexicographically newest-first on `sorted(..., reverse=True)` — which is what `_load_existing_sstables` relies on if you add persistence across restarts.

### The verifier checks

1. Basic `put` / `get`
2. `put` then `flush`, then `get` (value must survive in the SSTable)
3. `delete` in memtable shadows a prior `put` — returns `None`
4. `delete` after flush: tombstone in memtable hides value in SSTable
5. Tombstone flushed to newer SSTable hides value in older SSTable
6. Newer SSTable wins over older SSTable for the same key
7. Memtable value takes precedence over any SSTable value
8. Multiple keys across multiple flushes all recoverable
9. Overwrite in memtable: latest `put` for a key wins

## Verify

```bash
bash courses/course-20-database-engineering/challenges/01-build-an-lsm-memtable/verify.sh
```

All 9 hidden tests pass → flag printed.
