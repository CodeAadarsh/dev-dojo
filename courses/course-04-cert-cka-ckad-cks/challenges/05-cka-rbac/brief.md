# Least Privilege, Fast

A read-only service account is the "hello world" of RBAC and a staple of both CKA and CKS. The trick is scoping it *exactly* — can read pods, cannot touch anything else — and proving it with `kubectl auth can-i`.

## Mission

In namespace `dojo-rbac-exam` (created by setup), create:

1. a **ServiceAccount** named `viewer`
2. a **Role** that allows only `get`, `list`, `watch` on `pods`
3. a **RoleBinding** that binds the Role to the `viewer` ServiceAccount

The result must satisfy:

- `viewer` **can** `get` and `list` pods in the namespace
- `viewer` **cannot** `delete` pods (or do anything else)

## Prove it yourself before submitting

```bash
kubectl auth can-i list   pods --as=system:serviceaccount:dojo-rbac-exam:viewer -n dojo-rbac-exam   # yes
kubectl auth can-i delete pods --as=system:serviceaccount:dojo-rbac-exam:viewer -n dojo-rbac-exam   # no
```

`--as` **impersonates** the subject — the exam-fast way to test RBAC without logging in as the SA. Run the verifier when both answers are right.
