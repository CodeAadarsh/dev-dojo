# Solution: Windowed Stream

## The complete implementation

```python
# windowed.py


def compute_windows(events, window_size_s=60, max_lateness_s=10):
    windows = {}          # (key, window_start) -> int sum
    max_seen_ts = None    # tracks the high-watermark before lateness subtraction

    for key, ts, value in events:
        # Advance watermark
        if max_seen_ts is None:
            max_seen_ts = ts
        else:
            max_seen_ts = max(max_seen_ts, ts)

        watermark = max_seen_ts - max_lateness_s

        # Drop events older than the watermark
        if ts < watermark:
            continue

        window_start = (ts // window_size_s) * window_size_s
        k = (key, window_start)
        windows[k] = windows.get(k, 0) + value

    return windows
```

## Why each piece is correct

**`max_seen_ts = max(max_seen_ts, ts)` before the watermark check** — the watermark is derived from the *current* event's timestamp (or any previous max, whichever is higher). This means when `("sensor-B", 129, 7)` arrives, `max_seen_ts` is already 130 from the previous event. Watermark = `130 - 10 = 120`. We then check `129 >= 120` → accept. If you advanced `max_seen_ts` *after* the check, you'd use the stale watermark (120 from `("sensor-A", 130)` arrives when max was 80 previously) and the result would be wrong for different orderings.

**`(ts // window_size_s) * window_size_s`** — integer floor division gives the tumbling window start. `ts=129 // 60 = 2`, `2 * 60 = 120`, so the event lands in `[120, 180)`. This is the same formula Flink uses internally.

**`if ts < watermark: continue`** — events below the watermark are silently dropped, matching Flink's "discard" policy. The alternative ("side output") is not required here.

**`windows.get(k, 0) + value`** — accumulate into the window in a single pass. The dict starts empty; keys are created on first assignment. No need for `defaultdict` since we only read-then-write once per event.

## Tracing the critical late event

```
Processing order:
  ("sensor-A", 130, 9): max_seen_ts=130, watermark=120. 130>=120 -> accept. window=(sensor-A,120) += 9
  ("sensor-B", 129, 7): max_seen_ts=130, watermark=120. 129>=120 -> ACCEPT. window=(sensor-B,120) += 7
```

If you had incremented `max_seen_ts` *after* checking, you would check `129 >= 120` anyway (same watermark — both orderings land the same result in this case). But the spec says "watermark advances as each event is processed" which is interpreted as: update `max_seen_ts` first, then check. This is safer for streams where a very high-ts event jumps the watermark dramatically.

## What Flink/Spark actually do

Real frameworks emit a window result when the watermark passes the window end:

```
Window [0,60) emits when watermark > 60 (i.e. max_seen_ts > 70)
Window [60,120) emits when watermark > 120 (i.e. max_seen_ts > 130)
```

In this challenge we compute the final aggregate over the whole stream, so we don't need to simulate the trigger/emit lifecycle — we process all events and return the complete result dict. The lateness check ensures we would have accepted/rejected correctly in a streaming context too.

## Common mistakes

- Checking `ts < watermark` with `<=` (off-by-one): `ts == watermark` should be accepted. The contract is `ts >= watermark`.
- Updating `max_seen_ts` after the drop check: on this stream it doesn't matter, but on a stream where a very-late event arrives it would cause the watermark to regress (a stale high-water mark wouldn't advance on the late event, which is correct — but if you update first and the late event is also the new max, the watermark could jump past subsequent legitimate events).
- Using `float` division: `ts // window_size_s` must be integer floor division. `ts / window_size_s` gives a float key and `(float, window_start)` tuples don't compare equal to `(int, window_start)` tuples.
