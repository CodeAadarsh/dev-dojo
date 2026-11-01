# Solution — Kill and Heal

## The steps

```bash
# Confirm all three pods are Ready
kubectl -n dojo-chaos get pods

# Inject chaos: delete all pods at once (or just one — the lesson is the same)
kubectl -n dojo-chaos delete pod -l app=web --force --grace-period=0

# Watch the controller's response
kubectl -n dojo-chaos get pods -w
```

You'll see something like:

```
NAME                   READY   STATUS              RESTARTS   AGE
web-6d8f9b7c4-abc12    0/1     Terminating         0          5m
web-6d8f9b7c4-def34    0/1     Terminating         0          5m
web-6d8f9b7c4-ghi56    0/1     Terminating         0          5m
web-6d8f9b7c4-jkl78    0/1     ContainerCreating   0          1s
web-6d8f9b7c4-mno90    0/1     ContainerCreating   0          1s
web-6d8f9b7c4-pqr12    0/1     ContainerCreating   0          1s
web-6d8f9b7c4-jkl78    1/1     Running             0          4s
...
```

Three new pods with new names. The controller saw observed < desired and immediately scheduled replacements.

```bash
# Once three pods are 1/1 Ready, run the verifier
bash courses/course-28-chaos-engineering/challenges/01-kill-and-heal/verify.sh
```

## Why it works — the reconciliation loop

A ReplicaSet's controller runs a reconciliation loop (~every 5s, plus event-driven triggers). On each loop:

1. List pods matching `spec.selector`.
2. Compare observed count to `spec.replicas`.
3. If observed < desired: create `(desired - observed)` new pods.
4. If observed > desired: delete `(observed - desired)` pods.

When you delete a pod, the API server fires a `DELETE` event. The ReplicaSet controller receives this watch event, runs the reconcile, and creates a replacement immediately — not on the next polling cycle. This is why the new pod appears within 1–2 seconds.

```bash
# See the RS watching your pods
kubectl -n dojo-chaos get rs
kubectl -n dojo-chaos describe rs <name> | grep -A 5 Events
```

## Why naked pods fail the verifier

If you ran `kubectl -n dojo-chaos run extra --image=nginx:1.27-alpine` to inflate the count, those pods have no `ownerReferences`. The verifier checks:

```bash
kubectl -n dojo-chaos get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}'
```

A naked pod shows an empty kind. Delete it and no controller brings it back. The ReplicaSet is what makes the cluster self-healing, not the presence of pods.

## Hardening preview

This challenge shows the controller handles pod deletion. The next challenge escalates: a `kubectl drain` evicts *all* pods on a node simultaneously, which the ReplicaSet controller cannot prevent — it can only re-create them after eviction. Without a PodDisruptionBudget, the replica count briefly hits zero.
