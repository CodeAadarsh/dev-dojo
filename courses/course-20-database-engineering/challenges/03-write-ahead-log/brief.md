# Write-Ahead Log — Crash Recovery

The post-mortem entry: *"The telemetry pipeline crashed mid-batch during a deploy rollback. In-memory state was lost. We had 40 minutes of writes that just… disappeared. We need a WAL."*

A **write-ahead log** (WAL) is the durability primitive behind PostgreSQL, RocksDB, etcd, and Kafka. The rule is simple and absolute: **write to the log before applying to state.** If the process crashes between the log write and the state write, the log entry survives on disk and the operation can be re-applied on restart.

## The WAL contract

```
  ┌───────────────────────────────────────────────────────────────────────┐
  │  WRITE PATH (put / delete)                                            │
  │                                                                       │
  │  1. Append op to wal.log   ← MUST happen first (durability barrier)  │
  │  2. Apply op to _store     ← in-memory update                        │
  │                                                                       │
  │  CRASH between 1 and 2:  op is in log → will be re-applied on boot   │
  │  CRASH before 1:         op was never durably recorded → silent loss  │
  └───────────────────────────────────────────────────────────────────────┘

  ┌───────────────────────────────────────────────────────────────────────┐
  │  STARTUP (recovery)                                                   │
  │                                                                       │
  │  For each line in wal.log (oldest → newest):                         │
  │    {"op": "put",    "key": "x", "value": "v"}  → _store["x"] = "v"  │
  │    {"op": "delete", "key": "x"}                → del _store["x"]     │
  │                                                                       │
  │  Replaying a put on an already-recovered key is safe (idempotent).   │
  └───────────────────────────────────────────────────────────────────────┘
```

Each log entry is a **newline-delimited JSON record** (JSON Lines format). The append is atomic enough for crash recovery purposes on ext4/APFS because `write(2)` with a small payload (well under the 4 KB page boundary) is either fully written or not written — it does not leave partial records under normal conditions. For production systems, `fsync()` after each write provides a stronger guarantee; for this challenge a plain `f.write()` is sufficient.

## Context

`setup.sh` plants a starter project:

```
~/.kube-dojo-work/03-write-ahead-log/
├── kvstore.py        # KVStore skeleton — implement the TODOs
└── tests/
    └── test_sample.py  # visible sample tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-write-ahead-log
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement the WAL in `kvstore.py`:

### In `__init__`

Replay `wal.log` if it exists:

```python
if os.path.exists(self.wal_path):
    with open(self.wal_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if record["op"] == "put":
                self._store[record["key"]] = record["value"]
            elif record["op"] == "delete":
                self._store.pop(record["key"], None)
```

### In `put`

```python
def put(self, key: str, value: Any) -> None:
    # 1. append to WAL first
    with open(self.wal_path, "a") as f:
        f.write(json.dumps({"op": "put", "key": key, "value": value}) + "\n")
    # 2. then update in-memory store
    self._store[key] = value
```

### In `delete`

```python
def delete(self, key: str) -> None:
    with open(self.wal_path, "a") as f:
        f.write(json.dumps({"op": "delete", "key": key}) + "\n")
    self._store.pop(key, None)
```

### What the verifier checks

1. After `put`, `wal.log` exists and contains a record for the key.
2. A new `KVStore` instance pointed at the same `data_dir` recovers the written values (simulates a crash and restart).
3. A `delete` followed by a `flush` (new instance) returns `None` — the delete is persisted.
4. Multiple puts to the same key recover as the last write.
5. The WAL file grows monotonically (append-only — no truncation between writes).
6. Recovery of 10 keys across 10 ops — all correct after reconstructing from WAL.

## Verify

```bash
bash courses/course-20-database-engineering/challenges/03-write-ahead-log/verify.sh
```

All 6 hidden tests pass → flag printed.
