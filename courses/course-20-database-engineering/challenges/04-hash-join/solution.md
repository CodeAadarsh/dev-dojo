# Solution — Hash Join

## The Algorithm

Hash join proceeds in two phases:

**Build phase** — iterate the *smaller* relation and construct a hash table mapping each join-key value to the list of rows that carry it:

```
hash_table[row[join_key]].append(row)
```

**Probe phase** — iterate the *larger* relation. For every row, look up its join-key value in the hash table. For every row in the matching bucket, emit a merged output row.

The build phase is O(M) time and O(M) space where M = size of the smaller relation. The probe phase is O(N + output_size). Total: **O(M + N + output_size)** — linear rather than O(M×N).

## Complete Implementation

```python
from __future__ import annotations
from typing import Any


def hash_join(
    left: list[dict],
    right: list[dict],
    left_key: str,
    right_key: str,
) -> list[dict]:
    if not left or not right:
        return []

    # ── Step 1: choose build/probe sides ─────────────────────────────────────
    if len(left) <= len(right):
        build_rel, build_key = left, left_key
        probe_rel, probe_key = right, right_key
        build_is_left = True
    else:
        build_rel, build_key = right, right_key
        probe_rel, probe_key = left, left_key
        build_is_left = False

    # ── Step 2: build phase ───────────────────────────────────────────────────
    ht: dict[Any, list[dict]] = {}
    for row in build_rel:
        k = row[build_key]
        if k not in ht:
            ht[k] = []
        ht[k].append(row)

    # ── Step 3: probe phase ───────────────────────────────────────────────────
    result: list[dict] = []
    for row in probe_rel:
        k = row[probe_key]
        if k in ht:
            for build_row in ht[k]:
                if build_is_left:
                    result.append({**build_row, **row})
                else:
                    result.append({**row, **build_row})

    return result
```

## Why Each Step Is Correct

**Early return for empty relations.** If either side is empty there are no matching pairs — saves building the hash table.

**Build on the smaller side.** The hash table lives in memory. Building on the *smaller* relation minimises its size. The probe side can be arbitrarily large because we never store it — we scan it once and discard. In PostgreSQL the planner calls this relation the *inner* (build) and the *outer* (probe); `EXPLAIN` shows `Hash Cond` and `Buckets`.

**`ht[k]` is a list, not a single row.** This is the duplicate-key handling. If the build side has `[{k:1, lv:'A'}, {k:1, lv:'B'}]`, then `ht[1] = [row_A, row_B]`. The probe loop emits one output row per element of that list — giving the N×M cross-product within each key group.

**Merge order matters for key conflicts.** `{**build_row, **probe_row}` means probe wins on collision; but since we swap build/probe depending on which side is smaller, we always reconstruct the merge as `{**left_row, **right_row}` (left wins). The `build_is_left` flag ensures this.

## Complexity

| Phase | Time | Space |
|-------|------|-------|
| Build | O(M) | O(M) — hash table holds M rows |
| Probe | O(N) lookups, O(output) writes | O(output) |
| Total | O(M + N + output) | O(M + output) |

For an equi-join with no duplicates, output = min(M, N) → O(M + N). For a many-to-many all-match: output = M×N → same as nested loop in output size, but the *join computation* is still O(M + N).

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Building on the larger side | Correct output, excess memory | Check `len(left) <= len(right)` |
| Using a single-row value in the hash table (`ht[k] = row` instead of list) | Only the last row for each key survives — many-to-many produces wrong count | `ht[k]` must be `list[dict]` |
| Forgetting to emit all bucket rows | Output truncated on duplicate keys | Inner loop over `ht[k]` |
| Missing early exit for empty input | `KeyError` on `row[key]` when relation is empty | Check `not left or not right` early |
| Merging as `{**probe, **build}` unconditionally | Wrong column wins on conflict when build/probe sides are swapped | Track `build_is_left` |

## Real-World Connection

In PostgreSQL, set `enable_hashjoin = on` and examine:

```sql
EXPLAIN ANALYZE
  SELECT e.name, d.dept_name
  FROM   employees e
  JOIN   departments d ON e.dept_id = d.id;
```

You will see:
```
Hash Join  (cost=... rows=...)
  Hash Cond: (e.dept_id = d.id)
  ->  Seq Scan on employees
  ->  Hash
        ->  Seq Scan on departments
```

The indented `Hash` node is your build phase. If `departments` is small, the planner builds the hash table on it. If the hash table would exceed `work_mem`, Postgres spills buckets to disk (Grace hash join) — a natural extension of this same algorithm.

## Apply and Verify

```bash
cd ~/.kube-dojo-work/04-hash-join
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-20-database-engineering/challenges/04-hash-join/verify.sh
```
