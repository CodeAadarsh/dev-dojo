#!/usr/bin/env bash
# Plants the "Size the Pool" starter project into the work directory.
# Idempotent — re-running overwrites skeleton files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-size-the-pool"
mkdir -p "$WORK/tests"

# ── simulator.py (read-only reference) ───────────────────────────────────────
cat > "$WORK/simulator.py" << 'PYEOF'
"""
simulator.py — deterministic M/M/c queue simulator.

Model: M/M/c queue (Poisson arrivals, exponential service times, c workers).
  arrival_rate_rps : λ  — mean arrivals per second
  service_time_s   : W  — mean service time per request (exponential distribution)
  pool_size        : c  — number of parallel workers (your answer goes here)
  duration_s       : simulation horizon in seconds (default 60)
  seed             : random seed for reproducibility (default 42)

Returns a SimResult with:
  actual_throughput_rps : requests completed / duration_s
  max_queue_depth       : peak number of requests waiting (not yet being served)
  final_queue_length    : queue length at end of simulation (> 0 → likely unstable)
  completed             : total requests completed

Read this file to understand the model.  Do NOT modify it.
verify.sh uses its own inline copy.
"""
import heapq
import random
from dataclasses import dataclass


@dataclass
class SimResult:
    actual_throughput_rps: float
    max_queue_depth: int
    final_queue_length: int
    completed: int


def simulate(
    arrival_rate_rps: float,
    service_time_s: float,
    pool_size: int,
    duration_s: float = 60.0,
    seed: int = 42,
) -> SimResult:
    rng = random.Random(seed)

    ARRIVE = 0
    DEPART = 1
    events: list = []
    _counter = [0]

    def push(t: float, etype: int, worker: int = -1) -> None:
        _counter[0] += 1
        heapq.heappush(events, (t, etype, _counter[0], worker))

    # Pre-generate all arrival events
    t = 0.0
    while True:
        t += rng.expovariate(arrival_rate_rps)
        if t >= duration_s:
            break
        push(t, ARRIVE)

    free_workers = list(range(pool_size))  # stack of idle worker IDs
    waiting: list = []                     # queue of pending requests (arrival times)
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
PYEOF

# ── pool_sizer.py skeleton ────────────────────────────────────────────────────
cat > "$WORK/pool_sizer.py" << 'PYEOF'
"""
pool_sizer.py — implement compute_pool_size using Little's Law.

Little's Law: L = λW
  L  = mean number of requests in the system
  λ  = arrival rate (rps)
  W  = mean service time per request (seconds)

Stability condition for an M/M/c queue:
  utilisation per server  ρ = λW / c  must be < 1

With safety headroom h (keep utilisation ≤ 1 − h):
  c ≥ λW / (1 − h)  →  c_min = ceil(λW / (1 − h))
"""
import math


def compute_pool_size(
    arrival_rate_rps: float,
    service_time_s: float,
    target_throughput_rps: float,
    safety_headroom: float = 0.20,
) -> int:
    """
    Return the minimum worker count c such that:
      1. ρ = λW / c ≤ (1 − safety_headroom)   — queue is stable with headroom
      2. The pool can sustain at least target_throughput_rps

    Args:
        arrival_rate_rps:      λ — expected arrival rate (rps)
        service_time_s:        W — mean service time per request (seconds)
        target_throughput_rps: minimum throughput the pool must sustain (rps)
        safety_headroom:       fraction of capacity to reserve (default 0.20)

    Returns:
        Minimum integer pool size satisfying stability + headroom + throughput.
    """
    raise NotImplementedError("implement compute_pool_size")
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
"""Visible smoke tests — verify the function signature and a trivial case."""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pool_sizer import compute_pool_size


def test_returns_int():
    c = compute_pool_size(
        arrival_rate_rps=10.0,
        service_time_s=0.05,
        target_throughput_rps=10.0,
    )
    assert isinstance(c, int), f"expected int, got {type(c).__name__}"
    assert c >= 1, f"pool size must be >= 1, got {c}"


def test_trivial_single_worker():
    # λ=5 rps, W=0.1s → λW=0.5 → ρ=0.5 < 0.8 → 1 worker sufficient
    c = compute_pool_size(
        arrival_rate_rps=5.0,
        service_time_s=0.1,
        target_throughput_rps=5.0,
        safety_headroom=0.20,
    )
    assert c >= 1
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : implement compute_pool_size() in $WORK/pool_sizer.py"
echo "                  so that all three verifier scenarios pass."
echo
echo "Prerequisites   :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run smoke tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag   : bash courses/course-29-performance-engineering/challenges/05-size-the-pool/verify.sh"
