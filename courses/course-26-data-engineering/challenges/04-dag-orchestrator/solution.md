# Solution — Mini DAG Orchestrator

The complete `orchestrator.py`. Key decisions explained below.

```python
from __future__ import annotations
from typing import Any, Callable


class CycleError(ValueError):
    """Raised when the dependency graph contains a cycle."""


class Task:
    def __init__(self, name: str, fn: Callable, deps: list[str] | None = None, max_retries: int = 0):
        self.name = name
        self.fn = fn
        self.deps: list[str] = deps or []
        self.max_retries = max_retries

    def run(self, context: dict) -> Any:
        last_exc = None
        for attempt in range(self.max_retries + 1):
            try:
                result = self.fn(context)
                context[self.name] = result
                return result
            except Exception as e:
                last_exc = e
        raise last_exc


class DAG:
    def __init__(self, name: str):
        self.name = name
        self._tasks: dict[str, Task] = {}

    def add_task(self, task: Task) -> None:
        if task.name in self._tasks:
            raise ValueError(f"Duplicate task name: {task.name}")
        self._tasks[task.name] = task

    def validate(self) -> None:
        WHITE, GREY, BLACK = 0, 1, 2
        color = {n: WHITE for n in self._tasks}

        def dfs(node: str) -> None:
            color[node] = GREY
            for dep in self._tasks[node].deps:
                if dep not in color:
                    raise ValueError(f"Unknown dependency: {dep!r} referenced by {node!r}")
                if color[dep] == GREY:
                    raise CycleError(f"Cycle detected involving task {dep!r}")
                if color[dep] == WHITE:
                    dfs(dep)
            color[node] = BLACK

        for node in list(self._tasks):
            if color[node] == WHITE:
                dfs(node)

    def run(self, initial_context: dict | None = None) -> dict:
        self.validate()

        # Kahn's algorithm: build in-degree map, process queue
        in_degree: dict[str, int] = {n: 0 for n in self._tasks}
        dependents: dict[str, list[str]] = {n: [] for n in self._tasks}
        for name, task in self._tasks.items():
            for dep in task.deps:
                in_degree[name] += 1
                dependents[dep].append(name)

        from collections import deque
        queue: deque[str] = deque(n for n, d in in_degree.items() if d == 0)

        context: dict = dict(initial_context or {})
        failed: set[str] = set()
        first_exc: Exception | None = None

        while queue:
            name = queue.popleft()
            task = self._tasks[name]

            # Skip if any dependency failed
            if any(d in failed for d in task.deps):
                context[name] = "SKIPPED"
                failed.add(name)
            else:
                try:
                    task.run(context)
                except Exception as exc:
                    failed.add(name)
                    if first_exc is None:
                        first_exc = exc

            for child in dependents[name]:
                in_degree[child] -= 1
                if in_degree[child] == 0:
                    queue.append(child)

        if first_exc is not None:
            raise first_exc

        return context
```

## Why each piece is correct

**Grey/Black DFS for cycle detection.**
Depth-first search with two colours is the textbook O(V+E) approach. A node coloured GREY is currently on the recursion stack — if you visit a GREY node again you've found a back-edge, which means a cycle. Marking it BLACK on the way back means you never reprocess completed subtrees, so isolated nodes and separate components are handled correctly in the outer loop.

**Kahn's algorithm for topological execution.**
You could reuse the DFS order from `validate()`, but Kahn's is cleaner for execution: start with all zero-in-degree nodes (true roots), drain a queue, decrement in-degrees of dependents, enqueue them when their in-degree hits zero. This naturally handles multi-root DAGs and diamond shapes without extra bookkeeping.

**Retry loop in `Task.run`.**
`range(max_retries + 1)` means "attempt once by default, attempt N+1 times if max_retries=N." Storing the last exception and re-raising it after exhausting attempts ensures callers get the real error, not a `None` return.

**`SKIPPED` propagation.**
When a task is in `failed`, every direct child that has it as a dep is itself added to `failed` (and marked `SKIPPED` in the context). Because Kahn processes tasks in dependency order, by the time a child is dequeued, all its parents are already resolved — so the `any(d in failed ...)` check is always accurate.

**Raising after the run.**
The DAG collects the first exception instead of raising inline so that all skippable tasks still get processed (their SKIPPED marker appears in the context). The caller always sees the real cause of failure, not a skip-marker.

## Airflow parallel

```
Airflow TaskInstance states  →  this engine
  queued                     →  in the Kahn queue
  running                    →  Task.run executing
  success                    →  context[name] = return value
  failed                     →  task in `failed` set, exc stored
  upstream_failed            →  context[name] = "SKIPPED"
```

Airflow adds sensors, XCom, retries with exponential backoff, SLA misses, and a UI on top of this same core contract.
