# Provision a Tenant Namespace

Your platform team just got a ticket: "Onboard team Falcon — they need their own isolated slice of the cluster." You've done this on prod before, but informally. Now you're codifying the pattern so any junior engineer can replicate it safely.

A **tenant namespace** is not just `kubectl create namespace`. Without a ResourceQuota, one misbehaving pod can starve the node. Without a LimitRange, containers launch with no resource constraints and the scheduler loses its placement signal. Without a scoped RoleBinding, the team either can't deploy at all, or worse — you give them cluster-wide edit and they accidentally break another team's service.

## Mission

Provision namespace `dojo-tenant-a` with the full governance layer. The verifier checks **all** of the following:

1. **A ResourceQuota** named anything, with hard limits set for **`pods`**, **`cpu`**, and **`memory`**.
2. **A LimitRange** named anything, with at least one default container limit and/or request.
3. **A RoleBinding** in `dojo-tenant-a` that references **roleRef `edit`** (the built-in ClusterRole) and binds **ServiceAccount `tenant-operator`** (already created in `dojo-tenant-a` by setup.sh).

> The binding must be *namespace-scoped* (a RoleBinding, not a ClusterRoleBinding) — granting `edit` across the cluster would defeat the purpose.

## Why this trio matters

| Primitive | Without it | With it |
|-----------|------------|---------|
| ResourceQuota | One tenant pod loop can exhaust all node CPU/memory | Scheduler enforces hard ceilings; burst is bounded |
| LimitRange | Containers launch as BestEffort (no requests) → first OOM victim | Default requests/limits injected so pods get a QoS class even without explicit manifests |
| RoleBinding (scoped) | Team either has no access or cluster-wide blast radius | Principle of least privilege — full app-level edit, zero cross-tenant visibility |

## Suggested values (you pick the numbers, these are enough)

```yaml
# ResourceQuota
hard:
  pods: "10"
  cpu: "4"
  memory: 4Gi

# LimitRange (default container)
default:
  cpu: 200m
  memory: 128Mi
defaultRequest:
  cpu: 100m
  memory: 64Mi

# RoleBinding
roleRef.name: edit
subjects[0].kind: ServiceAccount
subjects[0].name: tenant-operator
subjects[0].namespace: dojo-tenant-a
```

Run the verifier once all three objects are in place:
```bash
bash courses/course-09-platform-engineering/challenges/04-tenant-namespace/verify.sh
```
