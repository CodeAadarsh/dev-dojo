# GitOps Handoff: CI Builds, CD Syncs

The platform team drew the architectural boundary in the post-mortem doc:
*"CI is allowed to build, test, and push. CI is not allowed to touch the
cluster."* The new rule: after a successful build, CI updates the image tag in
Git; ArgoCD reconciles the rest. This is the CI/CD handoff — and it is also
the reason your incident playbook has fewer "who ran `kubectl apply` and when?"
questions.

Your task: model that handoff with an ArgoCD Application that auto-syncs a
Git repository path into namespace `dojo-cicd-gitops`.

## Context

This is a **BRIDGE challenge** — it requires ArgoCD installed in the cluster.

```bash
# If not yet installed:
bash labs/bootstrap/install-argocd.sh
kubectl -n argocd get pods   # all Running before proceeding
```

`setup.sh` creates namespace `dojo-cicd-gitops` and plants an
`application.yaml` stub in your work directory:

```
~/.kube-dojo-work/06-gitops-handoff/
└── application.yaml   # complete and apply this
```

## Prerequisites

```bash
kubectl config current-context   # -> kind-dojo
kubectl -n argocd get pods       # ArgoCD pods Running
```

## Mission

Complete `application.yaml` — an ArgoCD `Application` resource — and apply it
to the `argocd` namespace. The verifier asserts five conditions:

| Check | Assertion |
|-------|-----------|
| ArgoCD present | `argocd` namespace and `applications.argoproj.io` CRD exist |
| Application found | An Application with `spec.destination.namespace: dojo-cicd-gitops` exists in `argocd` |
| Automated sync | `spec.syncPolicy.automated` is set (not empty) |
| Synced | `status.sync.status` = `Synced` |
| Healthy | `status.health.status` = `Healthy` |

**Application requirements:**

- `metadata.namespace: argocd`
- `spec.source.repoURL`: any public Git repo; the ArgoCD guestbook example
  (`https://github.com/argoproj/argocd-example-apps.git`, path `guestbook`)
  is a reliable choice with no auth.
- `spec.destination.server: https://kubernetes.default.svc` (the in-cluster API)
- `spec.destination.namespace: dojo-cicd-gitops`
- `spec.syncPolicy.automated` must be present (enabling automated reconciliation)

## The CI/CD boundary explained

```
┌─────── CI pipeline ───────────────────────────────────────┐
│  1. git push → trigger                                    │
│  2. test + build image → registry.example.com/app:a1b2c3 │
│  3. update deploy/app.yaml image tag in Git               │
│  4. git push → GitOps repo ─────────────────────┐        │
└───────────────────────────────────────────────── │ ───────┘
                                                   ▼
┌─────── CD (ArgoCD) ───────────────────────────────────────┐
│  5. detects Git drift  →  spec.image differs from cluster │
│  6. kubectl apply the updated manifest                    │
│  7. reports Synced + Healthy                              │
└───────────────────────────────────────────────────────────┘
```

CI never holds cluster credentials. ArgoCD never runs tests. The handoff is a
`git push` — immutable, auditable, reversible with `git revert`.

## Verify

```bash
bash courses/course-25-cicd/challenges/06-gitops-handoff/verify.sh
```
