# Solution: Size the Pool

## The formula

Little's Law states that in any stable system: `L = λW`

where:
- `L` = mean number of requests in the system (queue + in-service)
- `λ` = arrival rate (rps)  
- `W` = mean time a request spends in the system (service time, if queue is short)

For a stable M/M/c queue the per-server utilisation is `ρ = λ / (c × μ) = λW / c`. Stability requires `ρ < 1`. Adding a safety headroom `h` (buffer capacity for bursts) tightens the bound:

```
ρ ≤ 1 − h  →  λW / c ≤ 1 − h  →  c ≥ λW / (1 − h)
```

The minimum integer satisfying this is `ceil(λW / (1 − h))`.

## Implementation

```python
import math


def compute_pool_size(
    arrival_rate_rps: float,
    service_time_s: float,
    target_throughput_rps: float,
    safety_headroom: float = 0.20,
) -> int:
    # Use whichever is larger: the expected arrival rate or the throughput target.
    # In most cases they are the same value, but a target higher than lambda
    # means you want spare capacity beyond steady-state.
    lambda_eff = max(arrival_rate_rps, target_throughput_rps)
    # λW is the "traffic intensity" in Erlangs — the Little's Law numerator.
    traffic_intensity = lambda_eff * service_time_s
    max_utilisation = 1.0 - safety_headroom
    return max(1, math.ceil(traffic_intensity / max_utilisation))
```

## Verification walk-through for the three scenarios

| Scenario | λ | W | λW | `max_util` | `ceil(λW/max_util)` | `c` |
|----------|---|---|-----|------------|---------------------|-----|
| 1 | 80 | 0.025 | 2.0 | 0.80 | ceil(2.5) | **3** |
| 2 | 150 | 0.010 | 1.5 | 0.80 | ceil(1.875) | **2** |
| 3 | 500 | 0.006 | 3.0 | 0.80 | ceil(3.75) | **4** |

With scenario 1, `c=3` gives `ρ = 2.0/3 = 0.667` — running at 67% utilisation, well within the 80% budget. The remaining 13% is the burst absorber.

## The queue instability test

Why does the verifier also run the simulator? Because the formula gives you the *minimum* — it is not obvious from `ceil(...)` alone whether `c=2` vs `c=3` matters in practice. The simulator demonstrates:

- **c = 2** (one short): ρ = 2.0/2 = 1.0 — mathematically unstable. With seed=42 over 60s the queue depth climbs past 200.
- **c = 3** (correct): ρ = 0.667 — stable. Queue depth stays below 10.

This is why the incident in the brief happened: the team *thought* they had headroom, but they used P50 service time instead of P99. At P50 the pool was stable; under P99 load it hit `ρ > 1` and the queue entered a death spiral.

## The latency knee

There is a subtler reason to add headroom beyond `ρ < 1`. For an M/M/1 queue:

```
E[L_q] = ρ² / (1 − ρ)
```

At `ρ = 0.5`: E[L_q] = 0.5  
At `ρ = 0.8`: E[L_q] = 3.2  
At `ρ = 0.9`: E[L_q] = 8.1  
At `ρ = 0.95`: E[L_q] = 18  

The queue length (and latency) explodes non-linearly as `ρ → 1`. The "latency knee" is around `ρ = 0.7 – 0.8` — which is exactly why the 20% headroom targets `ρ ≤ 0.8`. Running at 80% means you are near the knee but not past it.
