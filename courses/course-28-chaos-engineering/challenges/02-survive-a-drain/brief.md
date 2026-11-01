# Survive a Drain

A production cluster upgrade requires draining nodes one at a time. Without a PodDisruptionBudget, `kubectl drain` is allowed to evict **all** pods on a node simultaneously — regardless of how many replicas you have. For a node that holds two of your three replicas, this means a period of one Ready pod (or zero). Kubernetes is perfectly happy to do this to you. You will prevent it.

## Mission

The setup deploys a 3-replica `web` Deployment in `dojo-chaos` with soft pod anti-affinity (pods prefer to spread across your two worker nodes).

**Part 1 — Add the PDB** before touching any node:

```bash
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: dojo-chaos
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
EOF
```

Verify the PDB sees your pods:

```bash
kubectl -n dojo-chaos get pdb web-pdb
# ALLOWED-DISRUPTIONS should be 1 (can lose 1 pod at a time, 2 must stay)
```

**Part 2 — Drain a worker node**:

```bash
# Find your worker names
kubectl get nodes

# Drain one worker — the PDB rate-limits evictions
kubectl drain <worker-node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=10
```

> `--ignore-daemonsets` is required: kind runs DaemonSet pods (kindnet, kube-proxy) on every node. Without this flag, drain refuses because it can't permanently evict them — the DaemonSet controller would immediately re-create them.

**Watch the drain in a second terminal:**

```bash
kubectl -n dojo-chaos get pods -o wide -w
```

You should see evictions happening one at a time, with a brief pause between each as the replacement pod becomes Ready.

## Target state (what `verify.sh` checks)

| Check | Required |
|-------|----------|
| Worker node | At least one has `SchedulingDisabled` (still cordoned post-drain) |
| PodDisruptionBudget | Exists in `dojo-chaos` with `spec.minAvailable` set |
| `readyReplicas` | ≥ `PDB.spec.minAvailable` |

You do **not** need to uncordon the node before running the verifier — the check is against post-drain steady state. Uncordon when you're done experimenting.

## How PDB enforcement actually works

The drain loop calls the **Eviction API** (`POST /api/v1/namespaces/{ns}/pods/{name}/eviction`) for each pod. This API checks every PDB that matches the pod. If evicting the pod would drop Ready count below `minAvailable`, the API returns `429 Too Many Requests` and the drain pauses. Once a replacement pod on another node becomes Ready and the PDB budget opens back up, the next eviction proceeds. This enforcement is in the API server — not just a suggestion.

Compare this to what `kubectl delete pod` does: it bypasses the Eviction API entirely and ignores PDBs. Chaos tooling must use the Eviction API to be disruption-budget-aware.

## Cleanup

```bash
kubectl uncordon <worker-node-name>
kubectl -n dojo-chaos delete pdb web-pdb
```
