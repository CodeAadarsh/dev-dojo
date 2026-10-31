#!/usr/bin/env bash
# Verifier — 06-tune-the-plan
# Passes when: index on event_type exists, EXPLAIN no longer shows Seq Scan
# on events, and COUNT(*) WHERE event_type='ERROR' returns 100.
set -uo pipefail

FLAG='KUBE{analyze_your_way_to_a_better_plan}'

fail() { echo "✗ $1"; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg container is not running — run setup.sh first"

docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1 \
  || fail "Postgres is not ready inside dojo-pg"

# ── 1. An index on event_type must exist ────────────────────────────────────
IDX_COUNT=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT count(*) FROM pg_indexes
      WHERE schemaname = 'ch06'
        AND tablename  = 'events'
        AND indexdef   LIKE '%event_type%'
        AND indexname  NOT LIKE '%pkey%';" \
  | tr -d ' \t\r\n')

[ -n "$IDX_COUNT" ] \
  || fail "Could not query pg_indexes — is schema ch06 present? Run setup.sh."

[ "$IDX_COUNT" -ge 1 ] \
  || fail "No index found on ch06.events.event_type — run: CREATE INDEX ON ch06.events(event_type);"

echo "Index check : found ($IDX_COUNT index(es) on event_type)"

# ── 2. EXPLAIN must not show a Seq Scan on the events table ──────────────────
EXPLAIN_OUT=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';" \
  | tr -d '\r')

if echo "$EXPLAIN_OUT" | grep -q "Seq Scan on events"; then
  echo "EXPLAIN output:"
  echo "$EXPLAIN_OUT"
  fail "Plan still shows a Seq Scan on events. Ensure ANALYZE ch06.events; has been run and the index on event_type exists."
fi

echo "Plan check  : no Seq Scan on events (plan is efficient)"

# ── 3. Query must return exactly 100 rows ───────────────────────────────────
COUNT=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';" \
  | tr -d ' \t\r\n')

[ -n "$COUNT" ] \
  || fail "COUNT query returned no result — is ch06.events accessible?"

[ "$COUNT" = "100" ] \
  || fail "Query returned $COUNT rows, expected exactly 100. Do not modify the table data — only add indexes and run ANALYZE."

echo "Count check : $COUNT ERROR rows (correct)"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
