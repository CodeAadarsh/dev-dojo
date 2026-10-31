# Capacity Estimation: 100M-DAU Social Feed

An engineering candidate writes on their design doc: *"Storage is ~10 TB/year, so we're fine on a single node."* The interviewer pauses. The math is off by 35×. The candidate hadn't written down units, hadn't derived from first principles — they guessed. The design review ends early.

Estimation is the first gate in any system design interview and the first thing that breaks in production planning. The goal here is not to memorize answers — it's to derive them reliably, on any spec, in under five minutes.

## Context

`setup.sh` creates a work directory:

```
~/.kube-dojo-work/01-capacity-estimation/
├── worksheet.md    # the spec, the formula guide, your scratch pad
├── answers.py      # fill this in with your computed values
└── checker.py      # validates your answers within ±10% tolerance
```

## Prerequisites

Python 3 in `PATH` is all you need. No packages.

```bash
cd ~/.kube-dojo-work/01-capacity-estimation
python3 checker.py   # runs against your answers.py
```

## The Spec

| Parameter | Value |
|-----------|-------|
| Daily Active Users (DAU) | 100 000 000 |
| Posts per user per day | 10 |
| Average post size | 1 KB |

Assume **write traffic is uniform** across 86 400 seconds/day (no peak factor — the interviewer will ask you to add one later, but derive the baseline first).

## Mission

Open `answers.py` and set the three variables:

```python
writes_per_sec    = ...   # integer — peak writes per second at uniform load
storage_year_gb   = ...   # integer — total storage added per year, in GiB (1 GiB = 1024^3 bytes)
write_bandwidth_mbps = ... # float — aggregate write throughput in MiB/s
```

`checker.py` imports `answers.py` and asserts each value is within **±10%** of the reference figure. It tells you which values pass and which are off.

The verifier runs `checker.py` from `verify.sh` and prints the flag only when all three pass.

## Why ±10%?

In a real interview, an order-of-magnitude error fails you; a 5–15% rounding difference doesn't. Estimation teaches you to know *which* approximations are safe (e.g. treating 1000 and 1024 as equivalent in storage math) versus dangerous (e.g. forgetting to account for replication).

The three numbers you derive here are the numbers that drive every downstream design decision:
- **writes/sec** → how many write replicas you need, whether you need a write buffer (Kafka), what your DB write IOPS budget is.
- **storage/year** → how many disks, when you need tiering, how big your retention window is.
- **write bandwidth** → whether commodity NICs saturate, whether you need sharding at the storage layer before you hit any latency SLA.

## Formula reference

You are not supposed to memorise these — you are supposed to derive them.

```
writes_per_sec        = DAU × posts_per_user / seconds_per_day
total_bytes_per_year  = DAU × posts_per_user × post_size_bytes × 365
storage_year_gib      = total_bytes_per_year / (1024^3)
write_bandwidth_mibps = writes_per_sec × post_size_bytes / (1024^2)
```

Work through the units. If your answer is not in the right ballpark (10²–10⁵ writes/sec for internet-scale services), re-check.

## Verify

```bash
bash courses/course-14-system-design/challenges/01-capacity-estimation/verify.sh
```

All three estimates within ±10% → flag printed.
