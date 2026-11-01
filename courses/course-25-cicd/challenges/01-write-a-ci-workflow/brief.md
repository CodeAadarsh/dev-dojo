# Write a CI Workflow

A new microservice just got its first commit. The PR description says: *"Shipping this today — all tests pass locally."* A reviewer replies: *"We have no CI. 'Passes locally' is not a gate. Nothing merges until there's a workflow."*

That reviewer is you. And the workflow is your job.

## Context

`setup.sh` plants a small Python project in your work directory:

```
~/.kube-dojo-work/01-write-a-ci-workflow/
├── app.py                  # two utility functions
├── tests/
│   └── test_app.py         # six tests, all currently green
├── requirements-dev.txt    # pytest, ruff
└── .github/
    └── workflows/          # empty — you create ci.yml here
```

## Prerequisites

```bash
pip install pyyaml   # verify.sh uses it to parse your workflow
```

## Mission

Author `.github/workflows/ci.yml` inside the work directory so that it would run correctly on GitHub Actions. You are **not** pushing to GitHub — the verifier parses your YAML locally and checks its structure.

The verifier asserts all of the following:

| Check | What passes |
|-------|-------------|
| Trigger: `push` | `on:` includes a `push` trigger |
| Trigger: `pull_request` | `on:` includes a `pull_request` trigger |
| At least one job | `jobs:` has at least one entry |
| Checkout step | a step using `actions/checkout` |
| Setup step | a step using `actions/setup-*` or with "setup" in its name |
| Lint step | a step with "lint" in its name, or `run:` containing `ruff`/`flake8`/`pylint` |
| Test step | a step with "test" in its name, or `run:` containing `pytest` |

## Why this matters

A CI workflow is a contract: every push is tested in an environment that is **not** your laptop. The `on: push + pull_request` pair means:
- Pushes to any branch trigger the check (catch breakage early).
- PRs trigger it again on the merged commit (catch integration failures that passing base + branch separately would miss).

Skipping either trigger is the difference between "we have CI" and "CI sometimes runs."

The step ordering — checkout → setup → lint → test — is also not arbitrary. Lint fails fast (syntax/style is cheap to check), so you don't wait 3 minutes for a test run only to discover the PR has an obvious import error. Fast gates first.

## Verify

```bash
bash courses/course-25-cicd/challenges/01-write-a-ci-workflow/verify.sh
```

The verifier parses `~/.kube-dojo-work/01-write-a-ci-workflow/.github/workflows/ci.yml` and prints the flag only when all checks pass.
