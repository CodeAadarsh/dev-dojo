# Spot the Bottleneck

A pull request description lands in your inbox: *"New architecture for the user-profile service. Handles 10k req/s on staging. Pushing to prod next week."*

You look at the metrics. P99 latency at 200 req/s: **38 ms**. P99 latency at 2,000 req/s: **4,200 ms**. At 5,000 req/s the service starts timing out.

That's an 110× latency degradation for a 10× increase in load. Something is very wrong. Find it.

## The architecture

```
                        10,000 req/s
                            │
                            ▼
                  ┌─────────────────┐
                  │   AWS ALB       │  (regional, managed)
                  └────────┬────────┘
                           │  round-robin
               ┌───────────┼────────────┐
               ▼           ▼            ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐
        │  API    │  │  API    │  │  API    │  ... (10 pods total,
        │  pod-1  │  │  pod-2  │  │  pod-3  │      auto-scaled up to 20)
        └────┬────┘  └────┬────┘  └────┬────┘
             │            │            │
             └────────────┼────────────┘
                          │  ALL queries (SELECT + INSERT + UPDATE)
                          │  no query routing, no connection pool config
                          ▼
               ┌──────────────────────┐
               │   PostgreSQL         │
               │   primary  (db-01)   │  ← single node
               │   2 vCPU · 8 GB RAM  │
               │   200 IOPS gp2 SSD   │
               └──────────────────────┘
                          │
                   (no read replicas)
                   (no caching layer)
                   (no connection pool)
```

**Traffic profile (measured):**

| Metric | Value |
|--------|-------|
| Request mix | 95% SELECT (profile reads, search, feed) — 5% INSERT/UPDATE |
| Peak concurrent DB connections | 340 (10 pods × up to 34 goroutines each) |
| DB CPU at 200 req/s | 12% |
| DB CPU at 2,000 req/s | 97% |
| DB CPU at 5,000 req/s | 100% (query queue depth > 500) |
| Index hit rate | 92% (indexes are fine) |
| Disk IOPS utilised at peak | 61 of 200 (disk is not the constraint) |
| Network bandwidth | well under limits |

## Mission

`setup.sh` creates your work directory and plants `findings.txt`. Fill in every section
with your diagnosis. The verifier checks your findings for the required keywords before
printing the flag.

The conditions `verify.sh` checks:

1. `findings.txt` contains the word **replica** (your fix must mention read replicas).
2. `findings.txt` contains **primary** or **single** (you identified which component is the bottleneck).
3. `findings.txt` contains no `TODO` placeholders (all sections completed).

Use the exact words in your findings — the check is case-insensitive.

## Why this pattern kills services

Horizontal scaling the API layer adds pods but not DB capacity. Every added pod adds
connections and queries to the same single primary. The primary is not CPU-bound at low
traffic — it is CPU-bound under the *concurrency* of parallel queries at high traffic.
Connection overhead alone (parse, plan, execute per connection) saturates the 2 vCPU
budget well before network or disk become factors.

This architecture is the single most common cause of "worked great on staging, failed
on prod" for early-stage backend services.
