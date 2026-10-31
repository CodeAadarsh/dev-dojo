# Solution — Strong vs. Eventual: Pick the Right Consistency Model

The flag is `KUBE{strong_for_balance_eventual_for_likes}`.

---

## The answers

### BankLedger → Strong consistency (CP)

**CAP choice:** CP — Consistency + Partition tolerance.

**Why:** A balance transfer is a multi-step atomic operation: debit sender, credit receiver. If two concurrent transfers both read the same pre-deduction balance and both commit, you have created money. This is not a "stale read" problem — it is a **correctness** problem. The only fix is making the read-modify-write cycle atomic and linearizable.

Under a network partition, the correct behaviour is to block writes (return 503) rather than accept conflicting updates. Losing availability for a few seconds is acceptable. Losing balance integrity is not.

**The failure mode if you choose eventual:** the Cassandra trace in `scenario.md` shows it. Last-write-wins merges concurrent balance updates; one transfer is silently dropped at the storage layer while the recipient already received the funds. You have money created from nothing, and the audit trail is corrupted. In a regulated fintech environment this is a reportable incident, not just a bug.

**Implementation:** use a single-primary write path. PostgreSQL with `REPEATABLE READ` or `SERIALIZABLE` isolation, or a distributed ledger (CockroachDB, Spanner) that guarantees linearizable transactions. Every `POST /transfer` runs inside an explicit transaction that holds a row lock on the sender's balance.

---

### TrendFeed → Eventual consistency (AP)

**CAP choice:** AP — Availability + Partition tolerance.

**Why:** A like counter is a commutative, convergent data structure — you are adding to it, not conditionally branching on it. The only question is "how many likes did this post get" — an answer that is off by a few for 200ms is not a business problem, not an audit problem, and not something any user can distinguish from eventual propagation delay in their browser.

Requiring strong consistency for like counts would force a write lock on every post across all replicas for every `POST /like`. At 50,000 write/s across a trending post, that serialises everything through a single primary, destroying the horizontal scale you need to hit P99 ≤ 50ms at four nines.

**The failure mode if you choose strong:** your like counter becomes a serialised bottleneck. A trending post that goes viral (100k likes/minute) creates write contention that bleeds latency across the whole cluster. You either cap your write throughput artificially or start timing out, which destroys the 99.99% availability target.

**Implementation:** Redis with async replication, or Cassandra with CRDT counters (`COUNTER` type). CRDTs (Conflict-free Replicated Data Types) are exactly right for commutative increments — they merge without coordination and converge deterministically.

---

## The asymmetry principle

The two services sit at opposite ends of a spectrum, and the design clue is in their SLAs:

| Service | Availability SLA | Consistency requirement |
|---------|-----------------|------------------------|
| BankLedger | 99.9% (3 nines) | Linearizable — never stale |
| TrendFeed | 99.99% (4 nines) | Eventual — stale is fine |

BankLedger can afford to be unavailable for ~8.7 hours/year. It cannot afford a single corrupted transaction. TrendFeed must be available for all but ~52 minutes/year — to achieve that, it must sacrifice strict consistency.

When you see an availability SLA of four nines or higher on a write-heavy service, that is almost always a signal that the team chose (or should choose) eventual consistency.

---

## Common mistakes

| Mistake | Consequence |
|---------|-------------|
| "Cassandra is ACID-compliant with lightweight transactions (LWT)" | LWT adds ~3× write latency and does not give you multi-row atomicity. It's a CAS on a single row. Correct for leader-election, wrong for multi-row balance transfers. |
| "We'll use eventual consistency and just handle conflicts in app code" | Distributed conflict resolution requires a deterministic merge function. For a balance, there is no correct deterministic merge — you need serialisation. |
| "Strong consistency is always safer" | It is always *more correct*, but at 4-nines availability requirements the 503s during partitions cost more than the correctness gain. Over-engineering ledger semantics into a like counter is a real failure mode. |
| "Read-your-own-writes is the same as linearizability" | It is not. Read-your-own-writes means you see your own writes on the same session/node. Another node reading the same key may still see a stale value. Linearizability means *every* reader sees the latest write. |

---

> **War story.** An early version of a payment aggregator I reviewed ran all accounts on Cassandra with ONE quorum level for speed. During a network brownout between AZ1 and AZ2, a high-value customer triggered a refund and a new charge simultaneously from two mobile sessions routed to different AZs. Both reads saw the original balance; both writes committed. The account balance went negative, a downstream payment processor rejected the charge, but the refund had already settled. The total loss per incident was small (a few thousand rupees), but the audit trail was irrecoverable — the Cassandra log showed two conflicting writes and the LWW merge had dropped the one that would have prevented the overdraft. The fix was moving balance ledger tables to PostgreSQL with a serialisable transaction level and keeping Cassandra only for activity logs and like counts.

---

## Checkpoint

You understand this trade-off when you can, without notes:

1. State the CAP theorem in one sentence, then explain why P is non-negotiable.
2. Explain why a balance transfer is unsafe under eventual consistency even with LWT.
3. Name a concrete CRDT type that works for a like counter and explain why it converges.
4. Given a new service, list the three questions you ask to determine CP vs AP.
5. Explain why a 99.99% availability target and strong consistency are in tension at high write rates.
