# Solution — Build an LSM Memtable

Complete `lsm.py` with all four methods implemented.

```python
import os
import json
from typing import Optional, Any

TOMBSTONE = "__TOMBSTONE__"


class SSTable:
    def __init__(self, path: str):
        self.path = path
        self._data: Optional[dict] = None

    def _load(self) -> None:
        if self._data is None:
            with open(self.path) as f:
                self._data = json.load(f)

    def get(self, key: str) -> Optional[Any]:
        self._load()
        return self._data.get(key)  # type: ignore[union-attr]

    def __contains__(self, key: str) -> bool:
        self._load()
        return key in self._data  # type: ignore[operator]


class LSMTree:
    def __init__(self, data_dir: str):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        self._memtable: dict = {}
        self._sstables: list = []
        self._flush_count: int = 0
        self._load_existing_sstables()

    def _load_existing_sstables(self) -> None:
        files = sorted(
            [f for f in os.listdir(self.data_dir)
             if f.startswith("sstable-") and f.endswith(".json")],
            reverse=True,
        )
        for fname in files:
            self._sstables.append(SSTable(os.path.join(self.data_dir, fname)))
            seq = int(fname[len("sstable-"):-len(".json")])
            self._flush_count = max(self._flush_count, seq + 1)

    def put(self, key: str, value: Any) -> None:
        self._memtable[key] = value

    def delete(self, key: str) -> None:
        self._memtable[key] = TOMBSTONE

    def get(self, key: str) -> Optional[Any]:
        if key in self._memtable:
            val = self._memtable[key]
            return None if val == TOMBSTONE else val
        for sst in self._sstables:
            if key in sst:
                val = sst.get(key)
                return None if val == TOMBSTONE else val
        return None

    def flush(self) -> str:
        path = os.path.join(self.data_dir, f"sstable-{self._flush_count:06d}.json")
        with open(path, "w") as f:
            json.dump(self._memtable, f)
        self._sstables.insert(0, SSTable(path))
        self._flush_count += 1
        self._memtable = {}
        return path
```

## Why each piece is required

**`put` and `delete` write to `_memtable` only.**
The memtable is the write buffer. All writes are O(1) dict assignments. No file I/O happens until `flush()`. This is the core latency benefit of LSM over B-trees: writes are always sequential and batched, never random in-place updates.

**`delete` stores `TOMBSTONE`, not a missing key.**
If `delete` simply did `del self._memtable[key]`, a subsequent `get` would fall through to an SSTable and return the old value. The tombstone sentinel is how an LSM tree communicates "this key was deleted" across all layers. The sentinel propagates through flushes into SSTables and shadows older values during lookup.

**`flush` uses `insert(0, ...)` to keep `_sstables` newest-first.**
The read path walks `_sstables[0], _sstables[1], ...` and stops at the first match. Prepending (index 0 = newest) ensures a key written in flush N+1 is found before the same key's value from flush N. `append` would invert the order and cause older values to win, which is wrong.

**`flush` uses zero-padded sequence numbers (`{seq:06d}`).**
`_load_existing_sstables` relies on lexicographic sort to reconstruct the newest-first order on restart. Without zero-padding, `sstable-10.json` would sort before `sstable-9.json` (because `"1" < "9"` lexicographically), corrupting the ordering.

**`get` checks memtable before SSTables.**
The memtable always contains the most recent state. An SSTable-first lookup would return stale data for any key written since the last flush.

**`SSTable` lazy-loads.**
The `_data` dict is `None` until the first access. For a real engine with hundreds of SSTables, loading them all at startup would be expensive and often unnecessary. This pattern also makes the `flush` → SSTable object creation cheap — the file is written, but reading it back is deferred until a `get` actually needs it.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-build-an-lsm-memtable
# replace lsm.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-20-database-engineering/challenges/01-build-an-lsm-memtable/verify.sh
```

## Going further

Real LSM engines add:
- **Compaction:** merge SSTables, drop obsolete tombstones, maintain a size limit. Without it, read latency grows as the SSTable list grows.
- **Bloom filters:** one per SSTable, checked before loading the file. Avoids disk I/O for keys that are definitely absent.
- **WAL (write-ahead log):** append each `put`/`delete` to a sequential log *before* writing to the memtable. On crash, replay the WAL to rebuild the memtable — which is exactly what Challenge 03 in this course asks you to implement.
- **Level organisation:** SSTables are tiered into levels (L0, L1, …). L0 SSTables can overlap; higher levels are sorted and non-overlapping for efficient point lookups.
