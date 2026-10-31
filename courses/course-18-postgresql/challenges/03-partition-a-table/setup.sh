#!/usr/bin/env bash
# Sets up the "Partition a Table by Month" challenge.
# Prereq: Docker running. Creates a plain (non-partitioned) events table,
# seeds it with rows spanning three months, and plants a migration stub
# in the work directory.
set -euo pipefail

SLUG="03-partition-a-table"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

echo "==> Ensuring dojo-pg container is running..."
docker ps -a --format '{{.Names}}' | grep -qx dojo-pg || \
  docker run -d --name dojo-pg \
    -e POSTGRES_PASSWORD=dojo \
    -e POSTGRES_DB=dojo \
    -p 55432:5432 \
    postgres:16-alpine

echo "==> Waiting for PostgreSQL to accept connections..."
until docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

echo "==> Creating plain events table with seed data..."
docker exec -i dojo-pg psql -U postgres -d dojo <<'SQL'
-- Drop any partitioned or plain version from previous runs
DROP TABLE IF EXISTS events CASCADE;
DROP TABLE IF EXISTS events_old CASCADE;

CREATE TABLE events (
    id         BIGSERIAL       PRIMARY KEY,
    event_type TEXT            NOT NULL,
    payload    JSONB           NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Seed three months of data
INSERT INTO events (event_type, payload, created_at)
SELECT
    (ARRAY['page_view','click','purchase','signup','logout'])[ceil(random()*5)::int],
    jsonb_build_object('user', (random()*10000)::int, 'session', gen_random_uuid()),
    ts
FROM (
    SELECT
        '2024-01-01'::timestamptz + (i || ' hours')::interval AS ts
    FROM generate_series(0, 71) AS i        -- 72 hours = Jan 1-3
    UNION ALL
    SELECT
        '2024-02-01'::timestamptz + (i || ' hours')::interval
    FROM generate_series(0, 71) AS i        -- Feb 1-3
    UNION ALL
    SELECT
        '2024-03-01'::timestamptz + (i || ' hours')::interval
    FROM generate_series(0, 71) AS i        -- Mar 1-3
) t;

ANALYZE events;
SQL

# Plant migration stub
cat > "$WORK/migrate.sql" <<'SQLEOF'
-- migrate.sql — Convert events to RANGE-partitioned by month
--
-- PostgreSQL cannot ALTER a table to add partitioning in-place.
-- The standard approach:
--   1. Rename the existing table (preserve the data)
--   2. Create a new partitioned parent with the same columns
--   3. Create at least two monthly child partitions
--   4. Copy the data back
--   5. Optionally drop the old table
--
-- The verifier checks:
--   a) events is a partitioned table (pg_partitioned_table)
--   b) at least 2 child partitions exist (pg_inherits)
--   c) an INSERT for 2024-01-15 lands in a child partition, not in 'events' itself
--
-- Apply when done:
--   docker exec -i dojo-pg psql -U postgres -d dojo < $HOME/.kube-dojo-work/03-partition-a-table/migrate.sql

-- Step 1: preserve existing data
ALTER TABLE events RENAME TO events_old;

-- Step 2: new partitioned parent (no PRIMARY KEY on the parent — partitioned tables
-- require the partition key to be part of any unique constraint)
CREATE TABLE events (
    id         BIGINT          GENERATED ALWAYS AS IDENTITY,
    event_type TEXT            NOT NULL,
    payload    JSONB           NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ     NOT NULL
) PARTITION BY RANGE (created_at);

-- Step 3: child partitions — add at least 2 (cover Jan and Feb 2024 at minimum)
-- TODO: uncomment and complete the partition definitions below

-- CREATE TABLE events_2024_01 PARTITION OF events
--     FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- CREATE TABLE events_2024_02 PARTITION OF events
--     FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Step 4: copy data (rows outside declared partition bounds will ERROR — add
-- more partitions or a DEFAULT partition to handle them)
-- TODO: uncomment after creating partitions
-- INSERT INTO events (id, event_type, payload, created_at)
--     SELECT id, event_type, payload, created_at FROM events_old;

-- Step 5 (optional): DROP TABLE events_old;
SQLEOF

echo
echo "Work directory : $WORK"
echo "Migration stub : $WORK/migrate.sql"
echo
echo "Current table  : events (NOT partitioned — 216 rows across Jan/Feb/Mar 2024)"
echo
echo "Apply when done:"
echo "  docker exec -i dojo-pg psql -U postgres -d dojo < $WORK/migrate.sql"
echo
echo "Verify:"
echo "  bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
