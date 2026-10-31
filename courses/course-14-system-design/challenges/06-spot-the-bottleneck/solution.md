# Solution — Spot the Bottleneck

The flag is `KUBE{read_replica_fixes_the_bottleneck}`.

---

## The bottleneck

The single PostgreSQL primary (`db-01`) is the bottleneck. 95% of traffic is `SELECT`
queries (reads). All 10–20 API pods route every query — reads and writes — to the same
single primary. At 2,000 req/s, the primary reaches 97% CPU saturation from the
concurrent query execution load, not from disk I/O (disk at 61/200 IOPS) and not from
network. The CPU saturation causes query queuing, which is why P99 climbs from 38ms to
4,200ms — not from slow individual queries, but from queries waiting in the PostgreSQL
connection queue before they even start executing.

Adding more API pods does not help — it adds more connections and more queries to the
same single primary, which makes CPU saturation worse, not better.

---

## Root cause

The architecture has no read path separation. A read-heavy workload (95% reads) with
horizontal API scaling needs horizontal read scaling. PostgreSQL's single primary handles
writes; reads should be distributed across replicas. Without replicas, the primary serves
reads from all 20 API pods simultaneously, saturating on connection overhead and query
execution CPU before disk or network become relevant.

The 200 IOPS limit and 2 vCPU are fine for a write-heavy or low-traffic read workload.
They are not fine when 20 API pods are each running 30–40 concurrent read queries.

---

## The fix

**Primary fix: add PostgreSQL read replicas.**

Route all `SELECT` queries to one or more read replicas via a read/write proxy (PgBouncer
in transaction mode, RDS Proxy, or application-level routing). Only `INSERT`, `UPDATE`,
and `DELETE` go to the primary.

```
               ┌──────────────────────┐
               │     PgBouncer        │  connection pooler + read/write split
               └──────┬──────┬────────┘
               writes │      │ reads
                      ▼      ▼
            ┌──────────┐  ┌──────────┐  ┌──────────┐
            │PostgreSQL│  │PostgreSQL│  │PostgreSQL│
            │ primary  │  │ replica-1│  │ replica-2│
            │(db-01)   │  │(db-02)   │  │(db-03)   │
            └──────────┘  └──────────┘  └──────────┘
```

At 95% reads, two replicas handle 95% of query volume; the primary handles only the 5%
write traffic. CPU on the primary drops from 97% to ~5%. Replicas each handle ~47.5%
of read traffic, running at ~45% CPU each. P99 returns to the 38ms baseline.

**Secondary fix: connection pooling.**

With 20 pods × 34 connections each = 680 connections at peak, PostgreSQL's per-connection
process model becomes overhead even before query execution begins. PgBouncer in
transaction mode reduces this to a shared pool of 50–100 backend connections regardless
of API pod count.

**Optional: read caching for hot profiles.**

For user profiles that are read thousands of times per second and change infrequently,
a Redis cache with a 30s TTL removes those reads from PostgreSQL entirely. This is
additive to, not a substitute for, read replicas.

---

## Trade-offs

| Fix | What it costs |
|-----|--------------|
| Read replicas | Replication lag (typically 10–100ms async). Reads from replicas may return data that is 1–2 commits behind the primary. Acceptable for 95% of profile reads; not acceptable for "read your own write immediately after a profile update." |
| Connection pooling | PgBouncer is another service to operate. In transaction-mode pooling, `SET` statements and prepared statements have restricted semantics (they reset per transaction, not per connection). |
| Read caching | Cache invalidation complexity. A profile update must invalidate the cache key. TTL-based invalidation means a user may see their old profile for up to 30s after an update. |

The replication lag for the "read your own write" problem is solved by routing writes
and the *immediately subsequent read* from the same session to the primary, or by
waiting for replica sync (synchronous replication) for those specific queries.

---

## Common mistakes

| Symptom | Misdiagnosis | Why it's wrong |
|---------|-------------|----------------|
| "Disk IOPS is only 61/200 — not disk." | "So the fix is a faster disk." | Correct that disk is not the bottleneck; wrong conclusion. Adding NVMe changes nothing because 97% CPU is the limit, not IOPS. |
| DB CPU at 97% | "Optimise queries / add indexes." | Index hit rate is already 92%. Individual queries are fast — the problem is concurrent volume, not slow queries. Adding an index on an already-indexed column improves nothing. |
| 340 concurrent connections | "Increase `max_connections`." | Increasing `max_connections` makes the CPU problem worse by allowing more concurrent execution. The correct fix is connection pooling *plus* read scaling. |
| "Just add a caching layer" | Cache fixes hot-path reads for static data | Does not help for long-tail profile reads that are rarely repeated. Cache hit rate on a diverse user base may be only 30–40%. |

---

> **War story.** On the LGTM log pipeline at SAP, we hit an identical pattern. A metadata store (Postgres on a single primary) worked fine up to ~500 req/s in staging. In production, a marketing push tripled traffic overnight. The DB hit 100% CPU within 10 minutes. The on-call added more API pods — CPU got worse. Adding API pods without read replicas is like adding lanes to a highway that feeds a single-lane bridge. The bridge (primary) is the constraint; adding approach lanes (API pods) only makes the bridge queue longer. We added two read replicas and a PgBouncer sidecar inside 2 hours; the primary dropped to 8% CPU and P99 went from timeouts to 41ms. The fix took 40 minutes once we correctly identified that the primary was the constraint — not queries, not disk, not the app layer.

---

## Checkpoint

You understand this bottleneck when you can, without notes:

1. Explain why adding more API pods makes the DB CPU worse, not better.
2. Name the two metrics in the architecture that prove disk is not the bottleneck.
3. Explain what happens to a query that arrives when all 200 IOPS are not used but CPU is at 100%.
4. Describe the read/write routing change required after adding replicas.
5. Explain the "read your own write" edge case with replicas and the two ways to solve it.
