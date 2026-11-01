# Deployment Strategies

> **Module 05 · Course 25** — Shipping is risk. Every deployment strategy in this module is a different answer to the same question: *how do you move traffic from version N to version N+1 while keeping your error budget intact?*

You have done rolling updates in production. This module pushes past the defaults: when to force Recreate, when blue-green is the right call despite the resource cost, how canary + progressive delivery works at the Kubernetes API level, how to wire automated rollback on an SLO breach, and — the piece most tutorials skip — database migrations in a pipeline without dual-version breakage.

---

## Recreate vs Rolling Update

These two strategies are baked into every Kubernetes Deployment. Every other pattern (blue-green, canary) is built on top of them.

### Recreate

```yaml
strategy:
  type: Recreate
```

Kubernetes terminates every old pod, then starts the new ones. Gap equals downtime. Use it when:

- The new version is **process-incompatible** with the old: shared in-memory session format changed, exclusive file lock on a data directory, incompatible port binding.
- You are deliberately testing cold-start behaviour — init containers, observability agent bootstrap, DNS warm-up time.
- The workload carries zero traffic: a batch migration tool, a one-off data backfill job.

Never use Recreate for a customer-facing API unless you have announced a maintenance window.

### Rolling Update

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1          # extra pods above desired count during the rollout
    maxUnavailable: 0    # no old pod is killed until the replacement passes readiness
```

Kubernetes replaces pods one batch at a time, gated by readiness probes. `maxUnavailable: 0` ensures served capacity never drops below the desired replica count — the correct setting for latency-sensitive APIs.

| Field | Safe default | When to adjust |
|-------|-------------|----------------|
| `maxSurge` | `1` or `25%` | Increase for faster rollouts where extra capacity is cheap |
| `maxUnavailable` | `0` | Increase to `1` only for batch workloads that can absorb one pod gap |

**The shallow-probe trap.** A readiness probe that checks `/healthz` and returns 200 before the database connection pool is warm lets a bad pod enter rotation while old pods are already killed. Probe the real traffic path:

```yaml
readinessProbe:
  httpGet:
    path: /ready              # handler that pings DB, checks cache reachability
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3         # 15s of failure before the pod is pulled from the LB
```

---

## Blue-Green

Blue-green runs two identical environments. One is live (`blue`); the other (`green`) bakes the new version. The cut-over is a Service selector change — atomic, zero-downtime, reversible in one command.

```
                    ┌──────────────────────┐
                    │   Service (prod)     │
                    │  selector: v=blue    │  ← swap to v=green to cut over
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼──────────────────┐
             ▼                                    ▼
   ┌─────────────────┐               ┌─────────────────┐
   │  Deployment     │               │  Deployment     │
   │  v=blue (live)  │               │  v=green (baking│
   │  10 replicas    │               │  10 replicas)   │
   └─────────────────┘               └─────────────────┘
```

The cut-over sequence:

```bash
# Wait for green to be fully ready before touching traffic
kubectl rollout status deployment/orders-green --timeout=5m

# Atomic selector swap — zero downtime
kubectl patch service orders-prod \
  -p '{"spec":{"selector":{"version":"green"}}}'

# Confirm endpoints switched
kubectl get endpoints orders-prod   # should list only green pod IPs
```

Rollback:

```bash
kubectl patch service orders-prod \
  -p '{"spec":{"selector":{"version":"blue"}}}'
```

**Cost:** double the pod count during the bake window. Acceptable for an API tier with tens of replicas; expensive for memory-heavy workloads with hundreds.

**When blue-green wins over rolling:** any schema change that causes the old binary to fail on new rows (before the rolling update finishes) creates a dangerous dual-version window where v1 and v2 pods share live traffic simultaneously. Blue-green eliminates that window — all-or-nothing cut-over.

---

## Canary

A canary routes a small slice of production traffic to the new version before committing the full rollout. You validate on real traffic, not synthetic tests.

### The label-split approximation

With 9 v1 pods and 1 v2 pod, a Service selecting `app: orders` (without a version selector) sends roughly 10% of requests to v2:

```yaml
# v2 canary Deployment — 1 of 10 total pods
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders
      version: v2
```

This works but is coarse: you cannot set exactly 5% without fractional pods, the split is request-count weighted (not byte-weighted), and there is no built-in automatic rollback.

### Progressive delivery with Argo Rollouts

Argo Rollouts replaces the `Deployment` kind with a controller that owns the traffic-split loop:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: orders
spec:
  replicas: 10
  strategy:
    canary:
      steps:
      - setWeight: 5           # 5% of traffic → canary
      - pause: {duration: 5m}  # automated soak; controller holds here
      - setWeight: 20
      - pause: {}              # manual gate — no duration means wait for human approval
      - setWeight: 50
      - pause: {duration: 10m}
      - setWeight: 100
      analysis:
        templates:
        - templateName: success-rate
        startingStep: 1        # analysis runs from the first setWeight onward
```

`pause: {}` without a duration is the **manual gate** idiom. A human promotes or rolls back via:

```bash
kubectl argo rollouts promote orders    # advance to the next step
kubectl argo rollouts abort orders      # roll back to stable revision
```

Put a manual gate at the 20% step — the point where a human should review dashboards before widening to half of traffic.

### Automated rollback on SLO breach

Define an `AnalysisTemplate` that queries your metrics backend. When the analysis fails, Rollouts aborts automatically:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
  - name: deployment-name
  metrics:
  - name: success-rate
    interval: 1m
    successCondition: result[0] >= 0.99    # 99% success rate floor
    failureLimit: 2                         # two consecutive failures trigger rollback
    provider:
      prometheus:
        address: http://prometheus:9090
        query: |
          sum(rate(http_requests_total{
            status=~"2..",
            deployment="{{args.deployment-name}}"
          }[2m]))
          /
          sum(rate(http_requests_total{
            deployment="{{args.deployment-name}}"
          }[2m]))
```

When `success-rate` drops below 0.99 for two consecutive evaluation windows, Argo Rollouts halts the rollout and reverts to the stable revision automatically. No page, no 2am kubectl surgery.

---

## Feature Flags

A feature flag decouples **deployment** from **release**: ship the new code binary to 100% of pods, keep the feature dark with a flag, then activate independently of any pod restart.

```
deploy v2 (feature=off, ships to all pods)
  → flag on 1% (internal)
    → flag on 10% (beta users)
      → flag on 100%
        → cleanup: remove flag + dead code path in v3
```

Feature flags and progressive delivery address different risk surfaces:

| Tool | Controls | Use for |
|------|---------|---------|
| Progressive delivery (canary) | Traffic weight | Infrastructure risk: crash rate, latency, error budget |
| Feature flag | Code path per user/segment | Product risk: UX, conversion, A/B test |

Both can operate simultaneously: canary at 10% of traffic + feature flag at 50% inside that canary = 5% total exposure of the new behaviour.

---

## Database Migrations in a Pipeline

Schema changes are where most "elegant" deploy strategies collapse. New pods expect new schema; old pods expect old schema. If v1 pods are still serving traffic when the schema changes, you get errors in both directions.

**The expand/contract pattern** keeps every migration backward-compatible across the dual-version window:

```
Phase 1 — Expand (additive only; backward-compatible):
  migration : ALTER TABLE orders ADD COLUMN status VARCHAR(20) DEFAULT 'active' NOT NULL
  deploy    : v2 code (reads + writes status; old code ignores new column safely)

Phase 2 — Validate:
  all pods are v2; no v1 replica in rotation; status fully populated

Phase 3 — Contract (remove the now-dead paths):
  migration : ALTER TABLE orders DROP COLUMN old_status  ← safe: nothing reads it
  deploy    : v3 code (old_status reference removed from ORM)
```

Rules for the expand phase: only `ADD COLUMN ... DEFAULT ...`, add nullable FK, add index. Never `DROP`, `RENAME`, or add `NOT NULL` without a `DEFAULT` in an expand migration.

Enforce the order with `needs` in GitHub Actions:

```yaml
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - run: |
        # Exit non-zero if there are unapplied migrations — fail fast before deploy
        python manage.py migrate --check
        python manage.py migrate

  deploy:
    needs: migrate             # deploy job does not start if migrate job fails
    runs-on: ubuntu-latest
    steps:
    - run: kubectl set image deployment/orders app=$IMAGE_TAG
    - run: kubectl rollout status deployment/orders --timeout=5m
```

The `--check` flag turns schema drift into a CI failure before any code ships.

---

## Debugging Deployment Strategies

Most "the deploy went wrong" incidents match one of the following patterns. Check these before escalating.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| New pods pass readiness and liveness but serve 5xx; no automatic rollback | Readiness probe checks a shallow `/health` that returns 200 before dependencies are warm; bad pods enter rotation undetected | Deepen the probe to verify a real dependency (DB ping, cache reachability); tighten `failureThreshold` |
| `kubectl rollout undo` reverts the Deployment spec but errors continue | Blue-green: the Service selector was not reverted; traffic still reaches the new Deployment despite the undo | `kubectl patch service` to restore the old selector; confirm with `kubectl get endpoints` |
| Canary at 10% shows elevated p99; rollout promotes automatically | `AnalysisTemplate` absent, or the Prometheus query aggregates the whole service label (not the canary subset) | Add an AnalysisTemplate; ensure the query's label selectors target the canary pod set by its version label |
| Migration ran; old pods in rotation start returning 500; `kubectl rollout undo` makes it worse | Non-backward-compatible migration (NOT NULL no DEFAULT, DROP, RENAME) landed while v1 pods were still serving; reverted code is now broken against new schema | Write a hotfix expand migration (add the DEFAULT); redeploy v2; schedule the proper v3 contract cleanup |
| Pods stuck `Terminating` for several minutes during rolling update; in-flight requests fail | `terminationGracePeriodSeconds` too short; pods receive SIGTERM and close while the load balancer still routes to them | Add `preStop: exec: command: ["/bin/sleep","5"]` to drain the LB; raise `terminationGracePeriodSeconds` to 60 |

> **War story.** A payment service running on shared infrastructure executed a rolling update during peak traffic. The migration added a `NOT NULL` column with no default — the expand phase was skipped because the engineer "just wanted to clean up the model." Old pods, still serving traffic for the four-minute duration of the rolling update, tried to SELECT the new column from existing rows. The ORM got NULLs where it expected a string and raised an exception on every read — turning a schema cleanup PR into a full SEV-2. The on-call ran `kubectl rollout undo` immediately. It made things worse: the reverted code was now running against the already-committed migration. The fix took 90 minutes: a hotfix migration adding `ALTER COLUMN status SET DEFAULT ''`, a redeploy, and a post-mortem that ended with a migration linter added to CI. The linter is a 40-line Python script that parses the migration file and fails any PR that adds a `NOT NULL` column without a `DEFAULT` in what is labelled an expand phase.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State the one production scenario where `Recreate` is acceptable, and why `RollingUpdate` cannot be used there.
2. Write the `strategy` stanza that guarantees zero capacity drop during a rolling update.
3. State the single kubectl command that cuts over a blue-green deployment and the single command that rolls it back.
4. Explain why 9 v1 pods + 1 v2 pod approximates (not equals) a 10% canary traffic split.
5. Write an Argo Rollouts canary step sequence: 5% automated 5-minute soak, 20% manual gate, 50% for 10 minutes, then 100%.
6. Describe the three phases of expand/contract and explain why compressing them into one deploy breaks in-rotation pods.
7. Explain what `needs: migrate` does in a GitHub Actions workflow and what the `--check` flag in the migration step buys you.
8. Given a canary that auto-promoted despite elevated p99 latency, name the two places to check first.

➡ Next: **GitOps & Workflow Engines** — how CI and CD hand off ownership of the image, and why the handoff is cleaner as a pull than a push.
