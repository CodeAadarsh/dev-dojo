# Solution — Drain Without Downtime

## Step 0 — see where the pods are

You can only drain a node that actually holds `web` pods, so look first:

```bash
kubectl -n dojo-maint get pods -o wide
```

```
NAME                   READY   STATUS    NODE
web-6f...-aaaaa        1/1     Running   dojo-worker
web-6f...-bbbbb        1/1     Running   dojo-worker
web-6f...-ccccc        1/1     Running   dojo-worker2
```

Pick a worker that has at least one pod — say `dojo-worker`.

## Step 1 — cordon it

```bash
kubectl cordon dojo-worker
kubectl get nodes
# dojo-worker   Ready,SchedulingDisabled   ...
```

`cordon` only flips `.spec.unschedulable=true`. Nothing moves yet — but the scheduler will no longer place the replacement pods *back* onto this node, which is exactly what you want before you start evicting.

## Step 2 — drain it

```bash
kubectl drain dojo-worker \
  --ignore-daemonsets \
  --delete-emptydir-data
```

What you'll see is the whole lesson in motion:

```
node/dojo-worker already cordoned
evicting pod dojo-maint/web-6f...-aaaaa
evicting pod dojo-maint/web-6f...-bbbbb
error when evicting pods/"web-6f...-bbbbb" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod dojo-maint/web-6f...-bbbbb
pod/web-6f...-bbbbb evicted
node/dojo-worker drained
```

That `Cannot evict ... would violate the pod's disruption budget` line is **not an error you fix** — it's the Eviction API doing its job. Drain evicts the first pod, waits for the Deployment to schedule a replacement on `dojo-worker2` and pass its readiness probe (which restores `Available` back to 2), then retries and evicts the second. The PDB turned a bulk eviction into a safe, paced one.

## Step 3 — confirm and verify

```bash
kubectl -n dojo-maint get pods -o wide        # nothing on dojo-worker now
kubectl -n dojo-maint rollout status deploy/web
bash courses/course-05-internals-cluster-repo/challenges/03-node-maintenance-drain/verify.sh
```

## Why each flag was necessary

- **`--ignore-daemonsets`** — kind runs `kindnet` and `kube-proxy` as DaemonSets on every node. They're meant to be there and will be recreated immediately, so drain refuses to proceed until you explicitly say "yes, leave those." Without this flag the drain errors out before evicting anything.
- **`--delete-emptydir-data`** — any pod with an `emptyDir` volume is holding data that cannot be moved; drain won't silently destroy it. In this lab the data is disposable, so you authorize the deletion.
- **No `--force`** — `--force` evicts *bare* pods (not backed by a controller) that would otherwise block the drain. Reaching for `--force` out of habit is how people delete pods nothing will ever recreate. You didn't need it here, and you should treat it as a red flag when you do.

## Finish the maintenance (real world)

After the kernel patch and reboot, return the node to service:

```bash
kubectl uncordon dojo-worker
```

The scheduler starts placing pods there again. The verifier checks the mid-maintenance state, so you can run it before uncordoning.

## The anti-pattern this replaces

```bash
# DO NOT do this on a node with live pods:
kubectl delete node dojo-worker     # or a hard `docker kill`
```

That is a **non-graceful** disruption. Pods are declared gone without eviction, connections are severed mid-request, `terminationGracePeriodSeconds` is ignored, and the PDB is never consulted. `cordon` + `drain` routes the same end state through the Eviction API, which is the only mechanism that honors disruption budgets. That difference is the whole point of node maintenance.
