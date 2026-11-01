# Solution — Output Guardrails

## The complete implementation

```python
# guardrails.py
import re
import json
from typing import Dict


class SchemaViolation(Exception):
    pass


class SchemaGuardrail:
    def __init__(self, schema: Dict[str, type]) -> None:
        self.schema = schema

    def enforce(self, raw: str) -> dict:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SchemaViolation(f"invalid JSON: {exc}") from exc

        result: dict = {}
        for key, expected_type in self.schema.items():
            if key not in data:
                raise SchemaViolation(f"missing required key: {key!r}")
            value = data[key]
            if isinstance(value, expected_type):
                result[key] = value
            else:
                try:
                    result[key] = expected_type(value)
                except (ValueError, TypeError) as exc:
                    raise SchemaViolation(
                        f"cannot coerce {key!r}={value!r} to {expected_type.__name__}: {exc}"
                    ) from exc
        return result


class PIIRedactor:
    _EMAIL = re.compile(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}')
    _PHONE = re.compile(r'\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]\d{4}')
    _CARD  = re.compile(r'\b\d{13,19}\b')

    def redact(self, text: str) -> str:
        text = self._EMAIL.sub('[EMAIL]', text)
        text = self._PHONE.sub('[PHONE]', text)
        text = self._CARD.sub('[CARD]', text)
        return text
```

## Why each piece is correct

### SchemaGuardrail

**`json.loads` first, re-raise as `SchemaViolation`** — the caller knows about `SchemaViolation`, not `json.JSONDecodeError`. Wrapping it keeps the exception hierarchy clean and means callers only need to catch one type.

**`isinstance` before coercion** — if the value is already the right type (e.g. `age` is already an `int`), skip the `type(value)` round-trip. Without this guard `str("Alice")` would silently pass through, which is correct, but `int(42)` redundantly constructs a new int — harmless but wasteful.

**`return result` contains only schema keys** — extra keys in the model output are silently dropped. This is intentional: the service contract is the schema, not whatever the model decides to add. Returning extras would couple downstream code to model output variability.

**`from exc` on re-raise** — preserves the original traceback in Python 3's exception chain, visible with `--tb=long` in pytest. Essential for debugging.

### PIIRedactor

**Application order: email → phone → card.** Phone numbers are 10 digits, which fall *outside* the card range (13–19), but formatted phones like `4085550192` (10 continuous digits) must be matched by the phone pattern *before* the card pattern would have a chance to claim them (it wouldn't, since `\b\d{13,19}\b` requires 13+ digits, but future changes to the card range could introduce regressions — the ordering documents intent).

**`_PHONE` pattern breakdown:**
```
\(?       optional opening paren
\d{3}     area code
\)?       optional closing paren
[\s.\-]?  optional separator (space, dot, hyphen)
\d{3}     exchange
[\s.\-]   required separator — distinguishes phone from a plain number
\d{4}     subscriber
```
The second separator is *not* optional — requiring it means `1234567890` (no separators) is not matched as a phone by this pattern. That's a deliberate trade-off: plain digit runs are only caught by the card pattern if they're 13-19 digits long. Adjust if your threat model requires matching unformatted 10-digit strings too.

**`_CARD` with `\b` word boundaries** ensures `41111111111111111234` (20 digits) is not matched, and that `id=4111111111111111` does match (the `=` is a word boundary). This reduces false positives on long numeric IDs.

## Production extension points

| Need | Extension |
|------|-----------|
| SSN redaction | Add `_SSN = re.compile(r'\b\d{3}-\d{2}-\d{4}\b')` |
| International phones | Extend `_PHONE` to match `+1-800-...` prefixes |
| Nested JSON schema | Recurse into dict values or use `jsonschema` library |
| Async guardrail | Wrap `enforce` and `redact` in `asyncio.to_thread` — both are CPU-bound |
| Audit log | Emit a structured log line in `enforce` and `redact` on every violation/redaction |
