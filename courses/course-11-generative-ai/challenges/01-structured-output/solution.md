# Solution — Structured Output

The function needs to do five things: parse JSON, strip extra keys, normalise severity, coerce `affected_services` from a CSV string if needed, and validate constraints.

```python
# solution.py
import json

SCHEMA_KEYS = {"title", "severity", "affected_services", "resolution_steps"}
VALID_SEVERITIES = {"low", "medium", "high", "critical"}


def parse_incident_report(raw: str) -> dict:
    data = json.loads(raw)

    # coerce affected_services to list before anything else
    if isinstance(data.get("affected_services"), str):
        data["affected_services"] = [s.strip() for s in data["affected_services"].split(",")]

    # normalise severity
    sev = str(data.get("severity", "")).lower()
    if sev not in VALID_SEVERITIES:
        raise ValueError(f"severity {sev!r} is not one of {VALID_SEVERITIES}")
    data["severity"] = sev

    # strip extra keys (dict comprehension keeps insertion order in Python 3.7+)
    result = {k: data[k] for k in SCHEMA_KEYS if k in data}

    # final constraint checks
    if not isinstance(result.get("title"), str) or not result.get("title"):
        raise ValueError("title must be a non-empty string")
    if not isinstance(result.get("resolution_steps"), list) or not result["resolution_steps"]:
        raise ValueError("resolution_steps must be a non-empty list")
    if not isinstance(result.get("affected_services"), list):
        raise ValueError("affected_services must resolve to a list")
    if set(result.keys()) != SCHEMA_KEYS:
        missing = SCHEMA_KEYS - set(result.keys())
        raise ValueError(f"missing required keys: {missing}")

    return result
```

## Why each step matters

**`json.loads` first, then coerce.** The JSON layer gives you a Python dict; coercion works on Python types, not on raw strings. Doing it in the wrong order (e.g., trying to split a string before parsing) is a common early mistake.

**`affected_services` coercion before key-stripping.** The dict comprehension at the end re-assembles only the schema keys. If you strip first and then coerce, you still have the right structure; but doing coercion earlier makes the error paths cleaner — the `isinstance` checks below it are always on the final type.

**`.lower()` before the enum check.** This is the exact bug the challenge was modelled on. An LLM can capitalise in many ways (`HIGH`, `High`, `hiGH`). Normalising to lowercase once, then checking membership in a set, handles all of them.

**`{k: data[k] for k in SCHEMA_KEYS if k in data}`.** This is the key-stripping step. It rebuilds the dict from a fixed key list rather than deleting keys from the original — cleaner and immune to iterating over a dict while modifying it.

**Final constraint checks.** These run after coercion and stripping, so they reflect the actual output the caller will receive. Checking `title` and `resolution_steps` here (not at the top) ensures you catch cases where the LLM omitted a field entirely.

## Hardening preview

In a real pipeline you would move this validation upstream: use the model's **tool-call / function-calling** interface (OpenAI, Anthropic tool_use) to constrain the output at generation time, and keep this layer as a defence-in-depth fallback. Libraries like `pydantic` or `instructor` automate exactly this pattern — the manual implementation here shows you what they're doing under the hood.
