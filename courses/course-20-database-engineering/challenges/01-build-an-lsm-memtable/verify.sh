#!/usr/bin/env bash
# Verifier for "Build an LSM Memtable".
# Writes a hidden pytest suite against lsm.py and prints the flag only when
# all 9 tests pass.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-build-an-lsm-memtable"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{lsm_memtable_sstable_flush}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]         || fail "work directory missing — run setup.sh first"
[ -f "$WORK/lsm.py" ]  || fail "lsm.py not found — run setup.sh first"

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
import sys, os, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lsm import LSMTree, TOMBSTONE


def test_basic_put_get():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("k", "v")
        assert tree.get("k") == "v"


def test_missing_key_returns_none():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        assert tree.get("ghost") is None


def test_flush_and_get_from_sstable():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("persisted", "data")
        tree.flush()
        # memtable is now cleared; value must be read from SSTable
        assert tree.get("persisted") == "data"


def test_delete_in_memtable_hides_put():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("x", "alive")
        tree.delete("x")
        assert tree.get("x") is None


def test_tombstone_in_memtable_hides_sstable():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("y", "old")
        tree.flush()
        tree.delete("y")          # tombstone in memtable
        assert tree.get("y") is None   # must not bleed through from SSTable


def test_tombstone_flushed_hides_older_sstable():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("z", "v1")
        tree.flush()              # sstable-000000.json has z->v1
        tree.delete("z")
        tree.flush()              # sstable-000001.json has z->TOMBSTONE
        assert tree.get("z") is None


def test_newer_sstable_wins_over_older():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("e", "v1")
        tree.flush()              # sstable-000000
        tree.put("e", "v2")
        tree.flush()              # sstable-000001 (newer)
        assert tree.get("e") == "v2"


def test_memtable_beats_sstable():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("f", "stale")
        tree.flush()
        tree.put("f", "fresh")    # overwrite in memtable
        assert tree.get("f") == "fresh"


def test_multiple_keys_across_flushes():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("a", "1")
        tree.put("b", "2")
        tree.flush()
        tree.put("c", "3")        # only in memtable
        assert tree.get("a") == "1"
        assert tree.get("b") == "2"
        assert tree.get("c") == "3"


def test_overwrite_in_memtable_latest_wins():
    with tempfile.TemporaryDirectory() as d:
        tree = LSMTree(d)
        tree.put("seq", "first")
        tree.put("seq", "second")
        tree.put("seq", "third")
        assert tree.get("seq") == "third"
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
