# Solution — Partition a Table by Month

## The Answer

Complete `~/.kube-dojo-work/03-partition-a-table/migrate.sql` (uncomment the TODOs) and apply it:

```sql
-- Step 1: save the old data
ALTER TABLE events RENAME TO events_old;

-- Step 2: new partitioned parent
CREATE TABLE events (
    id         BIGINT          GENERATED ALWAYS AS IDENTITY,
    event_type TEXT            NOT NULL,
    payload    JSONB           NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ     NOT NULL
) PARTITION BY RANGE (created_at);

-- Step 3: monthly child partitions
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE events_2024_03 PARTITION OF events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- Step 4: copy data
INSERT INTO events (id, event_type, payload, created_at)
    SELECT id, event_type, payload, created_at FROM events_old;

-- Step 5: drop the old table (optional — keep it as a rollback safety net)
-- DROP TABLE events_old;
```

Apply and verify:

```bash
docker exec -i dojo-pg psql -U postgres -d dojo < \
  ~/.kube-dojo-work/03-partition-a-table/migrate.sql

bash courses/course-18-postgresql/challenges/03-partition-a-table/verify.sh
```

---

## How Declarative Partitioning Works Internally

When you declare `PARTITION BY RANGE (created_at)`, PostgreSQL marks the parent table as a partitioned table in `pg_partitioned_table`. The parent table itself contains no rows — it is a logical container. Every child partition inherits the parent's column list and constraints.

```
pg_class (events)
  relkind = 'p'              -- partitioned table
  
pg_partitioned_table (events)
  partstrat = 'r'            -- range partitioning
  partnatts = 1              -- one partition key column
  partattrs = [ created_at ] -- the key column

pg_inherits
  inhparent = events.oid
  inhrelid  = events_2024_01.oid  ← child
  inhrelid  = events_2024_02.oid  ← child
  inhrelid  = events_2024_03.oid  ← child
```

Each child partition is a normal heap table (`relkind = 'r'`) with an additional constraint:

```
CHECK (created_at >= '2024-01-01' AND created_at < '2024-02-01')
```

PostgreSQL uses these constraints at query time for **constraint exclusion** (static) and **partition pruning** (dynamic, Postgres 11+). The planner compares the query's WHERE clause against each partition's bound and skips partitions whose ranges are provably disjoint from the filter.

---

## INSERT Routing

When you `INSERT INTO events (..., created_at) VALUES (..., '2024-01-15')`, PostgreSQL evaluates the partition key value against the bounds of each partition and routes the row to the matching child:

```
INSERT → partition router evaluates created_at = '2024-01-15 12:00:00'
  events_2024_01: ['2024-01-01', '2024-02-01') → MATCH → insert here
  events_2024_02: ['2024-02-01', '2024-03-01') → skip
  events_2024_03: ['2024-03-01', '2024-04-01') → skip
```

The row physically lives in `events_2024_01`. The parent table `events` has zero rows in its heap. This is why `tableoid::regclass` returns the child partition name: `tableoid` is the OID of the physical table that owns the tuple.

If you INSERT a `created_at` value that falls outside all declared partition bounds (e.g., `'2025-06-01'`), PostgreSQL raises:

```
ERROR:  no partition of relation "events" found for row
DETAIL:  Partition key of the failing row contains (created_at) = (2025-06-01 ...
```

Fix: add a `DEFAULT` partition to catch unmapped rows, or add the missing range partition.

---

## Partition Pruning in Action

After migration, observe partition pruning:

```sql
EXPLAIN SELECT * FROM events WHERE created_at >= '2024-02-01' AND created_at < '2024-03-01';
```

```
Append  (cost=0.00..5.12 rows=72 width=...)
  ->  Seq Scan on events_2024_02  (cost=...)
        Filter: (created_at >= '2024-02-01' AND created_at < '2024-03-01')
```

Only `events_2024_02` appears in the plan. The January and March partitions are excluded entirely. On a table with 36 monthly partitions this means 97% of the data is never touched.

---

## Indexes on Partitioned Tables

Creating an index on the parent automatically creates matching indexes on all child partitions:

```sql
CREATE INDEX idx_events_created_at ON events (created_at);
```

PostgreSQL creates `idx_events_2024_01_created_at`, `idx_events_2024_02_created_at`, etc. Each child index covers only its own rows, making it small enough to fit in cache even when the parent is terabytes.

A unique index on a partitioned table must include the partition key:

```sql
-- Works: id + created_at together are unique per partition
CREATE UNIQUE INDEX ON events (id, created_at);

-- Fails: cannot enforce uniqueness across partition boundaries without the key
CREATE UNIQUE INDEX ON events (id);  -- ERROR
```

---

## Adding New Partitions

Each month, add the next partition before the first insert of that month arrives:

```sql
CREATE TABLE events_2024_04 PARTITION OF events
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
```

Automate this with a scheduled job (pg_cron, a cron job, or a CI pipeline). Failing to create the next partition before the month starts will cause all inserts to fail with the "no partition found" error.

---

## Archival — the Whole Point

The killer feature: dropping a month is a metadata operation:

```sql
-- Archive (detach the partition, keep the table)
ALTER TABLE events DETACH PARTITION events_2024_01;
-- events_2024_01 now lives as a standalone table; copy to S3/cold storage

-- Discard (once archived)
DROP TABLE events_2024_01;
```

`DETACH PARTITION` + `DROP TABLE` are both near-instant, regardless of how many rows are in the partition. The equivalent `DELETE FROM events WHERE created_at < '2024-02-01'` would take minutes on a large table and generate a tsunami of WAL.

---

## DEFAULT Partition

A `DEFAULT` partition catches rows that don't match any declared range bound:

```sql
CREATE TABLE events_default PARTITION OF events DEFAULT;
```

With a default partition, inserts never fail with "no partition found". The trade-off: partition pruning cannot exclude the default partition when the query range overlaps with any gap in the declared bounds, so it is scanned for every query that could touch unmapped rows.

Best practice: keep the default partition small (only rows awaiting a new range partition to be created), then merge its rows into a proper range partition when you add one.

---

## Verify Checklist

```bash
# Is events partitioned?
docker exec dojo-pg psql -U postgres -d dojo \
  -c "SELECT relname, relkind FROM pg_class WHERE relname = 'events';"
# relkind = 'p' means partitioned table

# List child partitions
docker exec dojo-pg psql -U postgres -d dojo \
  -c "SELECT child.relname FROM pg_inherits
      JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
      JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
      WHERE parent.relname = 'events';"

# Test insert routing
docker exec dojo-pg psql -U postgres -d dojo \
  -c "INSERT INTO events (event_type, payload, created_at)
      VALUES ('test', '{}', '2024-02-14');
      SELECT tableoid::regclass, created_at FROM events WHERE event_type = 'test';"
```
