# GitOps & Workflow Engines

> **Module 06 · Course 25** — CI answers "is this code good enough to ship?" CD answers "is it actually running in prod?" Most pipeline problems come from blurring those two questions. This module draws the line clearly, shows how Argo CD picks up where GitHub Actions puts down, and covers when to reach for Argo Workflows or Tekton instead of bolting more YAML onto your GHA pipeline.

You have a pipeline that builds, tests, and pushes an image. This module covers the handoff after that push: how the image tag gets into a cluster, how progressive rollouts are driven from config rather than CI scripts, and when pipeline-as-CRDs give you things a hosted CI runner cannot.

---

## Push Delivery vs Pull Delivery

The difference between push and pull is who initiates the apply — and it turns out that matters a lot at 3am.

### Push delivery

```
CI job (GitHub Actions) ──── kubectl apply ──── cluster
        ↑ has kubeconfig
        ↑ has cluster credentials in repo secrets
```

The CI runner holds credentials and directly mutates the cluster. Simple to set up, but:

- **Credential sprawl.** Every pipeline that deploys needs cluster credentials. A compromised workflow or a leaked `KUBECONFIG` secret = an attacker with `cluster-admin`.
- **No drift detection.** If someone edits a live Deployment with `kubectl edit` and then CI does not run for a week, the cluster silently diverges from Git.
- **No rollback audit trail.** "Who applied what and when" lives in workflow run logs, not in a persistent source of truth.

### Pull delivery (GitOps)

```
CI job ──── git commit (image tag) ──── Git repo (config)
                                               ↑
                                    Argo CD watches repo
                                               │
                                    Argo CD ────── kubectl apply ──── cluster
                                    (runs inside the cluster; no outbound creds needed)
```

The cluster reaches out to Git, not the other way around. The source of truth is a Git repo. Every cluster state is a commit. Every rollback is `git revert`.

**Drift detection for free.** Argo CD compares live cluster state to the HEAD of the target branch every few minutes (configurable). A manual `kubectl edit` shows up as `OutOfSync` in the Argo CD UI within seconds. You can configure auto-sync to revert it, or leave it manual for human approval.

---

## The CI/CD Handoff Pattern

The canonical GitOps handoff separates two repositories: one for application code, one for deployment config.

```
┌──────────────────────────────────────────────────────┐
│  app-repo (github.com/org/orders)                    │
│                                                      │
│  push → GHA: test → build → docker push              │
│                              │                       │
│                    image: orders:sha-a3b4c5d         │
│                              │                       │
│                   GHA commits to config-repo ────────┤
└──────────────────────────────────────────────────────┘
                                │
┌──────────────────────────────────────────────────────┐
│  config-repo (github.com/org/k8s-config)             │
│                                                      │
│  apps/orders/deployment.yaml                         │
│    spec.template.spec.containers[0].image:           │
│      orders:sha-a3b4c5d   ← GHA updated this        │
└──────────────────────────────────────────────────────┘
                                │
                    Argo CD detects new commit
                    Argo CD kubectl apply → cluster
```

The GHA workflow that commits the new tag:

```yaml
- name: Update image tag in config repo
  env:
    GITHUB_TOKEN: ${{ secrets.CONFIG_REPO_TOKEN }}
  run: |
    git clone https://x-access-token:$GITHUB_TOKEN@github.com/org/k8s-config.git config
    cd config
    # sed is fine here: replace the exact tag line
    sed -i "s|orders:sha-.*|orders:sha-${{ github.sha }}|" apps/orders/deployment.yaml
    git config user.email "ci@org.com"
    git config user.name "CI Bot"
    git add apps/orders/deployment.yaml
    git commit -m "deploy orders sha-${{ github.sha }}"
    git push
```

The token scoped to the config repo is the only outbound credential CI needs. The cluster-facing `KUBECONFIG` never leaves the cluster.

> **Single-repo variant.** Many teams keep app code and config in the same repo under a `deploy/` directory. This is fine for small teams; separate repos scale better when multiple services share one config repo (one source of truth for cluster state regardless of which app changed).

---

## Argo CD in Practice

Argo CD is an operator that reconciles a Git path to a cluster namespace.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: orders
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/k8s-config
    targetRevision: main
    path: apps/orders
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated:
      prune: true          # delete resources removed from Git
      selfHeal: true       # revert manual kubectl edits automatically
    syncOptions:
    - CreateNamespace=true
```

`selfHeal: true` is the operational discipline enforcer — it makes "just quickly edit the live Deployment" impossible to sustain. Your Git repo is the cluster. Anything not in Git gets reverted within minutes.

**Sync waves** let you sequence resources within a single sync:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"   # lower = earlier; migrations run before app pods
```

Run the database migration Job at wave `1`, the Deployment at wave `2`. Argo CD will not advance to wave 2 until wave 1 resources are healthy.

---

## Argo Rollouts — Progressive Delivery as a GitOps Primitive

Argo Rollouts (covered in Module 05) integrates directly with Argo CD: the CD sync updates the Rollout spec, and the Rollouts controller handles the traffic-split loop. The CD layer never sees percentages — it just applies YAML.

```
config-repo: image tag updated
    → Argo CD syncs Rollout resource
      → Argo Rollouts controller begins canary steps
        → AnalysisTemplate queries Prometheus
          → on success: Rollouts promotes to 100%
          → on failure: Rollouts aborts; Argo CD shows OutOfSync on the running pods
```

This keeps the CI pipeline free of deployment logic: CI builds, tags, and commits. Every deployment decision — when to promote, when to roll back — lives in the cluster, queryable with `kubectl`.

---

## Argo Workflows vs Tekton vs GitHub Actions

When should you reach for a cluster-native workflow engine rather than GitHub Actions?

### GitHub Actions

Use it for: CI (test, lint, build, push). It runs on managed runners, has a huge ecosystem of community actions, and the YAML is familiar to every engineer. **Weakness:** runners are ephemeral VMs outside your cluster; they cannot directly mount PVCs, cannot schedule GPU pods, and cannot run multi-hour data pipelines cost-effectively.

### Argo Workflows

Pipeline-as-Kubernetes-CRD. Workflows are first-class Kubernetes objects, steps run as pods in your cluster, and outputs are stored as artifacts in object storage (S3/GCS/MinIO).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ml-pipeline-
spec:
  entrypoint: train-and-evaluate
  templates:
  - name: train-and-evaluate
    steps:
    - - name: preprocess
        template: python-step
        arguments:
          parameters:
          - {name: script, value: preprocess.py}
    - - name: train
        template: python-step
        arguments:
          parameters:
          - {name: script, value: train.py}
    - - name: evaluate
        template: python-step
        arguments:
          parameters:
          - {name: script, value: evaluate.py}

  - name: python-step
    inputs:
      parameters:
      - name: script
    container:
      image: python:3.11-slim
      command: [python, "{{inputs.parameters.script}}"]
      resources:
        requests:
          memory: "4Gi"
          cpu: "2"
```

Use Argo Workflows when: steps need GPU, need to mount persistent data volumes, run for hours, fan-out to hundreds of parallel pods, or depend on cluster-internal services (a feature store, a model registry).

### Tekton

Also pipeline-as-CRD, but designed specifically for CI/CD rather than general DAG workflows. The unit of reuse is a `Task` (a series of steps in one pod) combined into a `Pipeline`. More opinionated than Argo Workflows; integrates tightly with Tekton Triggers (event-driven pipeline kicks).

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: build-and-push
spec:
  steps:
  - name: build
    image: gcr.io/kaniko-project/executor:v1.23.1
    args:
    - --dockerfile=Dockerfile
    - --context=git://github.com/org/app
    - --destination=registry.example.com/app:$(params.tag)
```

Use Tekton when: you need in-cluster CI (air-gapped environments, compliance requirements preventing SaaS CI), or you want Tekton Catalog's growing ecosystem of reusable Tasks for common operations (git clone, buildah, skopeo, trivy scan).

### Decision matrix

| Criteria | GitHub Actions | Argo Workflows | Tekton |
|----------|--------------|----------------|--------|
| CI (test, lint, build) | Best fit | Possible | Possible |
| Multi-hour data pipeline | Poor (6h limit on hosted) | Best fit | Possible |
| GPU / PVC access | No | Yes | Yes |
| Air-gapped / on-prem CI | No | Yes | Yes |
| Ecosystem / community actions | Largest | Medium | Medium |
| Operational overhead | Zero | Medium | Medium |

In practice: use GHA for all CI, hand off to Argo CD for delivery, reach for Argo Workflows when pipelines need cluster resources that GHA runners cannot provide.

---

## Debugging GitOps & Workflow Engines

GitOps bugs have a short list of root causes. Most come down to which side of the CI/CD boundary you are debugging.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Argo CD shows `Synced` but pods are running the old image | CI committed a tag to the config repo but Argo CD's target revision is a branch that was not updated; or the commit went to a different path than the Application watches | Check the Application's `source.path` and `targetRevision`; confirm the config repo commit is on that branch at that path; `argocd app get <name>` shows exact Git SHA synced |
| Image tag in config repo is correct but pods pull the wrong image | Old pods with `imagePullPolicy: IfNotPresent` are still running; Kubernetes did not restart them because the Deployment spec hash did not change | Force a rollout: `kubectl rollout restart deployment/orders`; or change `imagePullPolicy` to `Always` for mutable tags (prefer SHA-pinned immutable tags) |
| Argo CD Application stays `OutOfSync` after a manual sync | Cluster has resources Argo CD cannot manage (different namespace, missing RBAC, a CRD not yet installed) | `argocd app sync <name> --debug`; look for `ComparisonError` in `argocd app get`; check that the AppProject grants access to the target namespace and resource group |
| GHA workflow completes but config repo commit never appears | The `CONFIG_REPO_TOKEN` has expired or lacks `contents:write`; the `git push` step exits 0 but was on a protected branch with required PR reviews | Check GHA step output for `remote: Permission to ... denied`; rotate the token; or use a GHA environment + bypass rule for the config commit bot |
| Argo Workflows pod stays `Pending` indefinitely | ResourceQuota or LimitRange in the workflow namespace blocks pod creation; or the ServiceAccount used by the workflow lacks pod create permission | `kubectl describe pod <workflow-pod>` for scheduler events; `kubectl describe resourcequota`; check RBAC with `kubectl auth can-i create pods --as=system:serviceaccount:argo:workflow-sa` |

> **War story.** A team had two things named `orders`: an Argo CD Application pointing at `apps/orders/` in the config repo, and a separate GHA workflow that was also doing `kubectl apply` directly against the cluster on every push to `main`. Both were "working" independently. The confusion surfaced when a rollback was needed: someone ran `argocd app rollback orders` to revert to the previous Git revision, but the GHA workflow ran 30 seconds later on an unrelated push and re-applied the bad version. The CD layer and the CI push-deploy were fighting each other. The fix was to delete the `kubectl apply` step from GHA and declare the config repo + Argo CD as the single deployment path — CI builds and commits, CD syncs, nothing else touches the cluster. The principle: **CI never touches a production cluster directly. If it can, it will.**

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State the three operational weaknesses of push delivery that pull delivery (GitOps) solves.
2. Describe the CI/CD handoff: what CI writes to the config repo and what Argo CD does with it.
3. Explain what `selfHeal: true` does in an Argo CD Application and when you would set it to `false`.
4. Describe sync waves in Argo CD and give the concrete example of a migration Job that must run before new pods start.
5. Name the two scenarios where Argo Workflows is a better fit than GitHub Actions.
6. Explain the "image tag drift" failure mode and the two ways to prevent it.
7. Given an Argo CD Application that shows `Synced` but pods are on the old image, list the two places to check first.
8. State the one principle the war story teaches about CI and production cluster access.

➡ Next: **Pipeline & Supply-Chain Security** — the pipeline itself is an attack surface, and most pipelines are configured as if it is not.
