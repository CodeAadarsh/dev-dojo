#!/usr/bin/env bash
# Challenge 06 — Tune the Plan
# Seeds ch06.events with 200 000 rows (100 ERROR, 199 900 INFO),
# disables autovacuum so statistics stay stale, and leaves no index on event_type.
set -euo pipefail

SLUG="06-tune-the-plan"
WORK="$HOME/.kube-dojo-work/$SLUG"

# ── Ensure dojo-pg container is running ─────────────────────────────────────
docker ps -a --format '{{.Names}}' | grep -qx dojo-pg || \
  docker run -d --name dojo-pg \
    -e POSTGRES_PASSWORD=dojo \
    -e POSTGRES_DB=dojo \
    -p 55432:5432 \
    postgres:16-alpine

echo "Waiting for Postgres to be ready..."
until docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
echo "Postgres is ready."

# ── Schema + table (idempotent) ──────────────────────────────────────────────
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQL'
DROP SCHEMA IF EXISTS ch06 CASCADE;
CREATE SCHEMA ch06;

CREATE TABLE ch06.events (
    id          bigserial    PRIMARY KEY,
    event_type  text         NOT NULL,
    payload     text,
    created_at  timestamptz  NOT NULL DEFAULT now()
);

-- Disable autovacuum so statistics stay stale and the learner must manually ANALYZE.
ALTER TABLE ch06.events SET (autovacuum_enabled = false);
SQL

echo "Seeding 200 000 rows (100 ERROR, 199 900 INFO)..."
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQL'
-- i % 2000 = 0 fires at i = 2000, 4000, ..., 200000 → exactly 100 ERROR rows.
INSERT INTO ch06.events (event_type, payload)
SELECT
    CASE WHEN i % 2000 = 0 THEN 'ERROR' ELSE 'INFO' END,
    'payload_' || i::text
FROM generate_series(1, 200000) AS s(i);

-- Intentionally NOT running ANALYZE so reltuples / statistics are stale.
SQL

echo "Done seeding. Statistics are deliberately stale (ANALYZE not run)."

# ── Scaffold work directory ──────────────────────────────────────────────────
mkdir -p "$WORK"
cat > "$WORK/fix_the_plan.sql" << 'SQLEOF'
-- ============================================================
-- Challenge 06 — fix_the_plan.sql
-- Work through the steps below to diagnose and fix the bad plan.
-- ============================================================

-- Step 1: Read the bad plan.
-- Notice: Seq Scan on events, rows estimate is wildly wrong.
EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';


-- Step 2: Check what reltuples thinks the table has (stale!).
SELECT relname, reltuples, relpages
FROM pg_class
WHERE relname = 'events'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'ch06');


-- Step 3: Fix the statistics.
ANALYZE ch06.events;


-- Step 3b: After ANALYZE, inspect the stats the planner now has.
SELECT
    attname,
    n_distinct,
    most_common_vals,
    most_common_freqs
FROM pg_stats
WHERE schemaname = 'ch06'
  AND tablename  = 'events'
  AND attname    = 'event_type';


-- Step 4: Add a B-tree index on event_type.
-- TODO: write the CREATE INDEX statement here.


-- Step 5: Re-check the plan — should now show Index Scan, not Seq Scan.
EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';


-- Step 6: Verify correctness — must return exactly 100.
SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';
SQLEOF

echo
echo "============================================================"
echo " Challenge 06 — Tune the Plan"
echo "============================================================"
echo " Work dir  : $WORK"
echo " Container : dojo-pg (postgres:16-alpine, port 55432)"
echo
echo " Connect   : psql -h 127.0.0.1 -p 55432 -U postgres -d dojo"
echo "             password: dojo"
echo
echo " Table ch06.events: 200 000 rows, 100 ERROR / 199 900 INFO."
echo " No index on event_type. autovacuum disabled (statistics stale)."
echo
echo " Starter SQL : $WORK/fix_the_plan.sql"
echo " Verify      : bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
echo "============================================================"
