# Hash Join

A ticket lands in the query-engine team's backlog:

> *"The analytics dashboard runs a 10-table star schema. The join operator is a nested-loop that scans the larger relation once per row of the smaller one — O(M×N) per join. On our 20M-row fact table, that's billions of comparisons and a 90-second dashboard load. Implement a hash join so we reduce this to O(M+N)."*

Your job: implement `hash_join` in `solution.py` so the verifier's hidden pytest suite passes on several datasets, including many-to-many duplicates.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-hash-join/
├── solution.py          # one function stub; implement it
└── tests/
    └── test_sample.py   # three visible sample tests you can run
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-hash-join
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement:

```python
def hash_join(
    left: list[dict],
    right: list[dict],
    left_key: str,
    right_key: str,
) -> list[dict]:
    ...
```

**Contract:**
- Each row is a Python dict.
- A match occurs when `left_row[left_key] == right_row[right_key]`.
- For every matched pair, return one merged dict: `{**left_row, **right_row}` (right's values win on key conflict — same semantics as `dict | dict`).
- Return all matched pairs; output order is not required to match any particular sort.
- **Build phase:** build a hash table on the *smaller* relation (by row count).
- **Probe phase:** iterate the *larger* relation, looking up each row's join key in the hash table.
- Handle duplicate keys: if `k` appears in 2 left rows and 3 right rows, the output must contain 2×3 = 6 merged rows.

**Examples:**

Basic equi-join (no duplicates):

| left | right | result |
|------|-------|--------|
| `{l_id:1, name:'alice'}` | `{r_id:1, score:90}` | `{l_id:1, name:'alice', r_id:1, score:90}` |
| `{l_id:2, name:'bob'}` | `{r_id:2, score:75}` | `{l_id:2, name:'bob', r_id:2, score:75}` |
| `{l_id:3, name:'carol'}` | (no match) | (omitted) |

Many-to-many duplicate keys (both sides have `k=1`):

```
left  = [{k:1, lv:'A'}, {k:1, lv:'B'}]
right = [{k:1, rv:'X'}, {k:1, rv:'Y'}, {k:1, rv:'Z'}]
result = 6 rows (every left row paired with every right row that shares k=1)
```

## Why this matters

Hash join is the workhorse of analytical databases (PostgreSQL, DuckDB, BigQuery). When you run `EXPLAIN ANALYZE` on a query and see `Hash Join (actual rows=...)`, this is what is happening. Understanding the build/probe split tells you:

- Why the query planner picks the smaller relation for the hash table (fits in memory, probed once per outer row).
- Why a broadcast join in Spark broadcasts the small table — the same "build once, probe many" logic.
- Why hash joins degrade to disk spills when the build side exceeds the hash join memory limit (`work_mem` in Postgres).

The verifier checks correctness on datasets including one 1,000-row relation, a many-to-many duplicate case, empty relations, and a random 10,000-key dataset.

## Verify

```bash
bash courses/course-20-database-engineering/challenges/04-hash-join/verify.sh
```

All tests green → flag printed.
