# Solution — Budget for Disruption

One small object does it. A PDB is not owned by the Deployment — it's a standalone `policy/v1` resource that finds pods by label selector.

```yaml
# api-pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
  namespace: dojo-pdb
spec:
  minAvailable: 2            # keep at least 2 of the 3 pods up during voluntary disruptions
  selector:
    matchLabels:
      app: api               # MUST match the pods' labels, or the PDB protects nothing
```

Apply and verify:

```bash
kubectl apply -f api-pdb.yaml
kubectl -n dojo-pdb get pdb api-pdb      # ALLOWED DISRUPTIONS should read 1
bash courses/course-02-sre-production/challenges/03-pdb-protects-drain/verify.sh
```

## The imperative one-liner

```bash
kubectl -n dojo-pdb create pdb api-pdb --selector=app=api --min-available=2
```

Confirm it's actually counting your pods (this is the check that catches a wrong selector):

```bash
kubectl -n dojo-pdb get pdb api-pdb -o wide
# NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# api-pdb   2               N/A               1                     5s
```

`ALLOWED DISRUPTIONS: 1` is the proof: with 3 healthy pods and a floor of 2, the eviction API will let exactly **one** pod be evicted at a time. If this column reads `0` while pods are healthy, your selector is wrong — the PDB matched nothing (or matched a scaled-down set) and is protecting an empty set.

## Why each piece is correct

- **`minAvailable: 2` is an absolute floor, not a rate.** With 3 replicas it permits one disruption at a time. The eviction API computes `disruptionsAllowed = currentHealthy − desiredHealthy` (here `3 − 2 = 1`); when that hits 0, further `Evict` calls get a **429 Too Many Requests** and a cooperative drain backs off and retries.
- **The `selector` is the whole ballgame.** A PDB has no owner reference to the Deployment — it's glued to pods purely by `matchLabels`. A typo (`app: apii`) produces a perfectly valid PDB that matches **zero** pods, reports `ALLOWED DISRUPTIONS: 0` or an empty `expectedPods`, and gives you a false sense of safety. The verifier checks `status.expectedPods` precisely to catch this class of silent failure.
- **It only constrains the *Eviction API*.** `kubectl drain` goes through eviction, so a PDB throttles it. A `kubectl delete pod`, an OOM kill, or a kernel panic do **not** — they bypass eviction entirely. A PDB is a guardrail for *planned* maintenance, not a seatbelt for crashes.

## Prove it actually blocks a drain (optional, multi-node)

On the 3-node dojo cluster you can watch the PDB do its job. Drain a worker and observe that eviction proceeds pod-by-pod instead of all at once:

```bash
# which nodes are the api pods on?
kubectl -n dojo-pdb get pods -o wide

# cordon + drain one worker; --ignore-daemonsets is needed because kindnet/kube-proxy
# run as DaemonSets that a drain would otherwise refuse to evict.
kubectl drain dojo-worker --ignore-daemonsets --delete-emptydir-data

# in another terminal, watch: Ready count should never fall below 2
kubectl -n dojo-pdb get pods -w
```

If more than one `api` pod lives on `dojo-worker`, you'll see the drain evict one, then **pause** — the log line is the tell:

```
evicting pod dojo-pdb/api-...
error when evicting pods/"api-..." (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

The drain waits for the Deployment to reschedule a replacement onto another node and go Ready, which restores the budget, and only then proceeds. Uncordon when you're done so the scheduler can use the node again:

```bash
kubectl uncordon dojo-worker
```

## SRE framing — the traps a staff engineer checks for

- **A PDB can wedge a drain forever.** `minAvailable: 3` on a 3-replica Deployment means `disruptionsAllowed: 0` — *no* pod can ever be evicted, so a node drain hangs indefinitely and your cluster upgrade stalls. The budget must leave room for at least one disruption (`minAvailable < replicas`, or `maxUnavailable >= 1`). This is the single most common PDB outage: a well-intentioned tight budget that blocks all maintenance.
- **PDB + anti-affinity is the real zero-impact-drain recipe.** The PDB throttles the *rate* of eviction, but if all 3 pods landed on one node, that node's drain still takes you to the floor in one hop (just more slowly). Spread pods across nodes with `topologySpreadConstraints` or `podAntiAffinity` so a single node's drain only ever touches one pod.
- **`minAvailable` as a percentage rounds *up*.** `minAvailable: 50%` on 3 pods means "keep at least 2" (ceil of 1.5). Know your rounding, or a percentage budget on an odd replica count will be stricter than you expect.
- **Unhealthy pods count against you.** If pods are crash-looping, `currentHealthy` drops, `disruptionsAllowed` can go negative, and the drain is blocked even though the pods are already broken. The `unhealthyPodEvictionPolicy: AlwaysAllow` field (added in recent Kubernetes) lets you evict already-unhealthy pods regardless of the budget — worth setting for most workloads so a crash-loop doesn't also block node maintenance.
