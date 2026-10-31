# Who Can Read Secrets?

You've inherited namespace `dojo-secrets`. It runs three workloads, each with its own ServiceAccount — `app-a`, `app-b`, `app-c` — and three Secrets:

| Secret | What it supposedly holds |
|--------------------|--------------------------|
| `payments-api-key` | the real prize |
| `telemetry-token`  | a metrics push token |
| `frontend-config`  | non-sensitive UI config |

Someone did the right thing and scoped each ServiceAccount with a **narrow Role** — in principle, least privilege. But narrow isn't the same as *correct*. One of these three identities can `get` the Secret that holds the flag; the other two cannot. Your job is to figure out **which identity** without reading the Secret as yourself.

## Mission

**Enumerate which ServiceAccount can `get` the flag Secret, then read the flag through that identity.** The flag is the `FLAG` key inside one of the three Secrets, in the form `KUBE{...}`. The other two Secrets contain decoys that tell you they are not the answer.

You are cluster-admin in this lab, so you impersonate each ServiceAccount with `--as` to test its rights — the same lens a security reviewer uses to answer the single most important RBAC question: *who can read secrets?*

> The "yes, but" of least privilege: scoping a Role with `resourceNames` is powerful and underused, but it means `auth can-i list secrets` can say **no** while `auth can-i get secret/<name>` says **yes** for the exact same account. If you only test `list`, you'll miss the account that can `get` one specific Secret. Enumerate per-verb and per-resource-name, not just per-resource.

## Approaches that get you there

1. **Sweep every (account × secret) pair** with `kubectl auth can-i get secret/<name> -n dojo-secrets --as=system:serviceaccount:dojo-secrets:<sa>` and watch for the single `yes`.
2. **List each account's rights** with `kubectl auth can-i --list -n dojo-secrets --as=...` and read the `Resource Names` column — a Role scoped to one Secret shows that Secret's name there.
3. **Inspect the Roles directly** (`kubectl -n dojo-secrets get role -o yaml`) and match each `resourceNames` entry to the Secret it unlocks.

## Why this matters

"Who can read secrets?" is the question every post-incident review and every SOC-2 auditor asks, and it is genuinely hard to answer by eyeballing YAML because permissions compose across Roles, ClusterRoles, and their bindings. `kubectl auth can-i ... --as=<subject>` is the authoritative answer — it runs the *real* authorization logic the API server uses, including `resourceNames` scoping that a grep of the manifests will quietly miss. Learn to drive it as a sweep and you can map Secret exposure across a namespace in seconds instead of guessing.

Submit the flag you recover.
