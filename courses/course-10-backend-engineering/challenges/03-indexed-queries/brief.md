# Indexed Queries

A data platform team pings you: *"The analytics query for category breakdowns takes 4–8 seconds even on our smallest dataset. Can you look at it? The table only has 5 000 rows."*

You open a SQLite shell. The query joins `products` to `categories` on `category_id`. `EXPLAIN QUERY PLAN` shows the problem immediately: the join column on `products` has no index, so every join forces a full table scan. Five thousand rows is nothing — on a real production table with millions of rows and concurrent load, this kills the database.

## Context

`setup.sh` plants a catalog database in:

```
~/.kube-dojo-work/03-indexed-queries/
└── catalog.db    # 5 001 products across 20 categories
```

Schema:

```sql
CREATE TABLE categories (
    id    INTEGER PRIMARY KEY,
    slug  TEXT UNIQUE NOT NULL,
    label TEXT NOT NULL
);

CREATE TABLE products (
    id               INTEGER PRIMARY KEY,
    sku              TEXT    NOT NULL,
    name             TEXT    NOT NULL,
    category_id      INTEGER NOT NULL,   -- FK to categories.id, intentionally unindexed
    price_cents      INTEGER NOT NULL,
    is_active        INTEGER NOT NULL DEFAULT 1,
    restricted_notes TEXT
);
```

No index on `products.category_id`. That is the bug.

## Mission

1. **Open the database** and run `EXPLAIN QUERY PLAN` on the target query (below). Observe `SCAN TABLE products` in the output — that is the full-table scan.
2. **Create the missing index** on `products.category_id`.
3. **Re-run `EXPLAIN QUERY PLAN`** and confirm the plan now shows `SEARCH TABLE products ... USING INDEX`.
4. **Run the target query** and read the `restricted_notes` value from the result. That value is the flag.

Target query:

```sql
SELECT p.restricted_notes
FROM products p
JOIN categories c ON p.category_id = c.id
WHERE c.slug = 'classified'
  AND p.is_active = 0;
```

Submit the `KUBE{...}` string you retrieve as the flag.

## EXPLAIN QUERY PLAN primer

```sql
EXPLAIN QUERY PLAN
SELECT p.restricted_notes
FROM products p
JOIN categories c ON p.category_id = c.id
WHERE c.slug = 'classified'
  AND p.is_active = 0;
```

**Without the index** you will see something like:

```
QUERY PLAN
|--SEARCH categories AS c USING INDEX sqlite_autoindex_categories_1 (slug=?)
`--SCAN products AS p
```

`SCAN products` = read every row = O(n). On `categories` SQLite already has an autoindex on `slug` (because `slug TEXT UNIQUE`), which is why that side is a `SEARCH`. The join side — `products.category_id` — has nothing.

**After `CREATE INDEX idx_products_category ON products(category_id)`:**

```
QUERY PLAN
|--SEARCH categories AS c USING INDEX sqlite_autoindex_categories_1 (slug=?)
`--SEARCH products AS p USING INDEX idx_products_category (category_id=?)
```

Both sides are index lookups. The query goes from O(n) to O(log n) on the products side.

## Why foreign keys are almost always missing their index

SQLite (and MySQL) do **not** automatically create an index on a foreign key column — that is the declaring table's responsibility. PostgreSQL is the same. This is one of the most common performance bugs in production schemas: the FK constraint is declared, the ON DELETE rule is set, but nobody added `CREATE INDEX idx_... ON child_table(fk_column)`. Every join on that FK column is a full scan until someone notices.

The rule: **any column that appears in a JOIN condition or a WHERE clause on a large table needs an index.** Check your own schema with `PRAGMA index_list(table_name)`.

## Debugging slow queries

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Simple join takes seconds on a small table | Missing index on join column | `CREATE INDEX idx_t_col ON t(col)` |
| `EXPLAIN QUERY PLAN` shows `SCAN TABLE` | No suitable index for the filter or join | Add the index; confirm plan changes to `SEARCH ... USING INDEX` |
| Index exists but `SCAN` still shown | Index is on wrong column, or query bypasses it (e.g. `WHERE f(col) = ...`) | Index the expression or restructure the query |
| Query sped up after `CREATE INDEX` but inserts got slower | Index maintenance cost on every write | Expected trade-off; index only what you query |

> **War story.** At a previous company a `/search` endpoint started timing out in production with p99 > 10 s. The table had 200 k rows — not huge. `EXPLAIN ANALYZE` (PostgreSQL) revealed a full sequential scan on a `user_id` column used in every `WHERE` clause. The column was a FK, the constraint was declared, but the index was never created. The deploy that added the endpoint forgot the migration step. Adding `CREATE INDEX CONCURRENTLY` on the live table took 8 seconds. p99 dropped to 12 ms. The root cause: code review caught the FK constraint but nobody checked for the companion index.

## Optional self-check

```bash
bash courses/course-10-backend-engineering/challenges/03-indexed-queries/verify.sh
```

This checker confirms an index exists on `products` and prints the flag value directly — use it to confirm you have the right answer before submitting.

## Extraction paths

Three ways to get the flag once you have the index:

1. **SQLite3 CLI**: `sqlite3 ~/.kube-dojo-work/03-indexed-queries/catalog.db` then paste the target query.
2. **Python**: `python3 -c "import sqlite3; conn=sqlite3.connect('$HOME/.kube-dojo-work/03-indexed-queries/catalog.db'); print(conn.execute(\"SELECT p.restricted_notes FROM products p JOIN categories c ON p.category_id=c.id WHERE c.slug='classified' AND p.is_active=0\").fetchone()[0])"`
3. **Self-check script**: `bash courses/course-10-backend-engineering/challenges/03-indexed-queries/verify.sh`
