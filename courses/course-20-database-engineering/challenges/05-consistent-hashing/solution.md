# Solution — Consistent Hashing with Virtual Nodes

## Core Insight

The problem with modulo partitioning (`hash(key) % N`) is that changing N recomputes every key's destination. The insight of consistent hashing:

> Map both keys and nodes to positions on a ring (a number line that wraps at `2^128`). A key's owner is the first *node position* clockwise from the key's position. Adding or removing a node only affects keys that were clockwise-adjacent to that node's positions — roughly `1/N` of all keys.

Virtual nodes multiply each physical node's ring presence by a factor K. This smooths load: with one real position per node, the arc lengths between positions are highly variable (one node might own 40% of the ring). With K=200, variance drops to ~±1/√200 ≈ ±7%.

## Complete Implementation

```python
import hashlib
import bisect


def _md5int(s: str) -> int:
    return int(hashlib.md5(s.encode()).hexdigest(), 16)


class ConsistentHashRing:
    def __init__(self, vnodes: int = 100) -> None:
        self._vnodes = vnodes
        self._ring: list[int] = []        # sorted integer positions
        self._map: dict[int, str] = {}    # position -> physical node name

    def add_node(self, node: str) -> None:
        for i in range(self._vnodes):
            pos = _md5int(f"{node}#vn{i}")
            self._map[pos] = node
            self._ring.append(pos)
        self._ring.sort()

    def remove_node(self, node: str) -> None:
        positions_to_remove = set()
        for i in range(self._vnodes):
            pos = _md5int(f"{node}#vn{i}")
            positions_to_remove.add(pos)
            self._map.pop(pos, None)
        self._ring = [p for p in self._ring if p not in positions_to_remove]

    def get_node(self, key: str) -> str:
        if not self._ring:
            raise ValueError("ring is empty — add at least one node first")
        pos = _md5int(key)
        idx = bisect.bisect_right(self._ring, pos) % len(self._ring)
        return self._map[self._ring[idx]]
```

## Why Each Piece Is Correct

### `add_node` — O((N+K) log(N+K))

Each virtual node label `f"{node}#vn{i}"` hashes to a deterministic integer. We append all K positions then sort. The sort is the dominant cost; for K=200 and a ring that already has M positions, one `add_node` call costs O((M+K) log(M+K)).

An alternative is `bisect.insort` for each position — O(M) per insert (list shift), so O(K×M) total. For small rings (< 10,000 total vnodes) the difference is negligible. For large rings, sort-after-bulk-append is faster because modern sort (Timsort) is optimised for "sorted run + small suffix" patterns.

### `remove_node` — O(N)

Build a set of positions to remove (O(K) hash lookups). Then filter with a list comprehension — one pass through the ring, O(N) total, where N is the current ring size. Using `list.remove()` in a loop would be O(K×N) because each `remove()` scans the whole list.

### `get_node` — O(log N)

`bisect.bisect_right(ring, pos)` binary-searches the sorted ring and returns the index of the first position strictly greater than `pos`. If `pos` is greater than all ring positions, `bisect_right` returns `len(ring)` — the `% len(ring)` wraps this to 0, implementing the clockwise wrap-around.

### Why `bisect_right` and not `bisect_left`?

`bisect_left` returns the index of the first element `>= pos`. If `pos` exactly equals a ring position (key hashes to a vnode position), `bisect_left` returns that vnode's index — we'd be assigning the key to the node at that position. `bisect_right` returns the *next* position. Both are valid conventions; what matters is consistency. The verifier tests the label format `{node}#vn{i}` and the md5 hash — as long as you pick one convention and stick to it, either works.

## The Minimal-Movement Proof

Consider a ring with N physical nodes, K vnodes each (NK total ring positions). When you add a (N+1)th physical node:

1. Its K vnodes land at K new positions on the ring.
2. Each new position "steals" a segment from the node that previously owned the arc immediately after that position.
3. The new node now owns K out of (N+1)K = NK+K total positions.
4. In expectation, it owns `K / (NK+K)` = `1/(N+1)` of the ring → `1/(N+1)` of the keys remap.

For N=4, K=200: ~2000 of 10,000 keys remap. With modulo hashing: all 10,000 remap. That's the 100× improvement consistent hashing delivers.

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Using `sorted(ring)` per `get_node` call | O(N log N) per lookup — functional but slow; the minimal-movement test may time out | Sort once in `add_node`; keep `_ring` always sorted |
| Storing physical node as the ring position value directly (not via `_map`) | Fine for single-type rings, breaks when you need `remove_node` to know which positions to remove | Always maintain both `_ring` (sorted ints) and `_map` (int→node) |
| Using Python's built-in `hash()` instead of `hashlib.md5` | `hash()` is randomised by PYTHONHASHSEED — results differ across runs; verifier uses fixed key strings | Always use `hashlib.md5` for deterministic output |
| `bisect_right(ring, pos) % len(ring)` when ring is empty | `ZeroDivisionError` | Check `not self._ring` first and raise `ValueError` |
| Not using a set for positions to remove in `remove_node` | O(K×N) loop with `list.remove()` | Build a set, filter with list comprehension |

## Real-World Nuances

**Token ranges vs. positions.** Cassandra maps each physical node to one or more *token ranges* (start, end) rather than point positions, but the clockwise traversal is the same.

**Replication.** A key's owner is the first node; its N-1 replicas are the next N-1 unique physical nodes clockwise. `get_node` would become `get_nodes(key, n=3)` returning a list.

**Weighted vnodes.** A node with 2× the capacity gets 2K vnodes. Load is proportional to vnode count.

**Hash slot sharding (Redis Cluster).** Redis pre-allocates 16,384 slots (`hash(key) % 16384`), assigns contiguous ranges of slots to nodes, and rebalances by moving slot ownership. This is a discretised consistent hash — the "vnodes" are the 16,384 slots, and moving a node means transferring slot ownership, not rehashing.

## Apply and Verify

```bash
cd ~/.kube-dojo-work/05-consistent-hashing
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-20-database-engineering/challenges/05-consistent-hashing/verify.sh
```
