# OPA Policy Escape — Solution

## Understanding the Gap

```bash
kubectl get blockprivilegedcontainer block-privileged-containers -o yaml
```

The broken `spec.match.kinds` section:

```yaml
spec:
  match:
    kinds:
    - apiGroups: ["apps"]
      kinds: ["Deployment"]    # ← Only Deployments!
    namespaces: ["dojo-sec-opa"]
```

Bare Pods belong to `apiGroups: [""]` (core group), not `apps`. So creating a Pod directly bypasses this constraint entirely.

## Proving the Gap

```bash
# This should fail but it DOESN'T (before the fix):
kubectl run priv-pod -n dojo-sec-opa \
  --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","securityContext":{"privileged":true},"command":["sleep","1"]}]}}' 
# Created! The constraint didn't block it.

kubectl delete pod priv-pod -n dojo-sec-opa
```

## The Fix

Edit the constraint to also match bare Pods:

```bash
kubectl edit blockprivilegedcontainer block-privileged-containers
```

Change `spec.match.kinds` to:

```yaml
spec:
  enforcementAction: deny
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]              # ← Bare Pods (core API group)
    - apiGroups: ["apps"]
      kinds: ["Deployment", "DaemonSet", "StatefulSet", "ReplicaSet"]
    namespaces: ["dojo-sec-opa"]
```

## Verifying the Fix

```bash
# After saving the edit, test again:
kubectl run priv-pod -n dojo-sec-opa \
  --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","securityContext":{"privileged":true},"command":["sleep","1"]}]}}'
# Error: pod "priv-pod" is forbidden: [denied by block-privileged-containers: Container 'c' must not run as privileged]
```

## Run the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{opa_constraints_must_be_strict}`**

---

## Why This Gap Is Common

OPA Gatekeeper policy authors often test their constraints by trying to create a Deployment. If the Deployment is blocked, they assume all pods are blocked — but Deployments create ReplicaSets, which create Pods. Each resource type must be explicitly matched.

Best practice: always include both `{""}:Pod` AND `apps:Deployment/DaemonSet/StatefulSet` in every constraint that should protect pods.
