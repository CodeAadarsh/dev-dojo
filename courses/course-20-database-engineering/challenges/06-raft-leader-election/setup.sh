#!/usr/bin/env bash
# Plants the "Raft Leader Election" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="06-raft-leader-election"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Raft leader election state machine
#
# Implement RaftNode.tick() and RaftNode.receive().
# The Network class and RaftNode.__init__ are complete — do not change them.
#
# Message types used in this simulation:
#   {'type': 'request_vote',          'term': int, 'candidate_id': int}
#   {'type': 'vote_response',         'term': int, 'vote_granted': bool, 'from': int}
#   {'type': 'append_entries',        'term': int, 'leader_id': int}
#   {'type': 'append_entries_response','term': int, 'success': bool}
from __future__ import annotations
from typing import Optional

FOLLOWER  = 'follower'
CANDIDATE = 'candidate'
LEADER    = 'leader'


class Network:
    """Injectable in-memory message bus. Provided — do not modify."""

    def __init__(self) -> None:
        self._queue: list[tuple[int, int, dict]] = []

    def send(self, from_id: int, to_id: int, msg: dict) -> None:
        self._queue.append((from_id, to_id, msg))

    def drain(self, nodes: dict[int, 'RaftNode']) -> None:
        """Deliver all enqueued messages to their recipients."""
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

        # Persistent-ish state (reset on init only for this simulation)
        self._term: int = 0
        self._voted_for: Optional[int] = None

        # Volatile state
        self._state: str = FOLLOWER
        self._votes_received: set[int] = set()
        self._tick_count: int = 0
        self._leader_id: Optional[int] = None

    # ── read-only properties ──────────────────────────────────────────────────

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

    # ── methods you must implement ────────────────────────────────────────────

    def tick(self) -> None:
        """Advance the logical clock by one tick.

        Follower/Candidate: increment _tick_count; when it reaches
        election_timeout, start an election.

        Leader: increment _tick_count; send AppendEntries heartbeat to all
        peers every (election_timeout // 2) ticks.

        Starting an election:
          - increment _term
          - set _voted_for = self.node_id
          - set _state = CANDIDATE
          - add self.node_id to _votes_received
          - reset _tick_count = 0
          - send {'type':'request_vote','term':_term,'candidate_id':node_id}
            to every peer via self.network.send()
        """
        raise NotImplementedError

    def receive(self, msg: dict) -> None:
        """Handle one incoming message.

        Higher-term rule (apply first, for EVERY message type):
          if msg['term'] > self._term:
            self._term = msg['term']
            self._state = FOLLOWER
            self._voted_for = None
            self._votes_received = set()
            self._leader_id = None

        Then dispatch on msg['type']:

        'request_vote':
          Grant if msg['term'] >= self._term AND
                   (self._voted_for is None OR self._voted_for == candidate_id).
          Reply with vote_response to the candidate.

        'vote_response':
          If state==CANDIDATE and msg['term']==self._term and vote_granted:
            add sender to _votes_received.
            If len(_votes_received) > (1 + len(peers)) // 2: become leader.
            Becoming leader: set state='leader', send AppendEntries to all peers.

        'append_entries':
          If msg['term'] >= self._term:
            record leader_id, reset _tick_count, become follower if not already.
          Reply with append_entries_response.
        """
        raise NotImplementedError
PYEOF

# ── tests/test_sample.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import Network, RaftNode, FOLLOWER, CANDIDATE, LEADER


def _build_cluster(n, base_timeout=5, timeout_step=2):
    net = Network()
    nodes = {}
    for i in range(n):
        peers = [j for j in range(n) if j != i]
        nodes[i] = RaftNode(i, peers, net, election_timeout=base_timeout + i * timeout_step)
    return net, nodes


def _run(net, nodes, rounds=30, drains_per_round=3):
    for _ in range(rounds):
        for node in nodes.values():
            node.tick()
        for _ in range(drains_per_round):
            net.drain(nodes)


def test_three_node_leader_elected():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1, f"expected 1 leader, got {len(leaders)}"


def test_higher_term_demotes_leader():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    leader = leaders[0]
    old_term = leader.term
    # Inject a higher-term RequestVote from a phantom node
    leader.receive({'type': 'request_vote', 'term': old_term + 10, 'candidate_id': 99})
    assert leader.state == FOLLOWER, "leader must step down on higher-term message"
    assert leader.term == old_term + 10
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement RaftNode.tick() and RaftNode.receive()"
echo "                   in solution.py so all tests pass."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
