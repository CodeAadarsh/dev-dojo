#!/usr/bin/env bash
# Challenge 05 — JSONB + GIN: Index the Document
# Seeds ch05.products with 5 000 rows of varied JSONB attributes, no index.
set -euo pipefail

SLUG="05-jsonb-gin-search"
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
DROP SCHEMA IF EXISTS ch05 CASCADE;
CREATE SCHEMA ch05;

CREATE TABLE ch05.products (
    id      bigserial PRIMARY KEY,
    name    text      NOT NULL,
    attrs   jsonb     NOT NULL
);
SQL

echo "Seeding 5 000 product rows with varied JSONB attributes..."
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQL'
INSERT INTO ch05.products (name, attrs)
SELECT
    'product_' || i::text,
    jsonb_build_object(
        'brand',    (ARRAY['Nike','Adidas','Puma','Reebok','UnderArmour'])[(i % 5) + 1],
        'color',    (ARRAY['black','white','red','blue','green'])[(i % 7) % 5 + 1],
        'size',     (ARRAY['XS','S','M','L','XL'])[(i % 5 + (i % 3)) % 5 + 1],
        'price',    round((30 + (i % 200))::numeric, 2),
        'in_stock', ((i % 3) != 0)
    )
FROM generate_series(1, 5000) AS s(i);

ANALYZE ch05.products;
SQL

# ── Scaffold work directory ──────────────────────────────────────────────────
mkdir -p "$WORK"
cat > "$WORK/index_and_query.sql" << 'SQLEOF'
-- ============================================================
-- Challenge 05 — index_and_query.sql
-- Fill in the two TODOs below and run this in psql.
-- ============================================================

-- TODO 1: Create a GIN index on the attrs column.
-- Syntax:  CREATE INDEX <name> ON ch05.products USING gin(attrs);
-- Tip: you may also use the jsonb_path_ops operator class for a smaller index.


-- TODO 2: Confirm the plan switched from Seq Scan to Bitmap Index Scan.
EXPLAIN SELECT * FROM ch05.products WHERE attrs @> '{"brand":"Nike"}';


-- Optional: run the query itself to see results.
SELECT id, name, attrs->>'brand' AS brand, attrs->>'color' AS color
FROM ch05.products
WHERE attrs @> '{"brand":"Nike"}'
LIMIT 10;
SQLEOF

echo
echo "============================================================"
echo " Challenge 05 — JSONB + GIN: Index the Document"
echo "============================================================"
echo " Work dir  : $WORK"
echo " Container : dojo-pg (postgres:16-alpine, port 55432)"
echo
echo " Connect   : psql -h 127.0.0.1 -p 55432 -U postgres -d dojo"
echo "             password: dojo"
echo
echo " The table ch05.products has 5 000 rows and a jsonb column 'attrs'."
echo " No index exists yet — sequential scans only."
echo
echo " Starter SQL : $WORK/index_and_query.sql"
echo " Verify      : bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
echo "============================================================"
