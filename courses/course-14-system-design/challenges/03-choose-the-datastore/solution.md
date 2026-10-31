# Solution — Choose the Datastore

The flag is `KUBE{redis_sorted_set_wins_leaderboard}`.

The target scenario is **Scenario 3 — Real-Time Game Leaderboard**. The correct datastore is **Redis**.

---

## Why Redis wins scenario 3

The deciding factor is the access pattern: 50 000 writes/sec where each write must simultaneously update a player's score **and** produce a rank among 1 million players in under 5ms.

Redis sorted sets expose three operations that map exactly to this requirement:

```
ZADD   leaderboard <score> <player_id>   # O(log N) — update score
ZREVRANK leaderboard <player_id>          # O(log N) — instant rank lookup
ZREVRANGE leaderboard 0 999              # O(N)     — top-1000 in one call
```

All three are atomic, single-RTT, and backed by a skip list / hash table dual structure. A sorted set of 1 million members uses ~80 MB — trivially fits in RAM.

### Why not PostgreSQL?

PostgreSQL can store scores, but ranking requires:
```sql
SELECT COUNT(*) FROM scores WHERE score > (SELECT score FROM scores WHERE player_id = $1);
```

At 50K concurrent updates this is:
- A **row-level lock** on the player's row every update (UPDATE is not lock-free)
- A **sequential or index scan** over the score column for each rank query
- Under 50K writes/sec, WAL I/O becomes the bottleneck before you can even serve reads

You can mitigate with a materialised view + refresh, or a denormalised rank column recomputed on a schedule — but now you have eventual consistency (lag) and more complexity. You have reinvented a sorted set, badly.

### Why not Cassandra?

Cassandra's strength is distributed high-throughput writes with wide-column access by a known partition key. It has no native sorted collection primitive. To implement ranking you would:
1. Pre-sort scores in the partition key design (e.g. bucketed score ranges), or
2. Use a secondary index (not designed for write-heavy workloads), or
3. Fan out writes to a sorted materialised view updated on every score change

None of these are atomic. A race between two updates to the same player can leave the rank view inconsistent. And ranking an arbitrary player still requires counting — you have to read across multiple partitions.

---

## What makes this question rich

This scenario exposes a common interview mistake: "I need persistence and 1M records, so PostgreSQL." The correct framing is "I need 50K atomic score+rank updates per second — what data structure supports that?" The answer to the data-structure question points directly to the datastore.

The canonical rule:
> **Choose Redis when your access pattern matches a Redis data structure directly: sorted set for ranking, hash for structured objects, bitmap for presence, stream for append-only log.**

---

## Scenario 1 and 2 answers (for completeness)

**Scenario 1 (Compliance Audit Log): PostgreSQL**
- Immutable rows, 7-year retention, range scans by timestamp, JOINs to account table.
- Redis has no durable range scan. DynamoDB's JOIN story is painful.
- PostgreSQL with an append-only policy (no UPDATE/DELETE via row-level security) + a btree index on `(account_id, timestamp)` is the exact fit.

**Scenario 2 (Session Store): Redis**
- 200K reads/sec at < 5ms p99. Sessions expire in 24h. Total data ~25 GB.
- Redis SET key value EX 86400 — one command, sub-millisecond, TTL built in.
- PostgreSQL at 200K reads/sec requires a cache layer — which is just Redis. Cassandra is unnecessary weight for 25 GB.
