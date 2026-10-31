# The Over-Privileged Account

Six months ago someone needed the CI pipeline to "just deploy things" and wired up a ServiceAccount called `ci-runner` in namespace `dojo-rbac`. Instead of scoping it to the one namespace it deploys into, they reached for a broad `ClusterRole` and a `ClusterRoleBinding` — the RBAC equivalent of `chmod 777` "to make the error go away."

Nobody revisited it. Today `ci-runner` is one of the most powerful identities in the cluster, and almost nothing it can do is anything a CI runner should be able to do.

A separate team keeps production credentials in namespace `dojo-vault`, in a Secret called `vault-secret`. They assume RBAC isolates them. It does not.

## Mission

**Become `ci-runner`, discover how far its permissions actually reach, and use them to read the flag out of `dojo-vault/vault-secret`.**

The flag is the value of the `FLAG` key in that Secret, in the form `KUBE{...}`.

You are cluster-admin in this lab (that is the whole point of a dojo), so you don't need a real token — you *impersonate* the ServiceAccount with `--as`. This is exactly how a reviewer, an auditor, or an attacker-with-admin models "what can this identity do?" before anyone's credentials are ever stolen.

> `--as=system:serviceaccount:<namespace>:<name>` tells the API server: "authorize this request as if that ServiceAccount sent it." Impersonation is itself a privileged verb — the fact that *you* can do it is a finding in a real audit, but here it is your lens into `ci-runner`'s world.

## Legitimate paths to the answer

There is more than one way in; try at least two, because each mirrors a real technique:

1. **Enumerate the subject's rights** with `kubectl auth can-i --list --as=system:serviceaccount:dojo-rbac:ci-runner`, spot that it can read Secrets cluster-wide, then read the Secret *as* that identity.
2. **Follow the bindings backwards** — find the `ClusterRoleBinding` that names `ci-runner`, read the `ClusterRole` it points at, and confirm the over-grant from the rules alone.
3. **Probe a single capability** with a targeted `kubectl auth can-i get secret -n dojo-vault --as=...` before you spend the privilege.

## Why this matters

RBAC is default-deny, which lulls teams into thinking any grant is "fine." The failure here is not a missing deny rule — it is a `ClusterRoleBinding` (cluster-scoped) doing the job a namespaced `RoleBinding` should have done. A `ClusterRole` grants nothing by itself; the *binding* decides the blast radius. Bind it with a `ClusterRoleBinding` and the rules apply in **every namespace, including ones that don't exist yet**. That is how a CI account that only ever deploys to one namespace ends up able to read every Secret in the cluster — and why "it's just a CI runner" is never a reason to skip the least-privilege review.

Submit the flag you recover.
