# Graphs

> **Module 05 · Course 13** — Every graph problem at a Tier-1 interview reduces to one of five primitives: reachability (DFS/BFS), ordering (topological sort), connectivity (union-find), shortest path (BFS on unweighted, Dijkstra on weighted), and cycle detection. Master the primitives and the "novel" problems become templates with a new coat of paint.

---

## Representations

Choose the representation before you code anything else. The wrong choice doubles your implementation time.

```python
# Adjacency list — use this by default
graph: dict[int, list[int]] = {
    0: [1, 2],
    1: [0, 3],
    2: [0],
    3: [1],
}

# Adjacency matrix — only when you need O(1) edge lookup
# or when the problem gives you one explicitly
n = 4
matrix = [[0] * n for _ in range(n)]
matrix[0][1] = matrix[1][0] = 1    # undirected edge 0-1
```

| Property | Adjacency list | Adjacency matrix |
|----------|---------------|-----------------|
| Space | O(V + E) | O(V²) |
| Edge existence check | O(degree) | O(1) |
| Iterate all neighbors | O(degree) | O(V) |
| Use when | sparse graphs (most interview problems) | dense graphs, explicit edge queries |

Most interview graph problems give you edges as a list of pairs. Build an adjacency list from them first:

```python
def build_graph(n: int, edges: list[tuple]) -> dict[int, list]:
    graph = {i: [] for i in range(n)}
    for u, v in edges:
        graph[u].append(v)
        graph[v].append(u)      # omit for directed graph
    return graph
```

---

## DFS

DFS is the right tool for: finding connected components, detecting cycles, topological sort, and any problem that asks "can we reach Y from X."

```python
def dfs_recursive(graph: dict, node: int, visited: set) -> None:
    visited.add(node)
    for neighbor in graph[node]:
        if neighbor not in visited:
            dfs_recursive(graph, neighbor, visited)

def dfs_iterative(graph: dict, start: int) -> set:
    visited, stack = set(), [start]
    while stack:
        node = stack.pop()
        if node in visited:
            continue
        visited.add(node)
        for neighbor in graph[node]:
            if neighbor not in visited:
                stack.append(neighbor)
    return visited
```

The iterative form uses a `stack` (LIFO). Note: the iterative DFS visits nodes in a different order than recursive DFS because of how the stack pops. For most connectivity questions the order doesn't matter — but for topological sort, use the recursive form with a post-order append, or use Kahn's algorithm instead.

---

## BFS

BFS is the right tool for: **shortest path in an unweighted graph**, level-by-level traversal, and any "minimum steps" problem.

```python
from collections import deque

def bfs_shortest_path(graph: dict, start: int, end: int) -> int:
    if start == end:
        return 0
    visited = {start}
    q = deque([(start, 0)])
    while q:
        node, dist = q.popleft()
        for neighbor in graph[node]:
            if neighbor == end:
                return dist + 1
            if neighbor not in visited:
                visited.add(neighbor)
                q.append((neighbor, dist + 1))
    return -1   # unreachable
```

Add neighbors to `visited` **when you enqueue them**, not when you dequeue. If you mark visited at dequeue time, the same node gets enqueued multiple times and your time complexity degrades from O(V + E) to O(V²) in the worst case.

---

## Topological Sort

Topological order only exists for **directed acyclic graphs (DAGs)**. If there's a cycle, no valid ordering exists.

### Kahn's algorithm (BFS, preferred in interviews)

```python
from collections import deque

def topo_sort_kahn(n: int, edges: list[tuple]) -> list[int]:
    graph = {i: [] for i in range(n)}
    in_degree = [0] * n
    for u, v in edges:
        graph[u].append(v)
        in_degree[v] += 1

    q = deque(i for i in range(n) if in_degree[i] == 0)
    order = []
    while q:
        node = q.popleft()
        order.append(node)
        for neighbor in graph[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                q.append(neighbor)

    return order if len(order) == n else []   # [] means cycle detected
```

Cycle detection is built in: if the final `order` is shorter than `n`, at least one node was never reachable with in-degree 0 (it's part of a cycle).

### DFS-based topological sort

```python
def topo_sort_dfs(n: int, edges: list[tuple]) -> list[int]:
    graph = {i: [] for i in range(n)}
    for u, v in edges:
        graph[u].append(v)

    WHITE, GRAY, BLACK = 0, 1, 2
    color = [WHITE] * n
    result = []
    has_cycle = [False]

    def dfs(node: int) -> None:
        if has_cycle[0]:
            return
        color[node] = GRAY
        for neighbor in graph[node]:
            if color[neighbor] == GRAY:
                has_cycle[0] = True
                return
            if color[neighbor] == WHITE:
                dfs(neighbor)
        color[node] = BLACK
        result.append(node)             # post-order append

    for i in range(n):
        if color[i] == WHITE:
            dfs(i)

    return [] if has_cycle[0] else result[::-1]   # reverse post-order = topo order
```

The WHITE/GRAY/BLACK coloring is the canonical cycle detection for directed graphs. GRAY means "currently in the DFS stack" — a back edge to a GRAY node is a cycle. BLACK means "fully processed" — revisiting a BLACK node is fine.

---

## Cycle Detection

| Graph type | Method | Signal |
|-----------|--------|--------|
| Undirected | DFS, track parent | neighbor is visited AND is not the parent |
| Directed (DFS) | WHITE/GRAY/BLACK | back edge to a GRAY node |
| Directed (BFS) | Kahn's topo sort | `len(result) < n` after processing |

```python
def has_cycle_undirected(graph: dict, n: int) -> bool:
    visited = set()

    def dfs(node: int, parent: int) -> bool:
        visited.add(node)
        for neighbor in graph[node]:
            if neighbor not in visited:
                if dfs(neighbor, node):
                    return True
            elif neighbor != parent:    # visited and not parent = back edge = cycle
                return True
        return False

    for i in range(n):
        if i not in visited:
            if dfs(i, -1):
                return True
    return False
```

---

## Union-Find (Disjoint Set Union)

Union-find answers "are nodes X and Y in the same component?" in near-O(1) time. Without path compression and union by rank it degrades to O(n) per operation — which is why the naive implementation is worse than BFS for small inputs but the optimized version beats everything for dynamic connectivity.

```python
class UnionFind:
    def __init__(self, n: int):
        self.parent = list(range(n))
        self.rank   = [0] * n
        self.components = n

    def find(self, x: int) -> int:
        if self.parent[x] != x:
            self.parent[x] = self.find(self.parent[x])   # path compression
        return self.parent[x]

    def union(self, x: int, y: int) -> bool:
        rx, ry = self.find(x), self.find(y)
        if rx == ry:
            return False    # already same component — would create a cycle
        if self.rank[rx] < self.rank[ry]:
            rx, ry = ry, rx
        self.parent[ry] = rx
        if self.rank[rx] == self.rank[ry]:
            self.rank[rx] += 1
        self.components -= 1
        return True
```

Use union-find when:
- The problem asks for number of connected components and edges arrive dynamically
- Redundant connection detection (adding an edge that would connect already-connected nodes)
- Kruskal's MST algorithm

---

## Dijkstra (Shortest Path, Weighted)

```python
import heapq

def dijkstra(graph: dict[int, list[tuple]], start: int, n: int) -> list[int]:
    # graph[u] = [(weight, v), ...]
    dist = [float('inf')] * n
    dist[start] = 0
    heap = [(0, start)]                 # (cost, node)

    while heap:
        cost, node = heapq.heappop(heap)
        if cost > dist[node]:
            continue                    # stale entry — skip
        for weight, neighbor in graph[node]:
            new_cost = cost + weight
            if new_cost < dist[neighbor]:
                dist[neighbor] = new_cost
                heapq.heappush(heap, (new_cost, neighbor))

    return dist
```

The `if cost > dist[node]: continue` guard is the critical line. A priority queue can hold multiple stale entries for the same node — without this guard, you process them all and get wrong answers. Time: O((V + E) log V).

Dijkstra does **not** work with negative weights. For negative weights, use Bellman-Ford (relax all edges V-1 times).

---

## Grid as Graph

Most 2D grid problems are graph problems in disguise. Cells are nodes; adjacent cells (4-directional or 8-directional) are edges.

```python
DIRS = [(0, 1), (0, -1), (1, 0), (-1, 0)]   # 4-directional

def num_islands(grid: list[list[str]]) -> int:
    if not grid:
        return 0
    rows, cols = len(grid), len(grid[0])
    visited = set()
    count = 0

    def dfs(r: int, c: int) -> None:
        visited.add((r, c))
        for dr, dc in DIRS:
            nr, nc = r + dr, c + dc
            if (0 <= nr < rows and 0 <= nc < cols
                    and (nr, nc) not in visited
                    and grid[nr][nc] == '1'):
                dfs(nr, nc)

    for r in range(rows):
        for c in range(cols):
            if grid[r][c] == '1' and (r, c) not in visited:
                dfs(r, c)
                count += 1
    return count
```

For **minimum steps** in a grid (unweighted), use BFS from the source. For **minimum cost** in a weighted grid, use Dijkstra with `(cost, row, col)` in the heap.

---

## Common Mistakes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Infinite loop on undirected cycle | Not tracking visited nodes | Add to `visited` before or immediately when processing |
| BFS gives wrong shortest path | Marking visited at dequeue instead of enqueue | Mark (or add to visited) when you enqueue a neighbor, not when you pop it |
| Topological sort returns wrong length | Using DFS topo without detecting back edges | Use Kahn's — the `len(order) < n` check catches cycles automatically |
| Union-find is O(n) per operation | Missing path compression in `find` | One-liner fix: `self.parent[x] = self.find(self.parent[x])` in the recursive `find` |
| Union-find without union by rank | Always attaching the second root to the first | Compare ranks; attach smaller rank tree under larger |
| Dijkstra gives wrong results on a graph with negative weights | Algorithm assumes relaxation is monotone | Use Bellman-Ford for negative weights; never use Dijkstra there |
| DFS cycle detection in directed graph misses cycles | Treating undirected logic (visited set) as directed | Use WHITE/GRAY/BLACK; "visited" alone cannot distinguish back edges from cross edges in directed graphs |

> **War story.** During an on-site at Uber, I was asked to find the number of connected components in a dynamic graph where edges were being added one by one. I started coding BFS for each query — O(V + E) per edge addition. The interviewer let me finish, then asked: "what's the total complexity?" I computed it: O(E × (V + E)), which was quadratic in the edge count. I had union-find in my head but reached for BFS out of habit. I rebuilt the solution with union-find in about 8 minutes — O(α(V)) per query, effectively constant. The lesson: the moment you see "dynamically added edges + connectivity queries," union-find is the answer, not BFS. Build a lookup table in your head: problem type → primitive → O-complexity. The mapping is small enough to memorize and worth more than any individual question.

---

## Checkpoint

You're ready for the challenges when you can, without prompting:

1. Implement BFS shortest path in an unweighted graph; state why marking visited at enqueue (not dequeue) matters for time complexity.
2. Implement Kahn's topological sort; explain how cycle detection falls out for free.
3. Implement `UnionFind` with both path compression and union by rank; state the amortized complexity.
4. Write the WHITE/GRAY/BLACK DFS cycle detection for a directed graph and give an example where the simple "visited set" approach gives a wrong answer.
5. Convert a 2D grid problem (find number of islands) into a graph traversal without explicitly building an adjacency list.
6. State when you'd use DFS vs BFS vs Dijkstra vs union-find — the decision rule, not just the names.

➡ Next up: **Recursion, Backtracking & DP** — where the mistake is almost always picking the wrong state representation.
