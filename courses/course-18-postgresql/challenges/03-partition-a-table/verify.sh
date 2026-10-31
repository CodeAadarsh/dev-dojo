#!/usr/bin/env bash
# Verifier: "Partition a Table by Month"
# Checks that:
#   1. events is a declaratively partitioned table (pg_partitioned_table)
#   2. at least 2 child partitions exist (pg_inherits)
#   3. an INSERT for 2024-01-15 routes to a child partition, not the parent
# Prints the flag only when all three conditions hold.
set -uo pipefail

SLUG="03-partition-a-table"
FLAG='KUBE{partition_routes_inserts_by_month}'
PROBE='_dojo_probe_jan24'

fail() { echo "✗ $1"; exit 1; }

echo "==> Checking dojo-pg container is running..."
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg is not running — run setup.sh first"

echo "==> Checking events table exists..."
TBL=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relname = 'events' AND n.nspname = 'public';" | tr -d '[:space:]')
[ "$TBL" -ge 1 ] 2>/dev/null \
  || fail "table 'events' not found in public schema — run setup.sh and then apply migrate.sql"

echo "==> Checking events is a partitioned table..."
IS_PART=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_partitioned_table pt
   JOIN pg_class c ON pt.partrelid = c.oid
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relname = 'events' AND n.nspname = 'public';" | tr -d '[:space:]')
[ "$IS_PART" -ge 1 ] 2>/dev/null \
  || fail "events is not a partitioned table — recreate it with PARTITION BY RANGE (created_at)"

echo "==> Counting child partitions (need >= 2)..."
NPARTS=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_inherits i
   JOIN pg_class p ON i.inhparent = p.oid
   JOIN pg_namespace n ON n.oid = p.relnamespace
   WHERE p.relname = 'events' AND n.nspname = 'public';" | tr -d '[:space:]')
[ "$NPARTS" -ge 2 ] 2>/dev/null \
  || fail "only $NPARTS child partition(s) found — create at least 2 monthly partitions"

echo "==> Inserting probe row for 2024-01-15 to test routing..."
docker exec dojo-pg psql -U postgres -d dojo -q \
  -c "INSERT INTO events (event_type, payload, created_at)
      VALUES ('$PROBE', '{\"probe\":true}', '2024-01-15 12:00:00+00');" 2>/dev/null \
  || fail "INSERT for 2024-01-15 failed — ensure a partition covers that date range (FROM '2024-01-01' TO '2024-02-01')"

echo "==> Checking probe row landed in a child partition (not the parent)..."
DEST=$(docker exec dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT tableoid::regclass::text FROM events WHERE event_type = '$PROBE' LIMIT 1;" \
  | tr -d '[:space:]')

# Clean up probe row regardless of outcome
docker exec dojo-pg psql -U postgres -d dojo -q \
  -c "DELETE FROM events WHERE event_type = '$PROBE';" >/dev/null 2>&1 || true

[ -n "$DEST" ] \
  || fail "probe row not found after INSERT — the partition for 2024-01-15 may be missing"

[ "$DEST" != "events" ] \
  || fail "probe row landed in parent table 'events' instead of a child partition — the insert-routing is not working. Ensure the partition bound covers 2024-01-15."

echo "    Probe row routed to: $DEST"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
