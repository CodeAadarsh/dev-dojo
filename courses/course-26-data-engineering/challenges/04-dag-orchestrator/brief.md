# Mini DAG Orchestrator

A post-mortem ticket lands on your desk: *"Saturday's billing pipeline silently succeeded even though the `enrich_events` task crashed. Downstream tasks read stale data and we billed 12% of customers the wrong amount. Root cause: the orchestrator didn't propagate the failure or respect the dependency graph."*

Airflow, Prefect, and Dagster all model pipelines as Directed Acyclic Graphs for exactly this reason — a failed node poisons all reachable descendants, not just its direct children, and a cycle in the dependency graph is a hard error caught at DAG-compile time, not at midnight.

Your job is to build the core of that engine from scratch.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-dag-orchestrator/
├── orchestrator.py          # DAG engine stub — three classes, bodies unimplemented
├── sample_tasks.py          # four wired-up tasks with a visible sample run
└── tests/
    └── test_sample.py       # seven-test smoke harness (visible subset of verify)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-dag-orchestrator
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement the three classes in `orchestrator.py`:

### `Task`
- `name: str`, `fn: Callable`, `deps: list[str]` (names of tasks this one depends on), `max_retries: int` (default 0).
- `run(context: dict) -> Any` — calls `fn(context)`, retries up to `max_retries` times on exception, stores result in `context[self.name]`. Raises the final exception if all attempts fail.

### `DAG`
- `add_task(task: Task)` — registers a task by name.
- `validate()` — raises `CycleError` (subclass `ValueError`) if the dependency graph contains a cycle. Called automatically before execution.
- `run(initial_context: dict = None) -> dict` — executes tasks in valid topological order, skips (and marks as `SKIPPED`) any task whose dependency failed, returns the final context dict.

The `context` dict flows through the whole run: each task can read results from upstream tasks and write its own result under its name.

### Execution contract the verifier checks

| Scenario | Expected |
|----------|----------|
| All tasks succeed | context contains each task's return value; correct topological ordering |
| A task exhausts retries | raises the last exception from the final attempt |
| A downstream task of a failed task | marked `SKIPPED` in the context, not executed |
| Dependency graph has a cycle A→B→C→A | `validate()` raises `CycleError` before execution |
| Multi-root DAG (two independent source tasks) | both run (no order constraint between them), dependents run after |

## Why this matters

Airflow's `TaskInstance` state machine — `queued → running → success/failed → upstream_failed` — is this contract with retries, SLAs, sensors, and a UI bolted on. The hard parts — topo sort, cycle detection, skip propagation — are exactly what you're implementing. Understanding the core makes the framework comprehensible instead of magical.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/04-dag-orchestrator/verify.sh
```

All tests green → flag printed.
