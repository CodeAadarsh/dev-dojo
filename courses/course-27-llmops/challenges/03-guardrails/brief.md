# Output Guardrails

A support chatbot started leaking user data — a customer's chat transcript included another user's email and credit card number, verbatim from the model output. The CISO filed a P0. The root cause: no output filtering between the LLM and the response serialiser. The secondary cause: the model occasionally returns free-form text instead of the agreed JSON schema, crashing the downstream parser.

Two mitigations need to ship before the feature comes back out of maintenance mode:

1. **Schema enforcement** — if the model output is not valid JSON or is missing required fields, reject it (or coerce where safe) rather than letting garbage through.
2. **PII redaction** — before any text leaves the service boundary, strip emails, phone numbers, and card-like digit sequences.

Your job: implement both.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/03-guardrails/
├── guardrails.py          # skeleton — SchemaGuardrail + PIIRedactor stubs
└── tests/
    └── test_guardrails_sample.py   # sample tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-guardrails
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `SchemaGuardrail.enforce` and `PIIRedactor.redact` in `guardrails.py`.

The verifier checks all of the following:

| Requirement | Detail |
|-------------|--------|
| **Valid JSON passes** | `enforce('{"name":"Alice","age":30,"score":9.5}')` returns `{"name":"Alice","age":30,"score":9.5}` |
| **Type coercion** | String `"25"` coerces to `int` 25; string `"7.2"` coerces to `float` 7.2 |
| **Invalid JSON raises** | Non-JSON string raises `SchemaViolation` |
| **Uncoercible value raises** | `{"age": "not-a-number"}` raises `SchemaViolation` |
| **Missing required key raises** | A JSON object missing a schema key raises `SchemaViolation` |
| **Email redaction** | `alice@example.com` → `[EMAIL]` |
| **Phone redaction** | `555-123-4567` and `(408) 555-0192` → `[PHONE]` |
| **Card redaction** | 13–19 continuous digit sequences → `[CARD]` |
| **Combined PII** | A single string with all three types has all three replaced |

## Design notes

`enforce` is intentionally a **coerce-then-validate** pipeline, not a strict validator. The model often returns `"age": "30"` (a string) when you declared `int` in the schema — coercing that is strictly better than rejecting it, because the model is being helpful, not wrong. Actual semantic errors (a name in the `age` field) should still surface as `SchemaViolation`.

For the regex patterns, order matters: apply email, then phone, then card. Phone numbers contain 10 digits which the card pattern would otherwise eat if you ran card first.

## Verify

```bash
bash courses/course-27-llmops/challenges/03-guardrails/verify.sh
```

All tests green → flag printed.
