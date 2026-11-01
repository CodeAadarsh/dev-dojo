# Kill and Heal

Your incident runbook reads: "If a pod is missing, the controller will re-create it automatically — no human action required." A skeptical new hire asks: "How do you *know* that's true? Can you prove it?" That's what you're doing here.

The `web` Deployment has been planted in `dojo-chaos` with three replicas. Your job is to inject the fault yourself — deliberately delete one or more pods — and then prove the ReplicaSet controller has fully healed the cluster back to steady state.

## Mission

1. Run `setup.sh` to plant the scenario.
2. Delete at least one pod to inject chaos:
   ```bash
   kubectl -n dojo-chaos delete pod <pod-name>
   # or delete all of them at once
   kubectl -n dojo-chaos delete pod -l app=web
   ```
3. Watch the controller respond:
   ```bash
   kubectl -n dojo-chaos get pods -w
   ```
4. Once the cluster looks healed, run `verify.sh`. It passes only when **all three** conditions are true:

| Check | Required |
|-------|----------|
| `spec.replicas` | ≥ 3 |
| `readyReplicas` | == `spec.replicas` (every replica Ready) |
| All running pods | Owned by a ReplicaSet (controller-managed) |

## Why the ownership check matters

If you manually run `kubectl run` to bring the pod count back to 3, the pods exist but are **not** controller-managed — there is no ReplicaSet watching them. Delete one again and it stays dead. Resilience comes from the controller owning the pods, not from any number of bare pods you happened to create.

The verifier checks `ownerReferences[0].kind == ReplicaSet` on every running pod. An orphaned pod fails this check.

See ownership for yourself:

```bash
kubectl -n dojo-chaos get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}'
```

## Why this is the foundation of every chaos experiment

Every advanced chaos technique — node drains, network partitions, zone failures — ultimately tests the same thing: "does my controller reconcile the desired state when something disappears?" If the answer is yes, your system is a candidate for real chaos engineering. If no, you're just hoping.

## Rules of engagement

- Namespace: `dojo-chaos`.
- You may delete one pod or all three — the lesson is identical.
- `--force --grace-period=0` is fine here (this is a dojo, not prod).
