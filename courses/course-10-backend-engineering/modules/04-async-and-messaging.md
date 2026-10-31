# Async & Messaging

> **Module 04 · Course 10** — Synchronous RPC is the wrong default for most inter-service communication. This module builds the mental model to know *when* to reach for a queue vs a stream, how Kafka actually works under the hood, and how to design consumers that are correct even when they receive the same message twice.

You already know what a message queue is. What you probably don't know is exactly why duplicate messages are inevitable, why "exactly-once" Kafka is a lie outside of a single cluster, and how the outbox pattern closes the gap between database writes and event delivery. That's what this module is about.

---

## Queue vs Stream — not the same primitive

Both carry messages from producers to consumers. The storage and consumption model are fundamentally different:

```
QUEUE (RabbitMQ, SQS, ActiveMQ)
  producer ---> [ msg1 | msg2 | msg3 ] ---> consumer A (msg deleted after ack)
                                       \--> consumer B (only gets unclaimed msgs)

  - Message is owned by one consumer
  - Deleted on ack
  - Competing consumers for parallelism
  - No replay
  - Order per-queue, not guaranteed across concurrent consumers

STREAM (Kafka, Kinesis, NATS JetStream)
  producer ---> [ msg1 | msg2 | msg3 | msg4 ... ]  (append-only log)
                    ^                ^
               consumer A        consumer B
               (offset 3)        (offset 1)

  - Message persists for configured retention
  - Each consumer group tracks its own offset
  - Full replay by rewinding offset
  - Order guaranteed within partition
```

Choose a **queue** when:
- Work is distributed across competing workers (job processing, email sending)
- You want the broker to handle backpressure for you
- Messages are destructive operations (send this webhook *once*)

Choose a **stream** when:
- Multiple independent consumers need the same events (audit, analytics, cache invalidation)
- Replay on bug fix or new consumer bootstrap matters
- You need event sourcing or time-travel debugging
- Ordering within an entity matters (all order events for order_id=42 in sequence)

The rule of thumb: **if you'd be fine losing the message once it's processed, use a queue; if consumers should be able to re-read history, use a stream.**

---

## Kafka — the topology that matters

Kafka's model is more opinionated than it looks. The parts that trip engineers up:

```
Topic: "order-events"  (6 partitions, replication-factor 3)

Partition 0: [ev0, ev3, ev6, ev9 ...]   <- broker 1 (leader), brokers 2+3 (followers)
Partition 1: [ev1, ev4, ev7, ev10 ...]  <- broker 2 (leader)
Partition 2: [ev2, ev5, ev8, ev11 ...]  <- broker 3 (leader)
...

Consumer Group "notifications-svc" (3 instances):
  Instance A → Partition 0, 3
  Instance B → Partition 1, 4
  Instance C → Partition 2, 5

Consumer Group "analytics-svc" (1 instance):
  Instance X → Partition 0, 1, 2, 3, 4, 5 (all of them)
```

Key properties to internalize:

**Parallelism ceiling = partition count.** If you have 6 partitions and 8 consumer instances in a group, 2 sit idle. Scale partitions before scaling consumers. This is also why you can't trivially reduce partitions later — it requires a new topic and migration.

**Partition key → consistent routing.** `ProducerRecord(topic, key, value)` where key is hashed to a partition. All messages for `order_id=42` land on the same partition → ordered delivery for that key. Null key → round-robin → no ordering guarantee.

**Offset commit = checkpoint.** Consumers poll records and commit offsets. Auto-commit (`enable.auto.commit=true`) commits the *last polled offset* on a timer — not the last *processed* offset. If your process crashes after poll but before processing, you lose those messages (at-most-once). Manual commit after processing gives you at-least-once.

```python
# at-least-once with manual commit
consumer = KafkaConsumer(
    "order-events",
    group_id="notifications-svc",
    bootstrap_servers=["localhost:9092"],
    enable_auto_commit=False,
    auto_offset_reset="earliest",
)

for msg in consumer:
    process(msg)                              # if this throws, offset not committed
    consumer.commit()                         # now safe to advance
```

**Consumer group rebalance.** When a consumer joins or leaves, Kafka triggers a rebalance — all partitions are reassigned. During rebalance, consumption pauses. Tune `session.timeout.ms` (how long without a heartbeat before Kafka declares the consumer dead) and `max.poll.interval.ms` (max time between polls before the consumer is kicked out). If your `process(msg)` is slow, increase `max.poll.interval.ms` or process asynchronously and poll faster.

```bash
# inspect lag and partition assignment
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group notifications-svc

# output: GROUP  TOPIC  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID
```

---

## Event-driven architecture

EDA means services communicate by emitting events rather than calling each other's APIs. Two distinct patterns:

**Event notification** — the event tells downstream services "something happened." It carries minimal data (`{ "type": "order.placed", "order_id": "42" }`). Consumers fetch details via API if needed.
- Pro: tiny payloads, publisher has no coupling to consumer's data needs
- Con: consumers make extra API calls; if the publisher's API is down, processing stalls

**Event-carried state transfer** — the event embeds the full relevant state snapshot (`{ "type": "order.placed", "order": { ... full order object ... } }`). Consumers are self-sufficient.
- Pro: consumers work without calling back; enables temporal decoupling
- Con: larger payloads, schema evolution is harder, sensitive fields in the event log

In practice, most teams start with event notification and migrate to event-carried state transfer when the fan-out of callbacks becomes a bottleneck.

**Choreography vs orchestration:**

| | Choreography | Orchestration |
|---|---|---|
| Model | Each service reacts to events independently | A central orchestrator tells each service what to do |
| Coupling | Services know events, not each other | Services know the orchestrator, not each other |
| Visibility | Hard to trace a full saga | Easy to see current state in the orchestrator |
| Failure handling | Each service handles retries locally | Orchestrator retries and compensates |
| Example | Saga via domain events | Temporal, AWS Step Functions |

Choreography scales better operationally (no single point of bottleneck) but becomes hard to reason about when sagas grow beyond 4–5 steps. The inflection point where orchestration wins is roughly when you need compensating transactions (rollback logic) across more than three services.

---

## The outbox pattern — why dual-write is broken

The naive implementation:

```python
def place_order(order):
    db.execute("INSERT INTO orders VALUES (?)", order)   # step 1
    kafka.produce("order-events", order_event(order))    # step 2  ← can fail here
```

If the process crashes between step 1 and step 2, the order is in the DB but the event was never published. The downstream services never see it. This is the **dual-write problem**: you cannot atomically commit to two different systems.

The outbox pattern fixes this by making the event part of the same DB transaction:

```sql
-- same transaction
INSERT INTO orders (id, ...) VALUES (...);
INSERT INTO outbox (id, aggregate_type, aggregate_id, event_type, payload, created_at)
  VALUES (gen_random_uuid(), 'order', $order_id, 'order.placed', $payload, NOW());
```

A separate **relay process** (or CDC connector like Debezium) polls or tails the outbox table and publishes to Kafka, then marks the row as published. The outbox is transactional with the domain write; the relay is retryable.

```
DB Transaction:                 Relay (runs outside transaction):
  INSERT orders                   SELECT * FROM outbox WHERE published_at IS NULL
  INSERT outbox               →   kafka.produce(row.payload)
  COMMIT                          UPDATE outbox SET published_at = NOW() WHERE id = ?
```

Relay failure before marking published → the event is re-published → consumers see a duplicate. This is exactly why consumers must be idempotent. The outbox pattern doesn't eliminate duplicates; it eliminates *loss*, and shifts the problem to idempotency.

**Debezium CDC alternative:** instead of polling, Debezium tails the Postgres WAL. Zero polling overhead, ~100ms latency from commit to Kafka. The tradeoff: operational complexity of a connector cluster and WAL slot management.

---

## Delivery semantics — the exactly-once myth

There are three delivery guarantees:

| Guarantee | What it means | Duplicate risk | Loss risk |
|-----------|---------------|----------------|-----------|
| At-most-once | Send once; if it fails, discard | None | Yes |
| At-least-once | Retry until ack | Yes | None |
| Exactly-once | Delivered and processed exactly once | None | None |

**At-most-once** is only acceptable for metrics, logs, or analytics where loss is tolerable. Never for financial or state-mutating operations.

**At-least-once** is the practical default. You commit the offset only after successful processing, and if you crash mid-process, you reprocess. This implies duplicates during failures.

**Exactly-once** within Kafka Streams (`isolation.level=read_committed` + idempotent producer + transactions) is real — for the pipeline *inside* Kafka. The moment your consumer writes to a database or calls an external API, the Kafka transaction boundary ends, and you're back to at-least-once. There is no distributed protocol that atomically commits a Kafka offset and a Postgres row without a two-phase commit (and even 2PC fails under certain partitions). The industry shorthand: **exactly-once delivery is a myth at system boundaries; exactly-once processing is achievable via idempotency**.

---

## Idempotent consumers

An operation is idempotent if applying it multiple times has the same effect as applying it once. The three patterns:

**Deduplication table.** Store the event ID; skip if already seen.

```sql
CREATE TABLE processed_events (
  event_id UUID PRIMARY KEY,
  processed_at TIMESTAMPTZ DEFAULT NOW()
);

-- in the consumer (within the same transaction as the domain write):
INSERT INTO processed_events (event_id) VALUES ($1)
ON CONFLICT DO NOTHING
RETURNING event_id;
-- if no row returned → already processed, skip the rest
```

**Natural idempotency.** Use an upsert keyed on the business entity:

```sql
INSERT INTO order_status (order_id, status, updated_at)
VALUES ($1, $2, NOW())
ON CONFLICT (order_id) DO UPDATE
  SET status = EXCLUDED.status,
      updated_at = EXCLUDED.updated_at
  WHERE EXCLUDED.updated_at > order_status.updated_at;
```

**Idempotency via event envelope.** Include a stable `event_id` (UUID v4 generated by the producer, not by the broker) in every event. This gives consumers a reliable deduplication key even when Kafka offsets rewind (e.g., after re-processing from a rewound offset).

```json
{
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "event_type": "order.placed",
  "aggregate_id": "42",
  "occurred_at": "2026-01-15T10:00:00Z",
  "payload": { ... }
}
```

---

## Debugging Async & Messaging

### Consumer lag

**Symptom:** notifications arrive minutes late; a `--describe` shows rising LAG; alerts fire on `kafka_consumer_lag`.

**Cause → Fix:**

| Lag pattern | Cause | Fix |
|-------------|-------|-----|
| All partitions lagging equally | Consumer throughput below publish rate | Add consumer instances (up to partition count); optimize `process()` |
| One partition lagging, rest fine | Hot partition (skewed key) or one consumer instance stuck | Check key distribution; kill and let Kafka rebalance; check that instance's logs |
| Lag jumps then recovers | Periodic slow processing (e.g. batch DB write) | Increase `max.poll.records`; move batch-write outside poll loop |
| Lag only during deploys | Rebalance pause | Tune `session.timeout.ms`; use static membership (`group.instance.id`) |

```bash
# watch lag in real time
watch -n 5 kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group notifications-svc

# see the actual message at an offset (non-destructive)
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic order-events \
  --partition 0 \
  --offset 1234 \
  --max-messages 1
```

### Poison messages

**Symptom:** consumer crashes on the same message repeatedly; lag grows by exactly 1; DLQ (if configured) fills up.

**Cause:** malformed payload, schema evolution mismatch (producer upgraded, consumer hasn't), encoding bug.

**Fix:**
1. Log the raw message bytes before deserializing (not after — the deserializer is what throws).
2. Wrap `process(msg)` in a try/catch that catches *all* exceptions, increments a retry counter (stored in Redis or a DB keyed on `topic:partition:offset`), and after N retries publishes to a DLQ topic and commits the offset.
3. Never let a single bad message block a partition forever.

```python
MAX_RETRIES = 3
retry_store = {}

for msg in consumer:
    key = f"{msg.topic}:{msg.partition}:{msg.offset}"
    try:
        process(msg)
        consumer.commit()
    except Exception as e:
        retries = retry_store.get(key, 0) + 1
        if retries >= MAX_RETRIES:
            dlq_producer.produce("order-events-dlq", key=msg.key, value=msg.value)
            logger.error("Sent to DLQ", extra={"key": key, "error": str(e), "raw": msg.value})
            consumer.commit()
            del retry_store[key]
        else:
            retry_store[key] = retries
            logger.warning("Retry %d/%d for %s", retries, MAX_RETRIES, key)
```

### Duplicate processing

**Symptom:** downstream effects (emails sent, rows inserted) appear twice; idempotency table shows no conflict, so the `ON CONFLICT DO NOTHING` path isn't being hit.

**Cause → Fix:**

| Duplicate source | Fix |
|------------------|-----|
| Consumer committed offset before processing completed | Never auto-commit; commit only after domain write AND processed_events insert are in the same transaction |
| Two consumer instances processed same partition during rebalance | Use cooperative rebalancing (`partition.assignment.strategy=CooperativeStickyAssignor`) to minimize partition migration; ensure idempotency table is consulted |
| Outbox relay published twice before marking published | Make relay update atomic: `UPDATE outbox SET published_at = NOW() WHERE id = $1 AND published_at IS NULL` — check rows_affected == 1 |
| Kafka offset rewound (manual reset or `auto.offset.reset=earliest` on new group) | Idempotency table protects you — if it's missing, add it |

```sql
-- diagnose: find events processed more than once
SELECT event_id, COUNT(*) AS times
FROM processed_events
GROUP BY event_id
HAVING COUNT(*) > 1;
-- if non-empty: your consumers are inserting to processed_events outside a serializable/repeatable-read transaction
```

> **War story.** At SAP we had a pipeline that enriched log events and forwarded them to an LGTM stack. A well-meaning engineer set `enable.auto.commit=true` and decreased the poll interval to reduce latency. During a GC pause on a consumer instance, auto-commit advanced the offset while 3000 log events were still in memory being enriched. The GC pause triggered a `session.timeout.ms` violation, Kafka declared the consumer dead, triggered a rebalance, and another instance picked up the same partition — starting from the *auto-committed* offset, which was already past those 3000 events. They were silently dropped. The alert? A 15-minute gap in a log-based SLO dashboard. The fix: switch to manual commit, commit only after the enriched batch was flushed to LGTM, add an end-to-end lag probe that detects gaps in sequence numbers embedded in log events. The auto-commit default is a trap for any workload where processing isn't instant.

---

## Checkpoint

You're ready for the async challenges when you can, without looking anything up:

1. Explain why you'd choose Kafka over SQS for a use case where three independent services need to consume the same order events, including a new analytics service added six months after launch.
2. Trace what happens to Kafka partition assignment when one consumer instance in a group dies and `session.timeout.ms` expires.
3. Describe exactly where the dual-write problem occurs, and the two DB writes the outbox pattern makes within a single transaction.
4. State why Kafka's exactly-once producer setting does not give you exactly-once processing when your consumer writes to Postgres.
5. Write (from memory) a deduplication table `INSERT ... ON CONFLICT DO NOTHING` that uses a UUIDv4 `event_id` and returns whether the event was already seen.
6. Diagnose a single stuck partition in a consumer group: which command, which column in the output, and what you look at next.
7. Explain the difference between a poison-message DLQ strategy and an idempotent consumer — they solve different problems.

➡ Next up: **Concurrency & Reliability** — threads, event loops, connection pools, and the rate-limiter/circuit-breaker toolkit that separates services that stay up from ones that take down their dependencies with them.
