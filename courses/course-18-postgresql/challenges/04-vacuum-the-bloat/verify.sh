#!/usr/bin/env bash
# Verifier — 04-vacuum-the-bloat
# Passes when ch04.events still has live rows and n_dead_tup < 100.
set -uo pipefail

FLAG='KUBE{vacuum_defeats_bloat}'

fail() { echo "✗ $1"; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg container is not running — run setup.sh first"

docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1 \
  || fail "Postgres is not ready inside dojo-pg"

# ── 1. Table must still exist ─────────────────────────────────────────────────
TABLE_EXISTS=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT count(*) FROM information_schema.tables
      WHERE table_schema = 'ch04' AND table_name = 'events';" \
  | tr -d ' \t\r\n')

[ "$TABLE_EXISTS" = "1" ] \
  || fail "ch04.events does not exist — did you DROP or TRUNCATE it? Re-run setup.sh and try VACUUM instead."

# ── 2. Live tuple count must be reasonable (not zeroed out) ──────────────────
LIVE=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT n_live_tup FROM pg_stat_user_tables
      WHERE schemaname = 'ch04' AND relname = 'events';" \
  | tr -d ' \t\r\n')

[ -n "$LIVE" ] \
  || fail "pg_stat_user_tables has no row for ch04.events — run: SELECT count(*) FROM ch04.events; first, then retry."

[ "$LIVE" -gt 1000 ] \
  || fail "n_live_tup = $LIVE — table appears empty or nearly empty. Do not TRUNCATE: use VACUUM to clean dead tuples while keeping live rows."

# ── 3. Dead tuple count must be near zero ────────────────────────────────────
DEAD=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT n_dead_tup FROM pg_stat_user_tables
      WHERE schemaname = 'ch04' AND relname = 'events';" \
  | tr -d ' \t\r\n')

[ -n "$DEAD" ] \
  || fail "Could not read n_dead_tup from pg_stat_user_tables."

if [ "$DEAD" -lt 100 ]; then
  echo "Live tuples : $LIVE"
  echo "Dead tuples : $DEAD  (< 100 — VACUUM succeeded)"
  echo
  echo "All checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  fail "n_dead_tup = $DEAD — still too many dead tuples. Run:  VACUUM ANALYZE ch04.events;  then retry."
fi
