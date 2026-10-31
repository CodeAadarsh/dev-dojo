# JSONB + GIN: Index the Document

A product team is building a catalog service. Product attributes — brand, color, size, price tier — vary wildly by category: a shirt has a size, a laptop has RAM, a shoe has width. Rather than pre-defining hundreds of nullable columns or a separate `attributes` table with a EAV (Entity-Attribute-Value) anti-pattern, the team chose a `jsonb` column called `attrs`. Flexibility solved. Performance not so much. A code review comment on the first PR: *"The `WHERE attrs @> '{"brand":"Nike"}'` filter does a 5 000-row sequential scan on every request. We need an index."*

Your job: add the right index and prove it's being used.

---

## JSONB vs JSON — why it matters for indexing

PostgreSQL has two JSON types:

| Type | Storage | Operators | Indexable |
|------|---------|-----------|-----------|
| `json` | Text, stored verbatim | `->>`, `->` | Only with expression indexes |
| `jsonb` | Binary (decomposed) | `->>`, `->`, `@>`, `?`, `?|`, `?&`, `@@` | Native GIN/GiST support |

`jsonb` is almost always the right choice. The binary decomposition means:
- Key lookups are `O(log n)` in the document rather than a string parse.
- Duplicate keys are deduplicated (last one wins).
- Whitespace and key ordering are not preserved (which is fine — you're storing data, not formatting).
- **Most importantly for this challenge: you can put a GIN index directly on the column.**

---

## GIN — the Generalized Inverted Index

A B-tree index stores one entry per row, ordered by the indexed value. It's great for `WHERE col = X` or `WHERE col BETWEEN A AND B` on scalar values. It cannot index into a jsonb document.

A **GIN** (Generalized Inverted Index) inverts the relationship: instead of "row → value", it builds "value → set of rows":

```
B-tree on (price):               GIN on (attrs jsonb):

 price  | row_ptr                 key          | posting list (row pointers)
--------+---------                ─────────────────────────────────────────
  29.99 | (page 3, slot 2)        "Nike"       → {row 1, row 6, row 11, ...}
  49.99 | (page 3, slot 7)        "Adidas"     → {row 2, row 7, row 12, ...}
  89.99 | (page 5, slot 1)        "black"      → {row 1, row 2, row 11, ...}
  ...                             "M"          → {row 3, row 8, row 13, ...}
                                  ...
```

For a JSONB column, every key and every value in every document gets an entry in the GIN. A query like `attrs @> '{"brand":"Nike","color":"black"}'` looks up both "Nike" and "black" in the GIN, intersects the posting lists, and reads only the matching heap pages. For a 5 000-row table where only 100 rows match, this is the difference between reading 5 000 heap tuples and reading 100.

### The `@>` containment operator

`@>` asks: "does the left document contain the right document as a sub-document?"

```sql
-- Does this document contain {"brand":"Nike"}?
'{"brand":"Nike","color":"black","size":"M"}'::jsonb @> '{"brand":"Nike"}'::jsonb
-- → true

-- Multi-key containment (AND semantics):
attrs @> '{"brand":"Nike","color":"black"}'
-- matches rows where attrs has BOTH brand=Nike AND color=black
```

Other useful JSONB operators (not required for this challenge, but worth knowing):

| Operator | Meaning | Example |
|----------|---------|---------|
| `->` | Get value by key (returns jsonb) | `attrs -> 'brand'` → `"Nike"` |
| `->>` | Get value by key (returns text) | `attrs ->> 'brand'` → `Nike` |
| `?` | Does key exist? | `attrs ? 'color'` |
| `?|` | Does any of these keys exist? | `attrs ?| ARRAY['color','size']` |
| `?&` | Do all these keys exist? | `attrs ?& ARRAY['brand','price']` |
| `@>` | Contains | `attrs @> '{"brand":"Nike"}'` |
| `<@` | Is contained by | `'{"brand":"Nike"}'::jsonb <@ attrs` |

GIN indexes support `@>`, `<@`, `?`, `?|`, and `?&`.

### `jsonb_ops` vs `jsonb_path_ops`

There are two GIN operator classes for JSONB:

| Operator class | Index size | Supports |
|----------------|------------|---------|
| `jsonb_ops` (default) | Larger | `@>`, `<@`, `?`, `?|`, `?&` |
| `jsonb_path_ops` | Smaller | `@>` only |

If you only need containment queries (`@>`), `jsonb_path_ops` produces a smaller, faster index:

```sql
CREATE INDEX idx_products_attrs ON ch05.products USING gin(attrs jsonb_path_ops);
```

The default `jsonb_ops` is used when you also need key-existence operators (`?`, `?|`, `?&`). For this challenge, either works — the verifier only checks for GIN and Bitmap Index Scan.

---

## Prerequisites

Docker must be running. `setup.sh` starts (or reuses) a `dojo-pg` container:

```bash
bash courses/course-18-postgresql/challenges/05-jsonb-gin-search/setup.sh
```

Connect with:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d dojo
# password: dojo
```

---

## Mission

Setup has planted `ch05.products` — a table with 5 000 rows, each having a `attrs jsonb` column with keys `brand`, `color`, `size`, `price`, and `in_stock`. There is no index on `attrs` yet.

Your tasks:

1. **Confirm the missing index.** Run `\d ch05.products` in psql and observe no GIN index. Run `EXPLAIN SELECT * FROM ch05.products WHERE attrs @> '{"brand":"Nike"}';` and confirm it shows a `Seq Scan`.

2. **Add a GIN index** on the `attrs` column. Index name and operator class are your choice.

3. **Write a containment query** using `@>` that filters by brand. Run `EXPLAIN` on it and confirm the plan switched to `Bitmap Index Scan`.

### What `verify.sh` checks (exactly)

| Check | Condition | Failure message |
|-------|-----------|-----------------|
| GIN index exists | A row in `pg_indexes` for `ch05.products` with `indexdef LIKE '%gin%'` | "no GIN index found on ch05.products" |
| Plan uses index | `EXPLAIN` of the `@>` query (with seqscan disabled) contains "Bitmap Index Scan" | "EXPLAIN does not show Bitmap Index Scan" |

Both must pass to receive the flag.

---

## Starter SQL

Your work directory `~/.kube-dojo-work/05-jsonb-gin-search/` contains `index_and_query.sql` with a scaffold to fill in.

---

## Verify

```bash
bash courses/course-18-postgresql/challenges/05-jsonb-gin-search/verify.sh
```
