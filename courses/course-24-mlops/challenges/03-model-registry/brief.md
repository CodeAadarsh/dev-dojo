# Model Registry

A Slack message from the on-call engineer: *"We rolled back to 'the previous model' but nobody can tell me which artifact that is. There are four `model_v*.pkl` files in S3 with no metadata and no record of which one went to production last week."*

A model registry is the source of truth for model lineage. Without one, "promote to production" is a file copy and a prayer. With one, it's a versioned, auditable operation: you know which artifact is in production, who registered it, what its metrics were, and how to load it.

## Context

`setup.sh` plants the scaffold in your work directory:

```
~/.kube-dojo-work/03-model-registry/
└── registry.py   # ModelRegistry skeleton — implement the four methods
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-model-registry
python3 -m venv .venv && . .venv/bin/activate
pip install scikit-learn numpy pytest
```

## Mission

Implement the four methods of `ModelRegistry` in `registry.py`:

| Method | Signature | Behaviour |
|--------|-----------|-----------|
| `register` | `(name, version, model, metadata) -> None` | Persist artifact + metadata; raise `ValueError` if version already exists |
| `list_versions` | `(name) -> list[dict]` | Return `[{"version": str, "metadata": dict}, ...]` sorted by version; raise `KeyError` if name unknown |
| `promote` | `(name, version, alias="production") -> None` | Tag version with alias; raise `KeyError` if version doesn't exist |
| `load` | `(name, alias_or_version) -> model` | Resolve alias → version, load and return model; raise `KeyError` if not found |

The verifier:
1. Registers two versions of the same model name.
2. Promotes version `"2"` to `"production"`.
3. Asserts `load("clf", "production")` returns the version-2 model (same predictions).
4. Asserts `load("clf", "1")` returns the version-1 model.
5. Asserts metadata is preserved through a round-trip.
6. Asserts `register` with a duplicate version raises `ValueError`.

**All state must survive `ModelRegistry.__init__` across separate instances** — the verifier creates a fresh `ModelRegistry(same_dir)` and calls `load`, so you cannot keep state only in memory.

## Why it matters

A model registry makes three previously-manual operations safe and auditable:

- **Rollback**: `load("clf", "production")` before and after a promotion gives you the before/after models in two lines — no hunting through S3 timestamps.
- **Comparison**: `list_versions("clf")` shows every version with its metrics side by side.
- **Governance**: metadata carries the training run ID, dataset hash, author, and experiment link — the audit trail that regulators and on-calls both need.

MLflow, Weights & Biases, and Vertex AI Model Registry all implement this same contract at scale. This challenge is the minimal version: file-backed, no server, the same conceptual core.

## Verify

```bash
bash courses/course-24-mlops/challenges/03-model-registry/verify.sh
```

All five tests green → flag printed.
