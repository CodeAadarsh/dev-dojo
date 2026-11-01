#!/usr/bin/env bash
# Verifier for "Size the Pool".
# Runs a hidden pytest harness; prints the flag only when all three scenarios pass.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-size-the-pool"
FLAG='KUBE{littles_law_pool_sized_for_stability}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/pool_sizer.py" ] || fail "pool_sizer.py not found — run setup.sh first"

PYTEST=""
if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPDIR_HIDDEN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cp "$WORK/pool_sizer.py" "$TMPDIR_HIDDEN/"

cat > "$TMPDIR_HIDDEN/test_hidden.py" << 'PYEOF'
"""
Hidden verifier tests for 05-size-the-pool.
Each scenario checks:
  (a) formula correctness: returned c is within [c_min, c_min+1]
  (b) simulation stability: throughput >= target*0.90 and max_queue_depth <= 200
"""
import math
import heapq
import random
from dataclasses import dataclass

from pool_sizer import compute_pool_size


# ── inline simulator (tamper-resistant) ──────────────────────────────────────
@dataclass
class SimResult:
    actual_throughput_rps: float
    max_queue_depth: int
    final_queue_length: int
    completed: int


def simulate(arrival_rate_rps, service_time_s, pool_size, duration_s=60.0, seed=42):
    rng = random.Random(seed)
    ARRIVE, DEPART = 0, 1
    events = []
    _ctr = [0]

    def push(t, etype, worker=-1):
        _ctr[0] += 1
        heapq.heappush(events, (t, etype, _ctr[0], worker))

    t = 0.0
    while True:
        t += rng.expovariate(arrival_rate_rps)
        if t >= duration_s:
            break
        push(t, ARRIVE)

    free_workers = list(range(pool_size))
    waiting = []
    completed = 0
    max_queue_depth = 0

    while events:
        now, etype, _, worker_id = heapq.heappop(events)
        if etype == ARRIVE:
            if free_workers:
                w = free_workers.pop()
                svc = rng.expovariate(1.0 / service_time_s)
                push(now + svc, DEPART, w)
            else:
                waiting.append(now)
                if len(waiting) > max_queue_depth:
                    max_queue_depth = len(waiting)
        elif etype == DEPART:
            completed += 1
            if waiting:
                waiting.pop(0)
                svc = rng.expovariate(1.0 / service_time_s)
                push(now + svc, DEPART, worker_id)
            else:
                free_workers.append(worker_id)

    return SimResult(
        actual_throughput_rps=completed / duration_s,
        max_queue_depth=max_queue_depth,
        final_queue_length=len(waiting),
        completed=completed,
    )


# ── scenarios ────────────────────────────────────────────────────────────────
HEADROOM = 0.20
MAX_QUEUE_THRESHOLD = 200
DURATION = 60.0

SCENARIOS = [
    dict(lam=80.0,  w=0.025, target=80.0),   # λW=2.0, c_min=3
    dict(lam=150.0, w=0.010, target=150.0),   # λW=1.5, c_min=2
    dict(lam=500.0, w=0.006, target=500.0),   # λW=3.0, c_min=4
]


def _run_scenario(s):
    lam, w, target = s["lam"], s["w"], s["target"]
    c_min = math.ceil(lam * w / (1 - HEADROOM))

    c = compute_pool_size(lam, w, target, HEADROOM)
    assert isinstance(c, int) and c >= 1, (
        f"compute_pool_size must return a positive int, got {c!r}"
    )
    assert c_min <= c <= c_min + 1, (
        f"λ={lam} W={w}: expected c in [{c_min}, {c_min+1}], got {c}"
    )

    result = simulate(lam, w, c, duration_s=DURATION, seed=42)
    assert result.actual_throughput_rps >= target * 0.90, (
        f"λ={lam} W={w} c={c}: throughput {result.actual_throughput_rps:.1f} "
        f"< {target * 0.90:.1f}"
    )
    assert result.max_queue_depth <= MAX_QUEUE_THRESHOLD, (
        f"λ={lam} W={w} c={c}: queue depth {result.max_queue_depth} "
        f"> {MAX_QUEUE_THRESHOLD} — system is saturated"
    )


def test_scenario_1_lam80_w025():  _run_scenario(SCENARIOS[0])
def test_scenario_2_lam150_w010(): _run_scenario(SCENARIOS[1])
def test_scenario_3_lam500_w006(): _run_scenario(SCENARIOS[2])
PYEOF

cd "$TMPDIR_HIDDEN"

if $PYTEST test_hidden.py -v 2>&1; then
    echo
    echo "All three scenarios passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "one or more scenarios failed — fix pool_sizer.py and retry"
fi
