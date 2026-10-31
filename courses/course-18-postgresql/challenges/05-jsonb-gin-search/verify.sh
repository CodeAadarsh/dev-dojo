#!/usr/bin/env bash
# Verifier — 05-jsonb-gin-search
# Passes when: a GIN index exists on ch05.products.attrs AND
# EXPLAIN of an @> query shows Bitmap Index Scan.
set -uo pipefail

FLAG='KUBE{gin_powers_jsonb_search}'

fail() { echo "✗ $1"; exit 1; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg container is not running — run setup.sh first"

docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1 \
  || fail "Postgres is not ready inside dojo-pg"

# ── 1. GIN index must exist on ch05.products ─────────────────────────────────
GIN_COUNT=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT count(*) FROM pg_indexes
      WHERE schemaname = 'ch05'
        AND tablename  = 'products'
        AND indexdef   LIKE '%gin%';" \
  | tr -d ' \t\r\n')

[ -n "$GIN_COUNT" ] \
  || fail "Could not query pg_indexes — is schema ch05 present? Run setup.sh."

[ "$GIN_COUNT" -ge 1 ] \
  || fail "No GIN index found on ch05.products — run: CREATE INDEX ON ch05.products USING gin(attrs);"

echo "GIN index   : found ($GIN_COUNT index(es) with 'gin' in definition)"

# ── 2. EXPLAIN must show Bitmap Index Scan ────────────────────────────────────
# We disable seqscan so the planner is forced to use the GIN index if it exists.
# If no usable index exists, the planner falls back to seq scan anyway.
EXPLAIN_OUT=$(docker exec -i dojo-pg psql -U postgres -d dojo -tA << 'SQL'
SET enable_seqscan = off;
EXPLAIN SELECT * FROM ch05.products WHERE attrs @> '{"brand":"Nike"}';
SQL
)

if echo "$EXPLAIN_OUT" | grep -q "Bitmap Index Scan"; then
  echo "Query plan  : Bitmap Index Scan confirmed"
  echo
  echo "All checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  echo "EXPLAIN output:"
  echo "$EXPLAIN_OUT"
  fail "EXPLAIN does not show a Bitmap Index Scan. Ensure the GIN index is on the 'attrs' column and run ANALYZE ch05.products; then retry."
fi
