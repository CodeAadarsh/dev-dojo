#!/usr/bin/env bash
# Verifier for "Output Guardrails".
# Writes a hidden pytest suite into the work dir, runs it, prints the flag only
# when every test passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-guardrails"
FLAG='KUBE{guardrails_schema_and_pii}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/guardrails.py" ] || fail "guardrails.py not found in $WORK — run setup.sh first"

cd "$WORK"

# ── write the hidden test suite ───────────────────────────────────────────────
cat > "$WORK/_hidden_test_guardrails.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guardrails import SchemaGuardrail, PIIRedactor, SchemaViolation

SCHEMA = {"name": str, "age": int, "score": float}


# ── SchemaGuardrail tests ──────────────────────────────────────────────────────

def test_valid_json_passes_unchanged():
    g = SchemaGuardrail(SCHEMA)
    result = g.enforce('{"name": "Alice", "age": 30, "score": 9.5}')
    assert result["name"] == "Alice"
    assert result["age"] == 30
    assert abs(result["score"] - 9.5) < 1e-9


def test_coerce_int_from_string():
    g = SchemaGuardrail(SCHEMA)
    result = g.enforce('{"name": "Bob", "age": "25", "score": 7.2}')
    assert isinstance(result["age"], int)
    assert result["age"] == 25


def test_coerce_float_from_string():
    g = SchemaGuardrail(SCHEMA)
    result = g.enforce('{"name": "Carol", "age": 28, "score": "8.8"}')
    assert isinstance(result["score"], float)
    assert abs(result["score"] - 8.8) < 1e-9


def test_coerce_str_from_int():
    g = SchemaGuardrail({"label": str, "count": int})
    result = g.enforce('{"label": 42, "count": 7}')
    assert isinstance(result["label"], str)
    assert result["label"] == "42"


def test_invalid_json_raises():
    g = SchemaGuardrail(SCHEMA)
    raised = False
    try:
        g.enforce("not valid json at all")
    except SchemaViolation:
        raised = True
    assert raised, "enforce() must raise SchemaViolation for non-JSON input"


def test_uncoercible_value_raises():
    g = SchemaGuardrail(SCHEMA)
    raised = False
    try:
        g.enforce('{"name": "Dave", "age": "not-a-number", "score": 5.0}')
    except SchemaViolation:
        raised = True
    assert raised, "enforce() must raise SchemaViolation when coercion fails"


def test_missing_required_key_raises():
    g = SchemaGuardrail(SCHEMA)
    raised = False
    try:
        g.enforce('{"name": "Eve", "age": 22}')
    except SchemaViolation:
        raised = True
    assert raised, "enforce() must raise SchemaViolation when a required key is absent"


def test_extra_keys_are_dropped():
    g = SchemaGuardrail(SCHEMA)
    result = g.enforce('{"name": "Frank", "age": 35, "score": 6.0, "extra": "ignored"}')
    assert "extra" not in result, "enforce() must return only schema-declared keys"


# ── PIIRedactor tests ──────────────────────────────────────────────────────────

def test_email_redacted():
    r = PIIRedactor()
    assert r.redact("Contact alice@example.com for help") == "Contact [EMAIL] for help"


def test_email_subdomain_redacted():
    r = PIIRedactor()
    result = r.redact("Reach us at support@mail.example.co.uk today")
    assert "[EMAIL]" in result
    assert "support@mail.example.co.uk" not in result


def test_phone_dashes_redacted():
    r = PIIRedactor()
    assert r.redact("Call 555-123-4567 now") == "Call [PHONE] now"


def test_phone_parens_redacted():
    r = PIIRedactor()
    result = r.redact("Dial (408) 555-0192 for support")
    assert "[PHONE]" in result
    assert "(408) 555-0192" not in result


def test_card_redacted():
    r = PIIRedactor()
    assert r.redact("Card: 4111111111111111 on file") == "Card: [CARD] on file"


def test_combined_pii_all_replaced():
    r = PIIRedactor()
    text = "Email bob@test.org, call (408) 555-0192, card 4111111111111111."
    result = r.redact(text)
    assert "[EMAIL]" in result
    assert "[PHONE]" in result
    assert "[CARD]" in result
    assert "bob@test.org" not in result
    assert "4111111111111111" not in result


def test_clean_text_unchanged():
    r = PIIRedactor()
    text = "The weather in Paris is fine today."
    assert r.redact(text) == text
PYEOF

# ── find pytest ───────────────────────────────────────────────────────────────
if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

if $PYTEST "$WORK/_hidden_test_guardrails.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix guardrails.py and retry"
fi
