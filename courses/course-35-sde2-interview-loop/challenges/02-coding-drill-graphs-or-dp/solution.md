# Solution — Longest Increasing Path in a Matrix

The flag is `KUBE{longest_increasing_path_dfs_memo}`.

## The approach

DFS with memoization. From every cell `(r, c)`, recurse into the four neighbors that are strictly larger. Cache the result so each cell is computed at most once.

```python
import sys
sys.setrecursionlimit(200 * 200 + 10)

from typing import List


def longest_increasing_path(matrix: List[List[int]]) -> int:
    if not matrix or not matrix[0]:
        return 0

    m, n = len(matrix), len(matrix[0])
    memo = [[0] * n for _ in range(m)]   # 0 = unvisited
    DIRS = [(0, 1), (0, -1), (1, 0), (-1, 0)]

    def dfs(r: int, c: int) -> int:
        if memo[r][c]:
            return memo[r][c]
        best = 1   # every cell is a path of length 1 by itself
        for dr, dc in DIRS:
            nr, nc = r + dr, c + dc
            if 0 <= nr < m and 0 <= nc < n and matrix[nr][nc] > matrix[r][c]:
                best = max(best, 1 + dfs(nr, nc))
        memo[r][c] = best
        return best

    return max(dfs(r, c) for r in range(m) for c in range(n))
```

## Why memoization is safe here (and why no `visited` set is needed per path)

The DFS only moves to **strictly larger** values. That means the path is a DAG — there are no cycles. If you could return to a cell, you'd need `matrix[nr][nc] > matrix[r][c]` at each step, but coming back to `(r, c)` means some later value in the path equals `matrix[r][c]`, which is a contradiction.

Because it's a DAG, `dfs(r, c)` always produces the same answer regardless of how you reached `(r, c)`. That makes memoization both correct and O(m×n): each cell is computed exactly once.

A `visited` set per path would be needed for a general BFS/DFS on a graph with cycles. Adding one here is harmless but unnecessary — and explaining why it's unnecessary is the SDE-2 signal.

## Complexity

| | Bound | Why |
|---|---|---|
| Time | O(m × n) | Each cell computed once via memo |
| Space | O(m × n) | Memo array + recursion stack depth bounded by path length |

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Starting `best = 0` and not adding 1 for the cell itself | Path length off by 1 | Start `best = 1`; the cell itself counts |
| Using `>=` instead of `>` | Equal adjacent values extend the path | Use strictly `>` |
| No `sys.setrecursionlimit` on large inputs | `RecursionError` on 200×200 | Set `sys.setrecursionlimit(m * n + 10)` before defining `dfs` |
| Checking `memo[r][c] is not None` when initialized to `None` | Works but fragile; `0` check is wrong | Use `0` for unvisited (valid results are ≥ 1), check `if memo[r][c]` |
| Adding a `visited` set per DFS call | Correct but O(m²×n²) in the worst case | No visited set needed; strict increase prevents cycles |

## War story

At a Grafana Labs phone screen, the candidate implemented a clean recursive DFS but initialized `memo = {}` (empty dict, correct) and wrote `if (r, c) in memo: return memo[(r, c)]`. The interviewer asked: "What happens if you call `dfs` on a 200×200 matrix with all distinct values?" The candidate said "it should be fine." It wasn't — the recursion depth can hit 40000 on a monotonically increasing spiral, which exceeds Python's default 1000. The fix is one line (`sys.setrecursionlimit`) or switching to iterative topological sort (topological order by value, then process smallest-to-largest — no recursion). The candidate knew the algorithm but didn't know Python's recursion ceiling. Know your runtime's limits.

## Iterative alternative (topological sort by value)

For production Python where you can't raise the recursion limit:

```python
from collections import defaultdict

def longest_increasing_path(matrix):
    if not matrix or not matrix[0]:
        return 0
    m, n = len(matrix), len(matrix[0])
    # out_degree[r][c] = number of strictly larger neighbors
    out_degree = [[0] * n for _ in range(m)]
    DIRS = [(0,1),(0,-1),(1,0),(-1,0)]
    for r in range(m):
        for c in range(n):
            for dr, dc in DIRS:
                nr, nc = r + dr, c + dc
                if 0 <= nr < m and 0 <= nc < n and matrix[nr][nc] > matrix[r][c]:
                    out_degree[r][c] += 1
    # Start from cells with no valid outgoing edge (local maxima)
    from collections import deque
    queue = deque((r, c) for r in range(m) for c in range(n) if out_degree[r][c] == 0)
    length = 0
    while queue:
        length += 1
        for _ in range(len(queue)):
            r, c = queue.popleft()
            for dr, dc in DIRS:
                nr, nc = r + dr, c + dc
                if 0 <= nr < m and 0 <= nc < n and matrix[nr][nc] < matrix[r][c]:
                    out_degree[nr][nc] -= 1
                    if out_degree[nr][nc] == 0:
                        queue.append((nr, nc))
    return length
```

Same O(m×n) complexity, no recursion. The BFS level count equals the longest path length.
