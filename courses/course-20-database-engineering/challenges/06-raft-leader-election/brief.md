# Raft Leader Election

An on-call engineer pages the distributed-systems team:

> *"Our custom consensus layer elected two leaders simultaneously — shard 3 accepted writes from both, and we have diverged replicas. The coordinator had a naive 'first-to-respond wins' vote scheme with no term tracking. We need proper Raft leader election with term enforcement."*

Your job: implement the Raft leader-election state machine in `solution.py` so the verifier's hidden pytest suite passes — including the "higher term supersedes" invariant.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/06-raft-leader-election/
├── solution.py          # Network + RaftNode stubs; implement tick() and receive()
└── tests/
    └── test_sample.py   # two visible sample tests you can run
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-raft-leader-election
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `RaftNode.tick()` and `RaftNode.receive()` in `solution.py`. The `Network` class and `RaftNode.__init__` are provided.

### State Machine

A node is always in one of three states: `'follower'`, `'candidate'`, `'leader'`.

```
                 timeout fires
  ┌──────────────────────────────────────────────┐
  │                                              ▼
follower  ──── timeout fires ──►  candidate  ─── majority votes ──►  leader
  ▲                                   │
  │                                   │  higher term seen
  └───────── higher term seen ─────────┘
  ▲                │
  └────────────────┘ (also: any state + higher-term message → follower)
```

### `tick()` — logical clock advance

- **Follower / Candidate:** increment an internal tick counter. When the counter reaches `election_timeout`, start an election.
- **Leader:** send periodic heartbeats (AppendEntries) to all peers at half the election_timeout interval.
- Starting an election: increment term, vote for self, reset tick counter to 0, send `RequestVote` to all peers.

### `receive(msg)` — handle one incoming message

All messages are dicts with a `'type'` key. The **higher-term rule** applies to every message type: if `msg['term'] > self.term`, immediately convert to follower, update term, clear `voted_for`.

**RequestVote** (`type='request_vote'`):
- Grant the vote if `msg['term'] >= self.term` AND (`voted_for is None` OR `voted_for == candidate_id`).
- Reply with `{'type': 'vote_response', 'term': self.term, 'vote_granted': bool, 'from': self.node_id}`.
- Resetting tick counter on granting a vote is optional but good practice.

**VoteResponse** (`type='vote_response'`):
- Only count if `self.state == 'candidate'` AND `msg['term'] == self.term` AND `msg['vote_granted']`.
- Add the sender to the vote set. If votes > cluster_size // 2 → become leader.
- Becoming leader: set state to `'leader'`, send immediate AppendEntries heartbeat to all peers.

**AppendEntries** (`type='append_entries'`):
- If `msg['term'] >= self.term`: recognise the leader, reset tick counter, record `leader_id`.
- If state is not already `'follower'`, convert to follower.
- Reply with `{'type': 'append_entries_response', 'term': self.term, 'success': True}`.

### Network API (provided, do not modify)

```python
net.send(from_id, to_id, msg)   # enqueue a message
net.drain(nodes)                 # deliver all queued messages to their recipients
```

The test harness drives the simulation in rounds:

```python
for _ in range(N_rounds):
    for node in nodes.values():
        node.tick()
    net.drain(nodes)         # deliver messages produced by this tick
    net.drain(nodes)         # second pass: deliver vote responses, AppendEntries, etc.
```

## Invariants the Verifier Checks

1. **Exactly one leader** — after convergence, exactly one node is in state `'leader'`.
2. **Correct term** — all nodes settle on the same term after convergence.
3. **Higher term supersedes** — injecting a `RequestVote` with `term+5` causes the current leader to immediately transition to `'follower'`.
4. **Re-election after step-down** — after the leader steps down, a new election converges within N rounds.
5. **Safety** — with staggered timeouts the node with the smallest timeout is always elected (no split vote is possible).

## Why This Matters

Raft is the consensus algorithm behind:

- **etcd** (and therefore Kubernetes control-plane HA) — your `kubectl apply` reaching etcd triggers a Raft leader write.
- **CockroachDB / TiKV** — each range uses a Raft group.
- **Consul leader election** for service discovery.
- **Kafka KRaft mode** — replacing ZooKeeper.

The key safety property — **at most one leader per term** — comes directly from the majority vote: two candidates can never simultaneously collect majority votes in the same term because each node votes at most once per term. The "higher term supersedes" rule prevents a partitioned ex-leader from accepting writes after rejoining.

## Logical Clock Diagram (5-node, staggered timeouts)

```
Tick  Node0(t=5)  Node1(t=7)  Node2(t=9)  Node3(t=11)  Node4(t=13)
────  ──────────  ──────────  ──────────  ───────────  ───────────
 1    follower    follower    follower    follower     follower
 2    follower    follower    follower    follower     follower
 3    follower    follower    follower    follower     follower
 4    follower    follower    follower    follower     follower
 5   [CANDIDATE]  follower    follower    follower     follower
     sends RV─────────────────────────────────────────►

drain:  nodes 1-4 receive RV, grant vote, send VoteResponse back to 0

drain:  node 0 receives votes from 1,2 → 3/5 = MAJORITY → [LEADER]
        sends AE heartbeat to 1,2,3,4

drain:  nodes 1-4 receive AE → reset tick, stay/become follower
        (nodes 1-4 never reach their own timeouts)
```

## Verify

```bash
bash courses/course-20-database-engineering/challenges/06-raft-leader-election/verify.sh
```

All tests green → flag printed.
