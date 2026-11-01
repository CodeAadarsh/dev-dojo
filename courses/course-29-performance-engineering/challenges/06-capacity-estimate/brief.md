# Capacity Estimate

Your team is preparing for a flash sale. A product manager asks: *"How many checkout-service instances do we need? And what is the max QPS we can handle before we're in trouble?"*

You have three numbers from the load test last sprint:
- Peak target: **800 QPS**
- P99 service time (measured at 40% load): **12 ms**
- SLO headroom: **25%** (keep each instance's CPU utilisation at or below 75%)

This is a back-of-envelope calculation that every SDE should be able to do in under two minutes. `setup.sh` gives you the spec and a worksheet; fill in your answers and run the verifier.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/06-capacity-estimate/
├── spec.json    # problem parameters (do not modify)
├── answers.py   # fill in REQUIRED_INSTANCES and MAX_SUSTAINABLE_QPS
└── checker.py   # visible checker — run this before verify.sh
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-capacity-estimate
python3 -m venv .venv && . .venv/bin/activate
# no additional packages needed
```

## The Math

```
max_rps_per_instance   = 1000 / p99_service_time_ms
effective_rps          = max_rps_per_instance × (1 − slo_headroom_fraction)
required_instances     = ceil(target_qps / effective_rps)    ← integer
max_sustainable_qps    = required_instances × effective_rps  ← float
```

The SLO headroom reserves capacity for burst absorption and GC pauses — running an instance at 100% means the first spike causes latency to blow through the SLO.

## Mission

Open `answers.py` and set:
- `REQUIRED_INSTANCES` — the minimum integer instance count
- `MAX_SUSTAINABLE_QPS` — total QPS the fleet can sustain at the target utilisation level

## Verify

`verify.sh` accepts `REQUIRED_INSTANCES` within ±1 of the correct value, and `MAX_SUSTAINABLE_QPS` within ±10%.

```bash
# Development loop: run the visible checker first
python3 checker.py

# When checker is green:
bash courses/course-29-performance-engineering/challenges/06-capacity-estimate/verify.sh
```

## Why this matters

Without this calculation, teams either:
1. **Under-provision**: latency SLOs breach under the first real traffic spike.
2. **Over-provision by feel**: "let's add 30% more instances" — right order of magnitude but non-reproducible and wrong after any service-time regression.

The formula is mechanical, but the inputs require discipline. P99 service time must come from the service *under load*, not idle — the numbers change by 2–5× under realistic concurrency. Using P50 (as in challenge 05's incident) is the most common mistake.
