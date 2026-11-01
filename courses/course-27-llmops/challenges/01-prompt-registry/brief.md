# Prompt Registry

The platform team just shipped a new LLM feature — a customer-facing summariser. On day two, someone edited the system prompt in production to "fix a small wording issue" and pushed directly, with no record of what changed or which prompt produced which summary. Customer complaints doubled overnight; nobody can prove which version was running.

Your ticket: *build the thing that would have prevented this — a versioned prompt registry.*

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-prompt-registry/
├── registry.py          # skeleton — PromptTemplate + PromptRegistry, all stubs
└── tests/
    └── test_registry_sample.py   # sample tests; run these while you develop
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-prompt-registry
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `PromptTemplate` and `PromptRegistry` in `registry.py`. The class interfaces are already declared; only the method bodies are stubs.

The verifier checks all of the following:

| Requirement | Detail |
|-------------|--------|
| **Register & retrieve** | `register(name, version, template)` stores the template; `get(name, version)` returns it; both raise `KeyError`/`ValueError` for unknown entries |
| **Render** | `PromptTemplate.render(**kwargs)` substitutes `{variable}` placeholders using Python's `str.format` |
| **Two versions independent** | Registering `v1` and `v2` for the same name keeps them separate; `get` selects the exact version requested |
| **Promote to production** | `promote(name, version)` designates that version as production; `get_production(name)` returns it |
| **No production before promote** | `get_production` raises before any `promote` has been called for that name |
| **Record usage / provenance** | `record_usage(name, version, output)` appends `{"version": version, "output": output}` to the log; `get_provenance(name)` returns the full list in insertion order |

## Why this matters

In production LLMops you constantly A/B-test prompts, roll back when quality drops, and need audit trails for every inference decision. The registry is the simplest primitive that gives you all three. Without it you end up with prompt soup in a `.env` file and no idea what changed when the evals collapsed.

## Verify

```bash
bash courses/course-27-llmops/challenges/01-prompt-registry/verify.sh
```

All tests green → flag printed.
