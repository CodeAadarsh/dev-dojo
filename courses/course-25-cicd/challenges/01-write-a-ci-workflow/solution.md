# Solution — Write a CI Workflow

The complete `.github/workflows/ci.yml`. Save this at `~/.kube-dojo-work/01-write-a-ci-workflow/.github/workflows/ci.yml`.

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  ci:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: pip install -r requirements-dev.txt

      - name: Lint
        run: ruff check .

      - name: Test
        run: pytest tests/ -v
```

## Why each piece is required

**`on: push + pull_request`.**
`push` means every commit to every branch gets checked — you catch breakage the moment it lands, not when someone opens a PR. `pull_request` triggers on the *merged* commit (base + branch merged together), not just the branch tip — this catches integration failures that each side passing independently would miss. Omitting `push` means feature branches are untested until a PR is opened. Omitting `pull_request` means the merge-preview is never tested.

**`actions/checkout@v4` as the first step.**
GitHub Actions runners start with an empty workspace. Without this step, there is no source code — every subsequent step would fail silently or with confusing "file not found" errors. Checkout is always first, always pinned to a major version (`@v4` not `@latest` — `@latest` is a supply-chain footgun).

**`actions/setup-python@v5` before `pip install`.**
Runners ship with a system Python, but it varies between runner images and changes without notice. Explicit `python-version: "3.12"` makes the environment reproducible across re-runs and across new runner images. It also enables the built-in pip cache when you add `cache: 'pip'` (see Challenge 03).

**Lint before test.**
`ruff check` runs in milliseconds. A syntax error or undefined name surfaces in under a second — you don't queue 3 minutes of test infrastructure only to see an `ImportError`. Fast gates first is the invariant. In large monorepos this ordering saves thousands of compute-minutes per week.

**`pytest tests/ -v` not `pytest`.**
The `-v` flag names every test in the log output. When a run fails at 2 AM and you're reading the CI log, `FAILED tests/test_app.py::test_add_negative` is far more useful than a bare failure count. `-v` is zero cost in correctness and saves real debugging time.

## Hardening preview

Pin action versions to a commit SHA, not a tag, to prevent supply-chain tag-moving attacks:

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
- uses: actions/setup-python@0b93645e9fea7318ecaed2b359559ac225c90a2b  # v5.3.0
```

Add `permissions: read-all` at the workflow level and grant only what each job needs (`contents: read`, `pull-requests: write` for comment-posting jobs). The least-privilege rule applies to GitHub tokens the same way it applies to IAM policies.
