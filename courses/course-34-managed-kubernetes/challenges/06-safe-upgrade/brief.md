# Safe Node-Pool Upgrade

Post-mortem, 14:22 UTC:

> **Incident INC-4471 — Checkout degraded, 8 minutes.**
>
> Root cause: Ops drained node `ip-10-0-1-47` during a planned k8s patch upgrade. A PodDisruptionBudget existed but its `matchLabels` used `app: payment` while the Deployment's pod template used `app: checkout`. The PDB matched zero pods. All three replicas were evicted simultaneously. A new pod was scheduled but failed its first probe requests because it started taking traffic before it was warm. Total disruption: 8 minutes.

You are writing the upgrade playbook that closes this gap — not documentation, but the actual manifests that make drains safe.

## Prerequisites

```bash
python3 -c "import yaml; print('ok')"   # must print "ok"
# if it errors: pip3 install pyyaml
```

No kind cluster required. Verifier parses the manifests you author on disk.

## Context

`setup.sh` creates:

```
~/.kube-dojo-work/06-safe-upgrade/
├── deployment.yaml   # checkout-api Deployment skeleton — missing readiness probe and
│                     # rolling-update config still allows maxUnavailable=1
└── pdb.yaml          # PodDisruptionBudget skeleton — minAvailable=0, selector unset
```

## The upgrade procedure (control plane → node pool)

EKS, GKE, and AKS all follow the same logical order:

1. **Upgrade the control plane first.** Managed control planes are backward-compatible with kubelets one minor version older. Upgrading nodes before the control plane risks unsupported API skew.
2. **Cordon the old node pool** (`kubectl cordon`) — new pods won't schedule there, existing pods keep running.
3. **Drain nodes one at a time** — `kubectl drain --ignore-daemonsets --delete-emptydir-data`. The drain respects PDBs: if evicting a pod would violate the budget, it blocks and waits.
4. **Watch new nodes register** — `kubectl get nodes -w`. Drain the next node only after the replacement is `Ready`.
5. **Verify workloads** — check pod distribution, logs, and any smoke test before deleting the old pool.

The PDB is the safety net that turns step 3 from "hope for the best" into a guarantee.

## Mission

Edit the two manifest skeletons in your work directory so a node drain is safe.

### `deployment.yaml`

Two things must be true:

1. **Add a `readinessProbe`** on `containers[0]`. Use an `httpGet` probe against the path and port the container exposes. The probe determines when a pod is ready to receive traffic after a restart — without it, the Service sends traffic to booting pods and requests fail.

2. **Set `strategy.rollingUpdate.maxUnavailable: 0`**. This means the rolling update (and the drain, which is a forced rolling update) must never drop below the full desired replica count. Combined with `maxSurge >= 1`, it guarantees overlap: new pods are Ready before old pods are terminated.

### `pdb.yaml`

One thing must be true:

1. **Set `spec.minAvailable` to an integer ≥ 1** (or a percentage string like `"50%"`). This is the floor that `kubectl drain` will not breach. A `minAvailable: 2` on a 3-replica Deployment means a drain can evict at most 1 pod at a time — the other 2 stay up.

2. **Match the Deployment's pod labels.** The PDB's `spec.selector.matchLabels` must match the pod template labels in the Deployment. A mismatched selector is the root cause of INC-4471.

## Exact verifier checks

`verify.sh` will pass only when **all** of these hold:

1. `pdb.yaml` contains a `PodDisruptionBudget` with `spec.minAvailable` set to an integer ≥ 1 or a non-zero percentage string (e.g. `"50%"`).
2. `deployment.yaml` contains a `Deployment` with `spec.template.spec.containers[0].readinessProbe` set.
3. `deployment.yaml` has `spec.strategy.type: RollingUpdate` (or omitted, which defaults to `RollingUpdate`).
4. `deployment.yaml` has `spec.strategy.rollingUpdate.maxUnavailable` set to `0` or `"0%"`.

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/06-safe-upgrade/verify.sh
```

All four checks green → flag printed.

## Why maxUnavailable: 0 matters during a drain

`kubectl drain` works by evicting pods. If `maxUnavailable: 1` (the default), Kubernetes allows one pod to be terminating before the drain waits. On a 3-replica Deployment, this means the drain can evict pod A, then immediately start evicting pod B before A's replacement is Ready — leaving you with 1 running pod serving 100% of traffic. Under load, that's degradation or timeout.

With `maxUnavailable: 0` and `maxSurge: 1`:
- Pod A is evicted only after its replacement is Ready and in the endpoints.
- Traffic is always served by ≥ N replicas.
- The PDB provides a hard cluster-level enforcement of the same guarantee, independent of the rolling update strategy.

The two settings (`maxUnavailable: 0` on the Deployment and `minAvailable >= 1` on the PDB) are complementary: the rolling update strategy protects against voluntary rolling deploys; the PDB protects against voluntary disruptions like drains, node-pool upgrades, and spot interruptions.
