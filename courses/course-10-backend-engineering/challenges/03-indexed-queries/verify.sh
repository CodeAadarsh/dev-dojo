#!/usr/bin/env bash
# Optional self-check for "Indexed Queries" (discovery challenge).
# Confirms an index exists on products, runs the discovery query,
# and prints the flag value. Use this to verify your answer before submitting.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-indexed-queries"
DBFILE="$WORK/catalog.db"

fail() { echo "✗ $1"; exit 1; }

[ -f "$DBFILE" ] || fail "catalog.db not found — run setup.sh first"

cd "$WORK"

INDEX=$(python3 -I -c "
import sqlite3
conn = sqlite3.connect('catalog.db')
rows = conn.execute(
    \"SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='products' AND name NOT LIKE 'sqlite_%'\"
).fetchall()
print(' '.join(r[0] for r in rows))
conn.close()
")

[ -n "$INDEX" ] || fail "no user-defined index found on the products table — have you run CREATE INDEX idx_products_category ON products(category_id)?"
echo "✓ index present : $INDEX"

FLAG_VALUE=$(python3 -I -c "
import sqlite3
conn = sqlite3.connect('catalog.db')
row = conn.execute('''
    SELECT p.restricted_notes
    FROM products p
    JOIN categories c ON p.category_id = c.id
    WHERE c.slug = 'classified'
      AND p.is_active = 0
''').fetchone()
print(row[0] if row else '')
conn.close()
")

[ -n "$FLAG_VALUE" ] || fail "query returned no rows — the seed data may be missing, try re-running setup.sh"
echo "✓ discovery query succeeded"
echo
echo "Flag:"
echo
echo "    $FLAG_VALUE"
