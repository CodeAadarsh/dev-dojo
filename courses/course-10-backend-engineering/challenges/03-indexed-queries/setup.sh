#!/usr/bin/env bash
# Plants the "Indexed Queries" catalog database into the work directory.
# Idempotent — re-running regenerates the database.
# Prereqs: python3 (stdlib only — no pip install needed).
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-indexed-queries"
mkdir -p "$WORK"

# ── seed.py ──────────────────────────────────────────────────────────────────
cat > "$WORK/seed.py" << 'PYEOF'
#!/usr/bin/env python3 -I
import sqlite3
import os
import random

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.db")

CATEGORIES = [
    ("electronics",  "Electronics"),
    ("clothing",     "Clothing"),
    ("books",        "Books"),
    ("home-garden",  "Home & Garden"),
    ("sports",       "Sports"),
    ("toys",         "Toys"),
    ("food",         "Food & Grocery"),
    ("health",       "Health & Beauty"),
    ("automotive",   "Automotive"),
    ("office",       "Office Supplies"),
    ("music",        "Music & Instruments"),
    ("art",          "Art & Crafts"),
    ("outdoors",     "Outdoor Equipment"),
    ("pets",         "Pet Supplies"),
    ("games",        "Video Games"),
    ("movies",       "Movies & TV"),
    ("jewelry",      "Jewelry"),
    ("tools",        "Tools & Hardware"),
    ("appliances",   "Appliances"),
    ("classified",   "Classified"),
]

REGULAR_SLUGS = [c[0] for c in CATEGORIES if c[0] != "classified"]

conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()

cur.executescript("""
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS categories;

CREATE TABLE categories (
    id    INTEGER PRIMARY KEY,
    slug  TEXT UNIQUE NOT NULL,
    label TEXT NOT NULL
);

CREATE TABLE products (
    id               INTEGER PRIMARY KEY,
    sku              TEXT    NOT NULL,
    name             TEXT    NOT NULL,
    category_id      INTEGER NOT NULL,
    price_cents      INTEGER NOT NULL,
    is_active        INTEGER NOT NULL DEFAULT 1,
    restricted_notes TEXT
);
""")

cur.executemany(
    "INSERT INTO categories (slug, label) VALUES (?, ?)",
    CATEGORIES,
)

slug_to_id = {row[0]: row[1] for row in cur.execute("SELECT slug, id FROM categories")}
classified_id = slug_to_id["classified"]

random.seed(42)

products = []
for i in range(1, 5001):
    slug = random.choice(REGULAR_SLUGS)
    products.append((
        f"SKU-{i:05d}",
        f"Product {i}",
        slug_to_id[slug],
        random.randint(99, 99999),
        1,
        None,
    ))

products.append((
    "SKU-CLSFD-01",
    "Classified Asset Omega",
    classified_id,
    0,
    0,
    "KUBE{index_your_foreign_keys}",
))

cur.executemany(
    "INSERT INTO products (sku, name, category_id, price_cents, is_active, restricted_notes) VALUES (?, ?, ?, ?, ?, ?)",
    products,
)

conn.commit()
conn.close()
print(f"Seeded {len(products)} products across {len(CATEGORIES)} categories.")
print(f"Database: {DB_PATH}")
PYEOF

python3 -I "$WORK/seed.py"

echo
echo "Work directory : $WORK"
echo "Database       : $WORK/catalog.db"
echo
echo "Task           : find and fix the missing index, then retrieve the flag."
echo
echo "Quick start    :"
echo "  sqlite3 $WORK/catalog.db"
echo "  sqlite> EXPLAIN QUERY PLAN"
echo "  sqlite>   SELECT p.restricted_notes"
echo "  sqlite>   FROM products p JOIN categories c ON p.category_id = c.id"
echo "  sqlite>   WHERE c.slug = 'classified' AND p.is_active = 0;"
echo
echo "  -- observe SCAN TABLE products, then:"
echo "  sqlite> CREATE INDEX idx_products_category ON products(category_id);"
echo "  sqlite> -- re-run EXPLAIN QUERY PLAN, then run the query to get the flag."
echo
echo "Self-check     : bash courses/course-10-backend-engineering/challenges/03-indexed-queries/verify.sh"
