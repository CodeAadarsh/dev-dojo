# Why Won't It Schedule

The `reports` Deployment in namespace `dojo-sched-fix` is deployed, the image is fine, but its pods are stuck **`Pending`** and never start. This is the single most common CKA troubleshooting shape: the scheduler can't place the pod.

## Mission

Make `reports` schedule and become **Ready**. But first — **diagnose it the right way.** Don't guess; let the cluster tell you:

```bash
kubectl -n dojo-sched-fix get pods
kubectl -n dojo-sched-fix describe pod <pending-pod>   # read the Events at the bottom
```

The Events line from the scheduler names the exact reason. Only then apply the minimal fix.

## The scheduling failure menu (what the Events might say)

| Event text | Cause | Typical fix |
|------------|-------|-------------|
| `didn't match Pod's node affinity/selector` | `nodeSelector`/affinity no node satisfies | label a node, or fix/remove the selector |
| `had untolerated taint {…}` | node taint, no matching toleration | add a toleration, or remove the taint |
| `Insufficient cpu`/`memory` | requests exceed free capacity | lower requests or free capacity |
| `node(s) were unschedulable` | node cordoned | `kubectl uncordon <node>` |

This challenge is **one** of those. Find which, fix it minimally, keep it to the intended behaviour.

Run the verifier once the pods are Running.
