# Streaming with Kafka

> **Module 03 · Course 26** — Kafka is the nervous system of most large-scale data platforms. You've probably already published to a topic or consumed from one. This module goes past the basics: how partitions determine ordering and parallelism, what consumer group rebalancing costs and when to tune it, the actual mechanics of each delivery semantic (and why "exactly-once" is more nuanced than it sounds), and the hard parts of windowed stateful processing that bite you when event time diverges from processing time.

---

## Topics, Partitions, and the Physical Layout

A Kafka **topic** is a logical stream of records. Underneath, it is divided into **partitions** — ordered, immutable, append-only logs, each stored on disk across the Kafka broker set.

```
Topic: "order-events"
┌─────────────────────────────────────────────────────────────────┐
│  Partition 0:  [offset 0] [offset 1] [offset 2] ... [offset N]  │
│  Partition 1:  [offset 0] [offset 1] [offset 2] ... [offset M]  │
│  Partition 2:  [offset 0] [offset 1] [offset 3] ... [offset K]  │
└─────────────────────────────────────────────────────────────────┘
         │                    │
         │ each partition lives on                     replica
         │ ≥1 broker                                   leadership
         ▼                                             rotates across
    [Broker 1 — leader for P0, P2]    [Broker 2 — leader for P1, follower for P0, P2]
```

**What you need to internalize about partitions:**

1. **Ordering is per-partition only.** Records within a partition are strictly ordered by offset. Records across partitions have no guaranteed ordering. If your application requires that order X always appears before order Y in the consumer, both records must go to the same partition.

2. **Parallelism ceiling = partition count.** You can have at most N consumers in a consumer group for a topic with N partitions. The 11th consumer in a 10-partition topic will be assigned zero partitions and receive nothing. Partition count is permanent (you can only increase it, and even increasing has caveats for keyed topics).

3. **Replication factor ≠ partition count.** A replication factor of 3 means 3 copies of every partition across 3 brokers for durability — this does not increase read or write parallelism. The leader handles all produce/consume for a given partition.

---

## Keys, Routing, and Ordering Guarantees

The **message key** determines which partition a record goes to. Kafka's default partitioner uses `murmur2(key) % numPartitions`.

```python
# Python producer — key controls partition assignment
producer.produce(
    topic='order-events',
    key=str(order.customer_id),  # all events for customer_id go to the same partition
    value=order.to_json()
)
```

**When to set a key:**
- You need all events for a given entity (customer, order, device) to be processed in order. Use the entity's ID as the key.
- You want consistent partition locality for stateful stream processing (the same key always lands on the same consumer thread's state store).

**When not to set a key (or use null):**
- Events are independent and order doesn't matter. Round-robin across all partitions maximizes throughput and balances broker load.
- Hotkey risk: if one key generates far more traffic than others (e.g., a viral merchant), all its events land on one partition — one broker, one consumer thread. Monitor partition lag per-partition, not just the topic aggregate.

---

## Consumer Groups & Rebalancing

A **consumer group** is a set of consumers that collectively consume a topic. Kafka assigns each partition to exactly one consumer in the group at a time. The group coordinator (a Kafka broker) manages this assignment.

```
Consumer Group: "analytics-pipeline"
Topic: "order-events" (10 partitions)

Consumer 1 ──▶  Partition 0, 1, 2, 3
Consumer 2 ──▶  Partition 4, 5, 6
Consumer 3 ──▶  Partition 7, 8, 9
```

### The rebalance event

A rebalance is triggered when:
- A consumer joins the group (new deployment, scale-out)
- A consumer leaves the group (crash, `close()`, graceful shutdown)
- A consumer fails its heartbeat (heartbeat interval exceeded `session.timeout.ms`)
- Partition count changes

During a rebalance, **all consumption stops** — consumers finish their current batch, commit offsets, revoke their partitions, wait for the coordinator to produce a new assignment, and then resume. On large consumer groups or topics with many partitions, this can cause a pause of several seconds.

### Tuning rebalance behavior

```python
# Key consumer configuration parameters
consumer = KafkaConsumer(
    'order-events',
    group_id='analytics-pipeline',
    # How long a consumer can be silent before the coordinator declares it dead
    session_timeout_ms=30_000,          # default 45s; reduce to detect crashes faster
    # How frequently the consumer sends heartbeats
    heartbeat_interval_ms=3_000,        # must be < session_timeout_ms / 3
    # Max time between poll() calls — if exceeded, consumer is evicted
    max_poll_interval_ms=300_000,       # increase if your processing loop is slow
    # How many records to fetch per poll
    max_poll_records=500,
    # Cooperative incremental rebalance — avoids full stop-the-world rebalances
    partition_assignment_strategy=['cooperative-sticky'],
)
```

**Cooperative incremental rebalance** (Kafka 2.4+, `partition.assignment.strategy=cooperative-sticky`) is the most important single config change for high-throughput consumers. Instead of all consumers revoking all partitions simultaneously, only the partitions that need to *move* are revoked. Consumers that keep their partitions continue processing. This eliminates stop-the-world rebalance pauses for scale-out events.

---

## Offsets and Commit Semantics

An **offset** is the position of a record within a partition. Committing an offset means telling Kafka "I have successfully processed everything up to this point."

```
Partition 0:  [0] [1] [2] [3] [4] [5]  ...
                           ↑
                    committed offset = 3
              (consumer will receive records from offset 4 on reconnect)
```

**Auto-commit vs manual commit:**

| Mode | Config | Risk |
|------|--------|------|
| Auto-commit | `enable.auto.commit=true` | Offsets committed on a timer, not after processing. A crash between commit and processing means re-delivery. An application bug commits before acknowledging to downstream — data loss. |
| Manual commit (at-least-once) | `enable.auto.commit=false`, commit after processing each batch | Safer. On crash, the consumer re-reads from last committed offset. Records that were processed but not committed are reprocessed. |
| Manual commit (sync before write) | commit only after downstream write succeeds | Required for idempotent pipelines |

**The commit position matters:**
- Commit *after* processing = at-least-once (default safe choice)
- Commit *before* processing = at-most-once (acceptable for ephemeral metrics, not data pipelines)
- Commit *atomically with downstream write* = effectively-exactly-once (complex, described below)

---

## Delivery Semantics

### At-least-once

The default and correct baseline for most data pipelines. A record may be delivered more than once if a consumer crashes before committing its offset. Your downstream must be idempotent (UPSERT, deduplicate by message ID) to compensate.

### At-most-once

Commit before processing. A crash loses the record. Acceptable only for non-critical telemetry where loss is tolerable. Never the right choice for financial or metering data.

### Exactly-once semantics (EOS)

Kafka's transactional API allows atomic multi-partition writes combined with consumer offset commits. This is *Kafka-internal exactly-once*: each message is delivered to the output topic exactly once, as seen by another Kafka consumer.

```python
# Producer EOS configuration
producer = KafkaProducer(
    transactional_id='order-processor-1',   # unique per producer instance
    acks='all',                              # wait for all in-sync replicas
    enable_idempotence=True,                 # deduplicate producer retries
)
producer.init_transactions()

# Atomic consume → process → produce → commit
producer.begin_transaction()
for record in batch:
    producer.produce('processed-orders', value=process(record))
producer.send_offsets_to_transaction(offsets, consumer_group_id)
producer.commit_transaction()  # atomic: offsets + produced records committed together
```

**The nuance:** EOS in Kafka means exactly-once *within the Kafka ecosystem* — from topic to topic via a Kafka Streams or transactional producer pipeline. Once you write to an external system (a database, a data warehouse), exactly-once depends on that system's transaction semantics. If your sink is idempotent (e.g., UPSERT with a unique key), you get effectively-exactly-once end-to-end. If your sink is not idempotent (e.g., `INSERT` with no conflict handling), Kafka EOS alone does not save you.

The practical guidance: use EOS for Kafka-to-Kafka processing; use idempotent upserts for Kafka-to-database sinks.

---

## Windowing and Stateful Stream Processing

**Windowing** divides a continuous event stream into bounded sets for aggregation. The three common types:

| Window type | Definition | Example use case |
|-------------|-----------|-----------------|
| Tumbling | Fixed-size, non-overlapping. Event belongs to exactly one window. | Revenue per 5-minute bucket |
| Sliding | Fixed-size, overlapping. Event may belong to multiple windows. | Rolling P99 latency over the last 5 minutes, updated every minute |
| Session | Event-driven boundaries. Window closes after a configurable gap of inactivity. | User session duration (close the window if no events for 30 min) |

```
Tumbling:   [00:00–05:00] [05:00–10:00] [10:00–15:00]
             event A             event B
                   event C

Sliding:    [00:00–05:00]
                 [01:00–06:00]
                      [02:00–07:00]  (window slides every minute)

Session:    [event A — — — gap > 30min — — — event B]
             |window 1|                        |window 2|
```

### Event time vs processing time

This is the hardest part of streaming. Two notions of time:

- **Event time:** when the event *actually happened* (the timestamp the producing application wrote into the record).
- **Processing time:** when Kafka received or your consumer processed the record.

For correct aggregations, always use **event time**. A sensor reading at 12:03 should go into the 12:00–12:05 window regardless of whether your consumer saw it at 12:04 or 12:25 (due to network lag or a rebalance). Processing-time windows are easier to implement but produce wrong answers whenever there is any lag.

```python
# Flink (pseudocode) — event-time tumbling window
stream \
    .assign_timestamps_and_watermarks(
        WatermarkStrategy
            .for_bounded_out_of_orderness(Duration.of_minutes(5))
            .with_timestamp_assigner(lambda e, _: e.event_ts_ms)
    ) \
    .key_by(lambda e: e.customer_id) \
    .window(TumblingEventTimeWindows.of(Time.minutes(5))) \
    .aggregate(SumAggregator()) \
    .add_sink(warehouse_sink)
```

### Backpressure

**Backpressure** is the mechanism by which a slow downstream stage signals to upstream stages to slow their production rate. In a correctly implemented stream processing system, backpressure propagates automatically — when the sink is slow, the processing slows, which slows consumption from Kafka, which increases consumer lag.

Uncontrolled consumer lag is the surface-level symptom of backpressure not being managed. The fix is rarely "consume faster" — it is to understand *why* the sink is slow (database write contention, network bandwidth, memory pressure) and address that root cause.

---

## Debugging Streaming with Kafka

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Consumer lag grows continuously and never drains | Consumer is slower than producer: processing bottleneck or insufficient consumer instances | Profile per-record processing time; increase parallelism (add consumers up to partition count); optimize the slow step first |
| Consumer lag spikes periodically, then recovers | Stop-the-world rebalances: scale events or heartbeat timeouts causing full partition revoke/reassign | Switch to `cooperative-sticky` assignment; tune `session.timeout.ms` and `max.poll.interval.ms`; stagger consumer deployments |
| Events processed out of order across partitions | Consumer assumes global ordering, but Kafka only guarantees per-partition ordering | Design your consumer to tolerate out-of-order events; use a single partition for entities that require strict global ordering |
| Late events not appearing in windowed aggregates | Watermark advancing past late event timestamps before they arrive; late events silently dropped | Widen the watermark lag budget; route late events to a side output for a reconciliation job; log late event rate as a metric |
| Duplicate records in the output table | At-least-once delivery + non-idempotent sink; consumer committed offset before downstream write succeeded | Make the sink idempotent (UPSERT with natural key); use Kafka transactional API if both source and sink are Kafka topics |
| `CommitFailedException`: message consumed but offset not committable | `max.poll.interval.ms` exceeded: the processing loop took too long, coordinator evicted the consumer, then commit was rejected | Reduce `max_poll_records`; increase `max.poll.interval.ms`; move slow work off the consumer thread to an async worker pool |
| Specific partition has 10× higher lag than others | Hot partition: one key generates disproportionate traffic | Identify the hot key (`kafka-log-dirs.sh --describe`); redesign key to distribute traffic; add a random suffix to the hot key and aggregate in a secondary step |

> **War story.** At SAP, a Kafka consumer pipeline was processing ~50k events/second without issue. We deployed a routine change to the consumer code. Within minutes, consumer lag began growing — 1M records behind, then 5M, then 10M. Alerts fired. We rolled back but lag didn't drain: the consumer was stuck in a continuous rebalance loop. The reason: the new code added a database call inside the `poll()` loop that occasionally took 6+ seconds. With `max.poll.interval.ms=5000` (the old default), the coordinator treated the paused consumer as dead, triggering a rebalance. The consumer rejoined, got the same partitions, and immediately paused again on the same slow DB call — infinite loop. The short-term fix was to increase `max.poll.interval.ms` to 60 seconds. The real fix was to move the slow DB call to an async batch outside the poll loop, keeping poll latency under 500ms. We also added a metric: `poll_loop_duration_ms`, with an alert at 2 seconds — below the timeout, but visible before it becomes a problem.

---

## Checkpoint

You can move on when you can answer these without reference:

1. Kafka guarantees ordering within a partition but not across partitions. Describe a producer key strategy that guarantees all events for a given user are processed in order.
2. What is the `session.timeout.ms` parameter, and what happens to a partition assignment when it expires?
3. Explain the difference between auto-commit and manual commit. Under what condition does auto-commit cause data *loss* (not duplication)?
4. What does Kafka's transactional API provide, and why is idempotent sink design still necessary when writing to a database?
5. An event generated at 12:03 arrives at your consumer at 12:31. Your tumbling window is 5 minutes. Where does this event belong, and what determines whether it is included or dropped?
6. Describe the difference between event time and processing time. Which do you use for correct windowed aggregations?
7. Your consumer lag is growing. Walk through your first three diagnostic steps.
8. What is a hot partition, how do you detect it, and what is the standard mitigation strategy?

➡ Next up: **Batch Processing & Spark** — the dataframe model, partitions, shuffles, skew, and lazy evaluation.
