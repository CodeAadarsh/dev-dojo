# CI/CD Principles & the Pipeline

> **Module 01 · Course 25** — Before you wire up a single workflow YAML, you need a precise mental model of *what you're building and why*. Cargo-culting Actions from a blog post gets you green badges; understanding the underlying contracts gets you pipelines that survive 6-month-old codebases, on-call rotations, and a PR from an intern who thinks `git push --force main` is normal.

You run Kubernetes at SAP and your LGTM pipeline ships 100 GB/day. You already know "CI runs tests." This module is about the engineering decisions underneath — the ones that determine whether your pipeline accelerates delivery or becomes the thing everyone works around.

---

## CI vs CD vs Continuous Deployment — the precise meanings

These three terms are routinely collapsed into a blur. Distinguish them:

| Term | Boundary | Contract |
|------|----------|----------|
| **Continuous Integration** | Ends at a passing, tested, packaged artifact | Every commit to the integration branch (usually `main`) merges, builds, and is verified automatically, *within minutes* |
| **Continuous Delivery** | Ends at a release-ready artifact in a release environment | Every green pipeline produces an artifact that *could* go to production right now, via a push-button deploy |
| **Continuous Deployment** | Ends in production | Every green pipeline *does* go to production, automatically — no human approval gate |

The confusion matters because the wrong definition leads to the wrong design. A team practicing **CD** (delivery) intentionally keeps a human approval gate before production — the pipeline does everything up to the gate deterministically; the human decides *when*, not *whether*. A team practicing **continuous deployment** has eliminated even that gate. Both are valid; neither is "better CI."

> **The LGTM context.** The SAP AI Core log pipeline is continuous *delivery*, not continuous deployment — every green build produces a container image that passes security scans and is ready to deploy, but a release manager gates the production rollout. That is a deliberate choice given the compliance surface of a multi-tenant SaaS platform. The pipeline is fast; the approval is the bottleneck, not the pipeline.

---

## The pipeline stages

A modern pipeline is not a flat list of steps. It is a **directed acyclic graph** of stages with explicit dependencies and failure semantics.

```
commit
  │
  ▼
[build]──────────────────────────────────────────────────────────────▶ fail fast
  │  compile / transpile / lint            seconds
  │
  ▼
[unit-test]──────────────────────────────────────────────────────────▶ fail fast
  │  pytest, jest, go test                 10–90s
  │
  ▼
[scan]───────────────────────────────────────────────────────────────▶ fail on HIGH
  │  SAST, dependency CVE (trivy/grype)    60–120s
  │
  ▼
[package]────────────────────────────────────────────────────────────▶ deterministic
  │  docker build, sign, push to registry  60–300s
  │
  ▼
[integration-test]───────────────────────────────────────────────────▶ fail
  │  API contract tests, DB migrations     60–300s
  │
  ▼
[deploy → staging]───────────────────────────────────────────────────▶ fail
  │  helm upgrade, kubectl apply, argo sync
  │
  ▼
[smoke + e2e]────────────────────────────────────────────────────────▶ fail
  │  curl health check, playwright         2–10 min
  │
  ▼
[gate: human approval]   ← continuous delivery stops here
  │
  ▼
[deploy → prod]          ← continuous deployment does not stop above this
```

Two rules hold at every stage:

1. **Fail as early as possible.** A linting failure caught in 8 seconds costs nothing. The same defect caught after a 5-minute Docker build costs the developer context, the runner, and the queue position. This is the entire justification for stage ordering.
2. **Each stage produces an artifact or a signal.** `build` produces a binary or image tag. `scan` produces a report. `package` produces a registry digest. Stages that consume from stages above them must use the *exact same artifact* — never rebuild from source at a later stage. This is the reproducibility contract.

---

## Fast feedback: the pipeline SLA that actually matters

"Fast" is not aesthetic. A pipeline that takes longer than the average developer's context-switch interval (empirically: 7–15 minutes) is a pipeline developers stop watching. Instead they context-switch, the notification arrives, the context is cold, and the fix takes longer than it would have.

The targets:

| Stage boundary | Target | Why |
|----------------|--------|-----|
| Commit → first signal | < 2 min | "Did I break it?" must be answerable before the developer switches tasks |
| Commit → full green | < 15 min | Stays inside a single cognitive session |
| Green → deploy-to-staging | < 5 min after green | Latency here directly delays QA and release |
| Staging → production (CD) | < 30 min from merge | Past this, deployments batch and risk accumulates |

When you inherit a pipeline that takes 40 minutes, the fix is almost always the same: parallelize what is currently sequential, cache what is currently rebuilt from scratch, and run heavier tests on merge rather than on every push.

---

## Trunk-based development

The delivery model that makes fast feedback actionable. The contract:

- One integration branch: `main` (or `trunk`). No long-lived feature branches.
- Every developer merges to `main` at least once per day.
- Feature flags (or `if FEATURE_FLAG_X:`) decouple deployment from release.
- Short-lived branches (< 2 days) are fine; branches that live a week accumulate merge debt.

```
main: ──A──B──C──D──E──F──  (multiple engineers, daily)
                 │
                 └── feature-x (lives 4 hours, then merges)
```

vs Gitflow:

```
main:    ──────────────────────────────v1.0─
develop: ──A──B──C──D──E────────────────
feature: ──────────X──X──X──X──merge──     ← merge debt accumulates here
```

Gitflow is the reason integration pipelines take 40 minutes on merge day. Trunk-based development keeps the merge diff small enough that a 5-minute pipeline is actually feasible.

> **The prerequisite for trunk-based development is a pipeline you trust.** If you can't merge to main and have confidence within 10 minutes, developers will use feature branches to defer that confidence — which is rational but compounds the problem. Fix the pipeline first.

---

## Gates vs stages

The terms are overloaded. In this dojo, a precise split:

**Stage**: a unit of work in the pipeline (build, test, scan, deploy). Stages run in sequence or parallel. A stage failure blocks downstream stages.

**Gate**: a *policy check* that determines whether to proceed past a boundary. Gates are binary: pass or block.

| Gate type | Where it lives | Example |
|-----------|----------------|---------|
| Required status check | GitHub branch protection | `test / pytest` must be green to merge |
| Coverage threshold | Test stage | `< 80%` coverage fails the stage |
| Security gate | Scan stage | Any `HIGH` or `CRITICAL` CVE blocks packaging |
| Human approval | Pre-production deploy | Required reviewer approves the deployment |
| Automated smoke gate | Post-deploy | 30-second health check before traffic shifts |

Gates are where you encode organizational risk tolerance as executable policy. A gate that is always overridden by the `--force` escape hatch is not a gate — it is theater.

---

## Idempotent and reproducible builds

Two properties that separate pipelines that work from pipelines that *happen* to work:

**Idempotent**: running the pipeline twice on the same commit produces identical behavior. Corollary: running it a third time on the same commit after a previous failure still produces the same result. Violations: time-seeded random seeds, `pip install` without a lockfile, mutable image tags.

**Reproducible**: given the same source + same environment, the output artifact is bit-for-bit identical. Violations: filesystem timestamps in the image layer, build machines with different OS versions, `FROM ubuntu:latest`.

The enforcement mechanisms:

```yaml
# Bad — mutable, non-reproducible
FROM python:3.11

# Good — pinned to a digest; the registry cannot serve a different image
FROM python:3.11-slim@sha256:a8b43f8b5b7e2d3c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7
```

```toml
# Bad — pip install without a lockfile (different runs may pull different versions)
pip install fastapi

# Good — pinned
pip install -r requirements.txt   # requirements.txt was generated with pip freeze
```

```makefile
# Bad — build artifact depends on when you run it
TAG := latest

# Good — build artifact is keyed to the exact commit
TAG := $(shell git rev-parse --short HEAD)
```

> **The SAP AI Core zero-rollback story.** Reproducible builds are what made zero-rollback possible in our pipeline. When an incident required re-deploying the previous build at 2 AM, the pipeline could reproduce the exact image from the same Git SHA + the same lockfile, not "approximately the same image from a few days ago." Mutable `:latest` tags on any base image in the chain would have made this impossible.

---

## Debugging CI/CD Pipelines

Pipelines fail in ways that are more subtle than a failing test. The symptoms that waste the most time:

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pipeline takes 20–40 min, "feels slow" | Stages are sequential that could be parallel; build artifacts are not cached between jobs | Parallelize independent stages; cache `node_modules`, `.venv`, Go module cache, Maven `.m2` keyed to the dependency lockfile hash |
| A gate fails intermittently ("flaky gate") | Network call in a test with no retry, race in a concurrent test, shared mutable state between tests, non-deterministic ordering | Identify the specific test with `pytest --reruns 3`; assert idempotency; use `pytest-xdist` with `--forked` to isolate |
| Pipeline is green; local build fails (opposite of "works on CI only") | Dev machine has a transitive dependency pinned differently, or an env var set globally that the pipeline doesn't set | Reproduce in Docker: `docker run --rm -v $(pwd):/app python:3.11-slim sh -c 'cd /app && pip install -r requirements.txt && pytest'` |
| "Works on CI only" — green pipeline, broken locally | CI has an env var, secret, or file that the dev machine doesn't; or the CI runner has a different binary version (e.g. `node 20` vs `node 18`) | Print all env vars in CI (`env | sort`); pin tools to exact versions in the pipeline; document the prerequisite versions in `README` or `Makefile` |
| One slow test blocks the entire pipeline queue | No timeout on individual tests; no sharding; the test spins up a real HTTP service on each run | Add `timeout` at the pytest fixture level; shard the suite across runners; mock external services in unit tests |
| Pipeline is green but prod broke | A required gate was overridden via the `--force` merge; a deploy gate runs *before* the smoke test completes | Audit the branch protection bypass log; move smoke to *before* the deploy completes (or make it a post-deploy required check) |

### Diagnosing a slow pipeline — the exact method

The fastest way to find the bottleneck is to look at the job timeline in the UI (GitHub Actions → summary → job graph) and find the longest path from commit to green. Then attack the critical path:

```bash
# time individual test files to find the slow outliers
pytest tests/ -v --durations=20

# profile where Docker build time goes
BUILDKIT_PROGRESS=plain docker build . 2>&1 | grep -E '^#[0-9]+ (CACHED|[0-9]+\.[0-9]+s)'
```

> **War story.** A microservice I inherited at SAP had a 38-minute pipeline. The culprit: the integration test stage was pulling a 1.2 GB Kafka image from Docker Hub on *every run*, on every branch push, because the runner's Docker cache was never persisted between jobs. The fix: push the image to GHCR once in a scheduled job, use `registry-cache` in `docker buildx`, and reference the pre-pulled image in integration tests. Pipeline dropped to 11 minutes. The second bottleneck — a sequential scan that ran *after* a 10-minute e2e suite — cost another 5 minutes that shifted to parallel. Down to 6 minutes total from 38. The actual change to the tests: zero lines. The change to the pipeline YAML: 40 lines.

---

## Checkpoint

You're ready to move on when you can answer without hesitation:

1. State the precise difference between continuous *delivery* and continuous *deployment*, and give a real-world reason to choose delivery over deployment.
2. Draw the stage graph for a Python microservice pipeline from commit to staging, with the correct failure semantics at each stage.
3. Explain why "fail fast" means ordering linting before unit tests, and unit tests before Docker builds.
4. Name three concrete symptoms that indicate a build is not reproducible.
5. Distinguish a gate from a stage; give one example of each from GitHub branch protection.
6. Explain why trunk-based development and a fast pipeline are co-dependent — why you need both, not just one.
7. Name the two most common causes of a 40-minute pipeline, and the two-step fix for each.
8. Describe the exact method to find the critical path in a slow GitHub Actions pipeline without reading the YAML.

➡ Next up: **GitHub Actions, Deeply** — workflows, jobs, matrix builds, OIDC, and all the sharp edges.
