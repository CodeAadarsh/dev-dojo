#!/usr/bin/env bash
# Plants the "Consistent Hashing with Virtual Nodes" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="05-consistent-hashing"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — consistent hash ring with virtual nodes
#
# Implement ConsistentHashRing with:
#   add_node(node)    — place `vnodes` virtual nodes on the ring
#   remove_node(node) — remove all virtual nodes for this physical node
#   get_node(key)     — return the physical node responsible for `key`
#
# Hashing: use hashlib.md5; convert hex digest to int with int(h, 16).
# Virtual node label format: f"{node}#vn{i}" for i in range(self._vnodes).
# Ring traversal: clockwise from hash(key); wrap around at ring end.
# Empty ring: get_node should raise ValueError.
import hashlib
import bisect


def _md5int(s: str) -> int:
    """Hash a string to a 128-bit integer using MD5."""
    return int(hashlib.md5(s.encode()).hexdigest(), 16)


class ConsistentHashRing:
    def __init__(self, vnodes: int = 100) -> None:
        self._vnodes = vnodes
        # TODO: initialise internal state for the ring.
        # Hint: you need a sorted list of integer positions and a mapping
        # from each position back to the physical node name.
        raise NotImplementedError

    def add_node(self, node: str) -> None:
        # TODO: for i in range(self._vnodes), compute _md5int(f"{node}#vn{i}"),
        # record it in the mapping, and insert into the sorted list.
        raise NotImplementedError

    def remove_node(self, node: str) -> None:
        # TODO: remove all virtual nodes for `node` from the ring and mapping.
        raise NotImplementedError

    def get_node(self, key: str) -> str:
        # TODO: hash `key`, find the first ring position >= that hash
        # (wrapping around with modulo), and return the physical node.
        raise NotImplementedError
PYEOF

# ── tests/test_sample.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import ConsistentHashRing


def test_get_node_returns_added_node():
    ring = ConsistentHashRing(vnodes=50)
    ring.add_node('db0')
    ring.add_node('db1')
    result = ring.get_node('some_key')
    assert result in ('db0', 'db1'), f"unexpected node: {result}"


def test_same_key_same_node():
    ring = ConsistentHashRing(vnodes=100)
    for n in ['db0', 'db1', 'db2']:
        ring.add_node(n)
    node1 = ring.get_node('user:42')
    node2 = ring.get_node('user:42')
    assert node1 == node2, "same key must always map to same node"


def test_remove_node_keys_reroute():
    ring = ConsistentHashRing(vnodes=100)
    ring.add_node('db0')
    ring.add_node('db1')
    # After removing db0, every key must go to db1
    ring.remove_node('db0')
    for key in ['a', 'b', 'c', 'hello', '12345']:
        assert ring.get_node(key) == 'db1', f"key {key!r} did not reroute to db1"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement ConsistentHashRing in solution.py"
echo "                   so all tests pass (3 visible + hidden suite)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
