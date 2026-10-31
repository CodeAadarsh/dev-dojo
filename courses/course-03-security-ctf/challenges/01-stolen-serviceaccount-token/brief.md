# Stolen ServiceAccount Token

An application team shipped a small worker pod in namespace `dojo-ctf`. During a security review you find two problems that are individually common and together dangerous:

1. The pod runs with its ServiceAccount token **automounted** (the default nobody turned off).
2. That ServiceAccount is bound to a Role that can **read Secrets** in the namespace — including one holding a credential it has no business touching.

Assume an attacker already has code execution inside that pod (an app bug — the Code layer from Module 01). You're going to stand in their shoes and prove the blast radius: **from inside the pod, with no cluster-admin kubeconfig, authenticate to the API server using only what's mounted in the pod, and read the Secret.**

## The scenario the setup script plants

- Namespace `dojo-ctf`.
- A Secret `db-credentials` containing `FLAG=KUBE{...}` (plus some decoy keys).
- A ServiceAccount `worker-sa`.
- A `Role` + `RoleBinding` granting `worker-sa` `get`/`list` on Secrets in `dojo-ctf`.
- A pod `worker` (`busybox:1.36`, just sleeping) that runs **as** `worker-sa` with `automountServiceAccountToken: true`.

## Mission

Recover the flag from the `db-credentials` Secret **using the pod's mounted token**, not your admin credentials. The intended path:

1. Get a shell in the pod: `kubectl -n dojo-ctf exec -it worker -- sh`.
2. Find the three files the API server needs you to present, all under
   `/var/run/secrets/kubernetes.io/serviceaccount/`:
   - `token` — the bearer credential (a signed JWT for `worker-sa`),
   - `ca.crt` — the cluster CA, so you can trust the API server's TLS,
   - `namespace` — the namespace the pod runs in.
3. Call the in-cluster API endpoint `https://kubernetes.default.svc` with `curl`,
   presenting the token as a `Bearer` header and the CA for verification, and read
   the `db-credentials` Secret.
4. The Secret value is base64 (not encrypted — see Course 01) — decode it.

> There is more than one legitimate route to the flag once you're in the pod. `curl` against the raw API is the one that teaches the mechanic; if `kubectl` happens to be reachable, the token works there too. Try the `curl` path first — in the real world the image rarely ships `kubectl`, and the token is all an attacker gets.

## Why this matters

This is the **pod-to-cluster** link of the escalation chain, reproduced exactly. Nothing here is a kernel exploit or a clever trick — it's two defaults left on:

- **Automounted token:** every pod becomes an API client whether it needs to be one or not. The fix is `automountServiceAccountToken: false` on the pod or ServiceAccount.
- **Over-broad RBAC:** a worker that never needs Secrets was granted `get secrets`. The fix is a Role scoped to the *one* resource it actually uses — or `resourceNames` pinning it to a single Secret.

If both were tightened, a compromised app in this pod would get a token that can do essentially nothing. That is the entire argument for least privilege, made concrete. Submit the `KUBE{...}` flag you recover.
