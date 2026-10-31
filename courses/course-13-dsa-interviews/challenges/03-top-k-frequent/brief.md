# Top K Frequent Elements

An analytics pipeline emits a stream of event-type strings. A product manager asks:
*"Can you show me the top 5 event types by frequency every minute?"*

The first implementation uses `sorted(counter.items(), key=lambda x: -x[1])[:k]` — O(n log n) for each tick. With 500k events per minute that's bottlenecking the reporting worker.

Your job: implement `top_k_frequent` so it passes a correctness suite, and document the better-than-O(n log n) approaches in `solution.md` once you're through.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/03-top-k-frequent/
├── solution.py          # one function stub; implement it
└── tests/
    └── test_sample.py   # visible sample tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-top-k-frequent
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `top_k_frequent(nums: List[int], k: int) -> List[int]`.

Given a non-empty list of integers `nums` and an integer `k`, return the `k` most frequent elements. Output order does not matter — any permutation of the correct `k` elements is accepted.

**Examples:**

| Input | k | Output (any order) |
|-------|---|-------------------|
| `[1,1,1,2,2,3]` | 2 | `[1, 2]` |
| `[1]` | 1 | `[1]` |
| `[4,1,2,2,4,4,3,3]` | 3 | `[4, 2, 3]` (any order) |

**Constraints:**

- `1 ≤ k ≤ len(set(nums)) ≤ len(nums) ≤ 10^5`
- `-10^4 ≤ nums[i] ≤ 10^4`
- The answer is **unique** — there are exactly k elements with the top k distinct frequencies. No ties at the k-th boundary.
- **Target:** better than O(n log n). The hidden suite has n=100,000 but does not enforce timing; the design is the point.

> The brief does not name the algorithm. Two O(n log k) or better approaches exist. The solution discusses both.

## Why this matters

"Top K" is a recurring pattern in distributed systems: top-K slow queries, top-K endpoints by error rate, top-K tenants by resource consumption. The naive sort works at small scale; knowing the heap and bucket-sort alternatives — and when to reach for which — is exactly what a Tier-1 interviewer is probing.

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/03-top-k-frequent/verify.sh
```

All tests green → flag printed.
