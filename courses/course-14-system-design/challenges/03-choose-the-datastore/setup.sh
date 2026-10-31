#!/usr/bin/env bash
# Plants the "Choose the Datastore" discovery scenario into the work directory.
# Idempotent — safe to re-run.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-choose-the-datastore"
mkdir -p "$WORK"

# ── scenarios.md ─────────────────────────────────────────────────────────────
cat > "$WORK/scenarios.md" << 'MDEOF'
# Choose the Datastore — Three Scenarios

Read each scenario carefully. The access pattern, scale target, and consistency
requirement together determine the right datastore. For scenario 3 (the target),
the correct choice holds the flag in answer_keys.json.

---

## Scenario 1 — Compliance Audit Log

A fintech company must store every transaction event for regulatory compliance.
Requirements:
- 50 million events written per day (~578 writes/sec, uniform)
- Each event is immutable once written (no UPDATE, no DELETE before 7-year retention)
- Queries: point lookup by event_id, range scan by timestamp, JOIN to account table
- Strict ordering: events within an account must be totally ordered
- Consistency: strong (financial audit; eventual consistency is not acceptable)

Candidate datastores: Redis · DynamoDB · PostgreSQL

The correct choice for scenario 1 is: **PostgreSQL**
- Redis: in-memory first, no durable ordered scans, wrong for 7-year retention
- DynamoDB: no multi-table JOINs, eventually consistent by default, range scans
  require careful key design and are not as natural as SQL window functions
- PostgreSQL: ACID transactions, immutable append (no UPDATE policy via triggers),
  range scans on btree indexes, native JOINs, proven at billions of rows

---

## Scenario 2 — Session Store

A social network needs to store active user sessions.
Requirements:
- 50 million concurrent active sessions (~500 bytes each = ~25 GB total session data)
- Sessions expire automatically after 24 hours
- Reads: 200 000/sec (user hits any page → session lookup)
- Latency SLA: < 5ms p99 for every session read
- Consistency: a stale session read is acceptable (user sees wrong name for 100ms);
  a missing session is not (they get logged out)

Candidate datastores: PostgreSQL · Redis · Cassandra

The correct choice for scenario 2 is: **Redis**
- PostgreSQL: 200K reads/sec on a session table with row-level locking at p99 < 5ms
  is not achievable without a cache layer — you would just be reinventing Redis poorly
- Cassandra: wide-column store optimised for multi-node write throughput; point-key
  reads are fast but TTL-based eviction and per-key ops are not its strength; overkill
  for 25 GB of session data that fits in RAM
- Redis: in-memory, sub-millisecond single-key lookup, native TTL (SET ... EX 86400),
  25 GB fits in a r6g.large ($0.10/hr). Canonical session store for a reason.

---

## Scenario 3 — Real-Time Game Leaderboard  [TARGET SCENARIO]

A mobile gaming platform needs a live global leaderboard.
Requirements:
- 1 million concurrent players
- Every time a player scores, update their cumulative total AND re-rank instantly
- Read: return the top 1 000 players in rank order, latency < 20ms p99
- Write: 50 000 score updates/sec (uniform)
- The rank of any given player must be queryable in < 5ms
- Consistency: slight lag (< 1s) in ranking is acceptable; data loss is not

Candidate datastores: PostgreSQL · Redis · Cassandra

Think about what operation is called 50 000 times per second:
  "Given player_id and new_score, update the player's score
   AND immediately return their new rank among 1 000 000 players."

What primitive does each datastore offer for this?

  PostgreSQL: UPDATE + SELECT COUNT(*) WHERE score > :player_score
              — a sequential scan or index scan over the scores column;
              at 50K writes/sec this is a row-level lock hotspot; ranking a
              player requires counting rows — O(N) without tricks

  Cassandra:  no built-in sorted collection; ranking requires a secondary
              index or a fan-out write to a pre-sorted partition — complex,
              not atomic, and still O(N) to rank an arbitrary player

  Redis:      ZADD leaderboard <score> <player_id>  — O(log N) update
              ZREVRANK leaderboard <player_id>       — O(log N) rank lookup
              ZREVRANGE leaderboard 0 999            — O(N) top-1000 in order
              All three operations are atomic and single-RTT. A sorted set
              of 1M members uses ~80 MB of RAM.

The answer for scenario 3 is in answer_keys.json under the key "scenario-3".
MDEOF

# ── answer_keys.json ─────────────────────────────────────────────────────────
cat > "$WORK/answer_keys.json" << 'JSONEOF'
{
  "scenario-3": {
    "postgresql": "KUBE{wrong_rank_query_requires_full_table_scan}",
    "cassandra":  "KUBE{wrong_cassandra_has_no_sorted_set_primitive}",
    "redis":      "KUBE{redis_sorted_set_wins_leaderboard}"
  }
}
JSONEOF

echo
echo "Work directory : $WORK"
echo
echo "Files:"
echo "  scenarios.md     — three scenarios; read all three before deciding"
echo "  answer_keys.json — maps your scenario-3 answer to a flag string"
echo
echo "Task           : reason through scenario 3 (Real-Time Game Leaderboard)."
echo "                 Open answer_keys.json; look up the correct datastore."
echo "                 Submit the KUBE{...} flag string in the platform."
