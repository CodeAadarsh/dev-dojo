# Course Schedule

An oncall engineer drops this in the incident thread: *"The deploy pipeline is stuck. Service A waits for B to be healthy, B waits for C, C waits for A. Nothing will ever start."* That's a dependency cycle — exactly what this problem checks for.

You have `n` courses numbered `0..n-1`. Some have prerequisites: `[a, b]` means *to take course `a` you must first finish course `b`*. Return a valid order to finish all courses, or an empty list if a cycle makes it impossible.

## Mission

Implement `find_order(n, prerequisites)` in `solution.py`.

```
find_order(2, [[1, 0]])          → [0, 1]  (finish 0 before 1)
find_order(4, [[1,0],[2,0],[3,1],[3,2]])  → [0,1,2,3] or [0,2,1,3]  (any valid topo order)
find_order(2, [[1, 0], [0, 1]]) → []      (cycle — impossible)
```

**Constraints**

- 1 ≤ `n` ≤ 2,000
- 0 ≤ `len(prerequisites)` ≤ 5,000
- `prerequisites[i]` is `[a, b]` where `0 ≤ a, b < n` and `a != b`
- Any valid topological order is accepted
- Return `[]` (empty list) if and only if a cycle exists

## Setup

```bash
bash courses/course-13-dsa-interviews/challenges/05-course-schedule/setup.sh
```

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/05-course-schedule/verify.sh
```

All tests green → flag printed.

## Why this matters

Topological sort (and its by-product, cycle detection) is a first-class primitive in distributed systems:

- **Service start-order**: systemd, Kubernetes init-containers, Helm hook weights — all need a DAG of dependencies
- **Build systems**: Bazel, Gradle, and Webpack trace the same graph to find a valid build order and detect circular imports
- **Task schedulers**: Airflow DAG validation, GitHub Actions `needs:` chains

Two standard approaches: **DFS with 3-color marking** (a back-edge to an in-progress node is a cycle) or **Kahn's BFS** (seed from in-degree-0 nodes; if the result has fewer than `n` entries, a cycle prevented some nodes from ever reaching in-degree 0). The hidden tests include cycles at various positions and large DAGs — both approaches are accepted.
