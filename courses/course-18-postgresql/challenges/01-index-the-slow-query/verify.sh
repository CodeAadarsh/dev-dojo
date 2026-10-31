#!/usr/bin/env bash
# Verifier: "Index the Slow Query"
# Checks that an index covering user_id exists on orders AND that the query
# planner uses an Index Scan (not a Seq Scan) for a per-user lookup.
# Prints the flag only when both conditions hold.
set -uo pipefail

SLUG="01-index-the-slow-query"
FLAG='KUBE{index_the_slow_query}'

fail() { echo "✗ $1"; exit 1; }

echo "==> Checking dojo-pg container is running..."
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg is not running — run setup.sh first"

echo "==> Checking orders table exists..."
TBL=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relname = 'orders' AND n.nspname = 'public';" | tr -d '[:space:]')
[ "$TBL" -ge 1 ] 2>/dev/null \
  || fail "table 'orders' not found in public schema — run setup.sh first"

echo "==> Checking that orders has enough rows (seeding may be incomplete)..."
CNT=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM orders;" | tr -d '[:space:]')
[ "$CNT" -ge 50000 ] 2>/dev/null \
  || fail "orders table has only $CNT rows (expected ~100 000) — re-run setup.sh"

echo "==> Checking an index on user_id exists..."
IDX=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_indexes
   WHERE tablename = 'orders'
     AND schemaname = 'public'
     AND indexdef ILIKE '%user_id%';" | tr -d '[:space:]')
[ "$IDX" -ge 1 ] 2>/dev/null \
  || fail "no index on orders.user_id found — CREATE INDEX ... ON orders(user_id);"

echo "==> Running EXPLAIN (FORMAT JSON) to confirm planner uses an index scan..."
PLAN=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "EXPLAIN (FORMAT JSON) SELECT * FROM orders WHERE user_id = 7777;")

# The JSON plan tree contains a "Node Type" entry for every node.
# An index-based plan always has at least one node whose type starts with "Index"
# (Index Scan, Index Only Scan, Bitmap Index Scan).
echo "$PLAN" | grep -q '"Node Type": "Index' \
  || fail "planner is still using a Seq Scan — run: ANALYZE orders; inside psql and retry. If it still seqscans the index may not match the filter column."

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
