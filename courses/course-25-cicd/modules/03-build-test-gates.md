# Build & Test Gates

> **Module 03 · Course 25** — "All tests pass" is the weakest possible guarantee a pipeline can offer. A suite where 30% of failures are intermittent, where coverage is gamed by testing getters, and where the e2e suite takes 25 minutes and fails every Tuesday tells you nothing. This module is about building a test layer that means something — and wiring it to branch protection so it actually blocks bad code, not just bad luck.

You write tests at work. The question is whether those tests function as a gate — a policy you trust enough to enforce — or as a ritual that gives the appearance of safety.

---

## The three-layer model

Unit → integration → e2e is not just a taxonomy, it is a cost/feedback trade-off:

```
                    cost per run    feedback time    # of tests typical
unit                cheapest        < 10s            1000s
integration         medium          30–120s          100s
e2e / smoke         expensive       2–15 min         10s–50s
```

```
                   "is my logic correct?"      unit
                   "do the parts fit?"         integration
                   "does the product work?"    e2e
```

The discipline is **not running the slow layer when the fast layer is sufficient**. An e2e test that checks `POST /items` returns 201 is a waste — that is a unit/integration test. An e2e test that checks "a user signs up, verifies email, and can place an order" is worth its cost because it exercises the integration of multiple services over real HTTP.

| Layer | What it tests | Mocking stance | Speed lever |
|-------|---------------|----------------|-------------|
| Unit | Pure logic, a single function/class | Everything external is mocked | Run in-process, no I/O |
| Integration | Module interacting with a real dependency (DB, queue) | Only *external* services mocked; local DB/Redis real | Testcontainers or in-process SQLite |
| e2e / system | Full product behavior from the user's perspective | Nothing mocked; real infra | Parallelize across browser workers; share setup fixtures |

> **The Testcontainers shortcut for integration tests.** Spinning up a real Postgres in a Docker container for the integration test suite is cheaper than you think — a `postgres:16-alpine` container starts in ~2 seconds and is torn down after the suite. This eliminates the "mock the ORM" pattern that catches nothing real, and the "require a running Postgres on the dev machine" pattern that breaks onboarding.

---

## Linting and formatting as gates

Linting and formatting checks should be the *first* stage to run — they are the cheapest signal available. A failed linting check in 6 seconds is better than the same problem discovered in a code review.

```yaml
jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
          cache: pip
      - run: pip install ruff mypy
      - run: ruff check src/                    # linting
      - run: ruff format --check src/           # formatting (fail if not formatted)
      - run: mypy src/ --strict                 # type checking
```

The `--check` flag on `ruff format` means "fail if the code is not formatted, don't modify it." This keeps the gate pure: it either passes or fails; it never silently changes files.

For JavaScript/TypeScript:

```yaml
- run: npx eslint src/ --max-warnings=0    # treat warnings as errors
- run: npx prettier --check src/
- run: npx tsc --noEmit                    # type check without emitting files
```

`--max-warnings=0` is important. A lint gate that allows warnings is not a gate — it is a dashboard nobody watches. Warnings accumulate until the code review becomes a debate about whether 400 lint warnings are acceptable.

---

## Coverage thresholds

Coverage as a gate is the most misused tool in this list. Two failure modes:

**Under-gating**: "tests exist" with no coverage floor means a PR that deletes 200 lines of tests and adds 200 lines of dead code sails through.

**Over-gating**: `--cov-fail-under=95` on a new codebase produces coverage gaming — trivial tests written to hit the number, not to verify behavior.

The correct use:

```yaml
- run: |
    pytest tests/ \
      --cov=src \
      --cov-report=xml \
      --cov-report=term-missing \
      --cov-fail-under=80
```

```ini
# pytest.ini or pyproject.toml [tool.pytest.ini_options]
[coverage:report]
exclude_lines =
    pragma: no cover
    def __repr__
    raise NotImplementedError
    if TYPE_CHECKING:
```

Setting `--cov-fail-under=80` and enforcing it in CI is a floor, not a target. The target is meaningful tests. Coverage is a lagging indicator.

The more useful metric: **branch coverage**, not line coverage. A function with `if condition: return x` can have 100% line coverage with a single test that passes `condition=True`. Branch coverage requires covering the `False` branch too.

```toml
# pyproject.toml
[tool.coverage.run]
branch = true                     # enable branch coverage tracking
source = ["src"]
```

---

## Test parallelization and sharding

**Parallelization** (multiple workers, same machine):

```bash
# pytest-xdist: run tests across N workers
pytest tests/ -n auto              # -n auto = one worker per CPU core
pytest tests/ -n 4                 # explicit worker count
```

Each worker is a separate process; tests must be stateless between workers. Side effects (writing to a shared file, a shared DB row) will cause races. Fix: use per-worker temp dirs, per-worker DB schemas, or mock shared resources.

**Sharding** (distribute across multiple CI jobs):

```yaml
jobs:
  test:
    strategy:
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - run: pytest tests/ --shard-id=${{ matrix.shard }} --num-shards=4
```

`pytest-shard` assigns tests to shards by hash of their node IDs — so the assignment is stable across runs and reproducible. Combine with `-n auto` for parallelism within each shard.

The target: a unit test suite that finishes in under 2 minutes, including setup, on 4 shards. If you hit that target, the unit suite is never your pipeline's critical path.

---

## Required status checks and branch protection

Branch protection is where the pipeline's enforcement lives. Without it, every gate is advisory.

GitHub UI path: **Settings → Branches → Branch protection rules → Add rule** on `main`.

Required settings for a production branch:

```
[x] Require a pull request before merging
    [x] Require approvals: 1
    [x] Dismiss stale pull request approvals when new commits are pushed
    [x] Require review from Code Owners
[x] Require status checks to pass before merging
    [x] Require branches to be up to date before merging
    Required status checks:
        test / pytest (ubuntu-24.04, 3.11)    ← exact job name from the matrix
        lint / ruff
        scan / trivy
[x] Require conversation resolution before merging
[x] Do not allow bypassing the above settings
```

"Do not allow bypassing" is the critical line. Without it, any admin can merge directly, which means the gate only applies to engineers who are not admins — which means the gate applies to everyone except the people who make the high-stakes calls.

The exact check name to enter in "Required status checks" must match the string that appears in the PR checks list. For a matrix job:

```
# workflow job named 'test', matrix dimension python-version: 3.11, os: ubuntu-24.04
# the check name is:
test (ubuntu-24.04, 3.11)
```

---

## Failing fast

Two levels of fast-fail:

**Within a job**: stop the job at the first failing step. This is the default — a `run:` step that exits non-zero stops the job. The antipattern is `|| true` after a command to suppress failure, which turns the gate into a no-op.

```yaml
- run: pytest tests/ --tb=short    # exits non-zero on any failure; job stops here
- run: trivy image myapp:latest --exit-code 1 --severity HIGH,CRITICAL
#                                   ^^ --exit-code 1 makes trivy fail the step on findings
```

**Across jobs**: stop downstream jobs when an upstream job fails. The default behavior is that jobs with `needs:` are skipped when the needed job fails. But jobs without `needs:` (running concurrently) continue regardless.

```yaml
jobs:
  build:
    steps: …
  test:
    needs: build       # skipped if build fails — correct
    steps: …
  deploy:
    needs: [build, test]  # skipped if either fails — correct
    steps: …
```

The antipattern: `if: always()` on a deploy step without any prior check. This means the deploy runs even when tests fail.

```yaml
# WRONG
jobs:
  deploy:
    if: always()          # deploys even on test failure
    needs: [test]

# CORRECT
jobs:
  deploy:
    if: ${{ needs.test.result == 'success' }}
    needs: [test]
```

---

## Debugging build and test gates

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| A flaky test blocks every merge for 30 minutes ("merge queue dread") | Test has a real race, time-dependent assertion (`datetime.now()`), or shared fixture state that isn't reset between test runs | Add `@pytest.mark.flaky(reruns=3)` temporarily; fix root cause: replace `datetime.now()` with an injectable clock; use fresh DB per test |
| Coverage threshold fails after a refactor that didn't reduce coverage | Files were moved; old `.coverage` from a different run was picked up; exclude pattern no longer matches | Delete `.coverage` before running; assert `--cov=src` matches the actual module path; check `coverage report` output |
| "Coverage gaming" — someone adds `# pragma: no cover` everywhere | No one reviews coverage changes in PR | Add a CI step that asserts the total `# pragma: no cover` count hasn't increased: `grep -r 'pragma: no cover' src/ | wc -l` and compare to a baseline |
| Required status check not appearing in branch protection dropdown | The job ran zero times (so GitHub hasn't recorded it as a check name yet); or the job name has a typo | Run the workflow once on a PR; the check name appears in the dropdown after the first run |
| `pytest-xdist` races: two workers write to the same temp file and tests pass locally but fail in CI | Shared tmp dir assumption; tests use a hardcoded path (`/tmp/output.csv`) that two workers collide on | Use `tmp_path` pytest fixture (unique per test) instead of hardcoded paths |
| e2e suite takes 20 minutes and is the pipeline critical path | Tests are sequential; each test sets up and tears down the entire app from scratch | Scope fixtures at the session level (`@pytest.fixture(scope="session")`); reuse the running app; parallelize with `pytest-xdist -n 4` |
| A passing CI check does not satisfy the required status check on the PR | The required check is registered under a different name (e.g., matrix dimension included in name) | Look at the PR checks tab; the exact string shown there is what branch protection needs |

### Diagnosing a flaky test — the exact method

Flaky tests are the highest-leverage quality problem in a pipeline. The fastest diagnostic:

```bash
# Run the suspect test 20 times in isolation — a flaky test will show a non-zero failure rate
for i in $(seq 1 20); do
  pytest tests/test_suspect.py::test_my_case -x --tb=short
done

# Capture timing (time-dependent failures often correlate with load)
pytest tests/test_suspect.py::test_my_case -v --durations=0 -x

# Check for shared state by running in a different order
pytest tests/ -p no:randomly     # disable random ordering to reproduce a specific failure
pytest tests/ --randomly-seed=12345  # fix the seed to reproduce
```

A test that fails 1 in 20 runs will fail nearly every day in a pipeline with 40 developers merging PRs. Expected daily failures = `N_runs * flake_rate`. At 40 PRs/day and 1/20 flake rate, that's 2 false-fail blocks per day.

> **War story.** A test at SAP that checked "the metrics endpoint returns the correct count" was marked as flaky for three months. Everyone assumed it was a race in the test framework. The actual cause: the test made a `requests.get` call to a metrics endpoint that aggregated from a Prometheus scrape, and the scrape interval was 15 seconds. The test ran within 15 seconds of the previous test that changed the metric — before the scrape picked up the change. On fast CI runners (new machines with warm caches) the window was often hit; on slower runners it wasn't. The fix: replace the Prometheus query with a direct call to the in-process metric registry, bypassing the scrape entirely. One-line fix. The root cause was a timing assumption that was invisible from the test body.

---

## Checkpoint

You're ready for the challenges when you can answer without hesitation:

1. Name the three test layers, the question each answers, and the mocking stance appropriate for each.
2. Explain the difference between line coverage and branch coverage; give a concrete function where line coverage reaches 100% but branch coverage does not.
3. Write the `pytest` command that runs with 4 workers in parallel, generates a coverage XML report, and fails if coverage drops below 80%.
4. Describe how to configure GitHub branch protection to require a specific matrix job check — including the exact string format for a 3.11/ubuntu-24.04 matrix leg.
5. Name the correct pytest fixture scope for a test that sets up a full application server shared across all tests in the session.
6. Diagnose a flaky test: name the first command to run, what a 1/20 flake rate costs a team of 40 engineers per week in pipeline hours, and the two most common root causes.
7. Explain why `--max-warnings=0` on ESLint is a gate, while `--max-warnings=50` is a dashboard.
8. Describe what "coverage gaming" looks like in a PR diff and the CI assertion that catches it.

➡ Next up: **Containers: Build, Scan & Sign** — reproducible Docker builds, multi-arch, trivy, SBOMs, cosign, and SLSA provenance.
