# Size the Pool

A post-incident review surfaces this line in the metrics: *"The worker pool was set to 4. Arrival rate was 150 rps. P99 service time was 10ms. The queue depth climbed to 12 000 before the pager fired."*

The fix is three lines of arithmetic. The discipline of doing that arithmetic *before* deploying is called capacity planning, and Little's Law is its foundation. This challenge makes you do it in code so you can automate it for any future service.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/05-size-the-pool/
├── pool_sizer.py       # skeleton — implement compute_pool_size()
├── simulator.py        # deterministic M/M/c queue sim — read it, do not modify
└── tests/
    └── test_visible.py # two smoke tests
```

`simulator.py` is a discrete-event M/M/c queue simulator (Poisson arrivals, exponential service, `c` workers, fixed random seed). It returns `actual_throughput_rps` and `max_queue_depth`. `verify.sh` uses its own inline copy of the simulator.

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-size-the-pool
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## The Math

**Little's Law**: `L = λW`
- `L` — mean number of requests in the system (workers + queue)
- `λ` — arrival rate (rps)
- `W` — mean service time (seconds)

**Stability condition** for an M/M/c queue: traffic intensity per server `ρ = λW / c < 1`.

With a safety headroom of `h` (keep utilisation ≤ `1 − h`):

```
c_min = ceil(λ × W / (1 − h))
```

## Mission

Implement `compute_pool_size(arrival_rate_rps, service_time_s, target_throughput_rps, safety_headroom)` in `pool_sizer.py`.

`verify.sh` runs three scenarios and asserts **both** of these for each:

| Check | What the verifier asserts |
|-------|--------------------------|
| Formula correct | `ceil(λW / (1−h)) ≤ returned_c ≤ ceil(λW / (1−h)) + 1` |
| Simulation stable | `actual_throughput_rps ≥ target × 0.90` **and** `max_queue_depth ≤ 200` |

The three scenarios (all with `safety_headroom=0.20`):

| Scenario | λ (rps) | W (s) | λW | Correct `c` |
|----------|---------|-------|-----|-------------|
| 1 | 80 | 0.025 | 2.0 | 3 |
| 2 | 150 | 0.010 | 1.5 | 2 |
| 3 | 500 | 0.006 | 3.0 | 4 |

## Why it matters

The incident above: `λ=150, W=0.010 → λW=1.5`. Pool of 4 (ρ=0.375) would have been fine. Pool of 4 was actually fine. So why did the queue blow up? Because the *wrong* service-time was used — P50 (2ms) was substituted for P99 (10ms). The pool was sized for P50 traffic and couldn't keep up during the P99 spikes. Capacity planning with the wrong percentile is worse than no capacity planning, because it creates false confidence.

## Verify

```bash
bash courses/course-29-performance-engineering/challenges/05-size-the-pool/verify.sh
```

All three scenarios pass → flag printed.
