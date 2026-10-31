# Solution — Capacity Estimation: 100M-DAU Social Feed

The flag is `KUBE{capacity_estimation_unlocked}`.

## The numbers

**Spec constants:**

```
DAU              = 100 000 000
posts/user/day   = 10
post_size_bytes  = 1 024  (1 KB)
seconds_per_day  = 86 400
```

### 1. Writes per second

```
write_volume_per_day = 100 000 000 × 10 = 1 000 000 000 writes/day
writes_per_sec       = 1 000 000 000 / 86 400 = 11 574 writes/sec
```

Anything in the range **10 417 – 12 732** passes the ±10% check.

The interviewer's follow-up is almost always: "now add a 3× peak factor." That gives you **~35K writes/sec** — the point where you start thinking about a write buffer (Kafka, Kinesis) in front of your DB.

### 2. Storage per year (GiB)

```
bytes_per_day    = 1 000 000 000 × 1 024    = 1 024 000 000 000 bytes/day
bytes_per_year   = 1 024 000 000 000 × 365  = 373 760 000 000 000 bytes/year
storage_year_gib = 373 760 000 000 000
                   / (1 024 × 1 024 × 1 024)
                 ≈ 348 091 GiB  (accepted range: 313 282 – 382 900 GiB)
```

> Why GiB and not GB? Disk vendors sell in GB (10^9). OS tools (`df`, cloud consoles) usually show GiB (2^30). Mixing them gives a ~7.4% error — which is under the ±10% tolerance here but bites you in cost modeling. Spell out your unit every time.

**Rough sanity check:** ~350 TiB/year ≈ 1 TiB/day. At $0.02/GiB/month (S3-class storage), that is ~$83K/month in raw storage costs before replication. That figure alone tells you whether you need tiering or a cold-storage strategy — and that reasoning is what separates a 4/5 from a 5/5 design.

### 3. Write bandwidth (MiB/s)

```
bytes_per_sec          = 11 574 × 1 024         = 11 851 776 bytes/sec
write_bandwidth_mibps  = 11 851 776 / (1 024^2) = 11.30 MiB/s
```

Accepted range: **10.17 – 12.43 MiB/s**.

11 MiB/s is well within a single 1 Gbps NIC (~119 MiB/s). But when you add:
- 3× replication copies: 3 × 11 MiB/s = 33 MiB/s still fine
- 10× read:write ratio + caching misses: potentially 100+ MiB/s total I/O
- Cross-AZ replication latency overhead

...the bandwidth becomes interesting again. Estimation is not a one-and-done step.

## answers.py

```python
writes_per_sec       = 11574
storage_year_gb      = 348091
write_bandwidth_mbps = 11.3
```

## Common mistakes

| Mistake | Consequence |
|---------|-------------|
| Using 100 000 (100K) instead of 100 000 000 (100M) DAU | Off by 1000× |
| Using GB (10^9) instead of GiB (1024^3) | ~7.4% error on storage |
| Dividing bandwidth by 8 (bits→bytes) without a reason | Off by 8× |
| Not writing units through the derivation | Silent unit mismatch you can't audit |
| Guessing instead of deriving | No paper trail to defend in the interview |

## What to say in an interview

After computing these numbers, the interviewer expects you to interpret them:

1. **"11 574 writes/sec is manageable for a single primary, but I'd plan for 3× peak during viral events, which puts us at ~35K — I'd front this with a message queue to smooth bursts."**
2. **"~340 TiB/year of raw post data. With 3× replication that's ~1 PiB/year. We'd need an object store (S3-class) with a lifecycle policy to cold storage after 90 days."**
3. **"11 MiB/s write bandwidth is light; the constraint is more about IOPS at the DB layer than raw throughput."**

Estimation that stops at the number and doesn't lead into a design decision is worth half marks.
