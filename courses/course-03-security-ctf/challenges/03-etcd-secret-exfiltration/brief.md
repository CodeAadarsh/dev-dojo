# Straight From etcd

Every Secret you've extracted so far went *through* the API server: you presented a credential, RBAC said yes, and you got the object back. That path has a gate you can slam shut — scope the token, tighten the Role, and the thief gets `forbidden`.

This challenge removes the gate. **etcd is the source of truth, and node access to etcd answers to no RBAC at all.** The API server is the only component that enforces authorization; etcd just stores bytes. Anyone who can talk to etcd with its client certs — anyone who has rooted the control-plane node — reads *every object in the cluster* directly, including every Secret, bypassing the API server entirely. And by default those Secrets are stored **in plaintext** (base64 is an encoding, not encryption — Course 01's lesson, now at the storage layer).

In this kind cluster the control-plane "node" is a Docker container named `dojo-control-plane`, so `docker exec` into it *is* the node compromise — the same foothold an attacker reaches via a container escape (you'll do that escape later in this course) or a stolen node credential. From there, etcd's own client certs are sitting on the filesystem at `/etc/kubernetes/pki/etcd/`.

## The scenario the setup script plants

| Object | Detail |
|--------|--------|
| Namespace | `dojo-etcd` |
| Secret `vault-backup` | Holds `FLAG=KUBE{...}` and a decoy `AWS_ACCESS_KEY_ID` |
| Storage | No `EncryptionConfiguration` on this cluster → the Secret sits in etcd as plaintext inside a protobuf blob |

## How objects are keyed in etcd

Kubernetes stores every object under a predictable registry path. Secrets live at:

```
/registry/secrets/<namespace>/<name>
          └─ so this flag is at:  /registry/secrets/dojo-etcd/vault-backup
```

The stored value is a length-prefixed protobuf object (it begins with the magic bytes `k8s\x00`), not JSON — which is why you don't parse it, you just scrape printable strings out of it.

## Mission

Do **not** use `kubectl get secret`. Read the flag straight out of etcd from the control-plane node, bypassing the API server and RBAC. The intended invocation, run against etcd's client certs on the node:

```bash
docker exec dojo-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-etcd/vault-backup' | strings | grep KUBE
```

- `ETCDCTL_API=3` selects the v3 API etcd actually serves; without it, old `etcdctl` builds default to the v2 API and the `get` returns nothing.
- The three `--cacert`/`--cert`/`--key` flags are etcd's own mTLS client identity — etcd requires client certs, and these are the ones kubeadm generated for the API server, lying unprotected on the node.
- `strings | grep KUBE` pulls the plaintext flag out of the binary protobuf. If the Secret were encrypted at rest, this would return nothing — that contrast is the entire lesson.

Submit the `KUBE{...}` flag you recover.

## Why this matters

RBAC is an **API-server** control. It is invisible to etcd. That single fact drives three production requirements, and this challenge is the argument for each:

1. **Encryption at rest** (`EncryptionConfiguration` with a KMS or `aescbc` provider) so a node/etcd compromise yields ciphertext, not credentials.
2. **Protect the node and etcd's certs** as crown jewels — node access is cluster-admin-equivalent whether or not RBAC says so.
3. **Rotate anything that ever lived in an unencrypted etcd** after a node compromise; assume every Secret leaked, because from here, it did.
