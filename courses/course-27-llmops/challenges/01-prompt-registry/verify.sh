#!/usr/bin/env bash
# Verifier for "Prompt Registry".
# Writes a hidden pytest suite into the work dir, runs it, prints the flag only
# when every test passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-prompt-registry"
FLAG='KUBE{prompt_registry_versioned}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/registry.py" ] || fail "registry.py not found in $WORK — run setup.sh first"

cd "$WORK"

# ── write the hidden test suite ───────────────────────────────────────────────
cat > "$WORK/_hidden_test_registry.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from registry import PromptRegistry


def test_register_and_render():
    r = PromptRegistry()
    r.register("greeting", 1, "Hello, {name}! You are a {role}.")
    t = r.get("greeting", 1)
    assert t.render(name="Alice", role="developer") == "Hello, Alice! You are a developer."


def test_two_versions_are_independent():
    r = PromptRegistry()
    r.register("summarise", 1, "Summarise: {text}")
    r.register("summarise", 2, "Provide a concise summary of: {text}")
    assert r.get("summarise", 1).version == 1
    assert r.get("summarise", 1).template == "Summarise: {text}"
    assert r.get("summarise", 2).version == 2
    assert r.get("summarise", 2).template == "Provide a concise summary of: {text}"


def test_promote_selects_production():
    r = PromptRegistry()
    r.register("classify", 1, "Classify: {input}")
    r.register("classify", 2, "Classify this text: {input}")
    r.promote("classify", 2)
    prod = r.get_production("classify")
    assert prod.version == 2
    assert prod.template == "Classify this text: {input}"


def test_get_unknown_raises():
    r = PromptRegistry()
    raised = False
    try:
        r.get("ghost", 1)
    except (KeyError, ValueError):
        raised = True
    assert raised, "get() must raise KeyError/ValueError for an unknown name/version"


def test_no_production_before_promote_raises():
    r = PromptRegistry()
    r.register("draft", 1, "Draft: {text}")
    raised = False
    try:
        r.get_production("draft")
    except (KeyError, ValueError):
        raised = True
    assert raised, "get_production() must raise before any promote() call"


def test_record_usage_and_provenance_order():
    r = PromptRegistry()
    r.register("qa", 1, "Answer: {question}")
    r.register("qa", 2, "Carefully answer: {question}")
    r.record_usage("qa", 1, "Paris")
    r.record_usage("qa", 2, "London")
    r.record_usage("qa", 1, "Berlin")
    prov = r.get_provenance("qa")
    assert len(prov) == 3, f"expected 3 provenance entries, got {len(prov)}"
    assert prov[0]["version"] == 1 and prov[0]["output"] == "Paris"
    assert prov[1]["version"] == 2 and prov[1]["output"] == "London"
    assert prov[2]["version"] == 1 and prov[2]["output"] == "Berlin"


def test_provenance_empty_before_any_record():
    r = PromptRegistry()
    r.register("new", 1, "Hello {x}")
    assert r.get_provenance("new") == []
PYEOF

# ── find pytest ───────────────────────────────────────────────────────────────
if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

if $PYTEST "$WORK/_hidden_test_registry.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix registry.py and retry"
fi
