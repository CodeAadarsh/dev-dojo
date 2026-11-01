# Solution — Matrix Builds and Dependency Cache

The complete `.github/workflows/ci.yml`. Save this at `~/.kube-dojo-work/03-matrix-and-cache/.github/workflows/ci.yml`.

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  ci:
    runs-on: ubuntu-latest

    strategy:
      matrix:
        python-version: ["3.11", "3.12"]

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
          cache: 'pip'

      - name: Install dependencies
        run: pip install -r requirements-dev.txt

      - name: Test
        run: pytest tests/ -v
```

## Why each piece is required

**`strategy.matrix.python-version: ["3.11", "3.12"]`.**
GitHub Actions expands the matrix into one parallel job per entry. With two entries, the `ci` job runs twice: once with 3.11, once with 3.12. Each leg is an independent job with its own runner — the runs are concurrent, so wall-clock time does not double. Any failure in any leg fails the entire workflow, so a version-specific regression can't sneak through.

The `${{ matrix.python-version }}` expression substitutes the current matrix value into the step. It's evaluated at job-dispatch time, so each leg sees its own version string.

**`cache: 'pip'` on `actions/setup-python@v5`.**
This single line enables automatic pip caching using Actions' cache service. The action constructs a cache key from:
- The runner OS
- The Python version (so 3.11 and 3.12 don't share a cache)
- A hash of all `requirements*.txt` files found in the repo

On a cache hit, `pip install` finds packages already on disk and skips the network entirely. On a cache miss (first run, or after a dep change), it downloads normally and saves to cache for the next run.

The overhead is minimal: cache lookup adds ~1 second. For a project with `pytest` as its only dependency, the saving is modest. For a project with `numpy`, `pandas`, and `scipy`, this drops 40-60 seconds from every run.

## Alternative: standalone `actions/cache` step

If you need fine-grained control over the cache key or path:

```yaml
- name: Cache pip
  uses: actions/cache@v4
  with:
    path: ~/.cache/pip
    key: ${{ runner.os }}-pip-${{ matrix.python-version }}-${{ hashFiles('requirements-dev.txt') }}
    restore-keys: |
      ${{ runner.os }}-pip-${{ matrix.python-version }}-
      ${{ runner.os }}-pip-
```

The `restore-keys` allow a partial cache hit when the exact key misses — the most recent cache for that Python version is used, and only the new packages are downloaded. This avoids cold-cache runs even after a single dependency is added.

## Hardening preview

**Fail-fast and max-parallel.**

```yaml
strategy:
  fail-fast: false
  max-parallel: 2
  matrix:
    python-version: ["3.10", "3.11", "3.12"]
```

`fail-fast: false` means a failure on 3.10 doesn't cancel the 3.11 and 3.12 legs. You get the full picture of which versions are broken in one run, rather than having to re-run after each fix. `max-parallel` throttles concurrent jobs when your matrix is large and you're on a free-tier runner quota.

**Include/exclude.**

```yaml
matrix:
  python-version: ["3.11", "3.12"]
  include:
    - python-version: "3.12"
      experimental: true
  exclude:
    - python-version: "3.11"
      os: windows-latest
```

`include` adds extra matrix combinations (or extra variables to existing ones). `exclude` removes specific combinations from the expansion. This lets you declare "test 3.12 on all OSes, but mark it experimental" without duplicating the entire matrix.

## Verify

```bash
bash courses/course-25-cicd/challenges/03-matrix-and-cache/verify.sh
```
