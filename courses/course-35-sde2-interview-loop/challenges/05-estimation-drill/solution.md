# Solution — Estimation Drill: Metrics Ingestion Pipeline

The flag is `KUBE{estimation_drill_passed}`.

## The derivation

**Spec constants:**

```
hosts                = 5 000
metrics_per_host     = 20
scrape_interval_s    = 10
bytes_per_point      = 64
seconds_per_day      = 86 400
days_per_year        = 365
```

### 1. Ingest QPS

```
data_points_per_scrape  = 5 000 × 20     = 100 000 per scrape cycle
ingest_qps              = 100 000 / 10   = 10 000 data points/second
```

The ±10% accepted range is **9 000 – 11 000 qps**.

This is the number that immediately determines your ingestion architecture. 10K writes/second pushes the ceiling of a single write-optimized node (Prometheus remote-write saturates around 50K samples/s, but you want headroom). At 3× burst you hit 30K writes/s — that is the boundary where most teams introduce a write buffer (Kafka topic, Kinesis stream) in front of the DB to absorb spikes.

### 2. Storage per year (GiB)

```
samples_per_day         = 10 000 × 86 400            = 864 000 000 samples/day
samples_per_year        = 864 000 000 × 365           = 315 360 000 000 samples/year
bytes_per_year          = 315 360 000 000 × 64        = 20 183 040 000 000 bytes/year
storage_year_gib        = 20 183 040 000 000 / 1024^3 ≈ 18 796 GiB
```

The ±10% accepted range is **16 916 – 20 676 GiB** (roughly 16.5 – 20.2 TiB).

~18.3 TiB of raw time-series data per year. Without compression that fits on two enterprise SSDs. With a typical TSDBs 10:1 compression ratio you are looking at ~1.8 TiB — comfortably on a single well-provisioned node. With 3× replication that is ~5.5 TiB across the replica set. This is why the initial architecture can be a single primary + 2 replicas rather than a distributed cluster.

> **GiB vs GB:** 18 796 GiB = 20 183 GB (decimal). The ~7.4% gap is under the ±10% tolerance here, but in cost modeling (cloud storage is priced in GB) you should write both and be explicit about which you mean.

### 3. Ingest bandwidth (MiB/s)

```
bytes_per_second           = 10 000 × 64          = 640 000 bytes/s
ingest_bandwidth_mibps     = 640 000 / 1024^2     = 0.610 MiB/s
```

The ±10% accepted range is **0.549 – 0.671 MiB/s**.

0.61 MiB/s is ~5 Mbps. A commodity 1 Gbps NIC handles ~119 MiB/s — this pipeline is nowhere near network-bound. Even at 3× burst (1.83 MiB/s) and 3× replication (5.5 MiB/s total), you are using under 5% of a single NIC. The constraint for this system is write IOPS and index maintenance at the TSDB layer, not network bandwidth. Saying that in the interview shows you connect estimation to architecture.

## answers.py

```python
ingest_qps             = 10000
storage_year_gib       = 18796
ingest_bandwidth_mibps = 0.610
```

## What to say in the interview

After computing, interpret:

1. **"10K writes/second is within single-node range for most TSDBs, but I'd design for a 3× burst factor which puts us at 30K. I'd put a Kafka topic between the agents and the TSDB to buffer bursts and decouple ingest from storage."**
2. **"~18 TiB/year raw. With typical 10:1 TSDB compression that's under 2 TiB — fits on a well-provisioned replica set for a 1-year retention window. Beyond 2 years we'd look at downsampling older data."**
3. **"Bandwidth is 0.6 MiB/s — not a bottleneck. The constraint is write IOPS and label-index cardinality at the TSDB layer."**

## Common mistakes

| Mistake | Effect |
|---------|--------|
| Dividing by scrape_interval = 1 instead of 10 | ingest_qps is 10× too high |
| Using 1000^3 (decimal GB) instead of 1024^3 (binary GiB) | storage off by ~7% |
| Forgetting × 365 | storage off by 365× |
| Dividing bandwidth by 1024 instead of 1024^2 | result in KiB/s not MiB/s, off by 1024× |
| Not writing units through each step | silent mismatch impossible to audit |
