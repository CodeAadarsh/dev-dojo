# Structured Output

A team member shipped an incident-response assistant that calls an LLM and forwards the raw response to a downstream alerting pipeline. It failed in production on day two: the LLM returned `"severity": "CRITICAL"` (uppercase), and the pipeline's enum check hard-crashed. The post-mortem action item landed in your queue: *"make the LLM output actually predictable."*

The root cause is the classic gap between what an LLM *will* return and what your code *expects*. The fix is a validation/coercion layer that sits between the model and the rest of the system.

## Mission

Implement `parse_incident_report(raw: str) -> dict` in `solution.py`.

The function receives a JSON string (as an LLM would produce it) and must return a dict that exactly matches this schema — no more keys, no fewer, all constraints satisfied:

| Key | Type | Constraint |
|-----|------|------------|
| `title` | `str` | non-empty |
| `severity` | `str` | one of `"low"`, `"medium"`, `"high"`, `"critical"` (always lowercase) |
| `affected_services` | `list[str]` | may arrive as a CSV string — split and strip whitespace |
| `resolution_steps` | `list[str]` | non-empty list |

Additional rules:
- Strip any keys the LLM invented that are not in the schema.
- Normalise `severity` to lowercase; raise `ValueError` if the lowercased value is not in `VALID_SEVERITIES`.
- If `affected_services` is a `str`, split on `","` and strip each element.
- Raise `ValueError` for any other schema constraint that cannot be satisfied (e.g. empty `title`, empty `resolution_steps`).

## Target state

The verifier runs `pytest test_solution.py -v` against five test cases:

1. Clean, valid JSON passes through with all values intact.
2. JSON with extra keys (`root_cause`, `timestamp`) — output must have **exactly** the four schema keys.
3. Severity `"CRITICAL"` (uppercase) — output must have `"critical"`.
4. `affected_services` is `"ingress-nginx, cert-manager, api"` — output must be a three-element list.
5. Severity `"urgent"` (not in `VALID_SEVERITIES`) — function must raise `ValueError`.

All five must be green. Then run the verifier to collect the flag.

## Why it matters

Every production LLM pipeline needs this layer. Without it you are at the mercy of the model's mood: it might return `"Severity"`, `"SEVERITY"`, or `"sev: high"` depending on temperature, prompt drift, or a model version change. Structured output via schema validation (or, upstream, via tool-call / response-format constraints) is the boundary that makes your pipeline maintainable. The bug that triggered this challenge was real — a missing `.lower()` call paged the on-call engineer at 2 AM.
