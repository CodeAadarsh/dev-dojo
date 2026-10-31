#!/usr/bin/env bash
# Verifier for "Consistent Hashing with Virtual Nodes".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="05-consistent-hashing"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{consistent_hashing_virtual_nodes}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ]  || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import ConsistentHashRing
import pytest


NODES_4 = ['db0', 'db1', 'db2', 'db3']
KEYS_10K = [f'key:{i}' for i in range(10000)]


def _build_ring(nodes, vnodes=200):
    ring = ConsistentHashRing(vnodes=vnodes)
    for n in nodes:
        ring.add_node(n)
    return ring


def test_get_node_returns_known_node():
    ring = _build_ring(NODES_4)
    for key in KEYS_10K[:100]:
        node = ring.get_node(key)
        assert node in NODES_4, f"key {key!r} mapped to unknown node {node!r}"


def test_determinism():
    ring = _build_ring(NODES_4)
    mapping = {k: ring.get_node(k) for k in KEYS_10K}
    # Re-query every key — must be stable
    for k, expected in mapping.items():
        got = ring.get_node(k)
        assert got == expected, f"non-deterministic: key {k!r} changed from {expected!r} to {got!r}"


def test_all_keys_assigned_after_add():
    ring = _build_ring(NODES_4)
    ring.add_node('db4')
    nodes_now = set(NODES_4) | {'db4'}
    for key in KEYS_10K[:200]:
        node = ring.get_node(key)
        assert node in nodes_now, f"key {key!r} mapped to unknown node after add: {node!r}"


def test_minimal_movement_on_add():
    ring = _build_ring(NODES_4)
    before = {k: ring.get_node(k) for k in KEYS_10K}
    ring.add_node('db4')
    remapped = sum(1 for k in KEYS_10K if ring.get_node(k) != before[k])
    # Optimal: 10000/5 = 2000 keys remap. Allow up to 2× optimal = 4000.
    assert remapped >= 200, (
        f"only {remapped} keys remapped on add — ring may not be distributing: "
        "check that all virtual nodes are placed correctly"
    )
    assert remapped <= 4000, (
        f"{remapped} keys remapped on add — expected at most ~4000 (2× optimal). "
        "Check that your implementation does NOT rehash all keys on every change."
    )


def test_minimal_movement_on_remove():
    ring = _build_ring(NODES_4)
    before = {k: ring.get_node(k) for k in KEYS_10K}
    ring.remove_node('db0')
    remapped = sum(1 for k in KEYS_10K if ring.get_node(k) != before[k])
    # Optimal: 10000/4 = 2500 keys remap. Allow up to 2× optimal = 5000.
    assert remapped >= 500, (
        f"only {remapped} keys remapped on remove — ring may be broken"
    )
    assert remapped <= 5000, (
        f"{remapped} keys remapped on remove — expected at most ~5000 (2× optimal)."
    )


def test_removed_node_never_returned():
    ring = _build_ring(NODES_4)
    ring.remove_node('db0')
    survivors = {'db1', 'db2', 'db3'}
    for key in KEYS_10K:
        node = ring.get_node(key)
        assert node in survivors, (
            f"key {key!r} mapped to removed node 'db0' after remove_node"
        )


def test_add_then_remove_stability():
    # After add + remove of the same node, the mapping must revert to original.
    ring = _build_ring(NODES_4)
    before = {k: ring.get_node(k) for k in KEYS_10K[:500]}
    ring.add_node('db4')
    ring.remove_node('db4')
    after = {k: ring.get_node(k) for k in KEYS_10K[:500]}
    assert before == after, "mapping did not revert after add+remove of the same node"


def test_empty_ring_raises():
    ring = ConsistentHashRing(vnodes=10)
    with pytest.raises((ValueError, IndexError, KeyError)):
        ring.get_node('any_key')


def test_single_node_all_keys():
    ring = ConsistentHashRing(vnodes=100)
    ring.add_node('solo')
    for key in ['a', 'b', 'z', 'user:999', 'key:0']:
        assert ring.get_node(key) == 'solo', f"single-node ring: {key!r} did not map to 'solo'"


def test_different_vnodes_counts():
    # vnodes=1 is degenerate but must not crash or return wrong nodes
    ring = ConsistentHashRing(vnodes=1)
    ring.add_node('n0')
    ring.add_node('n1')
    nodes = {'n0', 'n1'}
    for key in ['alpha', 'beta', 'gamma']:
        assert ring.get_node(key) in nodes
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
