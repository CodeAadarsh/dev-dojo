#!/usr/bin/env bash
# Plants reference materials for the Consistency Tradeoff challenge.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="05-consistency-tradeoff"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/scenario.md" << 'EOF'
# Scenario Data — Consistency Tradeoff

## BankLedger — observed behaviour under eventual consistency

The following trace was captured from a staging environment with three Cassandra nodes
and eventual consistency (QUORUM reads/writes disabled, ONE for speed):

```
t=0.000  node-1 receives POST /transfer  sender=alice  amount=800  balance_read=1000  → ACCEPT
t=0.003  node-2 receives POST /transfer  sender=alice  amount=800  balance_read=1000  → ACCEPT
t=0.018  node-1 propagates balance=200 to node-2 and node-3
t=0.021  node-2 propagates balance=200 to node-1 and node-3
t=0.025  last-write-wins merge: balance=200 (one transfer dropped silently)
```

Alice's balance is now ₹200 instead of ₹-600 because LWW silently discarded one
transfer — but the *recipients* both received ₹800. Alice's account lost ₹800 without
a corresponding debit recorded. That is a real audit finding, not just "stale reads."

## TrendFeed — observed behaviour under eventual consistency

```
t=0.000  100 concurrent POST /like/post-42  hit region-us-east
t=0.001  region-eu-west still shows count=10014 (pre-update)
t=0.200  both regions show count=10114
```

The 200ms convergence window: 0.2% of all like-count reads returned a stale value.
Zero financial impact. Users are not aware of the transient discrepancy.

## CAP theorem quick reference

- **C (Consistency):** every read returns the most recent write, or an error.
  In practice: linearizability — operations appear to execute atomically in some
  global order that respects real time.
- **A (Availability):** every request receives a non-error response (may be stale).
- **P (Partition tolerance):** the system continues to operate when network partitions
  split nodes. *You cannot avoid P in a distributed system — it WILL happen.*

Because P is non-negotiable, you are always choosing between C and A.

| Model | What you get | What you sacrifice | Example stores |
|---|---|---|---|
| CP (strong) | Correct, never-stale reads | Some writes blocked during partition; higher latency | PostgreSQL, CockroachDB, etcd, Spanner |
| AP (eventual) | Always available, low latency | Reads may be stale; concurrent writes can conflict | Cassandra, DynamoDB (default), Redis replication |
EOF

cat > "$WORK/answer.md" << 'EOF'
# My Answer

## BankLedger

CAP choice (CP or AP): TODO
Consistency model: TODO
Wrong-model failure: TODO

## TrendFeed

CAP choice (CP or AP): TODO
Consistency model: TODO
Wrong-model failure: TODO

## Flag

When confident, submit: KUBE{<fill_in>}
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : read scenario.md, complete answer.md, then submit the flag."
echo
echo "Files planted  :"
echo "  $WORK/scenario.md   — trace data and CAP quick reference"
echo "  $WORK/answer.md     — fill in before submitting"
echo
echo "No code required — this is a reasoning challenge."
