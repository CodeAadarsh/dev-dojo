#!/usr/bin/env bash
# Plants the "Write-Ahead Log" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="03-write-ahead-log"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── kvstore.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/kvstore.py" << 'PYEOF'
# kvstore.py — key-value store skeleton
#
# Add a WAL (write-ahead log) so that every put/delete is durable.
#
# Rules:
#   - Each op must be appended to wal.log BEFORE being applied to _store.
#   - On __init__, replay wal.log (oldest to newest) to recover _store.
#   - Log format: one JSON record per line (JSON Lines).
#     put:    {"op": "put",    "key": <str>, "value": <any>}
#     delete: {"op": "delete", "key": <str>}
#
# get() is already implemented — do not change it.
import os
import json
from typing import Optional, Any


class KVStore:
    def __init__(self, data_dir: str):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        self.wal_path = os.path.join(data_dir, "wal.log")
        self._store: dict = {}
        # TODO: if wal.log exists, replay it line-by-line to recover _store.
        # Each line is a JSON record: {"op": "put"|"delete", "key": ..., "value": ...}
        # Apply put -> self._store[key] = value
        # Apply delete -> self._store.pop(key, None)

    def put(self, key: str, value: Any) -> None:
        # TODO:
        #   1. Open wal.log in append mode ("a").
        #   2. Write json.dumps({"op": "put", "key": key, "value": value}) + "\n".
        #   3. Then update self._store[key] = value.
        self._store[key] = value  # currently no WAL — data lost on crash

    def delete(self, key: str) -> None:
        # TODO:
        #   1. Open wal.log in append mode ("a").
        #   2. Write json.dumps({"op": "delete", "key": key}) + "\n".
        #   3. Then self._store.pop(key, None).
        self._store.pop(key, None)  # currently no WAL — data lost on crash

    def get(self, key: str) -> Optional[Any]:
        return self._store.get(key)
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from kvstore import KVStore


def test_basic_put_get():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("msg", "hello")
        assert store.get("msg") == "hello"


def test_wal_file_created():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("x", "1")
        assert os.path.exists(os.path.join(d, "wal.log")), \
            "wal.log must exist after the first put()"


def test_recovery_after_crash():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("survived", "yes")
        # simulate crash: create a new instance from the same dir (no in-memory state)
        recovered = KVStore(d)
        assert recovered.get("survived") == "yes", \
            "KVStore must replay wal.log on __init__ to recover written values"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : add WAL logic to put(), delete(), and __init__() in kvstore.py"
echo "                   so all tests pass (3 visible + 6 hidden)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
