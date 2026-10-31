# Worked Designs

> **Module 06 · Course 14** — All the framework in modules 01–05 exists to be *applied*. This module walks five canonical system design problems end to end, using the same thought process you run in an interview: clarify requirements, back-of-envelope estimates, API design, data model, read/write path, deep dives, and the failure modes that interviewers probe for. Each design is self-contained and cross-references the relevant concepts from earlier modules.

One rule for every design below: **state your constraints before drawing boxes.** An interviewer asking "design a URL shortener" is not asking for the only right answer — they're watching whether you ask the right questions first.

---

## The Framework (one-minute recap)

1. **Clarify requirements** (functional + non-functional). Write them down; read-heavy vs write-heavy determines everything.
2. **Rough estimates**: scale, storage, bandwidth. Back-of-envelope; orders of magnitude only.
3. **API design**: endpoints, request/response shapes, auth boundary.
4. **Data model**: tables/collections, key access patterns, storage engine choice.
5. **Read path & write path**: draw the boxes, name the bottlenecks.
6. **Deep dives**: the one or two hardest sub-problems (the interviewer will push here).
7. **Failure modes & trade-offs**: explicitly call them out before the interviewer does.

---

## Design 1: URL Shortener

### Requirements

Functional: given a long URL, return a short code; given a short code, redirect to the long URL; optional: custom slugs, expiry, click analytics.

Non-functional: reads >> writes (100:1 read/write ratio typical); redirect latency < 10ms p99; 100M new URLs/day.

### Estimates

```
100M writes/day  = ~1,200 writes/s (peak ~3×: ~3,500 writes/s)
Read:write = 100:1 → 350,000 redirects/s at peak
URL entry: ~500 bytes (long URL avg 200 bytes + metadata)
100M/day × 365 × 5 years × 500B ≈ 90 TB storage
```

Conclusion: storage is manageable on a small cluster; read throughput demands heavy caching.

### API

```
POST /api/v1/shorten
  body: { url: "https://...", custom_slug?: "myslug", expires_at?: "2027-01-01" }
  response 201: { short_url: "https://sho.rt/abc123", slug: "abc123" }

GET /:slug          ← the hot path
  response 301/302: Location: <long_url>
  (301 = permanent, cached by browser; 302 = temporary, every redirect hits your service — use 302 if you want analytics)

GET /api/v1/stats/:slug
  response 200: { clicks: 423, last_clicked: "..." }
```

### Data Model

```sql
CREATE TABLE urls (
    slug        VARCHAR(8) PRIMARY KEY,   -- the short code
    long_url    TEXT NOT NULL,
    user_id     BIGINT,
    created_at  TIMESTAMPTZ DEFAULT now(),
    expires_at  TIMESTAMPTZ,
    click_count BIGINT DEFAULT 0
);
-- Index for reverse lookup (is this long URL already shortened?)
CREATE INDEX idx_urls_long_url ON urls(long_url);
```

### Write Path: Slug Generation

Option A — **Base62 counter**: an auto-increment ID (or a distributed counter via Redis INCR) converted to base62. ID 1 → `0000001`, ID 2 → `0000002`. Simple, sequential, no collision. Downside: predictable; easy to enumerate.

Option B — **Random base62**: generate 7 random chars, check collision, retry on collision. Collision probability is low (~1% after 20M entries with 7 chars = 62^7 = 3.5T space) but non-zero; keep a DB unique constraint as the guard and retry on `UNIQUE VIOLATION`.

Option C — **Hash of the long URL**: `base62(sha256(long_url)[:7])`. Deterministic — same long URL always yields the same slug, which deduplicates naturally. Downside: two different users expect separate analytics.

**In an interview: pick base62 counter** as the default (simple, no collision), add a 7-char prefix of a random salt if enumerability is a concern.

### Read Path

```
Client ──► CDN / Edge Cache ──► (cache miss) ──► API Gateway ──► Redis (slug → long_url)
                                                              └──► (cache miss) ──► Postgres
```

CDN cache the 301 redirect with a long TTL (popular slugs are fetched millions of times). Redis for hot slugs (LRU, ~10M slugs fit in a small Redis instance). Postgres as the source of truth. 99% of reads should be served from CDN or Redis.

### Deep Dive: Custom Slugs

Custom slugs create a reservation conflict: two users both want `sale`. Options: first-come-first-served with a unique constraint (simplest); or a slug marketplace (complex, out of scope). The unique constraint on `slug` in Postgres is sufficient — one of the two concurrent inserts will get a unique violation and retry with a generated slug.

### Deep Dive: Expiry

Don't delete rows in real time. Run a background job (daily cron or streaming tombstone): `UPDATE urls SET deleted_at = now() WHERE expires_at < now() AND deleted_at IS NULL`. The redirect path checks `expires_at` and returns 410 Gone if expired. Deletions are deferred because immediate delete under heavy write load creates hot-row contention.

### Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Using 301 for all redirects | Click analytics are bypassed (browser caches the redirect) | Use 302 when you need per-click analytics; accept the extra roundtrip |
| Storing click_count as a column with UPDATE counter++ | Write contention on a hot slug; deadlocks under load | Write clicks to a separate `click_events` table or a counter in Redis; aggregate asynchronously |
| Generating the same slug for different long URLs to "deduplicate" | Two users' analytics are merged; one user's expiry affects another's | One slug per (user, long_url) pair at minimum; deduplication only within the same user |
| No expiry check in the read path cache | Expired URLs still redirect after expiry | TTL the cache entry to `expires_at - now()`; or check `expires_at` on every cache hit |

---

## Design 2: News Feed (Push vs Pull)

### Requirements

Functional: a user sees a ranked feed of posts from people they follow; post creation; follow/unfollow.

Non-functional: 500M DAU; read-heavy (users refresh feeds frequently); write fan-out can be slow; feed reads should be < 200ms p99.

### Estimates

```
500M DAU × 5 feed reads/day = 2.5B reads/day = ~30,000 reads/s
10M posts/day = ~115 writes/s
Avg user follows 200 people; avg user has 200 followers
Celebrity: 50M followers; post creates 50M fan-out writes
```

### Push Model (Fan-out on Write)

When a user posts, immediately write the post ID into a **feed timeline table** for every follower.

```
Post created ──► Fan-out Worker ──► for each follower:
                                    INSERT INTO feed_timelines(user_id, post_id, created_at)
```

Pros: feed reads are O(1) — `SELECT * FROM feed_timelines WHERE user_id = ? ORDER BY created_at LIMIT 20`.
Cons: a celebrity with 50M followers creates 50M writes per post. At peak, this is O(followers × posts/s) = potentially billions of writes/s. Storage explodes for inactive users.

### Pull Model (Fan-out on Read)

No fan-out on write. Feed read assembles the feed at query time: for each person the user follows, fetch their recent posts, merge, rank, return top N.

```sql
SELECT p.* FROM posts p
JOIN follows f ON f.followed_id = p.author_id
WHERE f.follower_id = ? AND p.created_at > now() - interval '7 days'
ORDER BY p.score DESC LIMIT 20;
```

Pros: celebrities are cheap to write to (one post write).
Cons: feed reads are expensive — N JOINs, sorted merge of N streams. Latency degrades with follow count.

### The Hybrid (What Production Systems Use)

- **Normal users** (< ~10K followers): use push (fan-out on write). Writes are cheap; reads are O(1).
- **Celebrities** (> ~10K followers): skip the fan-out. When a celebrity's follower reads their feed, pull the celebrity's recent posts at read time and merge.

```
Feed Read:
  1. Read pre-computed timeline from feed_timelines (for normal followees)
  2. For each followed celebrity: fetch last 20 posts from posts table
  3. Merge and rank the combined list
  4. Return top 20
```

The merge at step 3 is an in-memory sorted merge — fast when the celebrity post list is small. Cache the celebrity post list with a short TTL.

### Data Model

```sql
CREATE TABLE posts (
    id          BIGINT PRIMARY KEY,         -- snowflake ID (time-ordered)
    author_id   BIGINT NOT NULL,
    content     TEXT,
    media_url   TEXT,
    score       FLOAT DEFAULT 0,            -- ranking signal; updated by ML job
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE feed_timelines (
    user_id     BIGINT,
    post_id     BIGINT,
    created_at  TIMESTAMPTZ,
    PRIMARY KEY (user_id, post_id)
);
-- This table is the "inbox" for push-model users; trimmed to last N days by a worker

CREATE TABLE follows (
    follower_id  BIGINT,
    followed_id  BIGINT,
    PRIMARY KEY (follower_id, followed_id)
);
```

### Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Pure push for all users | Celebrity post creates billions of writes; fan-out worker falls behind | Hybrid: pull for high-follower accounts |
| Not trimming feed_timelines | Table grows without bound; reads get slower | Background worker deletes rows older than 90 days |
| Ranking by created_at only (chronological) | Engagement collapses vs ranked feed | Separate the rank from the timestamp; store a score column; rank job runs asynchronously |
| Fan-out synchronous in the post write path | Post latency spikes with follower count; single follower fan-out on a celebrity would take minutes | Fan-out is always async via a message queue (post created event → fan-out worker) |

---

## Design 3: Chat System

### Requirements

Functional: 1:1 and group messages; message persistence; online/offline delivery; read receipts; typing indicators.

Non-functional: < 100ms message delivery p99 for online users; 100M DAU; messages stored for 7 years.

### Transport: WebSocket vs Polling vs SSE

| Transport | Latency | Server resources | Direction | Use for |
|---|---|---|---|---|
| Short polling | High (1-5s) | High (many wasted requests) | Client → server → client | Not acceptable for chat |
| Long polling | Medium (< 1s) | Moderate | Client → server (holds conn) | Fallback when WS unavailable |
| SSE (Server-Sent Events) | Low | Low | Server → client only | Notifications, not chat (unidirectional) |
| WebSocket | Low | Moderate (persistent conn) | Bidirectional | Chat — the right choice |

Each client opens a WebSocket connection to a **chat server**. Clients send messages over the WS; the server delivers to the recipient's WS if connected, otherwise stores for offline delivery.

### Architecture

```
Client A ──WS──► Chat Server 1 ──► Message Queue (Kafka) ──► Chat Server 2 ──WS──► Client B

Chat Server 1 does not know which server Client B is connected to.
It publishes the message to Kafka (topic: chat.messages).
All chat servers subscribe. The server that holds Client B's WS connection delivers it.

For group chat: one message → fan-out to N servers holding the group members' connections.
```

Presence routing: a **Redis hash** maps `user_id → server_id`. When a message arrives for User B, the sending server looks up which server holds B's connection and routes directly (pub/sub on a server-specific channel), bypassing the broadcast.

### Message Storage

```sql
CREATE TABLE messages (
    id          BIGINT PRIMARY KEY,           -- snowflake ID
    channel_id  BIGINT NOT NULL,              -- 1:1 or group channel
    sender_id   BIGINT NOT NULL,
    content     TEXT,
    media_url   TEXT,
    created_at  TIMESTAMPTZ DEFAULT now(),
    deleted_at  TIMESTAMPTZ                   -- soft delete
);
CREATE INDEX idx_messages_channel ON messages(channel_id, created_at DESC);
```

For read receipts: `message_reads(message_id, user_id, read_at)`. Append-only; bulk-ack on open.

### Typing Indicators and Presence

Typing indicators are **ephemeral** — they do not need persistence. Send a `TYPING` event over the WS; the recipient displays "User A is typing..." for 5s, reset on each `TYPING` event, clear when a message arrives. No database write needed.

Presence (online/offline):
- On WS connect: `SET user:{id}:online = 1 EX 30` in Redis.
- Heartbeat every 20s: extend the TTL.
- On WS close: delete the key.
- Any key missing = offline.

### Group Chat Fan-out

A group with 1,000 members receives one message — the server must deliver it to up to 1,000 WS connections, potentially across many servers. The same hybrid strategy as the news feed applies: for large groups (> N members), batch the fan-out asynchronously rather than fanning out in the message handler's hot path.

### Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Storing chat messages in a relational DB with no partition by channel | Full-table scans for message history; query time grows linearly with total messages | Partition `messages` by `channel_id` hash or by `created_at` range; or use Cassandra/ScyllaDB (write-optimized, range queries by partition key) |
| Delivering messages synchronously in the write path | Slow recipient (large group) blocks the sending user's request | Decouple delivery from write — write to DB + publish to queue; return 200 immediately |
| No offline message queue | Messages lost for offline users | Store message in DB; on reconnect, deliver all messages with `created_at > last_seen` |
| Fan-out over pub/sub to all servers for every message | Every server subscribes to every message; O(servers × messages) fan-out | Route messages to the specific server holding the recipient's connection via presence map |

---

## Design 4: Distributed Rate Limiter

### Requirements

Functional: given a client ID (user, API key, IP), allow or reject a request based on a configurable policy (e.g., 1,000 req/s per user). Policies configurable per endpoint. Return 429 with `Retry-After` when exceeded.

Non-functional: < 5ms overhead per check at p99; 10M RPS across the fleet; accurate (no more than 5% overshoot on the limit).

### Single-Server Baseline: Token Bucket in Memory

Fast. Works for one process. Fails when you have 50 API gateway instances — each has its own bucket, and a client can hit 50 instances at 999 RPS each = 49,950 RPS with no rejections.

### Distributed: Redis Atomic Operations

Central Redis as the shared bucket store. Two algorithms:

**Fixed Window with INCR + EXPIRE:**

```
key = "rl:{client_id}:{endpoint}:{current_minute_epoch}"
count = INCR key
if count == 1: EXPIRE key 60
if count > limit: return 429
```

O(1), simple. Weakness: the window boundary attack — a client can make `limit` requests in the last second of minute N and `limit` in the first second of minute N+1, getting `2 × limit` in 2 seconds.

**Sliding Window Log (sorted set):**

```
key = "rl_log:{client_id}:{endpoint}"
now = current_epoch_ms
window_start = now - 60000
MULTI
  ZREMRANGEBYSCORE key -inf window_start    -- remove expired entries
  ZADD key now now                          -- add current request (score=time, member=time)
  ZCARD key                                 -- count entries in window
EXEC
if count > limit: return 429
```

Accurate. O(log N) per request. Memory: O(requests in window) per client. For 1M concurrent users each making 100 req/s, sorted sets become large. Use for low-volume, precision-critical paths.

**Sliding Window Counter (approximate, O(1)):**

```
prev_count × (remaining_window_fraction) + curr_count
```

Uses two fixed-window counters (previous minute, current minute). Memory is O(1) per key. Accuracy within 1–2% of true sliding window. The recommended default for high-volume API rate limiting.

### Multi-Region Challenges

A central Redis means one cluster for all regions — high latency for distant regions (50–100ms from Asia to US-East). Options:

- **Local Redis per region + periodic sync**: low latency; allows > limit temporarily across regions. Acceptable for soft limits.
- **Global Redis with edge replicas** (Redis Global Replication / Upstash for Redis): reads from local replica (fast), writes to primary (slower). Stale reads allow brief overshoot.
- **Accept approximate limiting**: most production rate limiters are approximate. Exactness at global scale requires coordination that costs more than the occasional overshoot.

### Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Rate limiting by IP only | One NAT gateway = thousands of users sharing one IP; entire office blocked | Rate limit by authenticated user ID at minimum; IP as secondary defense for unauthenticated paths |
| No Retry-After header on 429 | Clients retry immediately, creating a retry storm | Always include `Retry-After: <seconds>` calculated from window reset time |
| Centralized rate limit check adds 100ms | Higher than the 5ms requirement; users notice | Sidecar proxy (Envoy, nginx) with local Redis replica; or in-process check with eventual consistency |
| One rate limit for all endpoints | POST /payments and GET /health share a budget | Per-endpoint (or per-tier) limits; health and status endpoints are exempt |

---

## Design 5: Payment Ledger (Idempotency + Double-Entry)

### Requirements

Functional: record money movement between accounts; support debit, credit, and transfer; expose account balance; expose transaction history; idempotent writes (duplicate requests must not double-charge).

Non-functional: zero data loss; CP consistency (correctness over availability for financial data); auditability (every balance change is traceable); 99.999% availability.

### Double-Entry Bookkeeping

Every financial movement creates **two ledger entries** — one debit, one credit — such that the sum of all entries for any account equals its balance, and the sum across all accounts is always zero (money is conserved).

```sql
CREATE TABLE accounts (
    id          BIGINT PRIMARY KEY,
    user_id     BIGINT NOT NULL,
    currency    CHAR(3) NOT NULL,
    -- Balance is NOT stored; computed as SUM(ledger_entries.amount) WHERE account_id = id
    -- Or: maintained as a denormalized cache with optimistic locking
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE transactions (
    id              BIGINT PRIMARY KEY,          -- snowflake ID
    idempotency_key VARCHAR(64) UNIQUE NOT NULL, -- caller-supplied; guards duplicate requests
    status          TEXT DEFAULT 'pending',      -- pending | completed | failed
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE ledger_entries (
    id              BIGINT PRIMARY KEY,
    transaction_id  BIGINT NOT NULL REFERENCES transactions(id),
    account_id      BIGINT NOT NULL REFERENCES accounts(id),
    amount          BIGINT NOT NULL,             -- in minor units (paise, cents); signed: + = credit, - = debit
    currency        CHAR(3) NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT now()
);
-- Invariant: for every transaction, SUM(ledger_entries.amount WHERE transaction_id = x) = 0
```

### Write Path: Transfer

```
POST /v1/transfers
  body: { from_account_id, to_account_id, amount, currency, idempotency_key }
```

```
1. BEGIN TRANSACTION
2. INSERT INTO transactions (idempotency_key, status='pending')
     ON CONFLICT (idempotency_key) DO NOTHING RETURNING id
     -- if no row returned: duplicate request, look up existing transaction and return its result
3. Check balance: SELECT SUM(amount) FROM ledger_entries WHERE account_id = from_account_id FOR UPDATE
     -- FOR UPDATE: row-level lock prevents concurrent balance reads from racing
4. If balance < amount: set transaction.status = 'failed', ROLLBACK, return 422
5. INSERT INTO ledger_entries (transaction_id, account_id=from, amount=-amount)
6. INSERT INTO ledger_entries (transaction_id, account_id=to,   amount=+amount)
7. UPDATE transactions SET status = 'completed'
8. COMMIT
```

The idempotency key check at step 2 is the guard against duplicate requests. The `FOR UPDATE` lock at step 3 prevents two concurrent transfers from both seeing a positive balance when only one can succeed. The double-entry at steps 5–6 ensures the invariant (sum = 0) is maintained.

### Balance Computation: Ledger Sum vs Denormalized Cache

**Ledger sum**: `SELECT SUM(amount) FROM ledger_entries WHERE account_id = ?`. Always accurate; slow for accounts with millions of transactions.

**Denormalized balance** in `accounts.balance`: fast reads; must be updated atomically with ledger entries in the same transaction. Use optimistic locking (`UPDATE accounts SET balance = balance - ? WHERE id = ? AND balance >= ?`) — the condition check and the update are atomic; if the condition fails, the transaction rolls back.

Production: use the denormalized balance for read-path latency, and a background **reconciliation job** that recomputes `SUM(ledger_entries.amount)` daily and alerts on any discrepancy. The reconciliation is how you find ledger corruption bugs before they become customer-facing.

### Reconciliation

```sql
-- Run daily; alert if any account's computed balance != stored balance
SELECT a.id, a.balance AS stored, SUM(le.amount) AS computed
FROM accounts a
LEFT JOIN ledger_entries le ON le.account_id = a.id
GROUP BY a.id, a.balance
HAVING a.balance != COALESCE(SUM(le.amount), 0);
```

Any row returned is a ledger corruption event. Treat it as a P0 incident.

### Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| No idempotency key; using request deduplication at the HTTP layer only | Timeout + retry from the client creates a double charge | Idempotency key in the `transactions` table with a UNIQUE constraint; check before any ledger write |
| Storing balance in minor units as FLOAT/DOUBLE | Floating-point rounding creates fractions of paise; balances drift | Always store money in integers (paise, cents); never float |
| Checking balance before locking | Two concurrent transfers both see positive balance; race condition | `SELECT ... FOR UPDATE` on the balance row, or use a conditional UPDATE that fails if balance < amount |
| Soft-deleting transactions without reversing ledger entries | Account balance is wrong (deleted transaction's entries still sum into the balance) | Never delete financial records; record a reversal transaction with entries that cancel the original |
| No reconciliation job | Silent ledger corruption goes undetected for months | Daily reconciliation; alert on any discrepancy; treat as P0 |

> **War story.** A payments platform I audited had exactly the race condition in the "checking balance before locking" row above. Two concurrent refund requests for the same order both queried the balance (10,000 paise), saw it was ≥ the refund amount (5,000 paise), and both proceeded to write ledger entries. The account ended up with a balance of 0 after two 5,000-paise debits — mathematically correct but wrong, because the customer was refunded twice. The fix was a single-query conditional update: `UPDATE accounts SET balance = balance - 5000 WHERE id = ? AND balance >= 5000 RETURNING balance`. If `balance < 5000`, the UPDATE matches zero rows, the application rolls back, and returns a 422. One SQL statement replaces the check-then-act race condition.

---

## Cross-Cutting Observations

Looking across all five designs, the same patterns appear regardless of the domain:

1. **Separate the read path from the write path.** Reads are served from cache (CDN, Redis); writes go through the authoritative store. Every design that violates this hits a scalability wall.

2. **Fan-out is always the hard problem.** URL shortener (slug → user), news feed (post → followers), chat (message → group members) — every design has a fan-out problem. The answer is always the same: hybrid push/pull, async worker, and an alert on worker lag.

3. **Idempotency keys belong in the same transaction as the side effect.** Every design that stores money, sends messages, or modifies state needs idempotency. The key must be colocated with the effect — never in a separate store without a distributed lock.

4. **The celebrity / hot-shard problem recurs.** A popular URL, a celebrity post, a hot Kafka partition, a high-traffic account — any design that routes by identity creates hot spots. The fix is consistent: cache the hot item at the read layer, async the write fan-out, and shard by a secondary key when the primary is skewed.

---

## Checkpoint

You're ready to handle a system design interview when you can, for any of these five problems:

1. State the non-functional requirements you'd clarify before drawing a single box.
2. Give rough estimates for storage and peak RPS.
3. Identify the read/write ratio and which side is the bottleneck.
4. Name the fan-out problem in that design and state the hybrid approach.
5. Identify the idempotency surface and explain where to store the key.
6. Name two failure modes specific to that design that an interviewer would probe.
7. State one trade-off you made and defend it.

Completing the challenges in this course tests the same muscles on code: you implement the primitives rather than just narrating them.

➡ The course challenges now give you a problem to code, not just describe. Pick the one that matches your weakest area from the five designs above.
