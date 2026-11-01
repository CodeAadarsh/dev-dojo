# Solution: Capacity Estimate

## The computation

From `spec.json`:
- `target_qps = 800`
- `p99_service_time_ms = 12`
- `slo_headroom_fraction = 0.25`

```python
import math, json

spec        = json.load(open("spec.json"))
max_rps     = 1000.0 / spec["p99_service_time_ms"]          # 83.333 rps per instance
eff_rps     = max_rps * (1 - spec["slo_headroom_fraction"])  # 83.333 × 0.75 = 62.5 rps
req         = math.ceil(spec["target_qps"] / eff_rps)       # ceil(800 / 62.5) = ceil(12.8) = 13
max_qps     = req * eff_rps                                  # 13 × 62.5 = 812.5 qps
```

**Fill in `answers.py`:**

```python
REQUIRED_INSTANCES: int = 13
MAX_SUSTAINABLE_QPS: float = 812.5
```

## Why each step

**`max_rps_per_instance = 1000 / 12 = 83.33`**
A single-threaded instance can handle at most one request at a time. With a service time of 12ms, it completes 1000/12 ≈ 83 requests per second if given a steady stream. This is the *theoretical ceiling* — you never actually run here.

**`effective_rps = 83.33 × 0.75 = 62.5`**
The 25% headroom means you keep each instance below 75% utilisation. This leaves capacity for:
- Traffic bursts (flash sale spikes don't arrive at exactly 800 QPS)
- GC pauses (a 50ms GC on a 12ms service time kills headroom fast)
- Background work (health checks, metrics scraping, connection handshakes)

**`required_instances = ceil(800 / 62.5) = ceil(12.8) = 13`**
You cannot run 12.8 instances. `ceil` gives the smallest integer that *covers* the target. With 12 instances: `12 × 62.5 = 750 QPS` — 50 QPS short of target. With 13: `812.5 QPS` — 12.5 QPS of spare headroom.

**`max_sustainable_qps = 13 × 62.5 = 812.5`**
This is the number to put in your runbook: "we breach SLO if QPS exceeds 812". It is the fleet capacity, not the target. When the PM asks "can we handle 850?", the answer is no — add one more instance to get `14 × 62.5 = 875 QPS`.

## Common mistakes

| Mistake | Effect |
|---------|--------|
| Using P50 service time (2–5ms instead of 12ms) | Over-estimates capacity per instance by 3–6×; fleet is 3–6× under-provisioned under P99 load |
| Forgetting to `ceil` | 12.8 instances rounds to 12, which is short by 50 QPS |
| Using headroom as a multiplier on instances instead of subtracting from utilisation | Produces `ceil(800/83.33) × 1.25 = 12` — still misses the formula |
| Not accounting for replicas the load balancer drops during rolling deploys | During a 13-instance deploy with 1 instance down at a time, effective capacity = `12 × 62.5 = 750 QPS` — you are already below target during the deploy window |
