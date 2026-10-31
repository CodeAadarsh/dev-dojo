# Solution — Design a URL Shortener

The flag is `KUBE{url_shortener_designed}`.

Below is a reference design that passes `verify.sh` and defends each choice at interview depth.

---

## Requirements

**Functional:**
- Shorten a long URL to a 7-character code (e.g. `https://sho.rt/aB3xZ7k`).
- Redirect `GET /{code}` to the original URL.
- Optional: custom slugs, expiry (TTL), analytics (click count).
- Out of scope (v1): authentication, per-user URL management.

**Non-functional:**
- Scale: 100M DAU, 100:1 read:write ratio.
- Write QPS: ~11 500/sec (100M × 10 URLs / 86 400s — using Course 14 Challenge 01 math).
- Read QPS: 1 150 000/sec (100× write QPS).
- Latency: redirect ≤ 10ms p99 (cached), ≤ 100ms p99 (cache miss).
- Availability: 99.99% (four nines).
- Consistency: eventual for analytics; strong for URL existence (no redirect to a deleted URL).

---

## Capacity

| Metric | Derivation | Value |
|--------|-----------|-------|
| Writes/sec | 100M × 10 / 86 400 | ~11 500 |
| Reads/sec | 11 500 × 100 | ~1 150 000 |
| Avg URL size | long URL 200B + code 7B + metadata ~50B | ~260 B |
| Storage/year | 11 500 writes/s × 260B × 86 400 × 365 | ~94 TB/year |
| Write bandwidth | 11 500 × 260B | ~3 MB/s |
| Read bandwidth | 1 150 000 × 260B | ~300 MB/s |

94 TB/year is manageable on a sharded PostgreSQL cluster with tiered storage. The read bandwidth (300 MB/s aggregate) makes a cache layer mandatory.

---

## API

### POST /shorten

```
POST /shorten
Content-Type: application/json

{ "url": "https://example.com/very/long/path?with=params", "ttl_days": 90 }

201 Created
Location: https://sho.rt/aB3xZ7k
{ "code": "aB3xZ7k", "short_url": "https://sho.rt/aB3xZ7k", "expires_at": "2024-09-01T00:00:00Z" }
```

- `400` for a non-URL payload.
- `409` if a custom slug is already taken.

### GET /{code}

```
GET /aB3xZ7k

302 Found
Location: https://example.com/very/long/path?with=params
```

Use **302 (temporary redirect)** in v1. A **301 (permanent redirect)** is cached by the browser indefinitely — once issued, you can never change the destination. Use 301 only after you have proven the URL is permanent and you want to offload redirect traffic from your servers entirely.

- `404` if the code does not exist or has expired.

---

## Data Model

**Table: `urls`**

```sql
CREATE TABLE urls (
    id          BIGINT PRIMARY KEY,        -- internal counter-based ID
    code        VARCHAR(10) NOT NULL UNIQUE,   -- base62-encoded id
    long_url    TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ,
    click_count BIGINT NOT NULL DEFAULT 0
);
CREATE INDEX urls_code_idx ON urls (code);
```

**Database: PostgreSQL** — ACID guarantees on writes, simple point-key reads, mature tooling, proven at tens of billions of rows with sharding.

### ID generation strategy: base62 counter

A distributed counter (Redis `INCR` on a `global:url_counter` key, or a PostgreSQL sequence) emits a monotone integer. Encode it in base62 (digits 0–9 + a–z + A–Z):

```python
BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

def encode(n: int) -> str:
    result = []
    while n:
        result.append(BASE62[n % 62])
        n //= 62
    return "".join(reversed(result)) or "0"
```

- 7-char base62 → 62^7 ≈ 3.5 trillion unique codes. At 11 500 writes/sec that is ~9 600 years before exhaustion.
- No collision — the counter is strictly monotone. No re-roll logic needed.
- **Trade-off:** exposes write volume to anyone who shortens two URLs in a row. Acceptable here (TinyBit is a public service; rate-limit if this matters).
- Counter bottleneck above ~50K writes/sec: shard the counter space (odd/even, or epoch+worker prefix, or switch to UUID v7 which is time-sortable and random-suffix).

---

## Scaling

### Cache layer

Cache the `code → long_url` mapping in Redis. Every redirect read hits Redis first.

- **Key:** `url:<code>`, **Value:** `long_url`, **TTL:** matches `expires_at`.
- Cache hit ratio target: ≥ 99% (reads are Zipf-distributed — top 1% of URLs absorb 80% of reads).
- On a cache miss: read from DB, write back to cache, return redirect.
- On URL expiry: let TTL evict the key naturally; set `expires_at` as the Redis TTL on write.

### Hot-key handling

A viral URL (e.g. a news story) can hit the same Redis key at millions of RPS, exceeding a single Redis node's throughput. Mitigations:

1. **Local in-process LRU cache** (100 ms TTL, top-N keys) in front of Redis — absorbs the spike without a network hop.
2. **Read replica sharding** — consistent-hash the code to one of N Redis replicas for reads.
3. **Probabilistic early expiration** (PER) — before the key expires, a random fraction of requests go to the DB and refresh the cache, preventing a thundering herd on expiry.

### Horizontal read scaling

The redirect service is stateless; run 10–100 replicas behind a load balancer. They share the Redis cluster and DB read replicas. Scale the redirect tier independently of the write tier.

### Write bottleneck

At 11 500 writes/sec a single Redis `INCR` node handles ~200K ops/sec — no bottleneck in v1. At 10× scale, pre-allocate counter ranges to each write service instance (e.g. instance A gets IDs 1–10 000, then fetches 10 001–20 000). This removes the per-write round-trip to Redis.

The DB write path (single primary in v1) becomes the bottleneck around 50–100K writes/sec. Shard by code prefix (hash-sharded, 4–16 shards) or move to a horizontally scalable store (Cassandra, Vitess) for the URL table.

---

## Common mistakes

| Mistake | Why it fails |
|---------|-------------|
| Using MD5/SHA truncated without collision detection | 7-char hex = 16^7 ≈ 268M codes; birthday collision at ~16K URLs — far too small |
| Choosing 301 redirect unconditionally | Browser caches it forever; you lose the ability to update or expire the link |
| No cache layer | 1.15M read RPS will destroy a DB |
| Monotone counter on a single RDBMS sequence at 100K+/s | Sequence becomes the write bottleneck |
| Storing the long URL in the code (reversible encoding) | Leaks the destination in the short URL; makes custom slugs impossible |

> **War story.** A team I audited at SAP built an internal URL shortener with MD5-truncated-to-6-hex IDs. At 80K internal links, they started seeing silent redirects to the wrong URL because two different long URLs hashed to the same prefix. The fix was to add a collision-retry loop — which worked, but they never changed the ID scheme. Three months later, at 500K links, retry rate was 4%. Base62 counter would have taken 30 minutes to implement and scaled to trillions without ever colliding.
