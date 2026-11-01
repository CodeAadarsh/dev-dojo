# Matrix Builds and Dependency Cache

A library that wraps Python's `statistics` module ships a compatibility fix for Python 3.11 `NormalDist`. The fix was tested locally on 3.12 and merged. Two days later a user files a bug: *"Your library crashes on 3.11 with a TypeError."* The fix used a keyword argument that doesn't exist in 3.11.

The root cause is not the bug itself — it's that CI only ran on one Python version. If the job had been a matrix, the regression would have been caught before the merge.

Your job: author a workflow that tests against multiple versions **and** caches dependencies so the multi-version run doesn't cost three times the install time.

## Context

`setup.sh` plants a small library project in your work directory:

```
~/.kube-dojo-work/03-matrix-and-cache/
├── statslib.py             # small statistics wrapper
├── tests/
│   └── test_statslib.py    # pytest suite, version-compatible
├── requirements-dev.txt    # pytest
└── .github/
    └── workflows/          # empty — you create ci.yml here
```

## Prerequisites

```bash
pip install pyyaml   # verify.sh uses it to parse your workflow
```

## Mission

Author `.github/workflows/ci.yml` inside the work directory. The verifier parses your YAML locally — you are not pushing to GitHub.

The verifier asserts all of the following:

| Check | What passes |
|-------|-------------|
| At least one job | `jobs:` has at least one entry |
| Matrix with >=2 entries | `strategy.matrix` has a key whose value is a list of 2+ items |
| Cache step present | a step using `actions/cache` OR a `setup-python` step with `with.cache` set |

Recommended matrix:
```yaml
strategy:
  matrix:
    python-version: ["3.11", "3.12"]
```

Recommended cache (single-line opt-in via setup-python):
```yaml
- uses: actions/setup-python@v5
  with:
    python-version: ${{ matrix.python-version }}
    cache: 'pip'
```

Or via a standalone `actions/cache@v4` step — either form passes.

## Why matrix + cache together

**Matrix without cache** means every version re-downloads the full dependency tree from PyPI on every run. For a package with 50 transitive deps, that's 30-60 seconds per matrix leg — dead time that grows linearly with the number of versions you test.

**Cache without matrix** saves install time but only on one version. A regression on an older runtime still ships.

**Matrix + cache** is the standard form for any library that must support multiple language versions. The cache key typically includes the Python version (so 3.11 and 3.12 get separate caches), the OS, and a hash of the lock file (so a dependency bump invalidates the cache automatically).

## Verify

```bash
bash courses/course-25-cicd/challenges/03-matrix-and-cache/verify.sh
```

The verifier parses `~/.kube-dojo-work/03-matrix-and-cache/.github/workflows/ci.yml` and prints the flag only when all checks pass.
