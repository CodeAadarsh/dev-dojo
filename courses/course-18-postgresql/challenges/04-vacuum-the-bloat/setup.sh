#!/usr/bin/env bash
# Challenge 04 — VACUUM the Bloat
# Creates ch04.events, seeds 20 000 rows, then runs three full-table UPDATE sweeps
# and a DELETE to generate ~65 000 dead tuples. autovacuum is disabled on the table
# so dead tuples accumulate until the learner manually VACUUMs.
set -euo pipefail

SLUG="04-vacuum-the-bloat"
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

# ── Schema + table (idempotent: drops and recreates) ────────────────────────
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQL'
DROP SCHEMA IF EXISTS ch04 CASCADE;
CREATE SCHEMA ch04;

CREATE TABLE ch04.events (
    id          bigserial PRIMARY KEY,
    session_id  text         NOT NULL,
    event_type  text         NOT NULL,
    payload     text,
    status      text         NOT NULL DEFAULT 'pending',
    created_at  timestamptz  NOT NULL DEFAULT now()
);

-- Disable autovacuum so dead tuples accumulate until the learner runs VACUUM.
ALTER TABLE ch04.events SET (
    autovacuum_enabled       = false,
    toast.autovacuum_enabled = false
);
SQL

echo "Seeding 20 000 rows..."
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQL'
INSERT INTO ch04.events (session_id, event_type, payload, status)
SELECT
    'sess_' || (i % 500)::text,
    CASE (i % 4)
        WHEN 0 THEN 'click'
        WHEN 1 THEN 'view'
        WHEN 2 THEN 'purchase'
        ELSE      'logout'
    END,
    'payload_' || i::text,
    'pending'
FROM generate_series(1, 20000) AS s(i);
SQL

echo "Wave 1/3: UPDATE all rows — sets status='active' (generates 20 000 dead tuples)..."
docker exec -i dojo-pg psql -U postgres -d dojo \
  -c "UPDATE ch04.events SET status = 'active' WHERE status = 'pending';"

echo "Wave 2/3: UPDATE all rows — appends '_v2' to payload (another 20 000 dead tuples)..."
docker exec -i dojo-pg psql -U postgres -d dojo \
  -c "UPDATE ch04.events SET payload = payload || '_v2';"

echo "Wave 3/3: UPDATE all rows — lowercases event_type (another 20 000 dead tuples)..."
docker exec -i dojo-pg psql -U postgres -d dojo \
  -c "UPDATE ch04.events SET event_type = lower(event_type);"

echo "DELETE 5 000 rows (adds 5 000 more dead tuples; live rows drop to 15 000)..."
docker exec -i dojo-pg psql -U postgres -d dojo \
  -c "DELETE FROM ch04.events WHERE id % 4 = 0;"

# Trigger a heap scan so the stats collector records n_dead_tup.
docker exec -i dojo-pg psql -U postgres -d dojo \
  -c "SELECT count(*) FROM ch04.events;" > /dev/null

# PG16 stats are in shared memory and flush immediately; a short sleep is insurance.
sleep 2

# ── Scaffold work directory ──────────────────────────────────────────────────
mkdir -p "$WORK"
cat > "$WORK/diagnose_and_vacuum.sql" << 'SQLEOF'
-- ============================================================
-- Challenge 04 — diagnose_and_vacuum.sql
-- Run this file in psql to step through the investigation.
-- ============================================================

-- Step 1: How bad is the bloat?
SELECT
    relname                                                     AS table_name,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup
          / NULLIF(n_live_tup + n_dead_tup, 0), 1)             AS dead_pct,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'ch04'
ORDER BY n_dead_tup DESC;

-- Step 2: Physical size before cleanup.
SELECT
    pg_size_pretty(pg_total_relation_size('ch04.events')) AS total_size,
    pg_size_pretty(pg_relation_size('ch04.events'))       AS heap_size;

-- Step 3: Run the right VACUUM.
-- VACUUM ANALYZE reclaims dead tuple slots AND refreshes planner statistics.
-- This is the safest choice for production: no exclusive lock, one command.
VACUUM ANALYZE ch04.events;

-- Step 4: Re-check — n_dead_tup should now be ~0, last_vacuum should be set.
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum
FROM pg_stat_user_tables
WHERE schemaname = 'ch04';

-- Note: pg_relation_size will still show the same file size after plain VACUUM.
-- Space is freed for re-use but the file is NOT truncated.
-- VACUUM FULL would shrink the file but requires an exclusive lock.
SELECT
    pg_size_pretty(pg_total_relation_size('ch04.events')) AS total_size_after,
    pg_size_pretty(pg_relation_size('ch04.events'))       AS heap_size_after;
SQLEOF

echo
echo "============================================================"
echo " Challenge 04 — VACUUM the Bloat"
echo "============================================================"
echo " Work dir  : $WORK"
echo " Container : dojo-pg (postgres:16-alpine, port 55432)"
echo
echo " Connect   : psql -h 127.0.0.1 -p 55432 -U postgres -d dojo"
echo "             password: dojo"
echo
echo " The table ch04.events has ~15 000 live rows and ~65 000 dead"
echo " tuples from heavy UPDATE/DELETE churn. autovacuum is disabled."
echo
echo " Starter SQL : $WORK/diagnose_and_vacuum.sql"
echo " Verify      : bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
echo "============================================================"
