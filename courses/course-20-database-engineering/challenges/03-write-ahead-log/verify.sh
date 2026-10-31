#!/usr/bin/env bash
# Verifier for "Write-Ahead Log — Crash Recovery".
# Writes a hidden pytest suite against kvstore.py and prints the flag only
# when all 6 tests pass.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="03-write-ahead-log"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{wal_crash_recovery_redo}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/kvstore.py" ]   || fail "kvstore.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os, tempfile, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from kvstore import KVStore


def test_wal_written_before_applying():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("alpha", "1")
        wal = os.path.join(d, "wal.log")
        assert os.path.exists(wal), "wal.log must exist after put()"
        with open(wal) as f:
            lines = [l.strip() for l in f if l.strip()]
        assert len(lines) >= 1, "WAL must have at least one entry after put()"
        record = json.loads(lines[0])
        assert record.get("op") == "put", f"first record op must be 'put', got {record}"
        assert record.get("key") == "alpha"
        assert record.get("value") == "1"


def test_recovery_put():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("x", "hello")
        store.put("y", "world")
        recovered = KVStore(d)   # new instance — simulates crash + restart
        assert recovered.get("x") == "hello", "x must survive crash recovery"
        assert recovered.get("y") == "world", "y must survive crash recovery"


def test_recovery_with_delete():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("a", "present")
        store.put("b", "also here")
        store.delete("a")
        recovered = KVStore(d)
        assert recovered.get("a") is None, "deleted key must be absent after recovery"
        assert recovered.get("b") == "also here", "non-deleted key must survive"


def test_recovery_last_write_wins():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("k", "v1")
        store.put("k", "v2")
        store.put("k", "v3")
        recovered = KVStore(d)
        assert recovered.get("k") == "v3", "last put must win after WAL replay"


def test_wal_append_only_grows():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        store.put("p", "1")
        size1 = os.path.getsize(os.path.join(d, "wal.log"))
        store.put("q", "2")
        size2 = os.path.getsize(os.path.join(d, "wal.log"))
        assert size2 > size1, "WAL must grow with each write (append-only)"


def test_recovery_ten_keys():
    with tempfile.TemporaryDirectory() as d:
        store = KVStore(d)
        for i in range(10):
            store.put(f"key{i}", f"val{i}")
        store.delete("key3")
        store.delete("key7")
        recovered = KVStore(d)
        for i in range(10):
            expected = None if i in (3, 7) else f"val{i}"
            result = recovered.get(f"key{i}")
            assert result == expected, (
                f"key{i}: expected {expected!r}, got {result!r} after recovery"
            )
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix kvstore.py and retry"
fi
