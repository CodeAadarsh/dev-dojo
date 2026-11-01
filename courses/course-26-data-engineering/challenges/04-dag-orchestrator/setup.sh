#!/usr/bin/env bash
# Plants the "Mini DAG Orchestrator" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="04-dag-orchestrator"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── orchestrator.py skeleton ─────────────────────────────────────────────────
cat > "$WORK/orchestrator.py" << 'PYEOF'
# orchestrator.py — mini DAG engine
# Implement the three classes: Task, CycleError, DAG.
# Do NOT change the public API signatures; the verifier imports them directly.
from __future__ import annotations
from typing import Any, Callable


class CycleError(ValueError):
    """Raised when the dependency graph contains a cycle."""


class Task:
    """A single unit of work inside a DAG."""

    def __init__(self, name: str, fn: Callable, deps: list[str] | None = None, max_retries: int = 0):
        self.name = name
        self.fn = fn
        self.deps: list[str] = deps or []
        self.max_retries = max_retries

    def run(self, context: dict) -> Any:
        """Execute fn(context), retrying up to max_retries times on exception.

        Stores the return value in context[self.name].
        Raises the final exception if every attempt fails.
        """
        raise NotImplementedError("implement Task.run")


class DAG:
    """A directed acyclic graph of Tasks."""

    def __init__(self, name: str):
        self.name = name
        self._tasks: dict[str, Task] = {}

    def add_task(self, task: Task) -> None:
        """Register a task. Raises ValueError on duplicate name."""
        raise NotImplementedError("implement DAG.add_task")

    def validate(self) -> None:
        """Raise CycleError if the dependency graph has a cycle.

        Uses DFS with a 'grey/black' colouring (grey = in current path).
        """
        raise NotImplementedError("implement DAG.validate")

    def run(self, initial_context: dict | None = None) -> dict:
        """Execute all tasks in topological order.

        Calls validate() first.
        A task whose direct or transitive dependency failed is marked SKIPPED
        (context[task.name] = 'SKIPPED') and not executed.
        Returns the final context dict.
        """
        raise NotImplementedError("implement DAG.run")
PYEOF

# ── sample_tasks.py ──────────────────────────────────────────────────────────
cat > "$WORK/sample_tasks.py" << 'PYEOF'
# sample_tasks.py — a small wired-up pipeline for manual experimentation.
# Running `python sample_tasks.py` should print results without errors once
# you have a working orchestrator.py.
from orchestrator import DAG, Task


def extract(ctx):
    print("  [extract] reading raw events...")
    return [{"id": 1, "amount": 100}, {"id": 2, "amount": 200}]


def validate_data(ctx):
    rows = ctx["extract"]
    print(f"  [validate] checking {len(rows)} rows...")
    assert all("amount" in r for r in rows)
    return True


def enrich(ctx):
    rows = ctx["extract"]
    print("  [enrich] adding region tag...")
    return [{**r, "region": "IN"} for r in rows]


def load(ctx):
    rows = ctx["enrich"]
    print(f"  [load] writing {len(rows)} enriched rows to sink...")
    return len(rows)


if __name__ == "__main__":
    dag = DAG("billing")
    dag.add_task(Task("extract", extract))
    dag.add_task(Task("validate_data", validate_data, deps=["extract"]))
    dag.add_task(Task("enrich", enrich, deps=["extract"]))
    dag.add_task(Task("load", load, deps=["enrich", "validate_data"]))

    result = dag.run()
    print("\nFinal context keys:", list(result.keys()))
    print("Loaded rows:", result["load"])
PYEOF

# ── tests/test_sample.py (visible smoke harness) ─────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from orchestrator import DAG, Task, CycleError


def make_counter():
    calls = []
    def fn(ctx):
        calls.append(1)
        return len(calls)
    return fn, calls


def test_single_task_runs():
    dag = DAG("t")
    dag.add_task(Task("a", lambda ctx: 42))
    ctx = dag.run()
    assert ctx["a"] == 42


def test_dep_chain_order():
    order = []
    dag = DAG("t")
    dag.add_task(Task("first", lambda ctx: order.append("first") or 1))
    dag.add_task(Task("second", lambda ctx: order.append("second") or 2, deps=["first"]))
    dag.run()
    assert order == ["first", "second"]


def test_cycle_detection():
    dag = DAG("t")
    dag.add_task(Task("a", lambda ctx: 1, deps=["b"]))
    dag.add_task(Task("b", lambda ctx: 2, deps=["a"]))
    with pytest.raises(CycleError):
        dag.run()


def test_failed_task_skips_downstream():
    def boom(ctx):
        raise RuntimeError("explode")

    dag = DAG("t")
    dag.add_task(Task("fail_me", boom))
    dag.add_task(Task("downstream", lambda ctx: 99, deps=["fail_me"]))

    with pytest.raises(RuntimeError):
        dag.run()

    # downstream should not have produced a numeric result
    # (it may be absent or SKIPPED depending on implementation)
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement Task.run, DAG.add_task, DAG.validate, and"
echo "                 DAG.run in orchestrator.py so the test suite passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Smoke run      : cd $WORK && python sample_tasks.py"
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-26-data-engineering/challenges/$SLUG/verify.sh"
