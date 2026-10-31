# Consistent Hashing with Virtual Nodes

A post-mortem from the storage team reads:

> *"We added a fourth shard to the cluster. The naive modulo-hash router (`key_hash % num_shards`) caused 75% of keys to remap to different shards — triggering a cache stampede that took the service down for 22 minutes while data warmed. We need a partitioning scheme where adding one node moves only ~1/N of keys, not everything."*

Your job: implement `ConsistentHashRing` in `solution.py` so the verifier's hidden pytest suite passes — including the minimal-movement property.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/05-consistent-hashing/
├── solution.py          # class stub; implement it
└── tests/
    └── test_sample.py   # three visible sample tests you can run
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-consistent-hashing
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement:

```python
class ConsistentHashRing:
    def __init__(self, vnodes: int = 100) -> None: ...
    def add_node(self, node: str) -> None: ...
    def remove_node(self, node: str) -> None: ...
    def get_node(self, key: str) -> str: ...
```

**Contract:**

- `add_node(node)` registers a physical node. Internally, create `vnodes` virtual nodes — one per value in `{node}#vn{0}`, `{node}#vn{1}`, …, `{node}#vn{vnodes-1}` — and place them on the ring by hashing each label.
- `remove_node(node)` deregisters a node and all its virtual nodes.
- `get_node(key)` returns the name of the physical node responsible for `key`. Walk clockwise from `hash(key)` until you hit a virtual node; return its owning physical node. Wrap around if `hash(key)` exceeds all ring positions.
- Use `hashlib.md5` for all hashing, converting hex digest to an integer with `int(h, 16)`.
- `get_node` on an empty ring should raise `ValueError`.

**Minimal-movement guarantee (what the hidden suite asserts):**

With 4 nodes already in the ring (`vnodes=200`) and 10,000 test keys, adding a 5th node should remap at most 40% of keys (optimal is 20% = 1/5). Removing one node should remap at most 40% (optimal is 25% = 1/4). An implementation that rehashes all keys on every change will fail this check.

**Determinism is critical:** the hidden suite uses fixed key strings and a fixed vnode label format (`{node}#vn{i}`). Do not add any randomness.

## Why This Matters

Consistent hashing is the partitioning primitive behind:

- **Cassandra / DynamoDB** — the token ring. Each physical node owns a contiguous arc of the MD5/Murmur hash space.
- **Redis Cluster** — 16,384 hash slots, each assigned to a node; resharding moves a bounded number of slots.
- **CDN routing** — consistent hashing assigns origin servers to edge caches; when a PoP goes offline, only its slice of traffic rereroutes.
- **Memcached client-side sharding** — the classic use case from the 2007 DeWitt & Gray paper that popularised the algorithm.

The `vnodes` parameter solves the *load imbalance* problem of the basic ring: with one virtual node per physical node, the arcs between consecutive positions vary wildly (up to O(log N) variance). With K virtual nodes each, the variance in arc length is O(1/√K) — load is near-uniform for K ≥ 100.

## The Ring Mechanics (ASCII Diagram)

```
             0
             │
    db3#vn2  │
   ┌──────┐  │
db2#vn0   │  │
   │      │  ▼
   │   ───────────────── ring (positions 0..2^128)
   │      │
   │   db0#vn1   db1#vn0
   │    ↑           ↑
   │    │           │
   └────┘           │
  db3#vn0         db0#vn2
                    │
                  db1#vn2
```

`get_node("user:1234")`:
1. Compute `pos = int(md5("user:1234").hexdigest(), 16)`
2. Find the first vnode position in the sorted ring that is ≥ pos (wrap if none)
3. Return the physical node owning that vnode

When `db2` is removed: only keys whose clockwise-next vnode was one of `db2`'s vnodes remap — to the *next* node in the ring. All other keys stay put.

## Verify

```bash
bash courses/course-20-database-engineering/challenges/05-consistent-hashing/verify.sh
```

All tests green → flag printed.
