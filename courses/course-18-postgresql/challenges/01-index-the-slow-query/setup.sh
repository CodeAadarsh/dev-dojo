#!/usr/bin/env bash
# Sets up the "Index the Slow Query" challenge.
# Prereq: Docker running. Seeds a 100k-row orders table in dojo-pg, plants
# a starter SQL file in the work directory.
set -euo pipefail

SLUG="01-index-the-slow-query"
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

echo "==> Seeding orders table (100 000 rows — takes ~5 s)..."
docker exec -i dojo-pg psql -U postgres -d dojo <<'SQL'
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    id         SERIAL          PRIMARY KEY,
    user_id    INT             NOT NULL,
    total      NUMERIC(12,2)   NOT NULL,
    status     TEXT            NOT NULL,
    created_at TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

INSERT INTO orders (user_id, total, status, created_at)
SELECT
    (random() * 9999 + 1)::int,
    (random() * 2000 + 10)::numeric(12,2),
    (ARRAY['pending','processing','shipped','delivered','cancelled'])[ceil(random()*5)::int],
    NOW() - (random() * interval '730 days')
FROM generate_series(1, 100000);

ANALYZE orders;
SQL

# Plant the starter work file
cat > "$WORK/solution.sql" <<'SQLEOF'
-- solution.sql — Index the Slow Query
--
-- The following query does a full sequential scan across 100 000 rows every
-- time a user opens their order history. On a real production table with
-- millions of rows this turns a single page-load into a 3+ second wait and
-- saturates shared_buffers with unwanted pages.
--
-- Target query (run this to see the current scan type):
--   docker exec dojo-pg psql -U postgres -d dojo \
--     -c "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 7777;"
--
-- Your task: write ONE CREATE INDEX statement below so that the same EXPLAIN
-- shows an Index Scan (or Bitmap Index Scan) instead of a Seq Scan.
-- Then run ANALYZE orders; so the planner picks up fresh statistics.
--
-- Apply this file when ready:
--   docker exec -i dojo-pg psql -U postgres -d dojo < $HOME/.kube-dojo-work/01-index-the-slow-query/solution.sql

-- ↓ your index here


SQLEOF

echo
echo "Work directory : $WORK"
echo "Slow query     : SELECT * FROM orders WHERE user_id = 7777;"
echo
echo "Apply your index:"
echo "  docker exec -i dojo-pg psql -U postgres -d dojo < $WORK/solution.sql"
echo
echo "Verify:"
echo "  bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
