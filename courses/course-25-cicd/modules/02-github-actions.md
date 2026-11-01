# GitHub Actions, Deeply

> **Module 02 · Course 25** — GitHub Actions is the default CI/CD platform for most teams shipping software in 2025. This module is not a tour of the YAML keys — the docs cover that. This is the mental model: how jobs fan out and fan in, how the security boundary actually works, and how you wire cloud credentials without embedding a secret that will be in a breach report six months from now.

You have seen Actions workflows before. The goal here is to stop squinting at YAML and start reasoning about the execution model. Every confusing behavior — cache misses, secret not found, matrix explosions — has a precise cause rooted in the primitives. Learn the primitives.

---

## The execution model: workflow → jobs → steps → actions

```
Workflow file (.github/workflows/ci.yml)
│
├── on: [push, pull_request]        ← event triggers when this workflow runs
│
├── job: build                      ← runs on a fresh VM (or container)
│   ├── runs-on: ubuntu-24.04
│   ├── step: actions/checkout@v4   ← an action (reusable unit of code)
│   ├── step: run: pip install …    ← inline shell command
│   └── step: run: pytest …
│
└── job: scan                       ← different VM, runs concurrently with 'build' by default
    ├── needs: build                ← explicit dependency; now scan runs AFTER build
    ├── step: …
    └── step: …
```

Key invariants:

- **Each job gets a fresh VM.** There is no shared filesystem between jobs by default. Artifacts you produce in `build` do not exist in `scan` unless you explicitly upload then download them.
- **Jobs run concurrently** unless you declare `needs:`. The execution graph is a DAG; `needs` is the edge.
- **Each step in a job runs in the same shell** (same environment, same working directory). An `export` in step 3 is visible in step 4. It is *not* visible in a different job.
- **`env:` has three scopes:** workflow-level (all jobs/steps), job-level (all steps in that job), step-level (only that step). Narrower scope wins on collision.

---

## Events and triggers

```yaml
on:
  push:
    branches: [main]          # only pushes to main
    paths:
      - 'src/**'              # only when src/ changes (path filter)
  pull_request:
    branches: [main]          # PRs targeting main
    types: [opened, synchronize, reopened]
  schedule:
    - cron: '0 2 * * 1'       # every Monday at 02:00 UTC
  workflow_dispatch:           # manual trigger button in the UI
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'staging'
  workflow_call:               # reusable workflow — triggered by another workflow
    inputs:
      image_tag:
        type: string
        required: true
```

The `paths:` filter is a sharp tool. A monorepo with 10 services can use it to only run a service's pipeline when that service's source changes. But: if you depend on shared code (a `libs/` directory), forgetting to add `libs/**` to the path filter means a change to shared code silently skips all the service pipelines. Write path filters defensively.

> **`workflow_dispatch` is not just for demos.** It is your escape hatch for hotfix deploys, scheduled retries, and manual promotions. A button in the UI that triggers the exact same pipeline as a push — with the same gates, same artifact — is safer than an engineer SSHing to run a deploy script by hand.

---

## Matrix builds

Run the same job across a combination of dimensions:

```yaml
jobs:
  test:
    strategy:
      matrix:
        python-version: ['3.10', '3.11', '3.12']
        os: [ubuntu-24.04, macos-14]
      fail-fast: false       # don't cancel all matrix legs when one fails
      max-parallel: 4        # cap concurrent runners (cost + queue management)
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - run: pytest tests/
```

That produces `3 × 2 = 6` parallel jobs. The matrix cartesian product is the default; you can exclude specific combinations or include ad-hoc entries:

```yaml
strategy:
  matrix:
    include:
      - python-version: '3.12'
        os: ubuntu-24.04
        extra-flag: '--run-experimental'
    exclude:
      - python-version: '3.10'
        os: macos-14
```

`fail-fast: false` is critical for diagnostic coverage — if `3.10/ubuntu` fails, you still want to know whether `3.12/macos` also fails or not. Set it to `true` only when you are cost-conscious and want to cancel early once any failure appears.

---

## Caching

The cache key design is the entire skill:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/pip
    key: pip-${{ runner.os }}-${{ hashFiles('requirements.txt') }}
    restore-keys: |
      pip-${{ runner.os }}-
```

How it resolves: Actions tries `key` first (exact match). On miss, it walks `restore-keys` in order, using the most-recent partial match. Then install normally; the cache action auto-uploads at job end.

The table that matters:

| Ecosystem | Cache `path` | Key ingredient |
|-----------|-------------|----------------|
| Python pip | `~/.cache/pip` | `hashFiles('requirements*.txt')` |
| Node npm | `~/.npm` | `hashFiles('package-lock.json')` |
| Go modules | `~/go/pkg/mod` | `hashFiles('go.sum')` |
| Maven | `~/.m2/repository` | `hashFiles('pom.xml')` |
| Docker layers (BuildKit) | use `cache-to: type=gha` in `docker/build-push-action` | — |
| Gradle | `~/.gradle/caches` | `hashFiles('**/*.gradle*', '**/gradle-wrapper.properties')` |

Cache **misses** cost you the full install time. Cache **hits** cost you ~20 seconds of download. A pip install of a scientific stack from scratch is 90–180 seconds; the cache hit is 15 seconds. Cache your dependencies.

---

## Artifacts

Artifacts cross the job boundary — they are the only first-class mechanism for passing files between jobs:

```yaml
jobs:
  build:
    steps:
      - run: pytest --junitxml=report.xml tests/
      - uses: actions/upload-artifact@v4
        if: always()               # upload even on failure (you want the report on failure)
        with:
          name: test-report
          path: report.xml
          retention-days: 7

  publish-report:
    needs: build
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: test-report
      - run: cat report.xml
```

`if: always()` on upload is not optional for diagnostic artifacts like test reports or coverage files — the default `if: success()` means the artifact vanishes precisely when you most need it.

Artifacts are not a substitute for a registry. Don't use `upload-artifact` to pass Docker images between jobs. Build once, push to a registry (GHCR, ECR, etc.), reference by digest in downstream jobs.

---

## Secrets and environments

```yaml
jobs:
  deploy:
    environment: production          # references a GitHub Environment
    env:
      DB_URL: ${{ secrets.DB_URL }}  # pulled from the 'production' environment's secrets
    steps:
      - run: echo "Deploying to production"
```

**Secrets are scoped** to the context in which they are accessed:

| Scope | Where defined | Accessible when |
|-------|--------------|-----------------|
| Repository secret | Settings → Secrets → Actions → Repository | All workflows in the repo |
| Environment secret | Settings → Environments → `<name>` → Secrets | Only jobs with `environment: <name>` |
| Organization secret | Org Settings → Secrets | All repos in the org (if granted) |

Environment secrets are stronger than repo secrets because you can attach *protection rules* to a GitHub Environment: required reviewers, deployment branch restrictions, wait timers. A `production` environment that requires a human to approve deployments from any branch except `main` is a gate that can't be bypassed by a YAML change.

```yaml
# Environment with protection (configured in GitHub UI, not YAML):
# - Required reviewers: [your-team]
# - Allowed branches: main
# - Secret: PROD_KUBECONFIG (not accessible from feature branches)
```

> **Never use a repository secret for production credentials.** A repo secret is accessible from any branch, including `feature/test-something` pushed by an attacker with write access. An environment secret scoped to `production` with a branch restriction is not.

---

## Reusable and composite workflows

**Reusable workflow** (`.github/workflows/deploy.yml` called by another workflow):

```yaml
# .github/workflows/deploy.yml
on:
  workflow_call:
    inputs:
      image_tag:
        type: string
        required: true
    secrets:
      KUBECONFIG:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-24.04
    steps:
      - run: kubectl apply -f k8s/ --set image.tag=${{ inputs.image_tag }}
        env:
          KUBECONFIG: ${{ secrets.KUBECONFIG }}
```

```yaml
# caller workflow
jobs:
  call-deploy:
    uses: ./.github/workflows/deploy.yml
    with:
      image_tag: ${{ needs.build.outputs.image_tag }}
    secrets:
      KUBECONFIG: ${{ secrets.PROD_KUBECONFIG }}
```

**Composite action** (`actions/my-setup/action.yml`):

```yaml
# .github/actions/python-setup/action.yml
name: 'Python Setup'
description: 'Install Python + deps with caching'
inputs:
  python-version:
    required: true
    default: '3.11'
runs:
  using: 'composite'
  steps:
    - uses: actions/setup-python@v5
      with:
        python-version: ${{ inputs.python-version }}
    - uses: actions/cache@v4
      with:
        path: ~/.cache/pip
        key: pip-${{ runner.os }}-${{ hashFiles('requirements*.txt') }}
    - run: pip install -r requirements.txt
      shell: bash
```

The rule: if you find yourself copy-pasting the same 5-step setup block across three workflow files, that's a composite action. If you find yourself duplicating an entire `deploy` job across three repos, that's a reusable workflow.

---

## OIDC to cloud — no long-lived credentials

This is the biggest security improvement Actions made available and the most underused. The problem it solves:

```
BAD: store AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in repo secrets
→ keys are long-lived, rotated manually (= rarely), leaked in logs or via repo access

GOOD: use OIDC — GitHub mints a short-lived JWT per job run; AWS/GCP/Azure exchange it for a temporary credential that expires when the job ends
```

AWS example:

```yaml
jobs:
  deploy:
    permissions:
      id-token: write    # REQUIRED: lets the job request an OIDC token from GitHub
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy
          aws-region: ap-south-1
      - run: aws s3 cp dist/ s3://my-bucket/ --recursive
```

The IAM role's trust policy on the AWS side restricts which repo/branch can assume it:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
    }
  }
}
```

`sub` pins this trust to commits on `main` of this specific repo. A PR from a fork cannot assume this role.

---

## Concurrency

Prevent multiple workflow runs from racing each other to the same environment:

```yaml
concurrency:
  group: deploy-${{ github.ref }}     # one running deploy per branch
  cancel-in-progress: true            # cancel the older run when a new one starts
```

This is critical for deploy workflows. Without it: two pushes in quick succession produce two concurrent deploys, the second deploy may complete before the first, and you have deployed in reverse commit order. `cancel-in-progress: true` ensures only the latest commit's pipeline deploys.

For test runs you usually want the opposite behavior:

```yaml
concurrency:
  group: test-${{ github.ref }}-${{ github.sha }}
  cancel-in-progress: false           # let all test runs complete (don't hide failures)
```

---

## Debugging GitHub Actions

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Cache never hits, every run installs from scratch | Key includes a component that changes on every run (e.g. `github.sha` or a timestamp); or `path` points to a directory that doesn't exist yet when the cache step runs | Check the exact key logged in the cache step; ensure `path` exists before `actions/cache` runs (or use `actions/setup-python` which manages its own cache) |
| Secret is empty / step fails with "Input required and not supplied" | Secret is defined at repo level but the job has `environment: production` set; repo-level secrets are shadowed by environment context | Move the secret to the environment, or remove `environment:` from the job |
| Matrix job count explodes (40+ jobs, queue exhaustion) | Cartesian product of 4+ dimensions; `max-parallel` not set | Add `max-parallel`; collapse related dimensions with `include:` instead of full cross-product |
| YAML indentation error: "mapping values are not allowed here" | Tab character instead of spaces; wrong indentation level for a `with:` or `env:` block | Run `yamllint .github/workflows/*.yml` locally; always use 2-space indentation |
| OIDC fails: "Error: Could not assume role" | `id-token: write` permission is missing from the job; or the IAM trust policy `sub` condition doesn't match the current ref | Verify `permissions: id-token: write`; print the `ACTIONS_ID_TOKEN_REQUEST_TOKEN` (it's not a secret) to see the actual `sub` claim value |
| "Step was cancelled" appears in the middle of a job | A previous step used `continue-on-error: false` (default) and failed; or the job hit the `timeout-minutes` limit | Check the step immediately above; add explicit `timeout-minutes` to long-running steps |
| Job runs on wrong branch / unexpected trigger | Trigger `paths:` filter too narrow; branch filter matches `release/**` but not `main` | Add a `workflow_dispatch` trigger and run manually for testing; read the "Event activity" in the workflow run UI to see the exact event payload that fired |

### Diagnosing cache misses — the exact method

Every `actions/cache` step logs the exact key it used. Find it in the "Set up job" → "Cache" logs:

```
Cache not found for key: pip-Linux-abc123def456
Restored from: pip-Linux-
```

The second line tells you which `restore-keys` entry matched (if any). If the full key misses every time, check whether `hashFiles(...)` is computing the same value locally vs in CI:

```bash
# locally
sha256sum requirements.txt   # compare this hash to what appears in the CI log
```

If they differ, the file has Windows line endings on one side or different EOL normalization in `.gitattributes`.

> **War story.** A GitHub Actions workflow was re-installing all dependencies on every run despite a cache step that looked correct. The key was `pip-${{ runner.os }}-${{ hashFiles('requirements.txt') }}`. The problem: `requirements.txt` was generated on a Windows machine and committed with CRLF line endings. Git was configured with `core.autocrlf=true` on the dev machine and `core.autocrlf=false` on the CI runner. The file the runner hashed was different from the file the developer assumed was committed. `hashFiles` saw a different hash on every CI runner because the cached entry was from a run where CRLF was present, and the new run saw LF. The fix was one line in `.gitattributes`: `requirements.txt text eol=lf`. The cache hit rate went from 0% to 98%.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Draw the execution model: which scopes share a filesystem, which do not, and how you move a file from `build` to `scan`.
2. Write the `strategy.matrix` block for a 3-version × 2-OS test suite with `fail-fast: false` and a `max-parallel` of 4.
3. Design a cache key for a Python project that hits on lockfile changes and falls back gracefully on misses.
4. Explain why an environment secret is more secure than a repository secret for production credentials — name the specific protection mechanism.
5. Sketch the OIDC flow from a GitHub Actions job to AWS: what does GitHub emit, what does AWS return, what expires and when.
6. Write the `concurrency:` block for a deploy workflow that cancels in-progress runs and the alternative for a test workflow that must not cancel.
7. Diagnose a cache miss: name the first log line to check and the command to validate `hashFiles` locally.
8. Name the permission required on a job to request an OIDC token, and explain what happens without it.

➡ Next up: **Build & Test Gates** — coverage thresholds, sharding, required status checks, and why flaky tests are a systemic risk.
