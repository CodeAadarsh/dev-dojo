# Secrets on Kubernetes

> **Module 03 · Course 31** — A Kubernetes Secret is not a secrets manager. It is a base64-encoded ConfigMap with an RBAC namespace and a different API group. This module maps the weaknesses precisely, then shows the three serious alternatives: External Secrets Operator (pull from any external store), sealed-secrets (asymmetric encrypt-in-repo), and CSI Secrets Store (mount as files from Vault/AWS/GCP). Each one solves a different part of the problem.

You have Vault running from Module 02. By the end of this module you will have a pod reading credentials from it without ever having a plaintext Secret in etcd.

---

## The Native Kubernetes Secret: Weaknesses

The Kubernetes Secret API exists for a reason — it lets you decouple configuration from images. But its threat model is weak by default:

```
kubectl get secret <name> -n <ns> -o yaml
```

This command returns the plaintext (base64 is encoding, not encryption) to any principal with the `get` or `list` verb on the `secrets` resource. The weaknesses, enumerated:

| Weakness | What it means in practice |
|----------|--------------------------|
| Base64 at rest in etcd | Anyone with `etcdctl` or direct file access reads every secret without a key |
| RBAC `list secrets` leaks all | A broad `ClusterRole view` (common default) includes listing secrets — and `list` returns `.data` |
| Namespace isolation is the only boundary | If a process escapes its pod into the node, all Secrets on that node are accessible via the node's kubelet credential |
| No versioning | You cannot roll back a rotated credential without re-applying the old one manually |
| No access audit by default | Who read which secret when? Not recorded unless you configure API audit logging |
| Mounted as env or volume | Env vars leak in logs, process listings, crash dumps; volume files persist in `/proc/<pid>/fd` |

> **The list verb trap.** In Kubernetes, `list` and `watch` on `secrets` returns the full `.data` field — not just metadata. A `ClusterRole` that says `verbs: ["get","list","watch"]` on `secrets` hands every secret in every (or a specific) namespace to any bearer of that role. Always scope to individual Secret names with `resourceNames:` when possible.

---

## External Secrets Operator

ESO is a Kubernetes operator that syncs secrets from an external store (Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, 1Password, and others) into Kubernetes Secrets. The native Secret in etcd becomes a *cache* — the source of truth is external.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Kubernetes cluster                                               │
│                                                                  │
│   ┌─ ESO controller ────────────────────────────────────────┐   │
│   │                                                         │   │
│   │  watches ExternalSecret CRs                             │   │
│   │         │                                               │   │
│   │         ▼                                               │   │
│   │  reads SecretStore (credentials for external provider)  │   │
│   │         │                                               │   │
│   │         ▼                                               │   │
│   │  fetches from Vault / AWS / GCP                         │   │
│   │         │                                               │   │
│   │         ▼                                               │   │
│   │  creates/updates native Secret                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   Your pod mounts the native Secret as normal                    │
└──────────────────────────────────────────────────────────────────┘
```

### Install (Helm)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace
kubectl -n external-secrets-system get pods
```

### SecretStore — the credential for your external provider

A `SecretStore` is namespace-scoped. `ClusterSecretStore` is cluster-scoped (for platform teams managing cross-namespace secrets).

```yaml
# For a local Vault dev server from Module 02
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: dojo-app
spec:
  provider:
    vault:
      server: "http://dojo-vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
          namespace: dojo-app
```

The `auth.tokenSecretRef` points to a Kubernetes Secret holding the Vault token. In production you replace this with `auth.kubernetes` to use pod identity — no long-lived token needed.

### ExternalSecret — maps external path → native Secret

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: dojo-app
spec:
  refreshInterval: 1h          # re-fetch on this schedule
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: db-secret            # name of the Kubernetes Secret to create
    creationPolicy: Owner      # ESO owns this Secret; deletes it when ES is deleted
  data:
    - secretKey: DB_PASSWORD   # key in the created Secret
      remoteRef:
        key: secret/app/database    # Vault path
        property: password           # field inside the Vault secret
    - secretKey: DB_USER
      remoteRef:
        key: secret/app/database
        property: user
```

Apply it and watch:

```bash
kubectl apply -f secretstore.yaml -f externalsecret.yaml -n dojo-app
kubectl -n dojo-app get externalsecret db-credentials
# NAME              STORE          REFRESH INTERVAL   STATUS   READY
# db-credentials    vault-backend  1h                 SecretSynced  True
```

The operator creates the native Secret `db-secret` with the decoded values. Your pod mounts it as normal.

---

## Sealed Secrets

Sealed Secrets takes a different approach: instead of pulling from an external store at runtime, you encrypt the Secret offline using the controller's public key, commit the encrypted `SealedSecret` to git, and let the controller decrypt it on the cluster.

```
Developer's laptop:
  plaintext Secret → kubeseal → SealedSecret (encrypted) → git commit

Cluster (sealed-secrets controller):
  SealedSecret (from git) → controller decrypts → native Secret
  (private key never leaves the controller)
```

### Install

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system --set fullnameOverride=sealed-secrets-controller

# install the kubeseal CLI
brew install kubeseal   # or download from GitHub releases
```

### Seal a secret

```bash
# create the source secret (don't apply it to the cluster directly)
kubectl create secret generic db-creds \
  --from-literal=password='hunter2' \
  --dry-run=client -o yaml > /tmp/db-creds-plain.yaml

# seal it with the cluster's public key
kubeseal --format yaml < /tmp/db-creds-plain.yaml > db-creds-sealed.yaml

# commit db-creds-sealed.yaml to git — it is safe to commit
# apply it to the cluster
kubectl apply -f db-creds-sealed.yaml
```

The controller decrypts it and creates the native Secret automatically.

> **Scope.** By default a SealedSecret is namespace+name scoped: the ciphertext can only be decrypted in the exact namespace and with the exact Secret name. This prevents an attacker who steals a `production` SealedSecret from replaying it in `staging`. Change scope with `--scope strict | namespace-wide | cluster-wide`.

---

## CSI Secrets Store

The Container Storage Interface Secrets Store (secrets-store-csi-driver) mounts secrets directly into pods as files, fetched from Vault / AWS / GCP at pod start-up. The secret never becomes a Kubernetes Secret object — it goes straight from the external store into the container's in-memory tmpfs mount.

```
Pod start:
  kubelet calls CSI driver → driver calls Vault → Vault returns secret
  driver writes secret to /mnt/secrets/db-password (tmpfs in the container)
  Pod starts, secret is a file, not an env var, not a Kubernetes Secret
Pod stop:
  tmpfs is unmounted — secret is gone from the node
```

```yaml
# SecretProviderClass — tells the CSI driver where to fetch
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db-creds
  namespace: dojo-app
spec:
  provider: vault
  parameters:
    vaultAddress: "http://dojo-vault.vault.svc.cluster.local:8200"
    roleName: "app-role"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/app/database"
        secretKey: "password"

---
# Pod using the CSI mount
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: dojo-app
spec:
  serviceAccountName: app-sa     # must match the Vault role
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "cat /mnt/secrets/db-password; sleep 3600"]
      volumeMounts:
        - name: secrets
          mountPath: /mnt/secrets
          readOnly: true
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: vault-db-creds
```

Advantages over env-var injection: the secret is a file, not in `environ`, not in crash dumps, and is cleaned up when the pod exits.

---

## Encryption at Rest: EncryptionConfiguration

By default, Kubernetes writes Secrets to etcd in base64. `EncryptionConfiguration` tells the API server to encrypt the data before writing it to etcd using a provider you choose.

```yaml
# /etc/kubernetes/encryption-config.yaml (on the control-plane node)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <32-byte-key-base64-encoded>
      - identity: {}   # fallback for pre-existing unencrypted secrets
```

The `aescbc` provider encrypts with AES-CBC. The key is in the config file — if the control-plane node is compromised, the key is compromised. For real protection, use a KMS provider (AWS KMS, GCP KMS) where the key is never on disk.

```bash
# verify a secret is encrypted in etcd after enabling EncryptionConfiguration:
# log into the kind control-plane node
docker exec -it dojo-control-plane bash

ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-app/db-secret | strings | head -20

# unencrypted: you see the base64 values and key names
# encrypted with aescbc: you see binary garbage (the ciphertext + provider prefix k8s:enc:aescbc:v1:...)
```

---

## Debugging Secrets on Kubernetes

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ExternalSecret` status `SecretSyncedError` | SecretStore misconfigured (wrong Vault addr, bad token, path typo) | `kubectl describe externalsecret <name>` — the Events section shows the exact Vault error; check `kubectl describe secretstore <name>` |
| ESO syncs once but never updates | `refreshInterval` is too long, or the Vault secret changed but the ESO version hash hasn't changed | Force re-sync: `kubectl annotate externalsecret <name> force-sync=$(date +%s)` |
| `SealedSecret` created but no native Secret appears | Controller can't decrypt — mismatched controller key (cluster was recreated) | `kubectl -n kube-system logs deploy/sealed-secrets-controller`; re-seal with the new cluster's public key |
| `kubeseal` outputs a SealedSecret but it never decrypts | Name or namespace in the sealed spec doesn't match where it's applied (strict scope) | Re-seal with `--namespace <target-ns> --name <target-name>` matching the apply target |
| CSI mount fails with `provider not found` | CSI driver not installed or provider plugin missing | Check `kubectl -n kube-system get pod -l app=secrets-store-csi-driver`; install the provider plugin (e.g., `secrets-store-csi-driver-provider-vault`) |
| `still plaintext in etcd` after enabling EncryptionConfiguration | EncryptionConfiguration only encrypts new writes — existing secrets must be re-written | Run `kubectl get secrets --all-namespaces -o yaml | kubectl apply -f -` to force a re-write through the new provider |
| KMS provider for EncryptionConfiguration returning errors | KMS key deleted or IAM permission revoked | `kubectl -n kube-system logs kube-apiserver-<node>`; check KMS provider logs; restore IAM permission; never delete a KMS key while secrets are encrypted with it |

### Diagnosing ESO not syncing

```bash
# look at the condition in the status block
kubectl -n dojo-app get externalsecret db-credentials -o yaml | grep -A 10 status

# read the events — these are the actual error messages from the ESO controller
kubectl -n dojo-app describe externalsecret db-credentials

# check whether the SecretStore itself can reach the backend
kubectl -n dojo-app describe secretstore vault-backend

# look at ESO controller logs for the root cause
kubectl -n external-secrets-system logs deploy/external-secrets -c external-secrets --tail=50
```

Common root causes: token expired, Vault sealed after restart, path has a trailing slash mismatch (`secret/app/` vs `secret/app`), or the SecretStore is in a different namespace than the ExternalSecret when using a namespaced store.

### Diagnosing a SealedSecret that won't decrypt

```bash
# is the controller running?
kubectl -n kube-system get pod -l name=sealed-secrets-controller

# what is the controller's certificate fingerprint?
kubeseal --fetch-cert --controller-namespace kube-system \
  --controller-name sealed-secrets-controller | openssl x509 -noout -fingerprint

# log the controller — it will emit 'no key could decrypt secret' or similar
kubectl -n kube-system logs deploy/sealed-secrets-controller | tail -30

# if the cluster was recreated (new controller key), you must re-seal:
# 1. retrieve the plaintext secret from a backup / Vault
# 2. re-seal with the new certificate
kubeseal --fetch-cert > /tmp/new-cert.pem
kubectl create secret generic db-creds \
  --from-literal=password='hunter2' \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/new-cert.pem --format yaml > db-creds-sealed.yaml
kubectl apply -f db-creds-sealed.yaml
```

### Confirming etcd encryption is actually active

```bash
# create a test secret
kubectl create secret generic enc-test --from-literal=val=testvalue123

# read it from etcd directly (on the control-plane node)
docker exec dojo-control-plane sh -c \
  "ETCDCTL_API=3 etcdctl \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   get /registry/secrets/default/enc-test" | strings | grep -c testvalue123
# 0 = encrypted (testvalue123 not visible)
# 1 = still plaintext (EncryptionConfiguration not active or identity provider took precedence)
```

> **War story.** A fintech platform enabled `EncryptionConfiguration` in staging and passed their internal security audit: "etcd is encrypted." Six months later they failed a PCI-DSS assessment for production. The auditor ran the `etcdctl get` test above and found plaintext. Investigation: the `identity: {}` provider was listed *first* in the provider list, before `aescbc`. Kubernetes applies providers in order — the first matching provider wins. With `identity` first, every write used the identity (no-op) provider and the `aescbc` entry was never reached. The fix was a one-line reorder in the config file and a force re-write of all secrets. The audit cost six weeks. The fix took four minutes.

---

## Checkpoint

You are ready for the challenges when you can:

1. Enumerate four weaknesses of the native Kubernetes Secret API beyond "base64 is not encryption."
2. Explain the `list` verb trap: why listing secrets is more dangerous than `get` in many contexts.
3. Draw the ESO sync loop: which resources the controller watches, what it calls externally, and what it creates.
4. Write a `SecretStore` and `ExternalSecret` for a Vault KV v2 path with a `refreshInterval`.
5. Explain the sealed-secrets threat model: what can an attacker do with a committed `SealedSecret` file?
6. State what "strict scope" means and why it is the safer default.
7. Explain how the CSI Secrets Store avoids creating a Kubernetes Secret object at all.
8. Write the `EncryptionConfiguration` snippet for AES-CBC and explain the `identity: {}` fallback.
9. State why you must re-write all secrets after enabling `EncryptionConfiguration` (and the command to do it).
10. Diagnose: sealed-secrets controller says `no key could decrypt` — what happened and what is the recovery path?

➡ Next up: **Encryption: At Rest, In Transit & Envelope** — you will implement envelope encryption in Python, understand how KEK/DEK rotation works without re-encrypting all data, and trace the chain from a lost KEK to total data loss.
