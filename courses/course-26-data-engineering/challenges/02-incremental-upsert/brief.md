# Incremental Upsert: Idempotent CDC Merge

A production Kafka consumer ingests a Change Data Capture (CDC) feed from the orders database and writes it to the data warehouse. The consumer has an at-least-once delivery guarantee — on any restart it replays from the last committed offset. This means `apply_cdc_feed` will be called with the same batch more than once. After a crash-loop that replayed three batches twice, the warehouse ended up with duplicate rows, phantom inserts, and deleted rows that came back from the dead.

Your job: implement `apply_cdc_feed` so it is **idempotent** — applying the same feed N times produces the same result as applying it once.

## Work directory

`setup.sh` plants the following in `~/.kube-dojo-work/02-incremental-upsert/`:

```
~/.kube-dojo-work/02-incremental-upsert/
├── data/
│   ├── base.csv        # initial table snapshot (10 rows)
│   └── cdc_feed.csv    # CDC operations: op in {INSERT, UPDATE, DELETE}
├── upsert.py           # stub — implement apply_cdc_feed() here
└── tests/
    └── test_upsert_visible.py   # visible sanity checks
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-incremental-upsert
python3 -m venv .venv && . .venv/bin/activate
pip install pytest pandas
```

## Mission

Implement `apply_cdc_feed(base_df, feed_df)` in `upsert.py`.

**Inputs:**

| Param | Type | Description |
|---|---|---|
| `base_df` | `pd.DataFrame` | Current table state. Columns: `id` (int), `name` (str), `amount` (float), `updated_at` (str) |
| `feed_df` | `pd.DataFrame` | CDC operations. Columns: `id`, `op`, `name`, `amount`, `updated_at`. `op` is one of `"INSERT"`, `"UPDATE"`, `"DELETE"` |

**Rules:**

1. **INSERT** — add the row. If a row with the same `id` already exists, treat it as an UPDATE (the feed may be replayed).
2. **UPDATE** — replace the existing row by `id`. If the `id` does not exist, insert it (upsert semantics).
3. **DELETE** — remove the row by `id`. If the `id` does not exist, it is a no-op (idempotent delete).
4. **Multiple ops for the same `id` in one feed** — apply the *latest* one only (highest position in the feed).
5. **Re-running the full feed** — calling `apply_cdc_feed(result, feed_df)` a second time must return the same DataFrame as the first call.

**Return:** a `pd.DataFrame` with the same columns as `base_df` (`id`, `name`, `amount`, `updated_at`), sorted by `id` ascending, index reset.

## Why idempotency is hard here

The naive approach — `base.append(inserts); base.update(updates); base.drop(deletes)` — breaks on replay because INSERTs that already landed get appended again. The correct approach is to treat every operation as an **upsert keyed by `id`**: collapse the feed to its last-seen operation per key, then apply the resulting upsert/delete set to the base. The verifier calls your function twice with the same feed and asserts the outputs are identical.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/02-incremental-upsert/verify.sh
```

Idempotency test + exact final-state assertions green → flag printed.
