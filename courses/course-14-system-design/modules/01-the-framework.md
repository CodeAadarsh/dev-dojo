# The System Design Framework

> **Module 01 · Course 14** — System design is the one interview where preparation compounds faster than any other. The 6-step framework below is a forcing function, not a recipe. Use it to drive the conversation, not to fill slides.

You've built distributed systems at work. This module is not "what is a load balancer." It's the meta-skill: how to decompose an ambiguous prompt into a defensible design in 45 minutes, how to communicate decisions as tradeoffs rather than facts, and where candidates who know the tech still fail.

---

## Why the frame matters

A blank whiteboard invites stream-of-consciousness. "We'll need a database, and maybe a cache, and I was thinking Kafka..." — this is the failure mode. The interviewer has seen a hundred candidates propose components. They want to see *reasoning under constraint*.

The 6-step framework forces you to produce a concrete artifact at each stage before moving on. Each artifact constrains the next:

```
requirements  →  numbers that size your system
                  ↓
                numbers that force storage choices
                  ↓
                storage choices that shape your API
                  ↓
                API that drives your component topology
                  ↓
                topology that surfaces your bottlenecks
```

If you skip requirements and go straight to components, you're designing in a vacuum. An interviewer asking "how many users?" after you've drawn three microservices is a polite way of saying your design is fiction.

---

## Step 1: Functional and non-functional requirements

**Spend 5 minutes here. Stop the clock yourself if you need to.**

### Functional requirements

What the system does. Extract them by asking:

- "What are the core actions a user can take?" → your write paths
- "What does a user read or consume?" → your read paths
- "What are the consistency constraints?" (can users see stale data? for how long?)
- "Any offline or async operations?" (notifications, processing, billing)

Write them as a numbered list on the board. Five to seven is right. If you have twelve, you haven't scoped.

### Non-functional requirements

These are the constraints that determine architecture. Never skip them:

| Dimension | Questions to ask | Why it matters |
|-----------|-----------------|----------------|
| Scale | DAU? Writes/sec? Reads/sec? | Determines whether a single DB is enough |
| Latency | p99 target for reads? writes? | Forces caching, async, CDN decisions |
| Availability | 99.9%? 99.99%? | Five 9s = 5 min/year downtime — drives redundancy cost |
| Consistency | Read-your-writes? Eventual? Strong? | Determines whether replicas are enough |
| Durability | Can you lose data? For how long? | Drives replication factor, WAL, backups |
| Geo | Single region? Multi-region? | Multi-region changes almost everything |

**State which requirements you are and are not designing for.** "I'll scope this to a single region for now, and note where multi-region changes the design" is a senior move. It shows judgment. An interviewer who wants multi-region will redirect you; most won't, and you've just saved 10 minutes.

---

## Step 2: Capacity Estimate

**5 minutes. Use round numbers. The goal is constraints, not accuracy.**

Back-of-envelope math is not a math test. It is a forcing function to surface:
- whether you need horizontal partitioning
- whether you need caching
- what storage you can afford
- what the read/write ratio looks like

Work from DAU → daily volume → per-second → per-machine:

```
Example: URL shortener

DAU: 100M users
Write: 1% create a URL/day  → 1M writes/day  → ~12 writes/sec
Read:  100 reads/click avg  → 100M reads/day → ~1,200 reads/sec
Read:write ratio = 100:1 (heavy read — caching is obvious)

Storage per year:
  1M URLs/day × 500 bytes/row × 365 days = ~180 GB/year
  5-year retention → ~1 TB total (fits comfortably on one DB node)

Bandwidth:
  1,200 reads/sec × 500 bytes = ~600 KB/s outbound (trivial)
```

Write the numbers on the board. They constrain every decision in steps 3–6.

### The estimate you never skip: read/write ratio

Everything downstream flows from this number:

- **Heavy read (>10:1):** caching pays off, read replicas make sense, eventual consistency is tolerable
- **Heavy write (>1:1):** focus on write throughput, sharding, WAL buffering
- **Balanced:** you must justify every tradeoff explicitly, because neither extreme applies cleanly

---

## Step 3: API Design

**5 minutes. REST or RPC — pick one and be explicit.**

Design the external contract *before* you design the internals. This is what clients depend on, and it forces ambiguities in your requirements to surface early:

```
POST   /urls                  { "long_url": "https://..." }     → 201 { "short_code": "abc123" }
GET    /urls/{code}                                             → 302 Location: <long_url>
DELETE /urls/{code}           (authenticated)                  → 204
GET    /urls/{code}/stats                                       → 200 { "clicks": 1234, "created_at": "..." }
```

Decisions to call out explicitly:

- **Idempotency key?** Retries on POST without an idempotency key double-create. Mention it.
- **Pagination?** If list endpoints exist, name the cursor strategy (keyset, not offset).
- **Versioning?** `/v1/` prefix or `Accept: application/vnd.api+json;version=2`? Doesn't matter which — matters that you named it.
- **Auth?** Token in header, not query param. Note it and move on.

Don't over-specify. The API section should take one board column. Its purpose is to anchor the data model.

---

## Step 4: Data Model

**10 minutes. Schema, access patterns, storage choice.**

What tables or collections or keys exist? What are the access patterns? The storage *type* follows from the access pattern, not the other way around.

| Access pattern | What it implies |
|----------------|-----------------|
| Point lookup by primary key | KV store or single-table relational with covering index |
| Range scan over sorted key | LSM-tree store (Cassandra, DynamoDB sort key) or B-tree with composite index |
| Full-text search | Elasticsearch / OpenSearch — not Postgres `LIKE` |
| Time-series (append-heavy, time-range scans) | InfluxDB / TimescaleDB — not a vanilla relational table |
| Complex joins + ACID transactions | Relational (Postgres) — not a document store |

For the URL shortener:

```sql
urls (
  short_code  CHAR(7)       PRIMARY KEY,
  long_url    TEXT          NOT NULL,
  user_id     BIGINT,
  created_at  TIMESTAMPTZ   DEFAULT now(),
  expires_at  TIMESTAMPTZ,
  click_count BIGINT        DEFAULT 0
)
```

Immediate questions to raise on the board:

- `click_count` updated on every redirect → write hot spot. Better: async counter, a separate time-series table, or approximate count via HyperLogLog in Redis.
- `short_code` as PK means lookup is O(log n) on the B-tree. Good.
- `long_url` is unbounded text. Add a length cap or a hash index for deduplication if users share the same long URL repeatedly.

---

## Step 5: High-Level Design

**10 minutes. Draw the component topology.**

Draw boxes for:

1. **Clients** (browser, mobile)
2. **API gateway / load balancer**
3. **Application layer** (stateless services — explain *why* stateless matters)
4. **Cache layer**
5. **Primary storage**
6. **Async workers** (if you have heavy processing, fan-out, or notifications)
7. **CDN** (if you have static assets or geographic distribution)

Connect them with arrows. Label each arrow with the protocol (HTTPS, gRPC, TCP, AMQP). Don't forget:

- Where TLS terminates
- Which store is source-of-truth
- Which path is synchronous (on the critical path) vs. async

```
         ┌──────────┐
         │  Client  │
         └────┬─────┘
              │ HTTPS
         ┌────▼─────────┐
         │   CDN / LB   │  ← TLS terminates here
         └────┬─────────┘
              │ HTTP
    ┌─────────▼──────────┐
    │  API Servers (3+)  │  ← stateless — any node handles any request
    └──┬──────────────┬──┘
       │              │
  ┌────▼──────┐  ┌────▼──────┐
  │   Redis   │  │ Postgres  │
  │  (cache)  │  │  (source  │
  │           │  │  of truth)│
  └───────────┘  └───────────┘
```

State what you're deferring: "I'll cover multi-region replication and the async click-counting pipeline in the deep-dive."

---

## Step 6: Deep-Dive and Bottlenecks

**Remaining ~10 minutes. This is where SDE-2 becomes SDE-3.**

Pick **two or three** bottlenecks and go deep. Not five shallow dives. The rule: go deep enough to say something the interviewer cannot say back to you without thinking.

The five most common bottleneck categories and what depth looks like:

| Bottleneck | Shallow answer | Deep answer |
|------------|----------------|-------------|
| Write throughput | "shard the DB" | pick the shard key, explain why sequential keys cause hot shards, quantify the write threshold where sharding pays off |
| Read latency | "add a cache" | explain cache-aside vs. write-through vs. write-behind, name your eviction policy, quantify the hit rate you need for the cache to matter |
| Availability | "run replicas" | name the failover mechanism (Raft leader election vs. read-only fallback), quantify RTO and RPO |
| Fan-out on write | "it's slow, precompute" | explain push vs. pull model, the celebrity problem (a user with 10M followers), hybrid approaches |
| Hot partition | "distribute more" | name consistent hashing, virtual nodes, why naive modulo breaks on resharding |

**Always present bottlenecks as tradeoffs, not solutions.** "Caching gives us better read latency but introduces the invalidation problem. For this use case I'd accept eventual consistency on click counts but not on the short code → URL mapping — here's why."

---

## How to drive the conversation

You control the pace. The interviewer will let you run wherever you go — that's how you fail.

```
│ 0:00  │ "Let me start with requirements. I want to make sure we're designing  │
│       │  the right thing before drawing any boxes."                           │
│ 0:05  │ "Here are the constraints I'll design for. Do these feel right?"      │
│ 0:10  │ (capacity) "The read:write ratio is roughly X:1, which tells me..."   │
│ 0:15  │ (API) "I'll sketch the external contract. The interesting questions   │
│       │  are around idempotency and pagination..."                            │
│ 0:25  │ (data model) "The access pattern drives me toward X. Let me explain   │
│       │  why, and flag the hot-spot risk in click_count."                     │
│ 0:35  │ (high-level) "Here's the topology. The synchronous critical path is..." │
│ 0:45  │ (deep-dive) "The two bottlenecks I want to focus on are..."           │
```

If the interviewer redirects you ("let's talk about scaling"), go there — they're steering you toward the deep-dive. Don't resist; they're giving you an opportunity to show depth.

---

## Common Mistakes

| Symptom | Root cause | How to fix |
|---------|-----------|-----------|
| Starts drawing components in the first two minutes | No requirements phase; guessing at the problem | Stop. Write functional requirements first. Every component should justify itself against a stated requirement. |
| Capacity section is "millions of users, let's scale horizontally" | No numbers; no constraints; no reasoning | Derive DAU → req/sec → storage from a stated assumption. Commit to the assumption, note the uncertainty, move on. |
| Storage choice decided before access pattern is named | Technology preference over reasoning | State the access pattern first — always. Storage follows from it. |
| Tradeoffs stated as facts ("Cassandra is faster") | Avoiding commitment; missing context | Every performance claim needs a "because" and a "compared to what." "Cassandra's LSM tree gives higher write throughput than Postgres' B-tree at the cost of read amplification." |
| Deep-dive is a tour of components | Never went deep on any one thing | Pick one bottleneck and go deep enough to reach a number, a mechanism, or a tradeoff no reasonable person would contest. |
| Ran out of time before the deep-dive | Spent too long on the high-level diagram | The topology diagram should be drawn in 10 minutes. Details belong in the deep-dive, not in the boxes. |

> **War story.** I was on-call for a service processing 100 GB/day of Loki log pipeline data at SAP. We got paged: p99 query latency spiked 5× during business hours. The team's first instinct was "add more read replicas." We spent two hours sizing replicas and testing failover before someone asked: *"what changed in the access pattern?"* A new tenant had started querying with unbounded time ranges — full table scans on a sharded Postgres table. No replica count fixes a missing index. We added a composite index on `(tenant_id, timestamp)` and latency dropped 90% in 10 minutes. The lesson: when you see a bottleneck in a design interview, state the *access pattern* first, then the remedy. Replicas fix throughput. Indexes fix query patterns.

---

## Checkpoint

You're ready for the challenges when you can, without a script:

1. State the six steps and the artifact each one produces.
2. Derive a req/sec number from a DAU figure for a given write percentage.
3. Explain why non-functional requirements are gathered in step 1, not after you've drawn the topology.
4. Name the three questions you ask to decide which storage type to use.
5. State two bottleneck categories and describe what "going deep" looks like for each.
6. Given a design with an obvious cache, explain the invalidation strategy and its tradeoff without prompting.
7. Explain what it means for a service to be stateless and why it matters for horizontal scaling.
8. In one sentence: what is the difference between a functional and a non-functional requirement?

→ Next: **Scaling Fundamentals** — the mechanics behind horizontal scale-out, why stateless matters, load balancing algorithms, caching layers, read replicas, and the distributed N+1 trap.
