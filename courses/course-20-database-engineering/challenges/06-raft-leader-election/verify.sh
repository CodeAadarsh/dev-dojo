#!/usr/bin/env bash
# Verifier for "Raft Leader Election".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="06-raft-leader-election"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{raft_leader_election_majority}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ]  || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import Network, RaftNode, FOLLOWER, CANDIDATE, LEADER


def _build_cluster(n, base_timeout=5, timeout_step=2):
    net = Network()
    nodes = {}
    for i in range(n):
        peers = [j for j in range(n) if j != i]
        nodes[i] = RaftNode(
            i, peers, net,
            election_timeout=base_timeout + i * timeout_step
        )
    return net, nodes


def _run(net, nodes, rounds=40, drains_per_round=4):
    for _ in range(rounds):
        for node in nodes.values():
            node.tick()
        for _ in range(drains_per_round):
            net.drain(nodes)


# ── basic election ────────────────────────────────────────────────────────────

def test_three_node_exactly_one_leader():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1, (
        f"expected exactly 1 leader in 3-node cluster, got {len(leaders)}: "
        f"{[(n.node_id, n.state, n.term) for n in nodes.values()]}"
    )


def test_five_node_exactly_one_leader():
    net, nodes = _build_cluster(5)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1, (
        f"expected exactly 1 leader in 5-node cluster, got {len(leaders)}: "
        f"{[(n.node_id, n.state, n.term) for n in nodes.values()]}"
    )


def test_followers_not_leader():
    net, nodes = _build_cluster(5)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    non_leaders = [n for n in nodes.values() if n.state != LEADER]
    assert len(non_leaders) == 4, (
        f"expected 4 non-leaders, got {[(n.node_id, n.state) for n in non_leaders]}"
    )


def test_leader_has_positive_term():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    assert leaders[0].term >= 1, "leader term must be at least 1"


def test_all_nodes_same_term_after_convergence():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    terms = [n.term for n in nodes.values()]
    assert len(set(terms)) == 1, (
        f"all nodes should agree on term after convergence, got: {terms}"
    )


def test_leader_state_string():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    assert leaders[0].state == 'leader', "state property must return the string 'leader'"


# ── higher-term invariant ─────────────────────────────────────────────────────

def test_higher_term_request_vote_demotes_leader():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    leader = leaders[0]
    old_term = leader.term

    leader.receive({'type': 'request_vote', 'term': old_term + 5, 'candidate_id': 99})

    assert leader.state == FOLLOWER, (
        f"leader must become follower after higher-term request_vote, got {leader.state!r}"
    )
    assert leader.term == old_term + 5, (
        f"leader term must update to {old_term + 5}, got {leader.term}"
    )


def test_higher_term_append_entries_demotes_leader():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    leader = leaders[0]
    old_term = leader.term

    leader.receive({'type': 'append_entries', 'term': old_term + 3, 'leader_id': 99})

    assert leader.state == FOLLOWER, (
        f"leader must become follower after higher-term append_entries, got {leader.state!r}"
    )
    assert leader.term == old_term + 3


def test_lower_term_request_vote_ignored():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    leader = leaders[0]
    old_state = leader.state
    old_term = leader.term

    leader.receive({'type': 'request_vote', 'term': old_term - 1, 'candidate_id': 99})

    assert leader.state == old_state, "stale-term request_vote must not change leader state"
    assert leader.term == old_term, "stale-term request_vote must not change leader term"


# ── re-election after step-down ───────────────────────────────────────────────

def test_new_election_after_stepdown():
    net, nodes = _build_cluster(3)
    _run(net, nodes)
    leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(leaders) == 1
    leader = leaders[0]
    old_term = leader.term

    # Force leader to step down
    leader.receive({'type': 'request_vote', 'term': old_term + 1, 'candidate_id': 99})
    assert leader.state == FOLLOWER

    # Run more rounds — a new leader should emerge
    _run(net, nodes, rounds=40, drains_per_round=4)
    new_leaders = [n for n in nodes.values() if n.state == LEADER]
    assert len(new_leaders) == 1, (
        f"expected 1 new leader after step-down, got {len(new_leaders)}: "
        f"{[(n.node_id, n.state, n.term) for n in nodes.values()]}"
    )
    assert new_leaders[0].term > old_term, "new leader must have a higher term"


# ── single-node degenerate case ───────────────────────────────────────────────

def test_single_node_becomes_leader():
    net = Network()
    nodes = {0: RaftNode(0, [], net, election_timeout=3)}
    _run(net, nodes)
    assert nodes[0].state == LEADER, (
        f"single node with no peers must elect itself, got {nodes[0].state!r}"
    )
    assert nodes[0].term >= 1


# ── voted_for semantics ───────────────────────────────────────────────────────

def test_no_double_vote_same_term():
    """A node that already voted in term T must not grant a second vote."""
    net = Network()
    # Node 0 is the voter; nodes 1 and 2 are candidates
    node0 = RaftNode(0, [1, 2], net, election_timeout=100)

    # Manually send two RequestVote for the same term from different candidates
    node0.receive({'type': 'request_vote', 'term': 1, 'candidate_id': 1})
    node0.receive({'type': 'request_vote', 'term': 1, 'candidate_id': 2})

    # Drain the network: collect vote_response messages sent by node0
    responses = net._queue[:]
    net._queue.clear()

    granted = [msg for (_f, _t, msg) in responses if msg.get('vote_granted')]
    assert len(granted) == 1, (
        f"node should grant exactly one vote per term, granted {len(granted)}"
    )
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
