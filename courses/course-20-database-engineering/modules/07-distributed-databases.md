# Distributed Databases

> **Module 07 · Course 20** — When data lives on multiple nodes, the problems that were solved problems on a single machine become unsolved or fundamentally harder: clocks disagree, networks partition, processes crash mid-operation, and no node can know the definitive current state of the world. This module builds the conceptual vocabulary — Raft, CAP, linearizability, 2PC, sagas — and then closes with the practical question you face on every system design: which database engine do you actually pick?

---

## Distributed Consensus: Raft

Consensus is the problem of getting a set of nodes to agree on a value despite failures. It's the foundation of every distributed database that claims "strong consistency." **Raft** is the most readable consensus algorithm (deliberately designed as an alternative to Paxos for understandability). Understanding Raft at the internals level lets you reason about the behavior of etcd, CockroachDB, TiDB, Consul, and any system that uses it under the hood — including the Kubernetes control plane.

### Roles

At any time, each Raft node is in one of three states:

```
┌─────────────────────────────────────────────────────────┐
│                     LEADER                              │
│  Accepts client writes, replicates to followers         │
│  Sends heartbeats to maintain authority                 │
└────────────────┬──────────────────────────┬─────────────┘
                 │  AppendEntries (heartbeat│log entries)
                 ▼                          ▼
       ┌──────────────┐           ┌──────────────┐
       │  FOLLOWER    │           │  FOLLOWER    │
       │  Passive;    │           │  Passive;    │
       │  replicates  │           │  replicates  │
       └──────────────┘           └──────────────┘
            ↑ if leader timeout → CANDIDATE → sends RequestVote
```

### Leader Election

**Term:** Raft divides time into numbered terms. A new term begins every time a leader election starts.

1. A follower stops receiving heartbeats from the leader (election timeout — typically 150–300ms, randomized to avoid simultaneous elections).
2. It increments its `currentTerm`, transitions to **CANDIDATE**, and votes for itself.
3. It sends `RequestVote(term, candidateId, lastLogIndex, lastLogTerm)` to all other nodes.
4. A node grants its vote if: (a) it hasn't voted in this term, and (b) the candidate's log is at least as up-to-date as its own.
5. If the candidate receives votes from a **majority** (N/2 + 1), it becomes **LEADER** for this term.
6. The new leader immediately sends heartbeats to suppress other elections.

The **randomized timeout** is what makes simultaneous elections rare. If two nodes started elections at exactly the same time with the same timeout, neither would win a majority and you'd loop. Random jitter (e.g., 150ms ± 50ms) ensures one usually wins first.

**Log up-to-date rule** (the safety invariant): a candidate with a shorter or older log cannot win the election. This ensures the elected leader always has all committed entries — it can't "lose" a committed entry after a leader change.

### Log Replication

```
        Leader log (term=3):
        ┌────┬────┬────┬────┬────┐
        │  1 │  2 │  3 │  4 │  5 │  ← log index
        │ T1 │ T2 │ T2 │ T3 │ T3 │  ← term when written
        └────┴────┴────┴────┴────┘
         ▲               ▲
     committed        uncommitted (not yet on majority)

Client write:
1. Client sends write to leader
2. Leader appends entry to its log (uncommitted)
3. Leader sends AppendEntries to all followers
4. Followers append to their logs, reply ACK
5. When majority has ACK'd → leader commits
6. Leader applies to state machine
7. Leader replies to client: success
8. In next heartbeat, leader tells followers the commit index
9. Followers apply committed entries to their state machines
```

A critical safety property: **a log entry is committed only when stored on a majority of nodes**. Once committed, it will never be lost regardless of future leader changes, because any future leader must have the entry in its own log (from the election vote rule above).

### Safety: Why Raft Never Loses Committed Data

Raft provides two guarantees:

1. **Election Safety:** at most one leader per term.
2. **Log Matching:** if two logs contain an entry with the same index and term, they're identical up to that point.

Together these mean: if an entry is committed in term T on leader L, any future leader L' elected in term > T will have that entry in its log, because a majority voted for L' and a majority holds the committed entry — so the intersection is non-empty.

### Performance Characteristics

A Raft write has latency of: `leader disk write + 1 RTT to follower + follower disk write`. For a 3-node cluster on the same datacenter:

```
~1ms disk write (NVMe) + ~1ms network RTT + ~1ms disk write = ~3ms per write
```

This is why distributed systems that need sub-millisecond writes (e.g., high-frequency trading) avoid consensus-based replication and use async instead.

**Leader bottleneck:** all writes go to the leader. To scale write throughput beyond what one leader can handle, you need **multi-raft** (different data ranges owned by different Raft groups, each with its own leader) — which is exactly how CockroachDB and TiKV are structured: one Raft group per range (64MB chunks).

---

## CAP Theorem

The CAP theorem (Brewer, 2000; Gilbert & Lynch proof, 2002) states that a distributed system can guarantee at most two of:

- **C — Consistency:** every read returns the most recent write (or an error). (More precisely: linearizability.)
- **A — Availability:** every request receives a non-error response (though it may not be the latest).
- **P — Partition tolerance:** the system continues operating despite arbitrary message loss between nodes.

In practice, network partitions are inevitable (networks drop packets; nodes crash and look like a partition). So **P is not optional** — you must tolerate partitions. The real choice is: **during a partition, do you prefer C or A?**

```
             Partition occurs
                   │
         ┌─────────┴────────┐
         ▼                  ▼
   Node A (side 1)   Node B (side 2)
   Can't reach B      Can't reach A

Choose C: refuse requests until partition heals → CP system
Choose A: serve requests with possibly stale data → AP system
```

**CP systems (prefer consistency during partition):** Raft-based stores — HBase, CockroachDB, etcd, Zookeeper. During a partition, the minority side stops accepting writes (it can't reach a quorum to commit). Clients on the minority side see errors or timeouts, not stale data.

**AP systems (prefer availability during partition):** DynamoDB (eventual consistency default), Cassandra (tunable, but typically eventual), CouchDB. During a partition, every node continues serving reads and writes independently, accepting that when the partition heals, conflicts must be resolved.

**CA is impossible:** if there's no partition tolerance, the system is simply unavailable during a network split — that's not a database, that's a failure mode.

> **CAP's real limitation:** it only covers one specific fault — a *total* partition. Real systems deal with partial failures, slow nodes (performance asymmetry is the most common issue, not binary up/down), and gray failures. CAP's binary framing doesn't capture this nuance.

---

## PACELC

PACELC (Abadi, 2012) extends CAP to the non-partition case:

**If a Partition: choose between Availability and Consistency (CAP)**
**Else (no partition): choose between Latency and Consistency**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PACELC Matrix                                       │
├──────────────────────┬──────────────────────┬──────────────────────────────┤
│ System               │ Partition: A or C?   │ Normal: L or C?              │
├──────────────────────┼──────────────────────┼──────────────────────────────┤
│ DynamoDB (eventual)  │ A                    │ L (high throughput, low lat)  │
│ Cassandra            │ A                    │ L                            │
│ CockroachDB          │ C                    │ C (serializable)             │
│ Spanner              │ C                    │ C (but high latency)         │
│ MySQL async replica  │ A                    │ L                            │
│ PostgreSQL (sync)    │ C (with quorum)      │ C                            │
└──────────────────────┴──────────────────────┴──────────────────────────────┘
```

The Else clause is the more commonly relevant: most of the time there's no partition, but strong consistency always adds latency (the commit must travel to a quorum before returning to the client). PACELC makes explicit that choosing consistency during *normal* operations is also a trade-off.

---

## Linearizability vs Eventual Consistency

These are the two ends of the consistency spectrum you actually encounter.

### Linearizability

A system is **linearizable** if every operation appears to take effect instantaneously at some point between its invocation and its response, and the order of effects is consistent with wall-clock time.

Concrete implication: if client A writes value X and client B subsequently reads, B always sees X (or something newer). There are no "time travel" reads.

```
Timeline:
A: ───── write X ─────────────────────────────────
B:              ─── read → must return X ─────────

If instead:
B:              ─── read → returns old value ─────  (NOT linearizable)
```

Systems that provide linearizability: Raft-based systems (CockroachDB, etcd), single-node PostgreSQL with serializable isolation, Google Spanner (with TrueTime).

Cost: every read must contact a quorum (or be served by a leader that's confirmed it still has authority — leader lease). This adds latency to reads, not just writes.

### Sequential Consistency

Weaker than linearizability: operations appear in some total order that's consistent with the per-process order, but not necessarily with wall-clock time. This allows a stale read if the read is from a process that hasn't seen the write yet.

### Eventual Consistency

The weakest useful guarantee: if no new updates are made, eventually all replicas converge to the same value. Does not say when; does not say what happens if two conflicting writes occur concurrently.

Systems: Cassandra default (tunable), DynamoDB default, most async replicated databases.

Practical implication: reads may return old data for an unbounded time after a write. The "eventually" is usually seconds (replication lag) but can be longer during failures.

### The Spectrum in Practice

```
Weakest ──────────────────────────────────────────────── Strongest
                                                               │
Eventual  →  Session (read-your-writes)  →  Causal  →  Linearizable
consistency    consistency                  consistency    consistency

Highest throughput / lowest latency ────► Lowest throughput / highest latency
```

For most OLTP applications, **causal consistency** (reads always see writes you've seen) is sufficient — you don't need full linearizability, which is unnecessarily expensive. The mistake is defaulting to eventual consistency everywhere and then being surprised when users see inconsistencies that can't be explained by natural delay.

---

## Distributed Transactions

A distributed transaction spans multiple nodes. The problem: a single COMMIT must be atomic across all of them.

### Two-Phase Commit (2PC)

2PC is the classic protocol. A **coordinator** node orchestrates; **participant** nodes execute.

```
Phase 1: PREPARE
───────────────────────────────────────────────────────────
Coordinator → Participant A: "Can you commit txn-123?"
Coordinator → Participant B: "Can you commit txn-123?"

Participant A: write WAL, acquire locks, reply "YES, I can"
Participant B: write WAL, acquire locks, reply "YES, I can"

Phase 2: COMMIT (all said YES)
───────────────────────────────────────────────────────────
Coordinator → Participant A: "COMMIT txn-123"
Coordinator → Participant B: "COMMIT txn-123"

Participant A: apply, release locks, reply ACK
Participant B: apply, release locks, reply ACK

Coordinator: txn-123 complete, respond to client
```

If any participant says NO in Phase 1:

```
Phase 2: ABORT
Coordinator → Participant A: "ABORT txn-123"
Coordinator → Participant B: "ABORT txn-123"
```

**The coordinator failure problem — why 2PC is "blocking":**

```
Phase 1 completes: both A and B said YES, wrote to their WAL
Coordinator crashes before sending Phase 2 COMMIT

State: A and B are locked. They wrote YES and are waiting.
They CANNOT commit on their own (they don't know if B also said YES).
They CANNOT abort on their own (coordinator might have sent COMMIT to B before crashing).

→ They BLOCK, holding locks, until coordinator recovers.
```

This is the **2PC blocking problem**: a coordinator failure after Phase 1 can hold locks for the duration of the recovery (seconds to minutes). For an online system processing payment transactions, this is a serious availability problem.

**Mitigations:**

1. **Distributed coordinator:** run the coordinator with Raft/Paxos so coordinator failure is handled by consensus (Google Spanner's approach — coordinator is itself a Paxos group).
2. **Cooperative termination protocol:** participants that have voted YES can query each other and abort if *none* of them has committed yet. This doesn't work if one participant has already committed, but reduces blocking in the common case.
3. **Timeout-based abort:** after a timeout, participants abort if no Phase 2 arrives — this is unsafe (the coordinator may have sent COMMIT to another participant) but some systems accept this risk.

**2PC is used by:** PostgreSQL's `PREPARE TRANSACTION` / `COMMIT PREPARED` (manual distributed transactions), Spanner (with Paxos coordinator), Vitess (MySQL sharding), CockroachDB internally (for cross-range transactions).

### Sagas

A **saga** breaks a long-running transaction into a sequence of local transactions, each with a **compensating transaction** that undoes the effect.

```
Booking saga:
  T1: Reserve flight    ─── if fails anywhere after ───► C1: Cancel flight reservation
  T2: Reserve hotel     ─────────────────────────────► C2: Cancel hotel reservation
  T3: Charge credit card ──────────────────────────────► C3: Refund credit card

Normal flow:    T1 → T2 → T3 (saga committed)
Failure at T3:  T1 → T2 → T3 fails → C2 → C1 (saga rolled back via compensation)
```

Sagas are **not ACID** — between T1 completing and T2 completing, another process can see the partial state (flight reserved, hotel not yet reserved). This is **BASE** (Basically Available, Soft state, Eventually consistent).

**Choreography vs Orchestration:**

| Style | How it works | When to use |
|-------|--------------|-------------|
| Choreography | Each service publishes events; others react | Loose coupling; hard to debug |
| Orchestration | One orchestrator calls each service in order | Easier to reason about; orchestrator is a SPOF |

Sagas are the dominant pattern in microservices for distributed business transactions because they avoid 2PC's lock-holding and coordinator-failure problems at the cost of temporary inconsistency and the complexity of writing compensating transactions.

> **Compensating transactions must be idempotent.** If the saga orchestrator retries C2 (cancel hotel) due to a timeout, the hotel service must handle receiving the same cancel request twice. This is easy to get wrong and is where most saga bugs live.

---

## NewSQL: Spanner and CockroachDB

NewSQL systems aim to give you the ACID properties and SQL interface of a traditional relational database at the write scalability of a sharded NoSQL system.

### Google Spanner

Spanner stores data in ranges (similar to partitions), each range owned by a Paxos group. Writes commit via the Paxos group for their range. Cross-range writes use 2PC where the coordinators are themselves Paxos groups (eliminating the coordinator SPOF).

**TrueTime:** Spanner exposes a `TT.now()` API that returns an interval `[earliest, latest]` bounding the true current time. GPS receivers + atomic clocks in every datacenter keep this interval tight (±~7ms globally). Spanner uses this to assign globally-ordered commit timestamps — it waits out the uncertainty interval before releasing a commit. This gives **external consistency** (real-time ordering across all transactions globally) without requiring all nodes to synchronize at commit time.

Cost: read latency is high (majority of Paxos group must respond), and cross-region transactions are expensive (Paxos spans continents).

### CockroachDB

Open-source Spanner-inspired. Uses Raft per range (similar to Spanner's Paxos per range). Global ordering via **hybrid logical clocks (HLC)** — a combination of physical time and a logical counter, which doesn't require atomic clocks but also doesn't provide Spanner's tight globally-serializable ordering.

CockroachDB's serializable isolation uses an **optimistic concurrency scheme with write-intent records:** a write leaves an "intent" on the key; readers see the intent and either push it (if they have higher priority) or wait. This is more aggressive than PostgreSQL's MVCC snapshot isolation in one way: transactions may be forced to retry when conflicts are detected at commit time.

---

## Decision Guide: Choosing the Right Engine

This is the part that separates system designers from ticket implementers. The choice is not "SQL vs NoSQL" — it's "what are my access patterns, consistency needs, and operational constraints?"

### SQL (RDBMS)

**Use when:**
- Data has complex relationships (joins are first-class)
- ACID transactions are required (financial systems, inventory management)
- Schema is relatively stable
- Team writes standard SQL and doesn't want to learn a new query language

**Engines:** PostgreSQL (OLTP + moderate OLAP), MySQL (OLTP), SQLite (embedded/testing)

**Scale ceiling:** vertical scaling + read replicas handles most OLTP loads. Horizontal write scaling requires a sharding layer (Vitess for MySQL, Citus for Postgres) which adds complexity. Above ~100K writes/sec on a single shard, you're fighting the system.

### Key-Value Stores

**Use when:**
- Access pattern is always by a single key (no range scans, no joins)
- Sub-millisecond reads at scale
- High write throughput

**Engines:** Redis (in-memory, single-threaded event loop; persistence optional), DynamoDB (managed KV+document with single-digit-millisecond SLA), Amazon ElastiCache, Aerospike (in-memory with SSD persistence)

**Avoid when:** you need to query by anything other than the primary key. "I'll just scan all keys" is never the answer.

### Document Stores

**Use when:**
- Entity structure varies per record (user profiles with different optional fields)
- Reads are always for a whole document (not partial projections)
- JSON is your natural schema

**Engines:** MongoDB, Firestore, Couchbase, DynamoDB (document mode)

**Common mistake:** using MongoDB because you "don't want to define a schema," then spending months fighting inconsistent documents, slow aggregations, and missing joins. Document stores have a schema — it's just implicit and inconsistently enforced.

### Wide-Column Stores (Big Table / Cassandra Model)

**Use when:**
- Time-series, audit logs, append-heavy write patterns
- You know your query patterns upfront (schema is query-driven)
- Need to write > 100K rows/sec across a cluster

**Engines:** Apache Cassandra, HBase, ScyllaDB (Cassandra reimplemented in C++), Bigtable (Google, managed)

**Model:** rows have a partition key and a clustering key. Everything is a lookup by partition key + range on clustering key. JOINs don't exist. Design your schema by working backwards from the exact queries you'll run.

### Time-Series Databases

**Use when:**
- Data is a stream of (timestamp, metric, value) tuples
- Query patterns are always time-range + tag filters + aggregate functions
- Retention policies (delete data older than 90 days) are a first-class need

**Engines:** InfluxDB, TimescaleDB (PostgreSQL extension — good if you already run Postgres), Prometheus (pull-based, local storage only), VictoriaMetrics (Prometheus-compatible, very efficient), Grafana Mimir (Prometheus at scale)

**Why not just use PostgreSQL?** TimescaleDB *is* PostgreSQL. For pure time-series, columnar storage with built-in downsampling and time-based partitioning outperforms row-oriented storage by 5–20× on write throughput and compression.

### Graph Databases

**Use when:**
- Your queries are inherently graph traversals: "find friends of friends who live in the same city and have bought the same product"
- The number of JOINs required in SQL grows with query depth (5-hop traversal = 5 JOINs)
- Relationship type diversity is high

**Engines:** Neo4j (Cypher query language), Neptune (AWS managed, supports Gremlin + SPARQL), Dgraph, JanusGraph

**When to use a graph DB vs storing a graph in PostgreSQL:** for up to ~5-hop traversals on data that fits on one node, PostgreSQL recursive CTEs work fine. When queries regularly traverse 10+ hops and data is 100M+ edges, a native graph engine's pointer-based adjacency lists beat repeated JOIN indexes significantly.

### Vector Databases

**Use when:**
- Storing embeddings from machine learning models
- Primary query: "find the K most similar vectors to this query vector" (approximate nearest neighbor search)
- Building semantic search, recommendation systems, RAG pipelines

**Engines:** Pinecone (managed), Weaviate, Qdrant, pgvector (PostgreSQL extension — best starting point if you already run Postgres and your scale is < 10M vectors), Milvus (large scale, standalone)

**Note:** pgvector with `ivfflat` or `hnsw` indexes handles tens of millions of vectors adequately. Move to a dedicated vector DB when approximate nearest neighbor query latency > 50ms at your required recall, or when your total vector count exceeds 100M.

### Search Engines

**Use when:**
- Full-text search with relevance ranking, stemming, fuzzy matching
- Faceted navigation (filter by multiple attributes simultaneously)
- Inverted index is the right data structure

**Engines:** Elasticsearch / OpenSearch (inverted index + JSON documents + aggregations), Typesense (fast, simpler), Meilisearch (developer-friendly, fast), Solr (older, Java-based)

**Warning:** Elasticsearch is not a database. It is an eventually consistent, eventually durable search index. Treat it as a read-optimized view of your source of truth, not as the source of truth itself. Lost documents during indexing failures are real and documented.

### Decision Matrix

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      ENGINE DECISION GUIDE                                      │
├───────────────────────────┬─────────────────────────────────────────────────────┤
│ Question                  │ → Points toward                                     │
├───────────────────────────┼─────────────────────────────────────────────────────┤
│ Need JOINs?               │ SQL (Postgres/MySQL/CockroachDB)                    │
│ Need ACID transactions?   │ SQL or NewSQL (CockroachDB/Spanner)                 │
│ Append-only at >100K/s?   │ Cassandra / ScyllaDB                                │
│ Time-series data?         │ TimescaleDB (if on Postgres) or InfluxDB/VictoriaM  │
│ Single-key lookup always? │ DynamoDB / Redis                                    │
│ Graph traversal queries?  │ Neo4j / Neptune (or Postgres CTEs for small graphs) │
│ ML embeddings / ANN?      │ pgvector (small) or Qdrant/Pinecone (large)         │
│ Full-text search?         │ Elasticsearch/Typesense alongside your primary DB   │
│ Everything else           │ Start with Postgres, migrate when you have the data │
└───────────────────────────┴─────────────────────────────────────────────────────┘
```

> **The "start with Postgres" rule.** PostgreSQL handles: full-text search (`tsvector`/`tsquery`), JSON documents (`jsonb`), time-series with TimescaleDB, graph traversals with recursive CTEs, vector search with pgvector, geospatial with PostGIS. For a team of < 20 engineers on a product with < 100M rows per table, staying on Postgres almost always beats the operational overhead of running five specialized engines. Add a specialized engine *when you have benchmarked proof* that Postgres can't meet your SLA — not before.

---

## Debugging Distributed Databases

### Split-Brain

**What it is:** a network partition causes both sides of a partition to believe they are the leader and accept writes independently.

```
Network partition at T=0:

     Side A (nodes 1,2)          Side B (nodes 3,4,5)
     ────────────────            ──────────────────────
     Leader: Node 1              Old leader (Node 1) unreachable
     Accepts writes              Elects new leader: Node 3
                                 Accepts writes
                                           ↑
                                 SPLIT-BRAIN: two leaders accepting writes
```

In Raft, this **cannot happen** because a leader requires a majority (N/2+1) to be elected. Side A (2 nodes out of 5) cannot elect a leader; only Side B (3 nodes out of 5) can. Node 1 on Side A will step down when it can't contact a majority during a lease renewal. Raft's majority quorum is the split-brain prevention mechanism.

For systems without a strict majority requirement (async replication, multi-leader), split-brain is a real risk:

```bash
# Detecting split-brain in a Cassandra cluster
nodetool ring         # shows token ownership; two nodes claiming same range = split-brain
nodetool status       # nodes should agree on who is UN (Up/Normal) vs DN (Down)

# In MySQL (Group Replication / Galera)
SHOW STATUS LIKE 'wsrep_cluster_size';   -- all nodes must agree on cluster size
SHOW STATUS LIKE 'wsrep_cluster_status'; -- must be 'Primary', not 'Non-primary'
```

**Resolution:** reconnect the partition; the split-brain resolution protocol merges diverged writes (if the system supports it) or sacrifices one side's writes (if it doesn't). For Raft-based systems, the minority side simply catches up when connectivity is restored.

### 2PC Coordinator Failure

**What it is:** the 2PC coordinator crashes after sending PREPARE to all participants (some of whom said YES) but before sending COMMIT or ABORT.

**Symptoms:**
- Long-lived locks on participant tables
- Transactions stuck in PREPARED state
- Blocking queries piling up
- Client timeouts on writes that should be fast

**Diagnosis in PostgreSQL:**

```sql
-- find all prepared transactions
SELECT gid, prepared, owner, database
FROM pg_prepared_xacts;

-- are they blocking anything?
SELECT pid, query, wait_event_type, wait_event, state
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';

-- check how old the prepared transactions are
SELECT gid, EXTRACT(EPOCH FROM (now() - prepared)) AS age_seconds
FROM pg_prepared_xacts
ORDER BY prepared;
```

**Resolution:**

```sql
-- if the coordinator will never recover and you know the transaction should commit:
COMMIT PREPARED 'txn-identifier-from-coordinator-log';

-- if it should abort:
ROLLBACK PREPARED 'txn-identifier-from-coordinator-log';
```

You must consult the coordinator's log to know which direction is correct — this is what makes 2PC coordinator failure a true operational incident, not just a retry.

**Prevention:** use a coordinator that's itself HA (Raft-based). CockroachDB does this internally. For application-managed 2PC, store coordinator state in a durable store (not just memory) so on restart it can resume Phase 2.

### Choosing the Wrong Engine

**The wrong engine shows up as:**

| Symptom | Likely wrong choice | Better fit |
|---------|--------------------|-----------:|
| Full table scans to answer basic queries | KV store used for relational queries | SQL |
| Developer time spent merging conflict objects | Multi-leader KV for transactional data | SQL with single-leader |
| Aggregation queries taking minutes | Row-oriented DB for analytics | Columnar DB (ClickHouse, BigQuery) |
| Elasticsearch data is "sometimes missing" | Using Elasticsearch as primary store | Use as secondary index only |
| Join performance degrades with graph depth | SQL for deep graph traversals | Graph DB |
| Cassandra reads require ALLOW FILTERING | Missing secondary index or wrong partition key | Redesign data model |

**Debugging the "slow Cassandra query":**

The most common Cassandra performance problem is a query that requires `ALLOW FILTERING` — meaning Cassandra must scan every partition to find matching rows. This is equivalent to a full table scan in a SQL database, except it's distributed and there's no optimizer to choose a better plan.

```sql
-- this forces a full cluster scan
SELECT * FROM events WHERE event_type = 'click' ALLOW FILTERING;

-- diagnosis: check if the table was designed for this query
DESCRIBE TABLE events;
-- if event_type is not the partition key or a clustering column, the schema is wrong

-- fix: create a table designed for this query
CREATE TABLE events_by_type (
  event_type TEXT,
  created_at TIMESTAMP,
  event_id UUID,
  payload TEXT,
  PRIMARY KEY (event_type, created_at, event_id)
) WITH CLUSTERING ORDER BY (created_at DESC);
```

Cassandra's query language (CQL) looks like SQL but isn't. It has no optimizer. Every query must be designed with the physical data layout in mind. If you find yourself writing `ALLOW FILTERING`, the schema needs to change, not the query.

---

## Checkpoint

You're solid on this module when you can:

1. Walk through Raft leader election: what triggers an election, what a candidate must prove to win, and why randomized timeouts prevent livelock.
2. Explain why Raft's majority-quorum rule prevents split-brain — and why a minority partition can't elect a leader.
3. State the CAP theorem in one sentence and name one CP database and one AP database, explaining the behavior of each during a network partition.
4. Extend CAP with PACELC: what's the else clause and why does it matter for normal-operation performance?
5. Contrast linearizability and eventual consistency with a concrete read-after-write example showing when each allows (or doesn't allow) a stale read.
6. Describe 2PC in both happy path and coordinator-failure path. Name the exact SQL commands to diagnose and resolve a stuck prepared transaction in PostgreSQL.
7. Explain what a saga is and why compensating transactions must be idempotent. Name the two orchestration patterns (choreography vs orchestration) and when to prefer each.
8. Given five engine options (SQL, Cassandra, DynamoDB, Elasticsearch, Neo4j), describe a system that needs each one and one that would be a mistake to run on each.
9. Diagnose an Elasticsearch "missing documents" incident and explain why using it as a source of truth is incorrect.
10. Read a `nodetool ring` output and identify a split-brain condition in a Cassandra cluster.

➡ Course complete — you now have the full database engineering stack: storage engines, indexing, transactions, query processing, replication, partitioning, and distributed systems. The next step is the challenge set: real workloads, real query plans, real cluster failures to debug.
