# Bind Thyself Admin

A platform team got tired of filing a ticket every time a workload needed a new Role, so they decided their CI ServiceAccount should "manage its own access." They granted it `create rolebindings`. That alone kept failing with a `forbidden` error about escalation, so — to make the error go away — they also granted it the `bind` verb. Code review waved it through with the line that sinks a hundred clusters:

> *"It can only create bindings, it can't read anything sensitive itself."*

That reasoning is exactly backwards. In RBAC, **the authority to create a RoleBinding is the authority to grant yourself any permission you are allowed to `bind`.** A subject that can bind a secret-reading Role does not *need* to read Secrets today — it can hand itself that power in one API call and read them a second later. The `bind` verb exists precisely to let a low-privilege subject grant permissions it does not itself hold; that is its entire purpose, and it is almost always a mistake to give it out.

You are standing in the shoes of the `dev` ServiceAccount in namespace `dojo-esc`. You have **no** direct access to Secrets. You are going to give yourself that access and walk out with the flag.

## The scenario the setup script plants

| Object | What it is | The catch |
|--------|-----------|-----------|
| Secret `crown-jewels` | Holds `FLAG=KUBE{...}` plus a decoy `DB_PASSWORD` | `dev` **cannot** read it at the start |
| ServiceAccount `dev` | Your identity for this challenge | Not cluster-admin, not a secret reader |
| Role `secret-reader` | Grants `get`/`list` on Secrets | Exists, but is **not** bound to `dev` |
| Role `binder` (bound to `dev`) | Grants `create`/`get`/`list` on `rolebindings` **and** the `bind` verb on `roles/secret-reader` | This is the whole vulnerability |

So `dev` starts with the power to *create bindings* and to *bind one specific Role* — and nothing else of value.

## What `dev` can and cannot do at the start

```
dev  ──✅── create rolebindings       (rbac.authorization.k8s.io)
     ──✅── bind the Role "secret-reader"
     ──❌── get / list secrets        (NOT granted directly)
     ──❌── anything cluster-scoped
```

## The escalation in one picture

```
   dev  (cannot read secrets)
     │
     │  create RoleBinding:  secret-reader  ──▶  dev
     │  (allowed, because dev holds `bind` on secret-reader)
     ▼
   dev  (now bound to secret-reader)
     │
     │  get secret crown-jewels
     ▼
   FLAG=KUBE{...}
```

## Why Kubernetes *let* this happen

Kubernetes has a built-in **privilege-escalation prevention** check on writes to RBAC objects. To create a RoleBinding that grants Role `R`, the API server requires the caller to satisfy **one** of:

1. Already hold **every** permission that `R` grants (you can't give away more than you have), **or**
2. Hold the `bind` verb on `R` (an explicit "this subject is trusted to delegate `R`").

The platform team hit check #1 failing (`dev` can't read Secrets, so it can't grant Secret-reading) and "fixed" it by satisfying check #2 — handing `dev` the `bind` verb. That turned `dev` into a delegation authority for a Role far more powerful than `dev` itself. The same trap exists with the `escalate` verb on `roles`/`clusterroles` (edit the Role's rules directly) and with `impersonate` (become someone who already has the access).

## Mission

Acting **as** `dev` — impersonate it with `--as=system:serviceaccount:dojo-esc:dev` on every command, never your admin identity — do the following:

1. Confirm the starting point: `dev` **cannot** read the Secret yet.
2. Self-grant the `secret-reader` Role by creating a RoleBinding that names `dev` as the subject.
3. Read the `crown-jewels` Secret and decode `FLAG` (base64, not encryption — see Course 01).

Submit the `KUBE{...}` flag you recover.

> **Impersonation note.** You run these commands from your admin kubeconfig but add `--as=system:serviceaccount:dojo-esc:dev`, which tells the API server to evaluate RBAC **as that ServiceAccount**. This is the honest way to test "what can this identity actually do?" without planting a pod — the authorization decision is identical to a real attacker holding `dev`'s token. If the escalation works under `--as`, it works for a thief.

## Why this matters

`get secrets` was never granted to `dev`. No one audited `dev` and found it holding secret access, because at rest it holds none. The danger is **latent**: the capability to acquire the access on demand. Four verbs carry this property — `bind`, `escalate`, `impersonate`, and write access (`create`/`update`/`patch`) on `roles`/`rolebindings`/`clusterroles`/`clusterrolebindings`. Any subject holding one of them is, for audit purposes, as privileged as the most powerful thing it can reach through it. Treat them as cluster-admin-adjacent.
