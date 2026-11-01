#!/usr/bin/env bash
# Plants the "Prompt Registry" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-prompt-registry"
mkdir -p "$WORK/tests"

# ── registry.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/registry.py" << 'PYEOF'
# registry.py — Versioned Prompt Registry skeleton
#
# Implement every method body. The class shapes and data-structure hints are
# provided; only the logic inside each method is stubbed with NotImplementedError.

from typing import List, Dict, Any


class PromptTemplate:
    """A single versioned prompt template."""

    def __init__(self, name: str, version: int, template: str) -> None:
        self.name = name
        self.version = version
        self.template = template  # e.g. "Hello, {name}! You are a {role}."

    def render(self, **kwargs: Any) -> str:
        """Return self.template with every {placeholder} substituted by kwargs."""
        raise NotImplementedError


class PromptRegistry:
    """In-memory registry of versioned prompt templates."""

    def __init__(self) -> None:
        # Suggested internal stores — you may rename but must keep the behaviour.
        self._store: Dict[str, Dict[int, PromptTemplate]] = {}   # name -> {version -> template}
        self._production: Dict[str, int] = {}                    # name -> promoted version
        self._provenance: Dict[str, List[Dict[str, Any]]] = {}   # name -> [{version, output}, ...]

    def register(self, name: str, version: int, template: str) -> PromptTemplate:
        """Create and store a PromptTemplate. Return it."""
        raise NotImplementedError

    def get(self, name: str, version: int) -> PromptTemplate:
        """Return the stored template. Raise KeyError if name/version unknown."""
        raise NotImplementedError

    def promote(self, name: str, version: int) -> None:
        """Mark version as the production version for name.
        Raise KeyError if the version has not been registered."""
        raise NotImplementedError

    def get_production(self, name: str) -> PromptTemplate:
        """Return the production template. Raise KeyError if none promoted yet."""
        raise NotImplementedError

    def record_usage(self, name: str, version: int, output: str) -> None:
        """Append {"version": version, "output": output} to the provenance log."""
        raise NotImplementedError

    def get_provenance(self, name: str) -> List[Dict[str, Any]]:
        """Return the full provenance list for name (insertion order). Empty list if none."""
        raise NotImplementedError
PYEOF

# ── tests/test_registry_sample.py (visible sample harness) ───────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_registry_sample.py" << 'PYEOF'
# Sample tests — use these while developing.
# The verifier runs a separate, more comprehensive suite.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from registry import PromptRegistry, PromptTemplate


def test_register_returns_template():
    r = PromptRegistry()
    t = r.register("greet", 1, "Hi {name}!")
    assert isinstance(t, PromptTemplate)
    assert t.version == 1


def test_render_substitutes_placeholders():
    r = PromptRegistry()
    r.register("greet", 1, "Hello, {name}!")
    t = r.get("greet", 1)
    assert t.render(name="World") == "Hello, World!"


def test_promote_and_get_production():
    r = PromptRegistry()
    r.register("summarise", 1, "Summarise: {text}")
    r.register("summarise", 2, "Concisely summarise: {text}")
    r.promote("summarise", 2)
    prod = r.get_production("summarise")
    assert prod.version == 2
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement all method bodies in registry.py so the"
echo "                 pytest harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-27-llmops/challenges/01-prompt-registry/verify.sh"
