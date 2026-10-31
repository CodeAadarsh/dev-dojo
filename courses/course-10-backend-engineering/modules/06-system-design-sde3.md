# System Design (SDE-2 → SDE-3)

> **Module 06 · Course 10** — System design interviews are often treated as an art form of vague diagrams. This module treats them as engineering: specific tradeoffs with measurable consequences. The goal isn't to memorize patterns; it's to internalize the numbers and forcing functions so your design choices are derived, not recalled.

You've shipped services. This module is about why the designs that work at 1k req/s break at 100k req/s, and how to reason through the change in advance.

---

## Back-of-envelope capacity — numbers you must know

Design decisions without numbers are opinions. Commit these to memory (powers of 2 approximate):

| Quantity | Value |
|----------|-------|
| L1 cache access | 1 ns |
| L2 cache access | 4 ns |
| RAM access | 100 ns |
| SSD sequential read (1MB) | 1 ms |
| HDD sequential read (1MB) | 20 ms |
| Round-trip in same datacenter | 0.5 ms |
| Round-trip cross-region | 150 ms |
| SSD random read (4KB) | 0.1 ms |
| gzip 1MB | 10 ms |

Storage math: 1 million users × 1 KB metadata = 1 GB (trivial). 1 billion users = 1 TB. 1 billion users × 100 KB profile data = 100 TB. 100 TB / 4TB-SSD = 25 nodes just for storage, before replication.

**Worked example: URL shortener.**

```
Assumptions:
  100M new URLs/day → 1200/s writes
  Read:write ratio = 100:1 → 120k reads/s
  URL lifespan 5 years → 100M * 365 * 5 = 182B URLs total
  Each URL: 500 bytes → 182B * 500B = 91 TB total storage

Write throughput: 1200/s → single Postgres handles this (< 10k writes/s is typical ceiling)
Read throughput:  120k/s → needs caching (Redis) and read replicas

Cache sizing: top 20% of URLs get 80% of traffic (Zipf distribution)
  Cache 20% of daily URLs → 20M * 500B = 10 GB Redis → fits comfortably

Bandwidth:
  writes: 1200/s * 500B = 600 KB/s (negligible)
  reads:  120k/s * 500B = 60 MB/s (modest, single link handles it)
```

This analysis tells you: you need caching and read replicas, but you don't need sharding at this scale. That's a real design conclusion, not a guess.

---

## Horizontal scaling

**The stateless service contract.** A service is horizontally scalable if any request can be handled by any instance without coordination. This means:
- No in-process session state
- No in-process cache that must be consistent across instances
- No server-side WebSocket state that must survive a restart

Breaking any of these requires either sticky sessions (kills the scaling property) or externalizing the state (Redis for sessions, cache; a broker for WebSocket fan-out).

**Vertical vs horizontal:**

| | Vertical (scale-up) | Horizontal (scale-out) |
|--|---------------------|----------------------|
| How | Larger instance (more CPU/RAM) | More instances |
| Limit | Largest available VM / server | Theoretically unbounded |
| Cost curve | Superlinear (3× CPU costs 5×) | Linear (3× instances costs 3×) |
| Failure domain | Single point | N redundant |
| Works well for | Databases (shared memory matters); stateful services | Stateless API servers; job workers |

The practical path: vertical scale first (it's simpler), then horizontal once the largest reasonable instance isn't enough. Don't distribute what you can fit on one machine — distributed adds latency, failure modes, and operational burden.

---

## Load balancing

L4 vs L7:

| | L4 (TCP/UDP) | L7 (HTTP/gRPC) |
|--|-------------|----------------|
| Sees | IP + port | Full request headers, URL, body |
| Routing | IP hash, round-robin | Header value, path, host, cookie |
| TLS | Pass-through or terminate | Must terminate to read headers |
| Cost | Low (no parsing) | Higher (parsing + TLS add latency) |
| Examples | AWS NLB, LVS, HAProxy (TCP mode) | AWS ALB, NGINX, Envoy |

**Algorithms:**

- **Round-robin.** Simple, works when all backend instances have equal capacity. Doesn't account for in-flight request count.
- **Least connections.** Route to the instance with the fewest active connections. Better than round-robin for long-lived connections (gRPC streams, WebSockets).
- **Consistent hashing.** Map request keys (user ID, session ID) to a ring; each key always routes to the same backend node (with bounded rebalancing on node add/remove). Use for caches where affinity improves hit rate, or stateful backends.

**Health checks.** Every load balancer must probe backends. Distinguish:
- **Passive:** LB observes real traffic errors, marks backend unhealthy after N failures.
- **Active:** LB sends synthetic probes (`GET /healthz`) on an interval. Catches backends that are up but returning errors on real traffic.

The failure mode of missing health checks: the LB keeps routing to a dead backend for the TTL of the health window, causing a fraction of requests to fail until the operator intervenes.

---

## Replication & read replicas

**Synchronous replication:** primary waits for at least one replica to acknowledge the write before returning to the client. Zero data loss on primary failure. Latency penalty = cross-AZ round-trip (~1ms same region, ~50ms cross-region). Postgres `synchronous_commit = on` + `synchronous_standby_names`.

**Asynchronous replication:** primary returns immediately; replicas catch up. Lower latency; on primary failure, replicas may be behind (replication lag). The promoted replica may serve slightly stale data as reads after a failover. `synchronous_commit = off` or `async` replicas.

**Replication lag** is the worst practical issue with read replicas. A write on the primary is visible to a reader on the replica after lag milliseconds. If your service writes then immediately reads (read-your-writes consistency), a lag of even 50ms can make the read return stale data:

```
t=0ms:  client writes user.email = "new@example.com" → primary
t=10ms: client reads user.email → replica (lag: 20ms) → returns "old@example.com"
```

Strategies:
- Read from primary for requests that immediately follow a write (or for any write-amplified read path).
- Track write timestamp; for N seconds after a write, route reads to primary.
- Accept eventual consistency and build the UI to handle it (optimistic updates).

```bash
# Postgres: check replication lag (on primary)
SELECT
  application_name,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
  write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

---

## Sharding / partitioning

Sharding splits data across multiple database nodes when a single node can't handle the volume. Each shard holds a subset of rows.

**Sharding key selection** is the hardest part. The key must:
- Have high cardinality (many distinct values)
- Distribute writes uniformly (no hot shards)
- Align with your most common query pattern (queries that span shards are expensive)

Tradeoffs:

| Key | Uniform? | Co-locates related data? | Common mistake |
|-----|----------|--------------------------|----------------|
| User ID (hash) | Yes | All user's data together | Tenant-level hotspot if one user is huge |
| Created_at (range) | No — recent data hot | Time-range queries efficient | All writes go to the latest shard |
| Geography | Depends on user distribution | Regional queries fast | Uneven user distribution |
| Random UUID | Yes | No — queries scatter across shards | Cross-shard JOINs and aggregations break |

**Range vs hash sharding:**
- **Range:** shard 1 holds IDs 0–999999, shard 2 holds 1000000–1999999. Range scans are efficient; range hotspots (sequential inserts) are common.
- **Hash:** shard = hash(key) % num_shards. Uniform distribution; range scans are impossible.

**Consistent hashing** (used in Cassandra, DynamoDB): map both keys and nodes onto a ring; key routes to the nearest clockwise node. Adding/removing a node only remaps ~1/N of the keys (vs hash-mod which remaps ~all keys). Essential for systems that add shards under load.

**Re-sharding** (increasing shard count) is painful: you must migrate data while the system is running, update routing logic, and handle in-flight requests during the transition. Techniques: double-write during migration, use a virtual shard layer (map N virtual shards to M physical shards; only remapping virtual→physical changes on re-shard).

---

## Consistency — CAP and PACELC

**CAP theorem:** in the presence of a network partition, choose Consistency *or* Availability. Since partitions in distributed systems are not optional, you always choose CP or AP.

- **CP systems** (Zookeeper, etcd): on partition, refuse writes/reads that can't be answered consistently. Return errors rather than stale data. Correct at the cost of availability.
- **AP systems** (Cassandra, DynamoDB in default mode): on partition, serve potentially stale data. Available at the cost of consistency.

**PACELC** extends CAP to the normal (no partition) case: even when the network is healthy, there's a tradeoff between **L**atency and **C**onsistency. A write that waits for quorum acknowledgement (consistency) takes longer than a write that returns after the primary acknowledges (latency). Most real systems operate in the PAC+ELC space.

**Consistency models (weakest to strongest):**

| Model | Guarantee | Example |
|-------|-----------|---------|
| Eventual consistency | All replicas converge given no new writes | Cassandra default, DynamoDB with DAX |
| Read-your-writes | You always see your own writes | Postgres with primary reads after write |
| Monotonic reads | Once you read a value, you never see older values | Session-based routing to replica |
| Bounded staleness | Reads lag by at most T seconds | Cosmos DB "bounded staleness" |
| Strong / linearizability | Every read sees the most recent write; operations appear instantaneous | Spanner, etcd |
| Serializability | Concurrent transactions behave as if they ran serially | Postgres `SERIALIZABLE` isolation |

Linearizability + serializability (called "strict serializability") is the strongest guarantee and the most expensive. For financial operations: you want at least serializability. For a social media like count: eventual consistency is fine.

---

## Caching tiers

```
Request
   │
   ▼
[L1: in-process]  ~100ns   — JVM heap, Python dict, Node.js Map
   │ miss
   ▼
[L2: distributed]  ~1ms    — Redis, Memcached (shared across instances)
   │ miss
   ▼
[L3: CDN / edge]  ~10ms    — Cloudflare, Fastly (static + computed responses)
   │ miss
   ▼
[Origin DB / API]  ~10ms+
```

**Cache-aside (lazy loading):** application checks cache first; on miss, reads from DB, writes to cache, returns data. Simple; cache only holds accessed data; stale on write (must invalidate or TTL).

**Read-through:** cache layer handles misses by fetching from DB automatically. Simpler application code; cache warms automatically on first read.

**Write-through:** every write goes to cache AND DB synchronously. Cache is always warm; write latency doubles; wasted cache space for write-heavy data.

**Write-behind (write-back):** write to cache; batch-flush to DB asynchronously. Low write latency; risk of data loss if cache node dies before flush.

**Cache stampede (thundering herd).** When a popular cache key expires, many requests miss simultaneously and all fetch from the DB at once. Fix:
- **Mutex / lock:** first miss acquires a lock and fetches; others wait.
- **Probabilistic early expiration:** recompute the cache value before it expires (randomly), based on the computation cost and time-to-expiry. Prevents simultaneous expiry without locking.
- **Stale-while-revalidate:** return stale data immediately; refresh asynchronously.

```python
import time, random, math

def get_with_soft_expiry(redis_client, key, ttl, fetch_fn, beta=1.0):
    """XFetch probabilistic early expiration to prevent cache stampede."""
    cached = redis_client.get(key)
    if cached:
        value, expiry, delta = cached
        if time.time() - beta * delta * math.log(random.random()) < expiry:
            return value  # still "fresh" probabilistically
    value = fetch_fn()
    delta = time.time()                     # time to recompute
    redis_client.set(key, (value, time.time() + ttl, delta), ex=ttl)
    return value
```

---

## Microservices vs modular monolith

The industry overcorrected from monoliths to microservices and is now correcting back. The actual tradeoffs:

```
MODULAR MONOLITH
  OrderModule → [calls in-process] → InventoryModule
                                  → PaymentModule

  Latency:  function call (~µs)
  Errors:   exception (handled by the calling code)
  Deploys:  one artifact, one deploy
  Tracing:  one call stack
  Scaling:  all modules scale together

MICROSERVICES
  order-svc → [HTTP/gRPC] → inventory-svc
                          → payment-svc

  Latency:  network + serialization (~ms)
  Errors:   network failure, timeout, 500 (need retry/circuit breaker)
  Deploys:  three artifacts, three pipelines, three clusters
  Tracing:  distributed trace (needs Jaeger/Tempo + propagation)
  Scaling:  each service scales independently
```

Microservices are justified when:
- Services have fundamentally different scaling requirements (CPU-bound ML inference vs I/O-bound API)
- Services need different deployment cadences (hotfix payment without touching orders)
- Organizational boundaries require independent ownership (Conway's Law)
- A module genuinely needs different infrastructure (Python for ML, Go for high-throughput stream processing)

Microservices are unjustified when the only reason is "best practice." Starting a new product as microservices is almost always the wrong choice — you don't know the right boundaries yet, and getting them wrong means expensive re-slicing later.

**Strangler fig pattern** for migrating a monolith: route specific endpoints to a new service via the API gateway while the monolith handles the rest. Incrementally strangle the monolith endpoint by endpoint, verifying parity at each step. Never rewrite the whole thing at once.

---

## Debugging Distributed Systems

### Hot shard

**Symptom:** one DB shard (or partition, or cache node) has 10× the CPU/QPS of others. That shard becomes the global bottleneck. Overall system throughput is bounded by the hot shard's capacity.

**Cause → Fix:**

| Cause | Fix |
|-------|-----|
| Sequential key (created_at, auto-increment) → all new writes hit last range shard | Switch to hash sharding; or UUID v4 key |
| Specific user/tenant generates disproportionate volume | Dedicated shard for that tenant; or rate limit + per-tenant queue |
| Skewed hash function | Change hash function; add compound key (user_id + bucket) |
| Caching layer missing → all reads hit the shard | Add Redis cache-aside; check cache TTL isn't too short |

```bash
# find hot shard by comparing per-shard QPS (Postgres example with per-schema setup)
SELECT schemaname, calls, total_exec_time, mean_exec_time
FROM pg_stat_statements
ORDER BY calls DESC LIMIT 20;

# compare per-node metrics in your monitoring (Grafana, Prometheus)
# look for: p99 latency outlier, CPU outlier, active connections outlier
```

### Cascading failure

**Symptom:** one service goes slow; its callers time out and retry; retries amplify load on the slow service; callers' thread pools exhaust; callers start returning errors to their callers; the entire call graph fails top-to-bottom.

**Cause:** missing timeouts, missing circuit breakers, missing retry backoff. Callers keep trying while the dependency is degraded.

**Fix (in order of impact):**
1. **Timeout everywhere.** No call without a deadline.
2. **Circuit breaker.** When the dependency is failing, fail fast. Don't retry into a degraded downstream.
3. **Jittered backoff.** Retries spread over time, not clustered.
4. **Load shedding.** Under extreme overload, actively reject requests (HTTP 503) to protect the healthy capacity. A service that accepts 10k req/s but is processing 50k req/s will respond to none of them; one that sheds 40k and processes 10k will degrade gracefully.
5. **Bulkheads.** One slow dependency can't exhaust capacity for all requests.

```python
# minimal cascading-failure defense in one function
async def call_payment_svc(payload):
    if payment_breaker.state == "open":
        raise ServiceUnavailable("payment-svc circuit open")
    try:
        async with asyncio.timeout(2.0):           # hard deadline
            resp = await http_client.post(
                PAYMENT_SVC_URL,
                json=payload,
                timeout=httpx.Timeout(connect=0.5, read=1.5),
            )
        payment_breaker.record_success()
        return resp.json()
    except (asyncio.TimeoutError, httpx.HTTPError) as e:
        payment_breaker.record_failure()
        raise ServiceUnavailable(f"payment-svc failed: {e}") from e
```

### Split-brain

**Symptom:** a distributed system (database cluster, cache cluster, distributed lock service) has two subsets of nodes that can't communicate. Each subset believes it's the primary/leader and accepts writes. Data diverges.

**Cause:** network partition that splits the cluster. Each subset is available (AP behavior) but they're writing different values to the same keys.

**Prevention:**
- **Quorum writes/reads.** Require acknowledgement from a majority (⌊N/2⌋ + 1) of nodes. A minority partition can't satisfy quorum → rejects writes → sacrifices availability for safety (CP).
- **Fencing tokens.** Each lock lease or leader election includes a monotonically increasing fencing token. Storage backends reject writes with a token older than the highest seen — prevents a split-brain leader from writing after a new leader has been elected.
- **STONITH (Shoot The Other Node In The Head).** One partition forces the other offline (via a management API or power switch) before continuing. Brutal but unambiguous.

```bash
# Postgres: check replication topology and standby states
SELECT pid, application_name, state, sent_lsn, write_lsn, replay_lsn
FROM pg_stat_replication;

# etcd: check member health (split-brain detection)
etcdctl endpoint health --endpoints=http://node1:2379,http://node2:2379,http://node3:2379

# Redis Sentinel: check who is currently the primary
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
# run this from multiple nodes; if answers differ, split-brain
```

> **War story.** A team at my previous job ran a Redis Cluster for session data. They had 3 primary shards, each with 1 replica. A network partition isolated one primary from both other primaries but left it reachable to its own replica and to ~30% of app servers. The isolated primary continued accepting session writes. When the partition healed, Redis Cluster forced a failover — the replica of the isolated primary had been promoted to primary during the split, and the two primaries had diverged. Slot ownership reconciliation picked the replica's data as authoritative, silently dropping 8 minutes of session writes from the isolated primary. Users who had written data in those 8 minutes lost their sessions. The mitigation: Redis Cluster with `min-slaves-to-write = 1` (now `min-replicas-to-write`) — the primary refuses writes if it can't reach its replica, sacrificing availability for safety. The real lesson: test your partition scenarios before production finds them for you.

---

## Checkpoint

You're ready for SDE-2 → SDE-3 design conversations when you can, without looking anything up:

1. Estimate storage and read throughput requirements for a system with 100M DAU, each making 10 reads and 1 write per day, with 1 KB per record.
2. Explain why consistent hashing reduces the re-sharding migration cost compared to `hash(key) % N` sharding.
3. State the difference between linearizability and serializability, and name a real database that guarantees each.
4. Describe the cache stampede problem and two concrete fixes that don't involve locking.
5. Explain the conditions under which you'd choose a modular monolith over microservices for a greenfield product, and name the organizational signal that flips that decision.
6. Trace a cascading failure from initial symptom to full system degradation, and name the three defensive patterns that break the chain at different points.
7. Describe the split-brain failure mode in a Redis Cluster, the config parameter that trades availability for safety, and how fencing tokens prevent a stale leader from writing after a new election.

---

*This module closes the SDE-1 → SDE-2 → SDE-3 arc of Course 10. The system design vocabulary and back-of-envelope habits here are prerequisites for the architectural challenge track coming in Course 10's challenge set.*
