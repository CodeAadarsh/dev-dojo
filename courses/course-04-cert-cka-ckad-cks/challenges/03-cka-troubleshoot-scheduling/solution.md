# Solution — Why Won't It Schedule

## Diagnose

```bash
kubectl -n dojo-sched-fix get pods          # STATUS: Pending
kubectl -n dojo-sched-fix describe pod <pod> # Events, bottom:
#   Warning  FailedScheduling  ... 0/3 nodes are available:
#   3 node(s) didn't match Pod's node affinity/selector.
```

That message is definitive: the pod demands a node that doesn't exist. Confirm the constraint and the node labels:

```bash
kubectl -n dojo-sched-fix get deploy reports -o jsonpath='{.spec.template.spec.nodeSelector}'; echo
#   {"disktype":"ssd"}
kubectl get nodes --show-labels | grep -o 'disktype=[^,]*' || echo "no node has disktype"
```

No node is labelled `disktype=ssd`, so the scheduler can never place the pod.

## Fix — pick one

**A. Satisfy the constraint** (keep the nodeSelector — the "right" fix if the intent was real):

```bash
kubectl label node dojo-worker disktype=ssd
```

**B. Drop the constraint** (if the selector was a mistake):

```bash
kubectl -n dojo-sched-fix patch deploy reports --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
```

Either way the pods schedule within seconds:

```bash
kubectl -n dojo-sched-fix rollout status deploy/reports
bash courses/course-04-cert-cka-ckad-cks/challenges/03-cka-troubleshoot-scheduling/verify.sh
```

## Why this matters

- **`describe pod` → Events is the whole game** for Pending pods. The scheduler always tells you why in plain language; reading it beats any amount of guessing. This same reflex solves taint (`had untolerated taint`), capacity (`Insufficient cpu`), and cordon (`node(s) were unschedulable`) failures.
- **nodeSelector vs nodeAffinity:** `nodeSelector` is the simple exact-match form; `requiredDuringSchedulingIgnoredDuringExecution` affinity is the expressive form, but both fail the same way — unschedulable if nothing matches.
- **Taints are the mirror image:** a node repels pods unless they tolerate it. If the Event had said `had untolerated taint`, the fix would be a `tolerations:` block on the pod (or `kubectl taint node <n> key-` to remove it).
