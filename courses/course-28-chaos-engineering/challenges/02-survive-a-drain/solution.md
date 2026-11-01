# Solution — Survive a Drain

## Step 1 — Create the PDB (before any drain)

```yaml
# web-pdb.yaml
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
```

```bash
kubectl apply -f web-pdb.yaml

# Verify the PDB sees all three pods and allows 1 disruption at a time
kubectl -n dojo-chaos get pdb web-pdb
# NAME      MIN-AVAILABLE   MAX-UNAVAILABLE   ALLOWED-DISRUPTIONS   AGE
# web-pdb   2               N/A               1                     5s
```

`ALLOWED-DISRUPTIONS: 1` means the drain can evict at most one pod at a time (3 ready - 2 min = 1 budget).

## Step 2 — Drain a worker node

```bash
# List nodes — pick a dojo-worker, not dojo-control-plane
kubectl get nodes
# NAME                  STATUS   ROLES           AGE   VERSION
# dojo-control-plane    Ready    control-plane   10m   v1.29.0
# dojo-worker           Ready    <none>          10m   v1.29.0
# dojo-worker2          Ready    <none>          10m   v1.29.0

# Drain dojo-worker (adjust name if your cluster differs)
kubectl drain dojo-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=10
```

In a second terminal, watch the PDB-rate-limited evictions:

```bash
kubectl -n dojo-chaos get pods -o wide -w
```

You'll see: one pod evicted → replacement starts on the surviving worker → replacement becomes Ready → next eviction proceeds. The count of Ready pods never drops below 2.

## Step 3 — Verify

```bash
bash courses/course-28-chaos-engineering/challenges/02-survive-a-drain/verify.sh
```

## Step 4 — Cleanup

```bash
kubectl uncordon dojo-worker
kubectl -n dojo-chaos delete pdb web-pdb
```

## Why `kubectl delete pod` bypasses the PDB

The Eviction API (`POST /api/v1/namespaces/{ns}/pods/{name}/eviction`) is distinct from the Delete API. The Eviction API checks PDBs; the Delete API does not. `kubectl drain` uses the Eviction API. `kubectl delete pod` uses the Delete API. This is why you can always `kubectl delete pod` your way past a PDB — it's not a hard lock, it's a policy on the eviction path.

Real chaos tooling (Chaos Mesh, Litmus) that wants to respect PDBs must use the Eviction API. `kubectl drain` respects it. Directly deleting does not.

## Integer vs percentage minAvailable

`minAvailable: 2` works for a fixed-size Deployment. For auto-scaling deployments, use `minAvailable: "66%"` — it recalculates the floor as replicas change. The verifier handles integer minAvailable; for the dojo, use the integer form.

## Why the control-plane node is excluded from the check

kind's control-plane node has a `node-role.kubernetes.io/control-plane:NoSchedule` taint by default, so workload pods don't land on it anyway. The verifier skips control-plane nodes in its cordoned-node check so you're not penalized for a taint that already keeps your app off that node.
