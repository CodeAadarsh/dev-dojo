#!/usr/bin/env bash
# Verifier for "Mini DAG Orchestrator".
# Plants a hidden pytest suite, runs it with fixed seeds, prints flag only when all pass.
set -uo pipefail

SLUG="04-dag-orchestrator"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{dag_orchestration_respects_deps}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/orchestrator.py" ] || fail "orchestrator.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# ── hidden test suite ────────────────────────────────────────────────────────
HIDDEN_DIR="$WORK/_verify_hidden"
mkdir -p "$HIDDEN_DIR"
cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from orchestrator import DAG, Task, CycleError


# ── helper builders ──────────────────────────────────────────────────────────

def recorder():
    """Return (fn, calls_list). fn appends its name-tag and returns call count."""
    calls = []
    def fn(ctx, tag="x"):
        calls.append(tag)
        return len(calls)
    return fn, calls


# ── test 1: single task executes and stores result ───────────────────────────
def test_single_task_result():
    dag = DAG("d")
    dag.add_task(Task("only", lambda ctx: 7))
    ctx = dag.run()
    assert ctx["only"] == 7, "result must be stored under task name"


# ── test 2: two independent tasks both run ───────────────────────────────────
def test_independent_tasks_both_run():
    ran = []
    dag = DAG("d")
    dag.add_task(Task("a", lambda ctx: ran.append("a") or "done_a"))
    dag.add_task(Task("b", lambda ctx: ran.append("b") or "done_b"))
    ctx = dag.run()
    assert set(ran) == {"a", "b"}
    assert ctx["a"] == "done_a"
    assert ctx["b"] == "done_b"


# ── test 3: linear chain — order enforced ────────────────────────────────────
def test_linear_chain_order():
    order = []
    dag = DAG("d")
    dag.add_task(Task("step1", lambda ctx: order.append(1) or 1))
    dag.add_task(Task("step2", lambda ctx: order.append(2) or 2, deps=["step1"]))
    dag.add_task(Task("step3", lambda ctx: order.append(3) or 3, deps=["step2"]))
    dag.run()
    assert order == [1, 2, 3], f"expected [1,2,3], got {order}"


# ── test 4: diamond DAG — common ancestor runs once ──────────────────────────
def test_diamond_common_ancestor_once():
    calls = {"root": 0}
    def root(ctx):
        calls["root"] += 1
        return "root_val"
    dag = DAG("d")
    dag.add_task(Task("root", root))
    dag.add_task(Task("left",  lambda ctx: ctx["root"] + "_L", deps=["root"]))
    dag.add_task(Task("right", lambda ctx: ctx["root"] + "_R", deps=["root"]))
    dag.add_task(Task("merge", lambda ctx: ctx["left"] + ctx["right"], deps=["left", "right"]))
    ctx = dag.run()
    assert calls["root"] == 1, "root must execute exactly once in a diamond"
    assert ctx["merge"] == "root_val_Lroot_val_R"


# ── test 5: cycle A→B→C→A raises CycleError before run ──────────────────────
def test_cycle_abc_raises():
    dag = DAG("d")
    dag.add_task(Task("a", lambda ctx: 1, deps=["c"]))
    dag.add_task(Task("b", lambda ctx: 2, deps=["a"]))
    dag.add_task(Task("c", lambda ctx: 3, deps=["b"]))
    with pytest.raises(CycleError):
        dag.run()


# ── test 6: self-loop raises CycleError ──────────────────────────────────────
def test_self_loop_raises():
    dag = DAG("d")
    dag.add_task(Task("a", lambda ctx: 1, deps=["a"]))
    with pytest.raises(CycleError):
        dag.run()


# ── test 7: failing task propagates — downstream is SKIPPED, whole run raises ─
def test_downstream_skipped_on_failure():
    downstream_ran = []

    def boom(ctx):
        raise ValueError("seed_failure_42")

    def child(ctx):
        downstream_ran.append(True)
        return "should_not_run"

    dag = DAG("d")
    dag.add_task(Task("fail_me", boom))
    dag.add_task(Task("child", child, deps=["fail_me"]))
    dag.add_task(Task("grandchild", lambda ctx: "nope", deps=["child"]))

    with pytest.raises(Exception):
        dag.run()

    assert downstream_ran == [], "downstream of a failed task must NOT execute"


# ── test 8: retry — task succeeds on second attempt ──────────────────────────
def test_retry_succeeds_on_second_attempt():
    attempts = []

    def flaky(ctx):
        attempts.append(1)
        if len(attempts) < 2:
            raise RuntimeError("transient")
        return "recovered"

    dag = DAG("d")
    dag.add_task(Task("flaky", flaky, max_retries=1))
    ctx = dag.run()
    assert ctx["flaky"] == "recovered", "task should succeed after one retry"
    assert len(attempts) == 2


# ── test 9: retry exhausted — raises final exception ─────────────────────────
def test_retry_exhausted_raises():
    def always_fails(ctx):
        raise RuntimeError("permanent_error_seed99")

    dag = DAG("d")
    dag.add_task(Task("bad", always_fails, max_retries=2))
    with pytest.raises(RuntimeError, match="permanent_error_seed99"):
        dag.run()


# ── test 10: initial_context flows into tasks ─────────────────────────────────
def test_initial_context_flows():
    dag = DAG("d")
    dag.add_task(Task("reader", lambda ctx: ctx["seed"] * 2))
    ctx = dag.run(initial_context={"seed": 21})
    assert ctx["reader"] == 42
PYEOF

if $PYTEST "$HIDDEN_DIR/test_hidden.py" -q 2>&1; then
    rm -rf "$HIDDEN_DIR"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "$HIDDEN_DIR"
    fail "test suite has failures — fix your implementation and retry"
fi
