#!/usr/bin/env bash
# Plants the "Output Guardrails" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-guardrails"
mkdir -p "$WORK/tests"

# ── guardrails.py skeleton ────────────────────────────────────────────────────
cat > "$WORK/guardrails.py" << 'PYEOF'
# guardrails.py — Output Guardrails skeleton
#
# Implement SchemaGuardrail.enforce and PIIRedactor.redact.
# The class shapes, docstrings, and import list are provided.

import re
import json
from typing import Dict


class SchemaViolation(Exception):
    """Raised when a model output cannot be made to conform to the schema."""


class SchemaGuardrail:
    """
    Coerce-then-validate guardrail for a flat JSON schema.

    schema: dict mapping field name -> Python type, e.g. {"name": str, "age": int}

    enforce(raw) must:
      1. Parse raw as JSON (raise SchemaViolation on parse failure).
      2. For each key in self.schema, check that it is present in the parsed object
         (raise SchemaViolation if missing).
      3. Coerce the value to the declared type if it is not already that type.
         Raise SchemaViolation if coercion fails.
      4. Return the coerced dict (only the keys declared in the schema).
    """

    def __init__(self, schema: Dict[str, type]) -> None:
        self.schema = schema

    def enforce(self, raw: str) -> dict:
        raise NotImplementedError


class PIIRedactor:
    """
    Redacts PII from free-form text using regex substitution.

    Patterns (apply in this order to avoid interference):
      - Email:  user@domain.tld  ->  [EMAIL]
      - Phone:  10-digit sequences in common formats  ->  [PHONE]
                (e.g. 555-123-4567, (408) 555-0192, 4085550192)
      - Card:   13–19 continuous digit sequences  ->  [CARD]
    """

    def redact(self, text: str) -> str:
        raise NotImplementedError
PYEOF

# ── tests/test_guardrails_sample.py (visible sample harness) ─────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_guardrails_sample.py" << 'PYEOF'
# Sample tests — run while developing.
# The verifier uses a separate, more comprehensive suite.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from guardrails import SchemaGuardrail, PIIRedactor, SchemaViolation

SCHEMA = {"name": str, "age": int, "score": float}


def test_valid_json_passes():
    g = SchemaGuardrail(SCHEMA)
    result = g.enforce('{"name": "Alice", "age": 30, "score": 9.5}')
    assert result["name"] == "Alice"
    assert result["age"] == 30


def test_invalid_json_raises():
    g = SchemaGuardrail(SCHEMA)
    raised = False
    try:
        g.enforce("not json")
    except SchemaViolation:
        raised = True
    assert raised


def test_email_redacted():
    r = PIIRedactor()
    assert r.redact("Contact alice@example.com for help") == "Contact [EMAIL] for help"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement SchemaGuardrail.enforce and PIIRedactor.redact"
echo "                 in guardrails.py so the pytest harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-27-llmops/challenges/03-guardrails/verify.sh"
