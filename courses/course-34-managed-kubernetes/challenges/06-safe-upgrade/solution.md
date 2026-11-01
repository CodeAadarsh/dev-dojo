# Solution — Safe Node-Pool Upgrade

## deployment.yaml (complete, passing)

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: dojo-checkout
  labels:
    app: checkout
    version: "1.0"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: checkout
        version: "1.0"
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: checkout-api
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### Why each probe field matters

**`readinessProbe.httpGet`** — uses the HTTP protocol to check if the container is accepting requests. Kubernetes removes the pod from all Service endpoints while the probe is failing and adds it back when it passes. This is the mechanism that prevents traffic from hitting a booting pod.

**`initialDelaySeconds: 5`** — gives the container 5 seconds to start before the first probe fires. Too low: early failures mark the pod NotReady immediately. Too high: traffic doesn't reach the pod for longer than necessary after a deploy. 5 seconds is conservative; tune down if your app starts faster.

**`periodSeconds: 10`** — probe fires every 10 seconds. The pod becomes Ready after one success post-boot; becomes NotReady after `failureThreshold` consecutive failures.

**`failureThreshold: 3`** — 3 consecutive failures = 30 seconds of unhealthy state — before the pod is marked NotReady and removed from endpoints. This prevents a momentary blip (GC pause, one slow response) from pulling a pod out of rotation.

**`maxUnavailable: 0`** — the key change. Default is `maxUnavailable: 25%` (or 1 on small deployments). With `maxUnavailable: 0`, the rolling update (and any drain that evicts pods) must keep all desired replicas available at all times. The updater cannot terminate pod A until pod A's replacement has passed its readiness probe.

**`maxSurge: 1`** — allows one extra pod above `replicas` during a rollout. Required to be non-zero when `maxUnavailable: 0`, otherwise the updater has no room to add a new pod before removing the old one — it would deadlock.

---

## pdb.yaml (complete, passing)

```yaml
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api-pdb
  namespace: dojo-checkout
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: checkout
```

### Why each field matters

**`spec.minAvailable: 2`** — on a 3-replica Deployment, this means at most 1 pod can be voluntarily evicted at a time. `kubectl drain` respects this: it will evict one pod, wait until a replacement is Ready (because the Deployment's rolling update logic will schedule one), then evict the next. Without a PDB, `kubectl drain` evicts all 3 pods simultaneously.

**`spec.selector.matchLabels: {app: checkout}`** — must match the pod template labels exactly. In INC-4471, the PDB used `app: payment` while the pod template used `app: checkout`. Result: zero pods matched, zero protection. This is the most common PDB misconfiguration in production.

`minAvailable: 2` vs `minAvailable: 1`: either passes the verifier. In practice:
- `minAvailable: 2` is safer for latency-sensitive services — always ≥ 2 healthy pods serving traffic.
- `minAvailable: 1` is acceptable if the service can handle the load on one instance and the drain is short-lived.
- `minAvailable: "67%"` (a percentage) automatically scales with `replicas` changes — preferred for deployments where replica count changes over time.

---

## The upgrade procedure (reference)

```bash
# 1. Upgrade the control plane first (cloud console or CLI).
#    eksctl upgrade cluster --name dojo-cluster --version 1.31 --approve

# 2. Cordon the old node pool — new pods stop scheduling here.
kubectl cordon <old-node-1> <old-node-2> ...

# 3. Drain one node at a time. The drain blocks on the PDB.
kubectl drain <old-node-1> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60

# 4. Wait for the replacement node to be Ready before draining the next.
kubectl get nodes -w

# 5. Repeat for each old node.
kubectl drain <old-node-2> --ignore-daemonsets --delete-emptydir-data

# 6. Verify pod spread across new nodes.
kubectl get pods -n dojo-checkout -o wide

# 7. Delete the old node group once all workloads have migrated.
```

---

## Debugging upgrade failures

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `drain` hangs with `Cannot evict pod as it would violate the pod's disruption budget` | PDB `minAvailable` is blocking — this is correct behaviour | Check if replacement pods are coming up; if stuck, debug the new node with `kubectl describe node <new-node>` |
| `drain` completes instantly but pods vanish | PDB selector doesn't match any pods (INC-4471) | `kubectl get pdb -o yaml` — check selector matches pod labels exactly |
| New pods stuck `Pending` after drain | New node pool not Ready yet, or node has taint rejecting pods | `kubectl describe pod <pending-pod>` — check `Events` for scheduling failure reason |
| Pod terminates but traffic still fails for ~30 seconds | `terminationGracePeriodSeconds` too short; app needs longer to drain connections | Increase `terminationGracePeriodSeconds` and add a `preStop: exec: sleep 5` hook to let the endpoints propagate before the container exits |
| Rolling update deadlocks with `0/1 nodes are available` | `maxUnavailable: 0` + `maxSurge: 0` — no room to add or remove | Set `maxSurge: 1` — required when `maxUnavailable: 0` |
