# Canary Rollout: Traffic Split by Replica Ratio

The post-mortem from last quarter's outage has one clear mandate: *no more
big-bang rollouts.* v1.1 passed QA and the PM gave sign-off for **10% of
production traffic** — not a full cut-over. The SRE playbook calls for a canary:
two Deployments behind one Service, traffic split by replica count, stable
untouched until confidence builds. Your cluster already has the stable
Deployment running in `dojo-cicd`. Your job: add the canary.

## Context

`setup.sh` applies a stable `dojo-web-stable` Deployment (3 replicas) and a
`dojo-web` Service to namespace `dojo-cicd`, then plants a starter
`canary.yaml` in your work directory:

```
~/.kube-dojo-work/05-canary-rollout/
└── canary.yaml    # stub — complete and apply this
```

```bash
kubectl -n dojo-cicd get deployments,services
# NAME                        READY   ...
# deployment.apps/dojo-web-stable   3/3     ...
# service/dojo-web                  ClusterIP ...
```

## Prerequisites

`kind` cluster named `dojo` running:

```bash
kubectl config current-context   # -> kind-dojo
kubectl -n dojo-cicd get pods    # 3 stable pods
```

## Mission

Complete `canary.yaml` (a Deployment manifest in `~/.kube-dojo-work/05-canary-rollout/`)
and apply it. The verifier checks:

| Check | Assertion |
|-------|-----------|
| Stable running | Deployment with `track=stable` has ≥ 1 ready replica in `dojo-cicd` |
| Canary running | Deployment with `track=canary` has ≥ 1 ready replica in `dojo-cicd` |
| Shared label | Both Deployments' pod templates carry the same `app` label value |
| Service covers both | A Service in `dojo-cicd` has `spec.selector.app` matching that shared label |

**Canary Deployment requirements:**

- Namespace: `dojo-cicd`
- Pod template labels must include: `app: dojo-web` (shared with stable), `track: canary`
- `spec.selector.matchLabels` must include `track: canary` (keeps canary pods isolated from stable's selector)
- Replicas: 1 (gives ~25% traffic — 1 canary pod vs 3 stable pods)
- Image: `nginx:1.27-alpine` (same image; in a real deployment this would be the new version)

The `dojo-web` Service already selects `app: dojo-web` — it routes to whichever
pods carry that label, regardless of `track`. Because kube-proxy load-balances
across all matching endpoints, replica count is the traffic knob.

## Why replica-ratio canary matters

Without a service mesh, you have no per-request routing. The Service sends each
new connection to a random endpoint from its selector pool. With 3 stable + 1
canary = 4 endpoints, roughly 25% of traffic hits the canary. That's enough
to detect a regression on real user traffic before you scale stable down.

The progression: **1 canary / 4 total → watch metrics → scale canary to 3,
stable to 0 → full rollout**. The rollback is `kubectl scale deploy dojo-web-canary
--replicas=0 -n dojo-cicd`. No DNS change, no Service edit, no downtime.

## Verify

```bash
bash courses/course-25-cicd/challenges/05-canary-rollout/verify.sh
```
