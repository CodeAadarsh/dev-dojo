# Estimation Drill: Metrics Ingestion Pipeline

The system-design interviewer writes the spec on the virtual whiteboard and then waits — silent. *"Let's size the ingestion tier before we design it."*

This is not a trick question and it is not a memory test. It is a test of whether you can derive defensible numbers from first principles, write units through every step, and use the resulting figures to drive a design decision. Estimation without units is guessing. Guessing in a Tier-1 interview is a strong no-hire signal.

This drill gives you a concrete spec and asks for three numbers. `checker.py` validates each one within ±10% of the reference figure, so there is no ambiguity about whether you are close enough.

## Context

`setup.sh` creates a work directory:

```
~/.kube-dojo-work/05-estimation-drill/
├── worksheet.md    # the spec, the formula guide, your scratch pad
├── answers.py      # set your three variables here
└── checker.py      # validates your answers within ±10%; run to see per-field feedback
```

## Prerequisites

Python 3 in `PATH`. No packages.

```bash
cd ~/.kube-dojo-work/05-estimation-drill
python3 checker.py   # instant feedback
```

## The Spec

A platform team operates a real-time metrics ingestion service. Agents on each host scrape all configured metrics on a fixed interval and push each data point to the ingestion API.

| Parameter | Value |
|-----------|-------|
| Monitored hosts | 5 000 |
| Metrics per host | 20 |
| Scrape interval | 10 seconds |
| Bytes per data point (timestamp + labels + value, encoded) | 64 |
| Retention period | 1 year |

Assume **uniform load** — no burst factor. Derive the steady-state baseline; the interviewer will ask about burst headroom after you nail the baseline.

## Mission

Open `answers.py` and set the three variables:

```python
ingest_qps            = ...   # integer — data points arriving per second
storage_year_gib      = ...   # integer — total bytes stored per year, in GiB (1 GiB = 1024^3 bytes)
ingest_bandwidth_mibps = ...  # float   — aggregate ingest throughput in MiB/s
```

`checker.py` imports `answers.py` and checks each value is within **±10%** of the reference figure. It tells you exactly which values pass and which are off.

## Why this matters beyond the interview

These three numbers directly drive the architecture:

- **ingest_qps** determines whether your ingestion tier is a single write-optimized DB node or needs a write buffer (Kafka/Kinesis) and horizontal sharding. At 10K QPS you are near the single-node write ceiling for most TSDBs (Prometheus remote-write, InfluxDB). At 100K QPS you need a partitioned ingest layer.
- **storage_year_gib** tells you how many disks you need and when you need tiering. 18 TiB is one mid-range SSD array; 180 TiB demands a distributed store.
- **ingest_bandwidth_mibps** tells you whether the network is the bottleneck before any other layer is. Below ~100 MiB/s you are safe on commodity NICs; above that you are planning for bonded links or a compression tier.

## Formula reference

Derive, do not memorize. Work in units throughout.

```
ingest_qps              = hosts × metrics_per_host / scrape_interval_seconds

samples_per_year        = ingest_qps × seconds_per_day × days_per_year
bytes_per_year          = samples_per_year × bytes_per_point
storage_year_gib        = bytes_per_year / (1024^3)

ingest_bandwidth_mibps  = ingest_qps × bytes_per_point / (1024^2)
```

Sanity-check by order of magnitude: 10K data points/second is within the range of mid-scale observability platforms. If your answer is 100 or 10 million, re-check the scrape interval divisor.

## Debugging Your Estimates

| Wrong answer | Likely mistake |
|-------------|---------------|
| ingest_qps way too high | Forgot to divide by scrape_interval (used 0 or 1 instead of 10) |
| storage_year_gib in the thousands of TiB range | Used bytes_per_year but forgot to convert to GiB; divide by 1024^3, not 1000^3 |
| storage_year_gib under 1000 | Divided by 1024^3 but forgot to multiply by days_per_year (365) |
| ingest_bandwidth_mibps off by 1024× | Divided by 1024 once (KiB/s) instead of twice (MiB/s) |

## Verify

```bash
bash courses/course-35-sde2-interview-loop/challenges/05-estimation-drill/verify.sh
```

All three estimates within ±10% → flag printed.
