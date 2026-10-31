# Solution — Least Privilege, Fast

All three objects, imperatively (fastest for the exam):

```bash
kubectl -n dojo-rbac-exam create sa viewer

kubectl -n dojo-rbac-exam create role pod-reader \
  --verb=get,list,watch --resource=pods

kubectl -n dojo-rbac-exam create rolebinding viewer-rb \
  --role=pod-reader --serviceaccount=dojo-rbac-exam:viewer
```

Verify with impersonation:

```bash
kubectl auth can-i list   pods --as=system:serviceaccount:dojo-rbac-exam:viewer -n dojo-rbac-exam   # yes
kubectl auth can-i delete pods --as=system:serviceaccount:dojo-rbac-exam:viewer -n dojo-rbac-exam   # no
kubectl auth can-i --list      --as=system:serviceaccount:dojo-rbac-exam:viewer -n dojo-rbac-exam   # full matrix
bash courses/course-04-cert-cka-ckad-cks/challenges/05-cka-rbac/verify.sh
```

Equivalent YAML (if you prefer declarative):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: viewer, namespace: dojo-rbac-exam }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: pod-reader, namespace: dojo-rbac-exam }
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: viewer-rb, namespace: dojo-rbac-exam }
subjects:
  - kind: ServiceAccount
    name: viewer
    namespace: dojo-rbac-exam
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

## Why this matters

- **`Role` + `RoleBinding` are namespaced**; `ClusterRole` + `ClusterRoleBinding` are cluster-wide. Mixing them up (e.g. a RoleBinding referencing a ClusterRole to grant namespaced access) is a common real pattern — and a common exam trap.
- **Verbs are additive and there is no "deny."** Least privilege means listing *only* the verbs needed. The moment you add `delete` (or use `--verb=*`), the account can delete — RBAC never subtracts.
- **`kubectl auth can-i --as=` is the audit tool.** `--as=system:serviceaccount:<ns>:<name>` impersonates the SA so you can prove exactly what an identity can and can't do — the same technique an attacker uses to enumerate a stolen token's reach (Course 03).
