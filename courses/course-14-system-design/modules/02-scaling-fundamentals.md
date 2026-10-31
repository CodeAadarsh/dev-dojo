# Scaling Fundamentals

> **Module 02 · Course 14** — "Just scale out" is not a strategy. This module is the mechanics behind that phrase: what horizontal scaling actually requires, where it breaks, and how caching layers interact in ways that surprise engineers who've only ever deployed to a single box.

---

## Vertical vs. horizontal — the real tradeoff

| Dimension | Vertical (scale up) | Horizontal (scale out) |
|-----------|--------------------|-----------------------|
| Mechanism | Bigger machine: more RAM, CPU, faster disk | More machines: distribute the load |
| Complexity | Zero — same code, bigger box | High — distributed state, partial failure, consensus |
| Cost curve | Superlinear above ~64 cores (spot price on 128-core machines is punishing) | Linear — commodity instances |
| Ceiling | Hard ceiling at the largest available instance | Effectively unlimited |
| Failure domain | Single point of failure | N machines, N independent failure domains |
| When to reach for it | DB primaries you can't shard yet; monoliths you can't split yet | Stateless app tier, workers, async consumers |

The practical heuristic: **vertical first, until the cost curve or the failure mode makes you stop.** Horizontal scaling is complexity you pay for in code, in ops, and in debugging time. Don't pay that tax before you have to.

> A Postgres primary can be vertically scaled quite far — a 16-core, 128 GB RAM machine with NVMe handles 50K–100K simple queries/sec. If you're below that, sharding is premature optimization. When you hit the ceiling, consider a read replica before a shard.

---

## Stateless services: the prerequisite for horizontal scaling

A stateless service is one where **no in-memory or local-disk state affects the response to the next request.** That means:

- No session data in local memory
- No files written to local disk that subsequent requests depend on
- No business logic tied to a specific process or connection

If you violate this, you cannot freely route requests across nodes. You get **sticky sessions** — a specific user must always land on the same machine. This means your load balancer is no longer balancing: it's doing affinity routing, and one node can be overloaded while others are idle.

### What "stateless" looks like in practice

```python
# Stateful — DON'T DO THIS in a horizontally-scaled service
_cart_cache: dict = {}   # module-level dict: dies on restart, never shared across replicas

@app.get("/cart/{user_id}")
def get_cart(user_id: str):
    return _cart_cache.get(user_id, [])   # only this process knows about this user's cart
```

```python
# Stateless — all state lives in an external store
import redis

r = redis.Redis(host="redis-cluster", port=6379)

@app.get("/cart/{user_id}")
def get_cart(user_id: str):
    raw = r.get(f"cart:{user_id}")
    return json.loads(raw) if raw else []   # any replica, same result
```

The rule: **if you'd lose something by killing the process, that something doesn't belong in the process.** Move it to a shared store. Every deployment, every auto-scaling event, every OOM kill is a process restart — stateful in-process data disappears.

---

## Load balancing

### L4 vs. L7

| Layer | What it sees | What it can do | TLS |
|-------|-------------|----------------|-----|
| L4 (TCP/UDP) | IP address + port | Route by connection; round-robin at the TCP level | Cannot inspect contents; TLS passthrough |
| L7 (HTTP) | Full HTTP request: method, path, headers, cookies | Route by path prefix, header value, canary weight; modify headers; rate limit per endpoint | Terminates TLS; re-encrypts to backend |

L4 is faster — less work per packet, no HTTP parsing. L7 is smarter. In practice:

- **L4 at the edge:** cloud provider NLB for raw throughput, DDoS mitigation, TCP-level routing
- **L7 inside:** Nginx, Envoy, your service mesh sidecar for routing logic, retries, observability

### Load-balancing algorithms

| Algorithm | How it works | Use when |
|-----------|-------------|---------|
| Round-robin | Requests cycle 1 → 2 → 3 → 1… | Homogeneous backends, short-lived requests |
| Least connections | New request goes to backend with fewest active connections | Long-lived connections (WebSocket, gRPC streaming), heterogeneous request durations |
| Weighted round-robin | Round-robin with a weight per backend | Rolling deploys — give the new version 10% traffic; ramp up |
| IP hash | `hash(client_ip) % n_backends` | When you *must* have affinity (stateful app you can't fix right now); accept skewed load |
| Power of two choices (P2C) | Pick 2 backends at random, route to the less-loaded one | Large fleets — less herd behavior than least-connections; widely used in Envoy |

**Don't default to round-robin for everything.** A 1-second database query and a 1-millisecond health-check endpoint both count as "one request" to a round-robin balancer. On backends with widely varying request durations, use least-connections.

### Health checks and the thundering herd on restart

When a backend restarts, it takes time to warm up — JVM JIT compilation, connection pool fill, in-process LRU cache cold. A naive L7 health check starts sending traffic the moment the process returns `200 OK` on `/healthz`. You get a **thundering herd** of cold requests landing on a single warm process with an empty cache.

Fix: a startup probe (Kubernetes `startupProbe`) that delays readiness, or a configurable warm-up window in the load balancer. Without it, every rolling deploy is a p99 spike.

---

## Caching layers

There are four distinct cache layers between a user and your database. Each has different invalidation semantics. Treat them as a stack, not alternatives:

```
Client (browser)
  ↓  HTTP Cache-Control / ETag
CDN / Edge nodes
  ↓  origin cache headers
Application tier (Redis, Memcached)
  ↓  cache-aside / write-through
Database (buffer pool, query cache)
```

### Layer 1: Client cache

HTTP `Cache-Control` headers control whether the browser caches and for how long:

```
Cache-Control: public, max-age=86400          → CDN and browser, 1 day
Cache-Control: private, max-age=3600          → browser only (personal data), 1 hour
Cache-Control: no-store                       → no caching (financial data, CSRF tokens)
ETag: "abc123"                                → conditional GET: only re-download if changed
Cache-Control: immutable, max-age=31536000    → fingerprinted asset — never expires
```

The principal trap: **versioned static assets should have `immutable, max-age=31536000`** — never expire until the URL changes. Your `index.html` entry point should have `no-cache` (always revalidate); your `app.a3f9c2.js` bundle should be immutable.

### Layer 2: CDN cache

A CDN is a geographically distributed reverse proxy. It caches content at edge nodes, serving it from 10–50 ms away instead of 200+ ms to your origin.

CDN cache invalidation is the hard part: most CDNs purge by URL, not by tag. This forces you into:

- **Cache-busting URLs** for static assets (fingerprinted filenames like `app.a3f9c2.js`)
- **Short TTLs + stale-while-revalidate** for dynamic content:

```
Cache-Control: s-maxage=60, stale-while-revalidate=3600
```

This tells the CDN: serve as fresh for 60 seconds, then serve stale while fetching a background refresh. Users see fast (possibly stale) responses; origin load is bounded by the revalidation frequency.

### Layer 3: Application cache (Redis / Memcached)

Three patterns, each with a different consistency model:

**Cache-aside (lazy loading)**

```
1. Request arrives.
2. Check cache. Hit → return. Miss → continue.
3. Read from DB.
4. Write result to cache with a TTL.
5. Return.
```

Simplest. Downside: on a cache miss, the first request pays the full DB cost. On cold start (or after a cache flush), all requests miss simultaneously → **cache stampede** (see Common Mistakes below).

**Write-through**

```
1. Write arrives.
2. Write to DB (source of truth).
3. Write to cache.
4. Return.
```

Cache is always warm for reads. Downside: every write pays double latency (DB write + cache write). Acceptable when writes are infrequent and read latency is the priority.

**Write-behind (write-back)**

```
1. Write arrives.
2. Write to cache only. Return immediately.
3. Async: flush dirty cache entries to DB in batch.
```

Lowest write latency. Highest durability risk — a cache crash before the flush loses data. Only use when you can tolerate some data loss: analytics counters, view counts, recommendation scores. Never for financial transactions.

### Layer 4: Database buffer pool

The DB engine's own in-memory cache. For Postgres it's `shared_buffers` (default 128 MB; should be ~25% of RAM). For MySQL/InnoDB, the `innodb_buffer_pool_size`. The DB is already caching. An application cache on top only pays off when:

- Your working set is too large for the DB's buffer pool
- You're doing expensive computations (multi-table joins, aggregations) whose results are reusable
- DB connections are the bottleneck — each Postgres backend is an OS process; 500 connections is expensive

### Cache invalidation strategies

| Strategy | Mechanism | Tradeoff |
|----------|-----------|----------|
| TTL expiry | Entry expires after N seconds | Simple; always some staleness window |
| Write-through | Invalidate or overwrite on every write | Consistent; write latency penalty |
| Event-driven | Application fires an invalidation event on write (pub/sub) | Consistent; adds pub/sub infrastructure complexity |
| Cache-busting | Key/URL includes a version hash or timestamp | Immutable entries; requires key management |

> **The golden rule:** cache what is expensive to compute, changes infrequently, and can tolerate some staleness. Cache an ML recommendation score. Do not cache a payment balance.

---

## Read replicas

A read replica streams committed transactions from the primary via replication log (WAL streaming in Postgres, binlog in MySQL) and applies them asynchronously. Your application reads from replicas and writes to the primary.

```
Application
     │
     ├── writes ──→ Primary (Postgres, us-east-1a)
     │                │
     │                │  WAL stream (async replication)
     │                ├──→ Replica 1 (same AZ)
     │                └──→ Replica 2 (cross-AZ)
     │
     └── reads  ──→ Replica 1 | Replica 2
```

The catch: **replication lag.** A replica is typically 10 ms–10 s behind the primary depending on write volume and network RTT. This means:

- You cannot read-your-own-writes from a replica without version tracking
- A write burst spikes replication lag, making replicas transiently more stale
- A replica that falls too far behind gets excluded from the read pool and falls further behind

**Read-your-writes consistency on top of replicas:** route any read that *immediately follows a write* from the same session to the primary. Implement this with a version token in the session cookie: on write, record the primary's LSN (log sequence number); on the subsequent read, if the target replica's LSN is below the session's, route to primary instead.

---

## The distributed N+1

The classic ORM N+1 problem (one query per row in a result set) is well-known. The distributed version is subtler and nastier:

```python
# N+1 over a remote cache — visually looks fine
users = db.query("SELECT id FROM users WHERE org_id = 42")   # returns 500 rows

for user in users:
    profile = redis.get(f"profile:{user.id}")   # 500 sequential round-trips at ~1 ms each = 500 ms
```

Each `redis.get` is a network call. 500 sequential network calls at 1 ms each is 500 ms — a wall of latency invisible in local development (where Redis is localhost) but critical in production (where Redis is across a datacenter).

Fix: use a batch API.

```python
ids = [u.id for u in users]
profiles = redis.mget([f"profile:{uid}" for uid in ids])   # one round-trip, ~2 ms regardless of N
```

The rule: **any loop that makes an I/O call inside it is a red flag.** Replace with a batch or bulk API wherever one exists. Where one doesn't, rethink the data model — co-locate the data, denormalize, or use a join rather than a loop.

---

## Common Mistakes

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| Horizontal scaling added cost but didn't reduce latency | In-process state (module-level dict, local queue) forces sticky sessions; requests effectively serialize | Audit for module-level mutable state; move all shared state to Redis or the DB |
| Cache hit rate is 95% in staging, 12% in production | Staging used a tiny, repetitive synthetic workload; production has long-tail access patterns the LRU evicts | Profile the actual production access pattern; cache aggregated or pre-computed results rather than individual rows if long-tail access dominates |
| Cache hit rate collapses on every deploy | All keys have the same TTL set at startup — they expire simultaneously (cache stampede) | Add TTL jitter: `TTL = base_ttl + random(0, base_ttl * 0.2)` so keys expire spread across a window |
| One load-balanced node is overloaded; others idle | IP hash with skewed distribution, or a "whale" client from a corporate NAT with many users behind one IP | Switch to least-connections; use IP hash only when affinity is genuinely required, and accept the skew risk explicitly |
| Single-writer bottleneck: writes queue behind the one DB primary despite adding replicas | Read scale-out applied to a write-bound workload — replicas help nothing here | Shard writes, or decouple the write path with a queue (writes are async; DB is updated out-of-band) |
| Read replicas return stale data for a write the user just submitted | Not tracking session causality; reads go to replicas with no version check | Route the write and the immediate subsequent read to the primary; or implement read-after-write consistency with an LSN token in the session |

> **War story.** During a SAP AI Core observability sprint we added Redis caching to a log aggregation API to reduce Postgres load. Cache hit rate looked great in staging — 95%. In production it was 12%. The difference: staging ran a tiny synthetic workload where the same log IDs were queried repeatedly. Production had 10 million distinct log entries with long-tail access patterns, and the LRU cache was constantly evicting entries it had just loaded, before any second request for the same key arrived. The fix wasn't a bigger cache — it was switching from caching individual log entries to caching pre-aggregated summaries by tenant and time window. A much smaller, much more reusable result set. Before you size a cache, profile the re-request rate: what percentage of your keys get requested again within the TTL window? If it's below ~50%, the cache is spending most of its memory on entries that will never be reused.

---

## Checkpoint

Before moving on, answer these without notes:

1. Name two situations where vertical scaling is the right first choice before reaching for horizontal.
2. Explain what makes a service "stateless" and give a concrete code example of the violation and the fix.
3. Compare L4 and L7 load balancing: what information does each layer see, and what does that enable?
4. Explain cache-aside vs. write-through: the mechanism and when you'd choose each.
5. What is a cache stampede, what causes it, and what is the TTL jitter fix?
6. Read replicas handle reads. Why can't you always route all reads to a replica immediately after a write?
7. What is the distributed N+1 pattern and how do you eliminate it?
8. A service has sticky sessions enforced by IP hash. The team wants to scale out horizontally. What breaks and what must change?

→ Next: **Data at Scale** — SQL vs. NoSQL vs. time-series vs. blob, indexing internals, sharding strategies and hot shards, replication consistency models, and why CAP is both correct and usually misapplied.
