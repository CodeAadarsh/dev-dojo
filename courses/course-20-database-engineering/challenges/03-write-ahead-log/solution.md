# Solution — Write-Ahead Log — Crash Recovery

The complete `kvstore.py` with all three methods implementing the WAL.

```python
import os
import json
from typing import Optional, Any


class KVStore:
    def __init__(self, data_dir: str):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        self.wal_path = os.path.join(data_dir, "wal.log")
        self._store: dict = {}
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

    def put(self, key: str, value: Any) -> None:
        with open(self.wal_path, "a") as f:
            f.write(json.dumps({"op": "put", "key": key, "value": value}) + "\n")
        self._store[key] = value

    def delete(self, key: str) -> None:
        with open(self.wal_path, "a") as f:
            f.write(json.dumps({"op": "delete", "key": key}) + "\n")
        self._store.pop(key, None)

    def get(self, key: str) -> Optional[Any]:
        return self._store.get(key)
```

## Why each piece is correct

**Log before applying (`put` and `delete`).**
Open in append mode `"a"`, write the JSON record, then update `_store`. This ordering is the WAL contract. If the process crashes after the file write but before `self._store[key] = value`, the record is in the log and will be re-applied next time `__init__` runs. If the process crashes before the file write, the operation was never durably recorded — this is acceptable because the caller has not yet received a success response.

**JSON Lines format.**
One record per line, parseable independently. If the log is partially written (very rare, but possible under heavy I/O), the `json.loads` call on a truncated line will raise `json.JSONDecodeError`. Production implementations add a length prefix or CRC to detect and skip partial records. For this challenge, normal file write semantics on a modern OS make partial records effectively impossible for small payloads.

**Replay in `__init__` is idempotent.**
Applying the same `put` twice to `_store` is a harmless dict assignment — the second application produces the same result. Applying a `delete` on a key that has already been removed (`pop(key, None)`) is also safe. This means replaying from a checkpoint and then replaying the rest of the log (as PostgreSQL does with its checkpoint + WAL tail recovery) is correct by construction.

**`_store.pop(key, None)` for delete.**
The `None` default prevents a `KeyError` if the key was already absent. This matters during recovery: a `delete` logged for a key that was itself created and then compacted out would otherwise crash the replay.

**Append mode `"a"` opens and closes the file per operation.**
A long-lived file handle in append mode would also work, but opening/closing per write is simpler, avoids stale state if the object is pickled or copied, and still produces correct sequential log entries because the OS appends atomically at the file offset.

## Relation to real engines

- **PostgreSQL WAL:** every DML writes a WAL record to a circular buffer flushed to `pg_wal/` before the transaction commits. On crash recovery, the startup process replays WAL from the last checkpoint. `fsync()` on the WAL segment before acknowledging commit is what makes Postgres's durability guarantee hold.
- **RocksDB:** the memtable WAL is written to a per-column-family log file in the same directory as the SSTable files. A `Put` appends to the log, then updates the `SkipList` memtable. On restart, the log is replayed to rebuild any unflushed memtable state. (See Challenge 01 in this course — the LSM memtable you built there is exactly what the WAL is protecting.)
- **etcd:** uses a WAL backed by the `go.etcd.io/etcd/pkg/v3/wal` package. Every Raft log entry is appended to the WAL before being applied to the state machine. Snapshots truncate the WAL tail periodically.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-write-ahead-log
# replace kvstore.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-20-database-engineering/challenges/03-write-ahead-log/verify.sh
```
