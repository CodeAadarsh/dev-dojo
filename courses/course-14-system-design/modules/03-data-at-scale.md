# Data at Scale

> **Module 03 · Course 14** — You will be asked "what database would you use?" in every system design interview. The correct answer is never "Postgres" or "Cassandra" — it is always the access pattern, followed by the storage type that serves it. This module gives you the map from pattern to technology and the failure modes that live in between.

---

## The storage landscape

```
What's your primary access pattern?
          │
          ├── structured data, complex joins, ACID transactions
          │       └──→ Relational (Postgres, MySQL, CockroachDB)
          │
          ├── flexible/nested schema, point lookups, no complex joins
          │       └──→ Document (MongoDB, DynamoDB, Firestore)
          │
          ├── wide rows, massive write throughput, time-ordered reads
          │       └──→ Wide-column (Cassandra, HBase, Bigtable)
          │
          ├── full-text search, faceted filtering, relevance scoring
          │       └──→ Search engine (Elasticsearch, OpenSearch)
          │
          ├── append-only metrics/events, time-range scans, rollups
          │       └──→ Time-series (InfluxDB, TimescaleDB, Prometheus)
          │
          ├── arbitrary blobs, large files, ML model artifacts
          │       └──→ Object store (S3, GCS, Cloudflare R2)
          │
          ├── graph traversal, shortest path, relationship queries
          │       └──→ Graph (Neo4j, Amazon Neptune)
          │
          └── low-latency counters, sessions, sorted sets, leaderboards
                  └──→ In-memory (Redis, Dragonfly)
```

The mistake is picking a storage type because you've used it before, or because it's the current industry hype. Postgres with a proper index outperforms Cassandra for a workload with complex joins. Cassandra absorbs 500K writes/sec where Postgres falls over. The tool follows the workload.

---

## The storage decision matrix

Lead with the access pattern. The storage type is the consequence, not the premise.

| Access pattern | Best fit | Why not the alternatives |
|---------------|---------|-------------------------|
| Point lookup by PK, complex joins, ACID | Postgres, MySQL | Mongo struggles with multi-document transactions; Cassandra has no joins |
| High write throughput, wide rows, time-ordered, no joins | Cassandra, DynamoDB, Bigtable | Relational primaries saturate write throughput; LSM-tree is write-optimized |
| Full-text search, faceted aggregations | Elasticsearch, OpenSearch | Postgres `LIKE '%foo%'` doesn't use a B-tree; `pg_trgm` is limited; ES inverted index is purpose-built |
| Append-only sensor/metric data, time-range scans | InfluxDB, TimescaleDB | Vanilla relational grows unboundedly without partitioning; TimescaleDB automates this with hypertables |
| Large binary objects (images, video, ML weights) | S3/GCS | Storing BLOBs in Postgres bloats the WAL, pollutes the buffer pool, and makes backup/restore painful |
| Social graph, multi-hop traversal | Neo4j, Neptune | Relational JOIN chains degrade as depth grows (`n` hops = `n` joins); graph DBs store adjacency natively |
| Session tokens, rate-limit counters, leaderboards | Redis | Sub-millisecond in-memory access; sorted sets for leaderboards; TTL per key; single-threaded ACID per key |

---

## Indexing internals

An index is a data structure that trades write amplification and storage for faster reads. Understanding which data structure the DB uses explains every performance surprise.

### B-tree index (Postgres, MySQL default)

A balanced tree of fixed-size pages. O(log n) for point lookups and range scans.

Efficient for:
- Point lookups: `WHERE id = 42`
- Range scans: `WHERE created_at BETWEEN '2024-01-01' AND '2024-06-01'`
- Prefix searches: `WHERE name LIKE 'foo%'` (leading wildcard defeats it: `'%foo'` → sequential scan)
- `ORDER BY` when the index matches the sort direction

Write cost: every insert, update, or delete must update the index page(s) and potentially trigger a page split. At very high write throughput (~10K–50K writes/sec on a single primary), B-tree maintenance starts to saturate the WAL.

### LSM-tree index (Cassandra, RocksDB, LevelDB)

Log-structured merge tree. Writes land in an in-memory buffer (memtable) + a write-ahead log, then get flushed to immutable sorted files on disk (SSTables), periodically merged via background compaction.

- **Sequential writes are extremely fast** — no random disk seeks, no page splits
- **Reads are amplified** — a read may need to check multiple SSTables (mitigated by per-SSTable bloom filters)
- **Compaction is background I/O** — it can spike disk throughput; size your nodes with headroom for it

The tradeoff: write-optimized at the cost of read amplification. Before you say "Cassandra is faster" in a design interview, qualify it: faster *at writes*, slower *at point reads*, with operational complexity around compaction tuning.

### Composite and covering indexes

```sql
-- Workload: "find all orders for customer 42, newest first"
SELECT id, status, total FROM orders
WHERE customer_id = 42
ORDER BY created_at DESC;

-- Composite index serves this in one tree traversal
CREATE INDEX orders_cust_date_idx ON orders(customer_id, created_at DESC);

-- Covering index: include the SELECT columns so the DB never touches the heap
CREATE INDEX orders_covering ON orders(customer_id, created_at DESC)
  INCLUDE (id, status, total);
```

**Left-prefix rule:** a composite index on `(a, b, c)` is usable for predicates on `a`, `a+b`, or `a+b+c`. Never on `b` or `c` alone. Every composite index you create: draw out the filter combinations it serves. If you can't name three queries it helps, you may not need it.

**EXPLAIN ANALYZE** is non-negotiable before claiming an index works:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...
-- Look for: Index Scan on orders_covering, not Seq Scan
-- Buffers hit: N means pages read from shared_buffers (fast)
-- Buffers read: N means pages read from disk (slow)
```

---

## Partitioning and sharding

Partitioning: splitting a dataset across nodes (or logical partitions on the same node) so no single machine holds everything.

### Horizontal partitioning (sharding)

Split by row. Each shard holds a subset of the rows:

```
User IDs 1–1,000,000     → Shard 0  (us-east-1)
User IDs 1,000,001–2M    → Shard 1  (us-west-2)
User IDs 2,000,001–3M    → Shard 2  (eu-west-1)
```

The application (or a routing tier) decides which shard to query for a given key.

### Shard key selection — the most consequential decision

| Strategy | Mechanism | Hotspot risk | Notes |
|----------|-----------|-------------|-------|
| Range-based | `shard = key / partition_size` | High if key is monotonic (sequential IDs, timestamps) | Range scans are efficient within a shard; cross-shard range scans are expensive |
| Hash-based | `shard = hash(key) % n_shards` | Low for uniform key distributions | Cannot do efficient range scans; resharding requires rehashing all keys |
| Consistent hashing | `hash(key)` maps to a position on a ring; nearest node clockwise owns it | Low even during ring changes (add/remove nodes) | Minimizes data movement on topology change; virtual nodes (vnodes) smooth uneven distribution |
| Directory-based | Lookup service: `key → shard_id` | None — fully flexible | Lookup service is a bottleneck and a new SPOF unless itself distributed |

The wrong shard key is more destructive than no sharding at all. A **hot shard** is one node receiving a disproportionate share of traffic — the sharding is doing nothing for that traffic while adding overhead everywhere else.

**Bad shard keys and why they fail:**

| Bad key | Why it's bad | Fix |
|---------|-------------|-----|
| Auto-increment integer PK | New rows always land on the shard with the highest range (insert hot shard) | Use UUID v4 or ULID (lexicographically random); or hash the PK before sharding |
| Timestamp | All writes go to the current-time shard; past shards are cold | Prefix with `hash(source_entity_id) % n` so writes spread across shards while still co-locating per-entity data |
| Low-cardinality field (country, status enum) | A handful of large values create hot shards with no way to subdivide | Never use a low-cardinality field as the sole shard key; combine with a high-cardinality field |

**Fix for time-series hot shards:** combine entity hash with time bucketing:

```
shard_key = bucket(hash(device_id) % n_shards, time_bucket_1h)
```

Now writes spread across shards (good for write throughput) while per-device time-range scans hit a single shard (good for read efficiency).

### Cross-shard joins — the tax you pay

Once data lives on multiple shards, any query that spans shards requires:

1. **Fan-out:** send the query to all N shards in parallel
2. **Scatter-gather:** collect and merge results in the application layer
3. **Sort / deduplicate / paginate** the merged result set

Fan-out latency = `max(shard_latency)`, not `avg(shard_latency)`. One slow shard poisons the whole response. Design the shard key so the most common queries are within-shard. Accept cross-shard only on the rare analytical path.

---

## Replication

### Sync vs. async replication

```
Primary  ──writes──→  WAL
                         │
            ┌────────────┼────────────┐
            │ sync       │ async      │
            ▼            ▼            ▼
         Replica A    Replica B    Replica C
         (ack before  (fire and    (fire and
          returning)   forget)      forget)
```

| Mode | Write latency | Data loss on crash | Typical use |
|------|--------------|-------------------|------------|
| Synchronous | Higher — wait for N replicas to acknowledge | None — durability guaranteed | Financial, medical — zero RPO |
| Asynchronous | Lower — primary doesn't wait | Possible — up to the replication lag | High-throughput services where some lag is acceptable |
| Semi-synchronous | Middle — wait for 1 replica, rest async | At most the lag of the async replicas | Good default for most production databases |

### Leader election and split-brain

When a primary fails, a replica must be promoted. The two failure modes:

- **No quorum fast enough** → availability drops; writes fail until a new leader is confirmed
- **Split-brain** → two nodes both believe they're primary, both accept writes, data diverges

Raft and Paxos solve this with a quorum requirement: a candidate needs `⌊n/2⌋ + 1` votes before acting as leader. This is why you always deploy an **odd number of nodes** (3 or 5). Two replicas cannot form a majority if one is unreachable — you can't distinguish "dead" from "network partition."

**The practical consequence:** etcd (Kubernetes' backing store) runs as a 3- or 5-node Raft cluster. A 2-node etcd is not highly available — it's a single point of failure with extra steps. Any single node failure below quorum halts all writes.

---

## Consistency models

From strongest to weakest:

| Model | What it guarantees | Real-world systems |
|-------|------------------|-------------------|
| Linearizability (strong) | All reads see the latest committed write; as if there's one machine | etcd, ZooKeeper, Google Spanner |
| Sequential consistency | All operations appear in the same order to all clients, but that order may not match real time | Some in-memory stores |
| Causal consistency | Writes that causally depend on each other appear in order; concurrent writes may differ across nodes | DynamoDB Streams, some Cosmos DB modes |
| Read-your-writes | You always see your own writes; others may see stale | Postgres primary reads, Redis |
| Monotonic reads | Once you see a value V, you'll never see a value older than V in a subsequent read | Most replicated systems with session affinity |
| Eventual consistency | If no new writes occur, all replicas will converge to the same value (eventually) | DynamoDB default, Cassandra default, S3 |

For system design interviews, the two you name most often:

- **Strong consistency:** writes go to the primary; all reads are linearizable; use for financial balances, inventory counts, anything where a stale read causes a real-world error
- **Eventual consistency:** replicas may lag; acceptable for social feed rankings, view counts, recommendation scores, anything where a brief stale read is tolerable and throughput matters more

---

## CAP theorem

In the presence of a **network partition** (P — unavoidable in any distributed system), you must choose:

- **C (Consistency):** all nodes see the same data at the same time; writes may be refused to preserve this → CP systems
- **A (Availability):** every request gets a response; responses may be stale → AP systems

**P is not optional.** Network partitions happen in production — a switch fails, a NIC drops packets, a cross-datacenter link is flaky. Any system claiming to be CA is either a single-machine system or one that treats partitions as fatal errors.

The practical implication:

| Partition behavior | Examples |
|-------------------|---------|
| CP — refuses writes during partition to preserve consistency | etcd, HBase, Zookeeper, Spanner |
| AP — accepts writes on both sides; reconciles on recovery (last-write-wins or vector clocks) | Cassandra (default), DynamoDB, CouchDB |

### PACELC — the useful extension of CAP

CAP only speaks to partition scenarios. PACELC extends it to the normal, no-partition case:

> If there is a **P**artition, choose **A** (availability) or **C** (consistency).
> **E**lse (normal operation), choose **L** (latency) or **C** (consistency).

| System | P → A or C? | Else → L or C? |
|--------|------------|----------------|
| DynamoDB (eventually consistent reads) | A | L |
| DynamoDB (strongly consistent reads) | A | C (higher latency) |
| Cassandra with `CONSISTENCY ONE` | A | L |
| Cassandra with `CONSISTENCY QUORUM` | A | C (higher latency, more replicas queried) |
| Google Spanner | C | C |
| ZooKeeper | C | C |

**Why PACELC matters:** most of the time there is no partition. The latency vs. consistency tradeoff under *normal* operation is the one you make every day — it's just invisible because it's a configuration option, not a failure scenario. PACELC names it explicitly and forces you to state your choice.

---

## Common Mistakes

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| Monotonically growing PK causes one shard to be overwhelmed ("insert hot shard") | Sequential shard key — all new data lands on the highest-range shard | Use UUID v4, ULID, or explicit `hash(entity_id) % n` as the shard key so inserts spread across shards |
| Cross-shard joins appear in the hot request path | Shard key chosen for data locality of individual entities, not for query co-locality | Revisit shard key to co-locate the most common join partners on the same shard; denormalize if co-location isn't possible |
| Application assumes strong consistency but the DB provides eventual | Cassandra `CONSISTENCY ONE` on reads/writes; DynamoDB default eventually consistent reads | Set `CONSISTENCY QUORUM` for both reads and writes in Cassandra; pass `ConsistentRead=True` in DynamoDB for correctness-critical reads; document the consistency level per table |
| p99 latency spikes when replication lag grows | Reads routed to a lagging replica; no lag monitoring | Add a replication lag metric; exclude replicas above a lag threshold (e.g. >5 s) from the read pool |
| Index exists, query is slow, EXPLAIN shows `Seq Scan` | Statistics are stale; planner underestimates selectivity | Run `ANALYZE <table>` (Postgres) to refresh statistics; check `EXPLAIN (ANALYZE, BUFFERS)` for actual vs. estimated row counts |
| Full-text search with `LIKE '%keyword%'` is slow | Leading wildcard defeats the B-tree index; full sequential scan | Enable `pg_trgm` + GIN trigram index for Postgres; migrate to Elasticsearch if search is a first-class feature |

> **War story.** We ran a multi-tenant metrics pipeline at SAP — around 40 tenants writing to a shared TimescaleDB hypertable partitioned by `(time)` with an index on `(tenant_id, time)`. p99 ingestion latency was fine for 39 tenants and 3× the SLA for one. The hot tenant had one million active time series — 100× the average. The hypertable was partitioned by time, so every query for that tenant scanned across multiple time-based chunks and then filtered by `tenant_id`. The index on `(tenant_id, time)` was there, but the planner wasn't using it for chunk exclusion because partition elimination in TimescaleDB happens on the time dimension. The fix was a second, explicit composite index `(tenant_id, time DESC)` declared on the hypertable level so the query planner could do an index-only scan per-tenant-per-chunk. No sharding migration, no infrastructure change — one index, p99 dropped to SLA in the next deploy. The lesson: partition key order is your query plan. Read the EXPLAIN output before ordering a bigger machine or a shard migration.

---

## Checkpoint

Before moving on, answer these without notes:

1. Given this workload — "show me all posts from people I follow, sorted by recency, with like counts" — name the storage type(s) you'd use for each sub-problem and why.
2. Explain the tradeoff between B-tree and LSM-tree indexes. Under what workload does each outperform the other?
3. Name two bad shard key examples and explain the precise mechanism by which each creates a hot shard.
4. A fan-out query hits 10 shards. What is the latency model and what architectural choices minimize it?
5. What is the difference between synchronous and asynchronous replication? Name a use case where the durability cost of async replication is acceptable.
6. Explain CAP in one sentence and name a real system that makes the CP choice and one that makes the AP choice.
7. What does PACELC add over CAP? Give a concrete example where the Else branch (no partition) is the tradeoff you're actually making.
8. A Cassandra table is configured `CONSISTENCY ONE` for both reads and writes. A write goes to node A. A read immediately after lands on node B. Is read-your-writes consistency guaranteed? Why or why not?

→ Next: **Async Messaging and Backpressure** — queues, event buses, fan-out patterns, and how to stop a slow consumer from taking down the producer.
