#!/usr/bin/env bash
# Plants the "Build an LSM Memtable" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="01-build-an-lsm-memtable"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── lsm.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/lsm.py" << 'PYEOF'
# lsm.py — tiny LSM memtable + SSTable skeleton
#
# Implement the four TODOs below so that the pytest harness passes.
# Rules:
#   - put(key, value)  -> writes to memtable
#   - delete(key)      -> writes TOMBSTONE to memtable
#   - flush()          -> serialises memtable to sstable-{seq:06d}.json,
#                         prepends new SSTable to self._sstables (newest-first),
#                         clears memtable, returns path
#   - get(key)         -> memtable first; then _sstables newest->oldest;
#                         TOMBSTONE found => return None; not found => return None
import os
import json
from typing import Optional, Any

TOMBSTONE = "__TOMBSTONE__"


class SSTable:
    """An immutable, lazily-loaded JSON file of key-value pairs."""

    def __init__(self, path: str):
        self.path = path
        self._data: Optional[dict] = None

    def _load(self) -> None:
        if self._data is None:
            with open(self.path) as f:
                self._data = json.load(f)

    def get(self, key: str) -> Optional[Any]:
        """Return the raw value for key, or None if key is absent from this SSTable."""
        self._load()
        return self._data.get(key)  # type: ignore[union-attr]

    def __contains__(self, key: str) -> bool:
        self._load()
        return key in self._data  # type: ignore[operator]


class LSMTree:
    """Minimal LSM tree: one memtable + a list of SSTables, newest-first."""

    def __init__(self, data_dir: str):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        self._memtable: dict = {}       # key -> value | TOMBSTONE
        self._sstables: list = []       # [SSTable, ...] newest-first
        self._flush_count: int = 0
        # Loads any *.json SSTable files already in data_dir (for persistence).
        self._load_existing_sstables()

    def _load_existing_sstables(self) -> None:
        """Discover existing SSTable files and register them newest-first."""
        files = sorted(
            [f for f in os.listdir(self.data_dir)
             if f.startswith("sstable-") and f.endswith(".json")],
            reverse=True,   # lexicographic desc = newest first (zero-padded seq)
        )
        for fname in files:
            self._sstables.append(SSTable(os.path.join(self.data_dir, fname)))
            seq = int(fname[len("sstable-"):-len(".json")])
            self._flush_count = max(self._flush_count, seq + 1)

    def put(self, key: str, value: Any) -> None:
        # TODO: insert key -> value into the memtable.
        raise NotImplementedError

    def delete(self, key: str) -> None:
        # TODO: insert a tombstone for this key into the memtable.
        # Use the TOMBSTONE sentinel so get() knows the key was deleted.
        raise NotImplementedError

    def get(self, key: str) -> Optional[Any]:
        # TODO:
        #   1. Check self._memtable first (always freshest).
        #      If present and value == TOMBSTONE -> return None.
        #      If present and value != TOMBSTONE -> return value.
        #   2. Walk self._sstables newest-first.
        #      For each SSTable, check if key is present (`if key in sst:`).
        #      If found and value == TOMBSTONE -> return None.
        #      If found and value != TOMBSTONE -> return value.
        #   3. Key not found anywhere -> return None.
        raise NotImplementedError

    def flush(self) -> str:
        # TODO:
        #   1. Build path: os.path.join(self.data_dir, f"sstable-{self._flush_count:06d}.json")
        #   2. Write self._memtable to that path as JSON.
        #   3. Prepend a new SSTable(path) to self._sstables  (insert at index 0).
        #   4. Increment self._flush_count.
        #   5. Reset self._memtable to an empty dict.
        #   6. Return path.
        raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lsm import LSMTree, TOMBSTONE


def test_basic_put_get():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("hello", "world")
        assert tree.get("hello") == "world"


def test_missing_key_returns_none():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        assert tree.get("no_such_key") is None


def test_flush_and_recover_from_sstable():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("persisted", "value")
        tree.flush()
        # memtable is now empty; value must come from SSTable
        assert tree.get("persisted") == "value"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement put(), delete(), get(), flush() in lsm.py"
echo "                   so all tests pass (3 visible + 9 hidden)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
