# Replication, Sentinel & Cluster

> **Module 05 · Course 19** — A single Redis node is a single point of failure with a memory ceiling of one machine. This module covers everything that happens once you add more nodes: async replication, Sentinel-managed failover, and the horizontally scaled Cluster mode. The goal is not to recite flags — it is to understand the failure modes well enough that you can debug them under pressure.

You already know how a single Redis instance works. What you're about to learn is how Redis coordinates *across* multiple nodes — and where that coordination breaks.

---

## 1. Async Replication — The Foundation

Redis replication is **asynchronous and single-direction**. The primary node streams writes to one or more replicas; replicas confirm receipt with a periodic ACK, but the primary does **not** wait for that ACK before responding to the client. This is the key trade-off: low-latency writes in exchange for potential data loss on primary failure.

```
  CLIENT
    │
    │  SET foo bar  (write)
    ▼
  PRIMARY ──────────────────────────────────────────────────────────────────┐
    │   (returns OK immediately, does not wait for replica ACK)             │
    │                                                                        │
    │  replication stream (TCP, persistent connection)                      │
    ▼                                                                        │
  REPLICA-1  REPLICA-2  …                                                   │
    │                                                                        │
    │  sends back: REPLCONF ACK <offset>  (every second by default)        │
    └────────────────────────────────────────────────────────────────────────┘
```

The primary tracks each replica's **replication offset** — a monotonically increasing byte count of the replication stream. When you run `INFO replication` on the primary you see:

```
role:master
connected_slaves:2
slave0:ip=127.0.0.1,port=6380,state=online,offset=123456,lag=0
slave1:ip=127.0.0.1,port=6381,state=online,offset=123420,lag=1
master_repl_offset:123456
```

`lag` is in seconds. `offset` shows how far behind each replica is in bytes. `master_repl_offset - slave_offset` gives replication lag in bytes — the "unreplicated window" that would be lost if the primary crashed right now.

---

### 1.1 PSYNC — Partial vs Full Resync

When a replica reconnects after a network blip, it doesn't want to rebuild its entire dataset from scratch. It sends:

```
PSYNC <replication-id> <offset>
```

The primary checks its **replication backlog** (a circular buffer, `repl-backlog-size` bytes, default 1 MB). If the replica's `offset` falls within the backlog, the primary replies `+CONTINUE` and streams only the missing bytes — a **partial resync**. If the replica's offset has fallen off the backlog (it was gone too long), the primary replies `+FULLRESYNC` and sends a full RDB snapshot.

```
Primary backlog (circular, fixed size):
  [oldest data ········· most recent data]
                         ▲ master_repl_offset

  Case A: replica fell here → partial resync possible (cheap)
                     ▲
  Case B: replica fell here → before the oldest entry → FULLRESYNC (expensive)
         ▲
```

> **Tuning `repl-backlog-size`.** If your replicas frequently reconnect and you keep seeing full resyncs in the logs, the backlog is too small. A replica that triggers a FULLRESYNC copies the entire dataset from primary — under load that's a significant CPU + network spike. The right size is roughly: `replication rate (bytes/s) × expected longest reconnect window (seconds)`. At SAP I've seen a flapping network card cause cascading FULLRESYNC storms on a 40 GB primary — every reconnect generates a new bgsave, and overlapping bgsave processes compete for memory.

There is a subtlety with **replication IDs**. A primary has a `master_replid` (40-char hex). When a replica is promoted, it generates a new replication ID. Redis 4+ also keeps the old ID in `master_replid2` so replicas that were synced to the old primary can still do partial resync against the new primary if their offset falls within the kept backlog.

---

### 1.2 Read Replicas in Practice

Replicas serve read traffic: `GET`, `SCAN`, `LRANGE`, etc. Write commands (SET, HSET, DEL, …) are rejected with `READONLY You can't write against a read only replica`. This is enforced by default; to temporarily lift it: `CONFIG SET replica-read-only no` — useful only for maintenance scripts, never in production.

```bash
# point a client explicitly at a replica
redis-cli -p 6380 GET mykey

# verify it is a replica:
redis-cli -p 6380 INFO replication | grep role
# -> role:slave
```

The important semantic: **reads from a replica may be stale**. You should only route reads there if your application can tolerate that staleness. Session tokens, inventory counts, distributed locks — never read from replicas. Static config values, precomputed leaderboard pages, content metadata — probably fine.

---

## 2. Sentinel — High Availability Without Cluster

Sentinel is the answer to: "what monitors the primary, and who runs the failover when it goes down?" The answer cannot be the application itself — that's circular. Sentinel is a separate process (or set of processes) that:

1. **Monitors** primaries and replicas with periodic PINGs.
2. **Notifies** via pub/sub when topology changes.
3. **Elects** a leader among Sentinels (Raft-adjacent) and **fails over** to a new primary.
4. Acts as a **service discovery** layer: clients ask Sentinel "who is the current primary for group X?" instead of hardcoding an IP.

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │                         Sentinel Quorum                             │
   │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
   │   │  sentinel-1  │  │  sentinel-2  │  │  sentinel-3  │             │
   │   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
   │          │    watch, vote   │    watch, vote   │                     │
   └──────────┼──────────────────┼──────────────────┼─────────────────────┘
              │                  │                  │
              └──────────────────┼──────────────────┘
                                 │ PING / INFO loop (every 1s by default)
              ┌──────────────────▼──────────────────────────────────────┐
              │                  PRIMARY (:6379)                         │
              └────────────────────────────────────────────────────────┬┘
                                                                        │ replication
                               REPLICA-1 (:6380) ◄──────────────────────┘
                               REPLICA-2 (:6381) ◄──────────────────────┘
```

### 2.1 Subjective Down vs Objective Down

A Sentinel marks a primary **SDOWN** (Subjectively Down) if it does not respond to PING within `down-after-milliseconds`. But one Sentinel's opinion is not enough to trigger failover — a slow network could cause a false positive (this is the split-brain scenario).

**ODOWN** (Objectively Down) requires a **quorum** of Sentinels to independently declare the primary SDOWN. The quorum is configured per-group:

```
sentinel monitor mymaster 127.0.0.1 6379 2
# ^ group name    ^ primary IP       ^ quorum (2 out of 3 sentinels must agree)
```

Only after ODOWN does a Sentinel start a leader election (using a separate majority vote, always `floor(N/2) + 1`). This means with 3 Sentinels: quorum for ODOWN can be 2, but leader election always requires 2-of-3. With 2 Sentinels, leader election requires 2-of-2 — a single failure kills your failover capability, which is why Sentinel docs require an odd number ≥ 3.

### 2.2 Failover Sequence (Step by Step)

1. Sentinel leader selects the best replica. Priority: `replica-priority` (lower = preferred), then lowest replication lag, then lowest replication offset delta, then lexicographic slave ID.
2. Sends `REPLICAOF NO ONE` to the selected replica — it becomes the new primary.
3. Sends `REPLICAOF <new-primary>` to all other replicas.
4. Updates its internal topology and notifies all other Sentinels.
5. Starts rejecting the old primary (which will now come back as a replica when it recovers).

Total failover time: `down-after-milliseconds` + election time + `REPLICAOF NO ONE` propagation. Typical: 30–60s with default settings. You can tune `down-after-milliseconds` down to ~5000ms for faster failover, but be careful — aggressive values increase false-positive failovers during momentary network jitter.

### 2.3 Client-Side: How to Use Sentinel

Clients must speak the Sentinel protocol — not connect directly to the primary IP. Here is the lookup dance:

```python
# redis-py example (Python)
from redis.sentinel import Sentinel

sentinel = Sentinel(
    [("sentinel-1", 26379), ("sentinel-2", 26379), ("sentinel-3", 26379)],
    socket_timeout=0.1,
)
primary = sentinel.master_for("mymaster", socket_timeout=0.2)
replica = sentinel.slave_for("mymaster", socket_timeout=0.2)

primary.set("key", "value")
replica.get("key")
```

The Sentinel connection itself is not a data connection — it speaks the Redis protocol but only for topology discovery. When a failover happens, the client library asks Sentinel again on the next reconnect and transparently switches to the new primary.

> **Sentinel does NOT shard.** Everything still fits on one primary. If your dataset is 200 GB and one machine has 128 GB RAM, Sentinel won't help — that's Cluster's job.

---

## 3. Cluster — Horizontal Sharding

Redis Cluster distributes keys across up to 1000 nodes (practical limit; theoretical is higher) using a fixed keyspace of **16384 hash slots**. Every primary node owns a contiguous (or non-contiguous) subset of slots; every cluster has exactly 16384 slots assigned in total.

```
  Node A (primary)          Node B (primary)          Node C (primary)
  Slots 0–5460              Slots 5461–10922           Slots 10923–16383
  ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
  │  replica-a1  │          │  replica-b1  │          │  replica-c1  │
  └──────────────┘          └──────────────┘          └──────────────┘
```

### 3.1 Hashing a Key to a Slot

```
slot = CRC16(key) mod 16384
```

`CRC16` is a specific variant (IBM SDLC, polynomial 0x1021). You can compute it yourself, but in practice you either rely on your client library or use `CLUSTER KEYSLOT <key>` for debugging:

```bash
redis-cli -c CLUSTER KEYSLOT user:1001
# -> 10259   (lands on Node C)

redis-cli -c CLUSTER KEYSLOT "{user}:profile"
# -> 5474    (uses only "user" as the hash input — see hash tags below)
```

The `-c` flag tells `redis-cli` to follow MOVED/ASK redirects automatically. Without it, you get the raw error.

### 3.2 MOVED vs ASK — The Two Redirects

**MOVED** means "this slot permanently lives on a different node." Your client must update its slot map and retry there:

```
127.0.0.1:7000> GET user:1001
-MOVED 10259 127.0.0.1:7002
```

A smart client (JedisCluster, redis-py with cluster mode, ioredis in cluster mode) caches the slot→node mapping and only gets `MOVED` during topology changes or when its cache is stale.

**ASK** means "this slot is mid-migration; go ask that node for this one command, then come back." It is transient — the slot map is not updated on `ASK`. The client must prepend an `ASKING` command before the retried command:

```
127.0.0.1:7000> GET migrating-key
-ASK 3999 127.0.0.1:7001
# client connects to 7001, sends:
ASKING
GET migrating-key
```

```
         Migration in progress for slot 3999
         ┌────────────────────────────────────────────┐
Source   │  keys already migrated  │  keys still here │  Destination
Node A   │         → Node B        │                  │  Node B
         └────────────────────────────────────────────┘
                                       ▲
               ASK for keys still here   MOVED for keys migrated
```

### 3.3 Slot Migration

Migrating slots is how you rebalance the cluster or add/remove nodes. The sequence for migrating a single slot from Node A to Node B:

```bash
# 1. On source (Node A): mark slot as migrating
redis-cli -p 7000 CLUSTER SETSLOT 3999 MIGRATING <node-B-id>

# 2. On destination (Node B): mark slot as importing
redis-cli -p 7001 CLUSTER SETSLOT 3999 IMPORTING <node-A-id>

# 3. Iterate keys in the slot and migrate them one by one
redis-cli -p 7000 CLUSTER GETKEYSINSLOT 3999 100   # get up to 100 keys
redis-cli -p 7000 MIGRATE 127.0.0.1 7001 "" 0 5000 KEYS key1 key2 ...

# 4. Once all keys are moved, notify all nodes:
redis-cli -p 7000 CLUSTER SETSLOT 3999 NODE <node-B-id>
redis-cli -p 7001 CLUSTER SETSLOT 3999 NODE <node-B-id>
# (gossip propagates to the rest)
```

`redis-cli --cluster rebalance` wraps all of this. Use the low-level commands only when you need precise control or when rebalance doesn't converge.

### 3.4 Multi-Key Constraints & Hash Tags

**The critical limitation of Cluster:** commands that touch multiple keys across different slots are rejected with `CROSSSLOT`:

```
redis-cli -c MSET user:1 a user:2 b
-CROSSSLOT Keys in request don't hash to the same slot
```

This affects: `MSET`, `MGET`, `DEL` with multiple keys, `SUNIONSTORE`, `ZUNIONSTORE`, Lua scripts, transactions (`MULTI/EXEC`) — anything that reads or writes more than one key in a single command.

**Hash tags** are the solution: if a key contains `{tag}`, only the portion inside braces is used for hashing. All keys with the same tag land on the same slot:

```bash
CLUSTER KEYSLOT "{user:1001}:profile"   # -> hashes "user:1001"
CLUSTER KEYSLOT "{user:1001}:cart"      # -> same hash, same slot
CLUSTER KEYSLOT "{user:1001}:sessions"  # -> same hash, same slot

# Now this works:
MGET "{user:1001}:profile" "{user:1001}:cart" "{user:1001}:sessions"
```

The tradeoff: if you tag everything with the same string (e.g., `{app}:*`), all keys land on one slot — you've undone sharding. Design tags to group *related* keys that need to be accessed together, not to group everything.

> **Lua scripts in Cluster.** A Lua script in Redis Cluster must declare all keys it will access in the `KEYS` array. The cluster checks that all keys share the same slot before executing. If they don't, you get `CROSSSLOT`. This means your script must be designed with hash tags in mind.

### 3.5 Cluster Topology Inspection

```bash
redis-cli -p 7000 CLUSTER INFO
redis-cli -p 7000 CLUSTER NODES          # full topology: node IDs, slots, roles
redis-cli -p 7000 CLUSTER MYID
redis-cli --cluster info 127.0.0.1:7000  # human-readable slot distribution
redis-cli --cluster check 127.0.0.1:7000 # detect config inconsistencies
```

---

## 4. Replication vs Sentinel vs Cluster — When to Use Which

| Scenario | Solution |
|----------|----------|
| Single-node with standby | Async replication (read from replica) |
| Single-primary HA (auto-failover) | Sentinel (3+ sentinels) |
| Dataset too large for one node | Cluster (3+ primaries, each with replica) |
| HA + horizontal scaling | Cluster (built-in primary–replica per shard) |

Sentinel and Cluster are not mutually exclusive in architecture — a Cluster node pair is effectively a mini Sentinel topology per shard. In practice, managed Redis (ElastiCache, Redis Cloud, Azure Cache) abstracts this away, but you still hit the edge cases documented here.

---

## Debugging Replication, Sentinel & Cluster

### Diagnosing Replica Lag

```bash
# On the primary:
redis-cli INFO replication | grep -E 'master_repl_offset|slave[0-9]'
# Look for lag > 0 and growing offset deltas

# On the replica:
redis-cli INFO replication | grep -E 'master_link_status|master_last_io_seconds_ago|slave_repl_offset'
# master_link_status:down  → TCP disconnected
# master_last_io_seconds_ago > 10  → no data flowing
```

Causes of persistent lag:
1. **Replica CPU-bound on expiry processing.** A replica running `DEBUG SLEEP` on expiry callbacks — check `redis-cli INFO stats | grep expired_keys` on both sides.
2. **Network bandwidth saturated.** The replication stream is a continuous TCP flow. A 1 Gbps link saturated by other traffic will cause lag.
3. **Large FULLRESYNC in progress.** Watch `rdb_bgsave_in_progress` and `loading` on the replica. The replica is reading the RDB — no writes are applied until loading is done.
4. **`min-slaves-to-write` blocking primary.** If configured, the primary stalls if fewer than N replicas are within `min-slaves-max-lag` seconds. This is an intentional tradeoff: durability at the cost of availability.

### Diagnosing Split-Brain in Sentinel

Split-brain: two nodes both believe they are primary because the Sentinels are partitioned.

```bash
# On both nodes:
redis-cli INFO replication | grep role
# If both say role:master, you have split-brain

# On sentinels:
redis-cli -p 26379 SENTINEL masters
redis-cli -p 26379 SENTINEL slaves mymaster
# Compare what each sentinel thinks the primary is
```

A partition where the old primary is isolated from Sentinels but still reachable by some clients causes **write divergence**: clients on the partitioned side write to the old primary; when the partition heals, those writes are lost (overwritten by the new primary's state). The configuration setting `min-replicas-to-write` on the primary mitigates this: if the primary cannot reach at least N replicas, it stops accepting writes — a deliberate fail-stop behavior.

```
# sentinel.conf
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
```

`parallel-syncs 1` means only one replica resyncs at a time during failover, preventing all replicas from doing a FULLRESYNC simultaneously and starving the new primary of read capacity.

### Diagnosing CROSSSLOT Errors

```bash
# Which slot is each key in?
redis-cli CLUSTER KEYSLOT key1
redis-cli CLUSTER KEYSLOT key2

# If different, wrap them in hash tags:
redis-cli CLUSTER KEYSLOT "{shared}:key1"
redis-cli CLUSTER KEYSLOT "{shared}:key2"
# These must return the same slot number
```

A CROSSSLOT error in production usually means a multi-key pipeline or transaction was written without Cluster in mind. Audit all `MGET`/`MSET`/`DEL` calls in the codebase for cross-slot patterns.

---

## Checkpoint

You should be able to answer these without notes:

1. What does `PSYNC <id> <offset>` return when the replica's offset is within the backlog? When it is not?
2. A replica shows `master_link_status:down`. What are three likely causes and their first diagnostic commands?
3. What is the difference between SDOWN and ODOWN in Sentinel? Why does the distinction matter for preventing false-positive failovers?
4. With 5 Sentinels, what quorum is required for ODOWN (configured)? What quorum is required for leader election (fixed)?
5. A client sends `MGET user:cart user:profile` against a Redis Cluster and receives `CROSSSLOT`. Explain exactly why and show the fix.
6. During slot migration, when does a client receive `MOVED` vs `ASK`? What extra step must the client do before retrying on an `ASK`?
7. You observe both primaries in a Cluster reporting `role:master`. Describe the state of the cluster and the immediate mitigation.
8. What does `repl-backlog-size` control, and how do you size it appropriately?

➡ Next: **Pub/Sub & Streams** — fire-and-forget messaging vs durable, consumer-group-aware event queues.
