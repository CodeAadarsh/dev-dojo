# Replication & Partitioning

> **Module 06 · Course 20** — A single-node database is a single point of failure and a single performance ceiling. Replication moves copies of your data to multiple nodes for durability and read scale. Partitioning moves *slices* of your data across nodes to break the write ceiling. They look similar but solve different problems — and combining them (sharding) introduces the hardest failure modes in distributed data systems.

This module goes deep on both: not just "what is replication lag" but the exact causal chain from an async commit to a stale read, and not just "what is consistent hashing" but why rebalancing under hash partitioning is terrifying without it.

---

## Replication: Leader-Follower

Leader-follower (also called primary-replica, master-slave) is the default replication topology in PostgreSQL (streaming replication), MySQL (binary log replication), MongoDB (replica set), Redis Sentinel, and most managed cloud databases.

```
        ┌────────────────────────────────────────────────────────────┐
        │                    LEADER (primary)                        │
        │   receives all writes                                      │
        │   maintains the WAL / binlog                               │
        └──────────────────┬─────────────────────┬───────────────────┘
                           │  WAL stream          │  WAL stream
                           │  (async)             │  (sync to one follower)
                           ▼                      ▼
               ┌─────────────────┐    ┌─────────────────────┐
               │  FOLLOWER 1     │    │  FOLLOWER 2 (sync)  │
               │  read replica   │    │  standby / failover │
               │  lags ~10ms–5s  │    │  always current     │
               └─────────────────┘    └─────────────────────┘
```

### Synchronous vs Asynchronous Replication

**Asynchronous replication (default):**

```
Client → Leader: COMMIT
Leader: writes WAL to local disk, ACKs client ← commit returns here
Leader: streams WAL to followers in background
Followers: apply WAL, eventually catch up
```

Consequence: **durability window**. If the leader crashes after ACKing the client but before the follower receives the WAL entry, that committed transaction is gone. The follower becomes the new leader and it never had that transaction. The client thinks it committed; the database says it didn't. This is the `async` durability tradeoff and it's the default on every cloud RDS "Multi-AZ" outside the synchronous standby.

**Synchronous replication:**

```
Client → Leader: COMMIT
Leader: writes WAL locally
Leader → Follower: send WAL entry and wait for ACK
Follower: writes WAL to disk, sends ACK
Leader: ACKs client ← commit returns here
```

Zero-data-loss on single-node failure. The cost: a commit's latency now includes a full round-trip to the follower. For a follower in the same datacenter (1ms RTT) that's acceptable. Cross-datacenter (40–150ms RTT) it's often not.

PostgreSQL's hybrid: `synchronous_commit = remote_apply` ensures the follower has *applied* the change (readable), while `synchronous_commit = remote_write` only ensures the follower has received the WAL to disk (safe but follower may show old data for a short window).

### Read Replicas and Replication Lag

Read replicas absorb read traffic. Every managed database service (RDS Read Replicas, Cloud SQL read replicas, PlanetScale, etc.) uses this model.

**Replication lag** is the time between a write being committed on the leader and it being visible on a replica. Causes:

1. **Network latency:** WAL must travel cross-AZ or cross-region.
2. **Replica I/O saturation:** if the replica's disk is slow, WAL apply backs up.
3. **Large transactions:** a single large UPDATE generates a burst of WAL; the replica must apply the full transaction atomically, which can cause a visible lag spike.
4. **Long-running queries on the replica:** PostgreSQL replicas can't apply WAL to pages that are locked by a running query — query conflicts cause the replica to pause replication up to `max_standby_streaming_delay`.

Measure it:

```sql
-- on PostgreSQL leader
SELECT application_name,
       client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       (sent_lsn - replay_lsn) AS replication_lag_bytes
FROM pg_stat_replication;

-- on replica: how far behind am I?
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS lag_seconds;
```

### The Read-Your-Writes Problem

Async replication creates the following sequence:

```
T=0: User POSTs a new comment → write goes to leader, ACK returned
T=1: User GETs their comments → read goes to replica (load-balanced)
T=2: Replica receives the write (lag = 2s)
```

Between T=0 and T=2, the user reloads the page and sees their own comment vanish. This is a **read-your-writes** violation, and it is the most common production replication bug because it passes all unit tests (they hit the leader) and only shows up in production (where reads are load-balanced).

Solutions:

1. **Sticky reads:** after a write, route subsequent reads for that user/session to the leader for a short window (common in Rails, Shopify's technique).
2. **Leader reads for the session:** read all non-stale data from the leader; only use replicas for analytics or stale-OK reads.
3. **Replica read with lag check:** only send to a replica whose `lag_seconds` < X; otherwise fall back to leader.
4. **Track the write's LSN and wait:** after a write, note the LSN; before serving a read on a replica, confirm the replica has replayed past that LSN. PostgreSQL 10+ exposes `pg_current_wal_lsn()` and `pg_last_wal_replay_lsn()`.

---

## Multi-Leader Replication

Multi-leader (also called multi-master) allows writes to any node. All nodes accept writes and replicate to each other.

```
       ┌──────────────────┐      ┌──────────────────┐
       │   LEADER DC-A    │◄────►│   LEADER DC-B    │
       │  writes accepted  │      │  writes accepted  │
       └──────────────────┘      └──────────────────┘
              ▲                         ▲
              │  reads/writes           │  reads/writes
```

**The problem: write conflicts.** If two users update the same row concurrently on different leaders:

```
DC-A: UPDATE products SET price = 999 WHERE id = 42;
DC-B: UPDATE products SET price = 1199 WHERE id = 42;  (concurrent)
```

Which value wins? The database cannot apply both updates atomically across leaders. Every multi-leader system must have a **conflict resolution strategy:**

| Strategy | How it works | Suitable for |
|----------|--------------|-------------|
| Last-Write-Wins (LWW) | Highest timestamp wins | Commutative updates; loses data silently |
| First-Write-Wins | First to replicate wins | Idempotent inserts; poor for counters |
| Merge | Values are merged (union of sets, max of counters) | CRDTs (counters, sets, flags) |
| Custom logic | Application callback decides | Domain-specific; most correct |
| Avoid conflicts | Route all writes for a record to one leader | Strongest guarantee; kills multi-leader benefits |

**CRDTs (Conflict-free Replicated Data Types)** are data structures whose operations are designed to merge without conflict: a G-Counter (grow-only counter) resolves by taking the max per-node; an LWW-Register resolves by timestamp. Redis cluster's counters, DynamoDB's eventual-consistency writes, and Riak all use CRDT-inspired approaches.

Multi-leader is used in:
- Geo-distributed applications needing local-write latency (Salesforce, Google Docs offline mode)
- CouchDB's sync protocol
- Any system where "merge later" is acceptable over "wait for consensus now"

---

## Quorum Reads and Writes

In a quorum system, you have N replicas, write to W of them, and read from R of them. The condition **W + R > N** guarantees that any read set and any write set overlap by at least one node — so at least one node in any read has the latest write.

```
N = 3, W = 2, R = 2  →  W + R = 4 > 3  ✓ strong quorum

                   ┌─── Node 1 ───┐  ← write here
Write ─────────────│              │
                   └─── Node 2 ───┘  ← write here
                   (Node 3: not written)

                   ┌─── Node 2 ───┐  ← read here (latest)
Read ──────────────│              │
                   ┌─── Node 3 ───┘  ← read here (stale)
```

Node 2 is in both the write set and the read set — so the read always includes the latest write.

**Sloppy quorum (DynamoDB default):** if the preferred W nodes are unavailable during a write, the write temporarily goes to other available nodes and is **hinted** to be forwarded later. This improves write availability but means the strict W+R>N overlap guarantee breaks during partitions.

Quorum settings in practice:
- `W=N, R=1` — every node must ack a write; reads are fast but writes are unavailable if any node is down.
- `W=1, R=N` — writes are fast; reads are slow and always return the latest, but any node failure makes reads unavailable.
- `W=N/2+1, R=N/2+1` — balanced; tolerates up to N/2 failures on either side.

Real systems (Cassandra, DynamoDB, Riak) let you configure W and R per-operation, so you can use `W=ALL, R=1` for critical writes and `W=1, R=1` for best-effort writes from IoT sensors.

---

## Partitioning

Replication copies data; partitioning *divides* it. Every row lives in exactly one partition.

### Why Partition?

1. **Write throughput:** a single-node write bottleneck is broken — different partitions live on different nodes and accept writes in parallel.
2. **Query performance:** if you always filter by the partition key, only one partition is scanned instead of all.
3. **Maintenance:** vacuum, reindex, backup on individual partitions rather than one enormous table.

### Range Partitioning

Rows are assigned to partitions by value ranges of the partition key.

```
Partition key: order_date

┌──────────────────────────────────────────────────────────────────────┐
│ Partition P1  2020-01-01 ≤ order_date < 2021-01-01                  │
│ Partition P2  2021-01-01 ≤ order_date < 2022-01-01                  │
│ Partition P3  2022-01-01 ≤ order_date < 2023-01-01                  │
│ Partition P4  2023-01-01 ≤ order_date < 2024-01-01  ← current year  │
└──────────────────────────────────────────────────────────────────────┘
```

**Partition pruning:** `WHERE order_date BETWEEN '2023-06-01' AND '2023-08-01'` touches only P4. All other partitions are eliminated before execution.

**Problem: hot partition.** All current-year inserts go to P4. P4 is the hot partition — it receives 100% of write traffic. In a distributed setup, the node holding P4 becomes the bottleneck.

Range partitioning is excellent for time-series data where you query recent data and archive old partitions, but bad for tables where the write distribution follows the partition key closely in time.

### Hash Partitioning

Rows are assigned by `hash(partition_key) % N`.

```
Partition key: user_id

hash(user_id=101) % 4 = 1 → Partition P1
hash(user_id=202) % 4 = 2 → Partition P2
hash(user_id=303) % 4 = 3 → Partition P3
hash(user_id=404) % 4 = 0 → Partition P0
```

**Advantage:** write traffic is uniformly distributed across all partitions (assuming `user_id` is uniformly distributed).

**Disadvantage:** range queries (`WHERE user_id BETWEEN 100 AND 200`) must scan all partitions — there's no pruning for ranges.

### Consistent Hashing

Naive hash partitioning (`hash(key) % N`) has a catastrophic rebalancing problem: when N changes (you add or remove a node), *almost every key* maps to a different partition. You must re-route nearly all data.

**Consistent hashing** fixes this. Keys and nodes are both mapped to positions on a ring (hash space 0–2^128). A key belongs to the first node clockwise from its position.

```
          0
         / \
   (N=4)    2^128
      ┌──────────────┐
      │   HASH RING  │
      │              │
 Node A            Node C
  (pos 90°)       (pos 270°)
      │              │
 Node B            Node D
  (pos 180°)      (pos 360°/0°)

Key K maps to the first node clockwise from hash(K):
  hash(K) ≈ 120° → falls between Node A and Node B → owned by Node B
```

**Rebalancing when adding a node (Node E at 225°):**

```
Before: keys 180°–270° owned by Node C
After:  keys 180°–225° owned by Node E, keys 225°–270° still by Node C
```

Only the keys in the arc between Node B and Node E need to move. All other keys stay put. Typical rebalancing moves only `1/N` of all keys instead of `(N-1)/N`.

**Virtual nodes:** a single physical node owns multiple positions on the ring (e.g., 150 virtual nodes each). This smooths out load imbalances when physical nodes have different capacities, and further reduces the data moved during rebalancing (each add/remove affects many small arcs rather than one large arc).

Used by: Apache Cassandra (virtual nodes), Amazon DynamoDB (consistent hashing with virtual nodes), Redis Cluster (hash slots — 16384 fixed slots, a simplified form of consistent hashing).

### Rebalancing

**Rebalancing** = moving data from overwhelmed/removed nodes to new/underloaded ones while the cluster remains available.

Rebalancing approaches:

| Approach | How | Trade-off |
|----------|-----|-----------|
| Fixed number of partitions | Pre-split into many partitions (e.g. 1000 for 10 nodes = 100/node); rebalance by moving whole partitions | Simple; can't change partition count without full resharding |
| Dynamic partitioning | Split a partition when it exceeds a size threshold | Adapts to data growth; initial cluster has 1 partition and serial bottleneck |
| Proportional to nodes | Fixed partitions per node; add a node, split existing partitions | Cassandra's model; good middle ground |

**Rebalancing and availability:** while a partition moves, reads and writes for that partition must be served. The cluster must either:
- Keep the old partition readable until the new one confirms receipt (double-write window), or
- Block reads and writes for that partition (hard unavailability window).

Most production systems use **two-phase moves**: write to both old and new location; once new confirms it's caught up, switch reads to new, then remove old. This makes the rebalancing transparent but doubles write traffic during migration.

### Secondary Indexes on Partitioned Data

Secondary indexes on partitioned tables come in two flavors, each with different trade-offs.

**Local (partition-local) index:** each partition has its own index covering only its rows.

```
Partition P0: index on email covering P0 rows only
Partition P1: index on email covering P1 rows only
...
```

A query `WHERE email = 'x@y.com'` must scatter to all partitions (scatter-gather), since the email doesn't determine which partition it's in. This is O(N) index lookups.

**Global index:** one index spans all partitions.

```
Global index on email
  'a@b.com' → Partition P2, row 4440
  'x@y.com' → Partition P0, row 1021
```

A lookup is O(1) in the global index + one partition fetch. But updating the global index on a write to partition P0 requires a cross-partition update — if the global index lives on a different node, that's a distributed write with 2PC overhead.

DynamoDB uses **local secondary indexes** (no cross-partition overhead) plus **global secondary indexes** (eventually consistent cross-partition, with the consistency trade-off explicitly documented). Cassandra only has local indexes for this reason. Most SQL databases (Citus, Spanner) offer both with explicit documentation of the trade-offs.

---

## Debugging Replication & Partitioning

### Replication Lag Anomalies

**Symptom A: Replica lag spikes to minutes every night.**

Typical cause: a scheduled batch job runs a large `UPDATE` or `DELETE` on the leader at midnight. The WAL volume spikes; the replica falls behind. The spike shows in:

```sql
-- on replica
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS lag_secs;
-- spikes from 0.1 to 180 during batch window

-- on leader: check WAL generation rate
SELECT pg_current_wal_lsn() - '0/0'::pg_lsn AS lsn_bytes_total;
-- run this twice, 1 minute apart; the delta is your WAL generation rate
```

Fix: batch the job into smaller transactions (1000 rows at a time) so each WAL segment is manageable and the replica can keep pace.

**Symptom B: Replica lag grows steadily and never catches up.**

Cause: replica I/O throughput < leader WAL generation rate. The replica is structurally underpowered.

```bash
# On the replica host
iostat -x 1 10   # watch %util on the disk; if pinned at 100%, disk is the bottleneck
vmstat 1 10      # watch wa (iowait); high iowait = I/O bound
```

Fix: upgrade the replica's disk I/O (use provisioned IOPS SSD), or reduce leader write rate (batch writes, write to fewer columns per row).

**Symptom C: Replica lag spikes on long queries.**

PostgreSQL-specific: the replica pauses replication when a running query conflicts with WAL application. Check:

```sql
-- on replica
SELECT * FROM pg_stat_activity WHERE wait_event_type = 'Lock';
SELECT * FROM pg_replication_slots;  -- slots that haven't consumed WAL can hold things back
```

Fix: set `max_standby_streaming_delay = '30s'` (cancel conflicting replica queries after 30s), or use `hot_standby_feedback = on` (replica tells leader to delay vacuuming rows it's reading — increases bloat on leader but prevents conflicts).

### Hot Partition Detection

**Symptom:** one shard/partition has 10× the CPU/IOPS of the others.

Diagnosis: check per-partition metrics in your monitoring. In Cassandra:

```bash
nodetool tpstats          # thread pool stats; one node pinned
nodetool tablehistograms  # per-table latency histograms
```

Root cause: the partition key has low cardinality or a "most popular" value. Example: partitioning a social media "likes" table by `post_id` — a viral post's partition gets millions of writes per second.

Fix options:
1. **Composite partition key:** `(post_id, shard_suffix)` where `shard_suffix` is `user_id % K`. Spreads writes for one post across K partitions but requires reading from all K for aggregation.
2. **Write-side fanout:** write a +1 increment to a random sub-partition; read by summing all sub-partitions. Used by Twitter's like counter.
3. **Caching layer:** absorb the hot reads with Redis; only persist to the DB periodically.

### Rebalancing Storms

**Symptom:** adding a node to a Cassandra/Ceph/DynamoDB cluster triggers massive inter-node traffic that saturates the network and causes latency to spike for all traffic.

Root cause: the rebalance operation moves too much data too fast.

Mitigation:
- Set a rebalance throughput limit: `nodetool setstreamthroughput 50` (50 MB/s) in Cassandra; add nodes one at a time.
- In DynamoDB: use gradual capacity increases (not sudden +1000 WCU jumps); the service rate-limits its own rebalancing.
- Pre-split partitions before load hits: create partitions early in an empty table so data distributes evenly from the first write.
- In Ceph: set `osd_max_backfills = 1` to limit concurrent backfill operations during rebalance.

---

## Checkpoint

You're solid on this module when you can:

1. Explain the exact sequence of events that causes a read-your-writes violation after an async write — and name two concrete code-level mitigations.
2. State the W + R > N quorum condition and show with N=5 why W=3, R=3 provides strong consistency but W=2, R=2 does not.
3. Describe what a write conflict looks like in a multi-leader system, name three resolution strategies, and say which one loses data silently.
4. Compare range and hash partitioning on two dimensions: write distribution (hot vs uniform) and range query support (pruning vs scatter-gather).
5. Explain consistent hashing's ring model: why adding a node moves only 1/N keys instead of (N-1)/N, and what virtual nodes add.
6. Contrast local vs global secondary indexes on a partitioned table — trade-offs in read latency and write cost.
7. Given a replica lag spike at midnight, name the most likely cause and the specific command to confirm it.
8. Describe what a rebalancing storm looks like at the network layer and name two concrete controls to throttle it.

➡ Next: **Distributed Databases** — consensus (Raft), CAP/PACELC, distributed transactions, and choosing the right engine for your workload.
