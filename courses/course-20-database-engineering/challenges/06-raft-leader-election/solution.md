# Solution — Raft Leader Election

## The Safety Guarantee

Raft's core safety claim: **at most one leader is elected per term.** This follows from two rules working together:

1. Each node votes for at most one candidate per term (`voted_for` tracks this).
2. Becoming a leader requires votes from a strict majority of the cluster.

Two candidates cannot both collect a majority in the same term because there aren't enough votes: in a 5-node cluster, a majority is 3 votes. If candidate A collects 3, only 2 remain — candidate B can't reach 3. The majority overlap is the heart of the proof.

## Complete Implementation

```python
from __future__ import annotations
from typing import Optional

FOLLOWER  = 'follower'
CANDIDATE = 'candidate'
LEADER    = 'leader'


class Network:
    def __init__(self) -> None:
        self._queue: list[tuple[int, int, dict]] = []

    def send(self, from_id: int, to_id: int, msg: dict) -> None:
        self._queue.append((from_id, to_id, msg))

    def drain(self, nodes: dict[int, 'RaftNode']) -> None:
        pending, self._queue = self._queue, []
        for (_from, to, msg) in pending:
            if to in nodes:
                nodes[to].receive(msg)

    def pending_count(self) -> int:
        return len(self._queue)


class RaftNode:
    def __init__(
        self,
        node_id: int,
        peers: list[int],
        network: Network,
        election_timeout: int,
    ) -> None:
        self.node_id = node_id
        self.peers = peers
        self.network = network
        self.election_timeout = election_timeout
        self._term: int = 0
        self._voted_for: Optional[int] = None
        self._state: str = FOLLOWER
        self._votes_received: set[int] = set()
        self._tick_count: int = 0
        self._leader_id: Optional[int] = None

    @property
    def state(self) -> str:
        return self._state

    @property
    def term(self) -> int:
        return self._term

    @property
    def voted_for(self) -> Optional[int]:
        return self._voted_for

    @property
    def leader_id(self) -> Optional[int]:
        return self._leader_id

    # ── internal transitions ──────────────────────────────────────────────────

    def _become_follower(self, term: int) -> None:
        self._state = FOLLOWER
        self._term = term
        self._voted_for = None
        self._votes_received = set()
        self._tick_count = 0
        self._leader_id = None

    def _start_election(self) -> None:
        self._state = CANDIDATE
        self._term += 1
        self._voted_for = self.node_id
        self._votes_received = {self.node_id}
        self._tick_count = 0
        for peer in self.peers:
            self.network.send(self.node_id, peer, {
                'type': 'request_vote',
                'term': self._term,
                'candidate_id': self.node_id,
            })
        # Single-node cluster: already a majority of one
        cluster_size = 1 + len(self.peers)
        if len(self._votes_received) > cluster_size // 2:
            self._become_leader()

    def _become_leader(self) -> None:
        self._state = LEADER
        self._leader_id = self.node_id
        self._tick_count = 0
        for peer in self.peers:
            self.network.send(self.node_id, peer, {
                'type': 'append_entries',
                'term': self._term,
                'leader_id': self.node_id,
            })

    # ── public interface ──────────────────────────────────────────────────────

    def tick(self) -> None:
        if self._state == LEADER:
            self._tick_count += 1
            heartbeat_interval = max(1, self.election_timeout // 2)
            if self._tick_count % heartbeat_interval == 0:
                for peer in self.peers:
                    self.network.send(self.node_id, peer, {
                        'type': 'append_entries',
                        'term': self._term,
                        'leader_id': self.node_id,
                    })
        else:
            self._tick_count += 1
            if self._tick_count >= self.election_timeout:
                self._start_election()

    def receive(self, msg: dict) -> None:
        msg_term = msg.get('term', 0)
        msg_type = msg['type']

        # Higher-term rule: always supersedes, regardless of message type
        if msg_term > self._term:
            self._become_follower(msg_term)

        if msg_type == 'request_vote':
            candidate_id = msg['candidate_id']
            can_vote = (
                msg_term >= self._term
                and (self._voted_for is None or self._voted_for == candidate_id)
            )
            if can_vote:
                self._voted_for = candidate_id
                self._tick_count = 0   # reset to avoid spurious election on granting
            self.network.send(self.node_id, candidate_id, {
                'type': 'vote_response',
                'term': self._term,
                'vote_granted': can_vote,
                'from': self.node_id,
            })

        elif msg_type == 'vote_response':
            if (
                self._state == CANDIDATE
                and msg_term == self._term
                and msg.get('vote_granted')
            ):
                self._votes_received.add(msg['from'])
                cluster_size = 1 + len(self.peers)
                if len(self._votes_received) > cluster_size // 2:
                    self._become_leader()

        elif msg_type == 'append_entries':
            if msg_term >= self._term:
                self._leader_id = msg.get('leader_id')
                self._tick_count = 0
                if self._state != FOLLOWER:
                    self._become_follower(msg_term)
                    # _become_follower clears leader_id; restore it
                    self._leader_id = msg.get('leader_id')
            self.network.send(self.node_id, msg.get('leader_id', -1), {
                'type': 'append_entries_response',
                'term': self._term,
                'success': msg_term >= self._term,
            })
```

## Why Each Step Is Correct

### `tick()` — LEADER path

Heartbeat interval is `election_timeout // 2`. With `election_timeout=5`, heartbeats go out every 2 ticks. Followers have timeouts of 7, 9, 11, 13 — they will always receive a heartbeat (resetting their tick counter) before they time out. This prevents unnecessary re-elections.

### `tick()` — FOLLOWER / CANDIDATE path

`tick_count >= election_timeout` (not `==`) handles the case where the counter overshoots. This cannot happen with deterministic simulation, but it's a correctness habit.

### `_start_election()` — single-node edge case

A single node with no peers calls `_start_election`, casts its own vote, and `len({self.node_id}) = 1 > 1 // 2 = 0` → immediately becomes leader. Without this check, a single-node cluster would never elect a leader (it sends 0 vote requests and never receives a vote response).

### `receive()` — higher-term rule placement

`_become_follower(msg_term)` is called **before** dispatching on `msg_type`. After the call:
- `self._term == msg_term`
- `self._voted_for == None`
- `self._state == FOLLOWER`

So when we then process `request_vote`:
- `msg_term >= self._term` is `msg_term >= msg_term` → `True`
- `voted_for is None` → `True`
- Vote granted. This is correct: if someone has a higher term, we definitely haven't voted in it yet.

### `receive()` — `append_entries` with state restoration

`_become_follower` clears `_leader_id`. Since we just received an `append_entries` from a legitimate leader, we want to know who the leader is. The line `self._leader_id = msg.get('leader_id')` restores it after the transition.

### `receive()` — vote idempotency

If a candidate re-sends `request_vote` (e.g., the first was lost) and we already voted for them (`voted_for == candidate_id`), we grant again. This is Raft's idempotency rule — it prevents a follower from being permanently stuck if the response was lost in transit.

## Correctness Walk-Through (3-node cluster)

Nodes: 0 (timeout=5), 1 (timeout=7), 2 (timeout=9).

```
Tick 5:
  node 0: tick_count=5 >= 5 → _start_election()
    term=1, voted_for=0, votes={0}
    sends RV(term=1, candidate=0) to 1 and 2

net.drain():
  node 1 receives RV(term=1, cand=0):
    msg_term(1) == self._term(0)? No, 1 > 0 → _become_follower(1)
    now: term=1, voted_for=None
    can_vote: 1 >= 1 and voted_for is None → True
    voted_for = 0, tick_count = 0
    sends VR(term=1, granted=True, from=1) to 0
  node 2: identical → sends VR(term=1, granted=True, from=2) to 0

net.drain():
  node 0 receives VR(from=1, granted=True):
    state==CANDIDATE, term==1, granted → votes={0,1}, size=2
    2 > 3//2=1 → MAJORITY → _become_leader()
    sends AE(term=1, leader=0) to 1 and 2
  node 0 receives VR(from=2, granted=True):
    state==LEADER now → condition self._state==CANDIDATE fails → ignored

net.drain():
  node 1 receives AE(term=1, leader=0):
    msg_term(1) >= self._term(1) → leader_id=0, tick_count=0
    state is already FOLLOWER → no transition needed
  node 2: identical
```

After this: node 0 is LEADER (term=1), nodes 1 and 2 are FOLLOWER (term=1). Exactly one leader.

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Applying higher-term rule *after* dispatch | A `request_vote` with higher term doesn't reset `voted_for` before granting → double votes | Move higher-term check before dispatch |
| Storing `voted_for = candidate` inside `_become_follower` | Clears the vote when higher-term AE arrives mid-election | Keep `_become_follower` as a clean reset; set `voted_for` only in vote handling |
| Checking `>` instead of `>=` in `can_vote`'s term check | Denies votes for current term → no leader ever elected | Use `msg_term >= self._term` |
| Checking `>` instead of `>=` in `append_entries` guard | Follower doesn't reset on heartbeats from current leader → spurious elections | Use `msg_term >= self._term` |
| Forgetting single-node edge case | Single-node cluster never becomes leader (never receives vote) | Check majority immediately after voting for self in `_start_election` |
| `cluster_size = len(self.peers)` instead of `1 + len(peers)` | Majority threshold is off-by-one → either elects with too few votes or never elects | Always include self in cluster size |

## War Story

At an on-site, I was asked to implement Raft on a whiteboard. I got the algorithm right but wrote `voted_for = candidate` *inside* the `if msg_term > self._term` branch. The subtle bug: when I received a `request_vote` with **equal** term (common during re-elections), the higher-term branch didn't fire, and I never set `voted_for` — so both candidates in a split election could receive a yes vote from the same node. The safety invariant broke. The interviewer caught it by asking: "walk me through a two-candidate split vote at term T." The fix is one line. Moral: the higher-term update and the vote granting are separate operations; keep them clearly separated.

## Apply and Verify

```bash
cd ~/.kube-dojo-work/06-raft-leader-election
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-20-database-engineering/challenges/06-raft-leader-election/verify.sh
```
