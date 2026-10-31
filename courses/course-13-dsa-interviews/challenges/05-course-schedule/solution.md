# Solution — Course Schedule

The flag is `KUBE{topo_sort_detects_deadlock}`.

## Approach 1: Kahn's Algorithm (BFS, preferred)

```python
from collections import deque

def can_finish(num_courses: int, prerequisites: list) -> bool:
    graph = {i: [] for i in range(num_courses)}
    in_degree = [0] * num_courses

    for course, prereq in prerequisites:
        graph[prereq].append(course)
        in_degree[course] += 1

    q = deque(i for i in range(num_courses) if in_degree[i] == 0)
    processed = 0

    while q:
        node = q.popleft()
        processed += 1
        for neighbor in graph[node]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                q.append(neighbor)

    return processed == num_courses
```

Cycle detection is implicit: if a cycle exists, the nodes in the cycle can never reach in-degree 0 (each node in the cycle still has one incoming edge from within the cycle). They're never enqueued, so `processed < num_courses` at the end.

## Approach 2: DFS with 3-color marking

```python
def can_finish(num_courses: int, prerequisites: list) -> bool:
    graph = {i: [] for i in range(num_courses)}
    for course, prereq in prerequisites:
        graph[prereq].append(course)

    WHITE, GRAY, BLACK = 0, 1, 2
    color = [WHITE] * num_courses

    def has_cycle(node: int) -> bool:
        color[node] = GRAY
        for neighbor in graph[node]:
            if color[neighbor] == GRAY:
                return True    # back edge = cycle
            if color[neighbor] == WHITE and has_cycle(neighbor):
                return True
        color[node] = BLACK
        return False

    for i in range(num_courses):
        if color[i] == WHITE:
            if has_cycle(i):
                return False
    return True
```

GRAY = "in the current DFS path." A back edge to a GRAY node means we've found a cycle. BLACK = "fully explored" — revisiting a BLACK node is not a cycle.

## Which to use

Kahn's is cleaner in interviews — the cycle detection condition (`processed == n`) is easier to explain than the 3-color logic. DFS with colors is the right answer when the interviewer asks "how else could you do it?" or asks you to also return the topological order (DFS post-order reversed).
