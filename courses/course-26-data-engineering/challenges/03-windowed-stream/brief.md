# Windowed Stream: Tumbling Windows with Late Events

A metrics aggregation service consumes an event stream from sensor nodes. Each node emits `(sensor_id, timestamp, reading)` tuples. The network is flaky: events occasionally arrive seconds late — but never more than 10 seconds behind the watermark. The Flink job that previously handled this is being replaced with a leaner in-process aggregator. The product requirement: sum readings per sensor per 60-second tumbling window, and correctly absorb late events within the lateness budget.

After the migration was rushed, the late event at `t=129` for `sensor-B` was dropped entirely, and the window `[120,180)` for `sensor-B` shows a sum of 0 instead of 7. The root cause: the watermark advanced past the window before the late event arrived, and the implementation had no lateness handling.

Your job: implement `compute_windows` so it handles out-of-order events within the allowed lateness.

## Work directory

`setup.sh` plants the following in `~/.kube-dojo-work/03-windowed-stream/`:

```
~/.kube-dojo-work/03-windowed-stream/
├── windowed.py              # stub — implement compute_windows() here
└── tests/
    └── test_windowed_visible.py   # visible sanity checks
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-windowed-stream
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## The event stream (fixed, embedded in the verifier)

Events are `(key: str, ts: int, value: int)` — epoch-seconds. The stream:

```
("sensor-A", 10,  5)
("sensor-B", 15,  3)
("sensor-A", 25,  8)
("sensor-B", 70,  4)
("sensor-A", 75,  2)
("sensor-B", 80,  6)
("sensor-A", 130, 9)
("sensor-B", 129, 7)   # <-- arrives after ("sensor-A", 130), out-of-order
("sensor-A", 195, 1)
("sensor-B", 200, 2)
```

## Mission

Implement `compute_windows(events, window_size_s=60, max_lateness_s=10)` in `windowed.py`.

**Input:** `events` — a list of `(key, ts, value)` tuples delivered in the order shown above (mimics consumer receive-order, not event-time order).

**Output:** a `dict` keyed by `(key, window_start)` with integer window_start values (epoch-seconds, multiples of `window_size_s`), mapping to the **sum** of values for events in that window.

Window assignment: event at `ts` belongs to window `[floor(ts / window_size_s) * window_size_s, ...)`.

**Lateness rule:** the watermark advances to `max(seen_ts) - max_lateness_s` as each event is processed. An event at `ts` is accepted into its window if `ts >= watermark` at processing time. Events earlier than the current watermark are dropped silently.

The event `("sensor-B", 129, 7)` arrives 6th in processing order (after `("sensor-A", 130, 9)` has advanced the watermark to `130 - 10 = 120`). Since `129 >= 120`, it must be accepted into window `[120, 180)` for `sensor-B`.

**Expected output (exact):**

| key | window_start | sum |
|---|---|---|
| sensor-A | 0 | 13 (ts=10→5, ts=25→8) |
| sensor-B | 0 | 3 (ts=15→3) |
| sensor-A | 60 | 2 (ts=75→2) |
| sensor-B | 60 | 10 (ts=70→4, ts=80→6) |
| sensor-A | 120 | 9 (ts=130→9) |
| sensor-B | 120 | 7 (ts=129→7, late but within budget) |
| sensor-A | 180 | 1 (ts=195→1) |
| sensor-B | 180 | 2 (ts=200→2) |

## Why this matters in production

Flink, Spark Streaming, and Kafka Streams all implement exactly this model: event-time windows, watermarks, and allowed lateness. Understanding the mechanics — watermark = max_ts - lateness, accept if ts >= watermark — lets you reason about why your window emits when it does and whether you're silently dropping late data. The verifier checks the exact window sums, including the late event.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/03-windowed-stream/verify.sh
```

All eight window assertions green → flag printed.
