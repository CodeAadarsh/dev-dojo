# Solution — Sealed Secrets: Commit a Secret Safely

The flag is `KUBE{sealed_secret_only_cluster_unseals}`.

## Step 1 — Confirm the controller is running

```bash
kubectl get pods -n kube-system | grep sealed-secrets
# sealed-secrets-controller-xxxx   1/1   Running
```

The controller generates an RSA key pair on first boot and stores the private key as a
Secret in `kube-system`. The public certificate is what `kubeseal` fetches to encrypt.

## Step 2 — Create the plaintext manifest (dry-run only)

```bash
kubectl create secret generic dojo-app-creds \
  --namespace=dojo-sealed \
  --from-literal=db_password=hunter2 \
  --dry-run=client -o yaml > /tmp/plaintext-secret.yaml
```

Look at it:

```bash
cat /tmp/plaintext-secret.yaml
# data:
#   db_password: aHVudGVyMg==   <- base64, not ciphertext
```

This file must **never** be applied or committed. The value is base64-encoded, not
encrypted — it decodes instantly.

## Step 3 — Seal the Secret

```bash
kubeseal --format=yaml < /tmp/plaintext-secret.yaml > sealed-secret.yaml
```

`kubeseal` fetches the controller's public certificate from the cluster
(`kube-system/sealed-secrets-controller`), encrypts each value, and emits a
`SealedSecret` CR:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: dojo-app-creds
  namespace: dojo-sealed
spec:
  encryptedData:
    db_password: AgA...  # RSA-OAEP + AES-GCM ciphertext
  template:
    metadata:
      name: dojo-app-creds
      namespace: dojo-sealed
```

This YAML is **safe to commit.** Without the cluster's RSA private key it cannot be
decrypted — even by `kubeseal` itself on a different cluster.

## Step 4 — Apply

```bash
kubectl apply -f sealed-secret.yaml
# sealedsecret.bitnami.com/dojo-app-creds created
```

## Step 5 — Verify the controller unsealed it

```bash
kubectl get secret dojo-app-creds -n dojo-sealed
# NAME             TYPE     DATA   AGE
# dojo-app-creds   Opaque   1      3s

kubectl get secret dojo-app-creds -n dojo-sealed \
  -o jsonpath='{.data.db_password}' | base64 -d; echo
# hunter2
```

Check the owner reference — this confirms it was the controller, not a manual apply:

```bash
kubectl get secret dojo-app-creds -n dojo-sealed \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
# SealedSecret
```

## What happens if you delete the SealedSecret

```bash
kubectl delete sealedsecret dojo-app-creds -n dojo-sealed
```

The controller cascades the delete to the owned Secret. Reapply the sealed YAML and it
is back in seconds — this is the GitOps loop.

## Scope binding — why you cannot replay across namespaces

By default `kubeseal` embeds the target namespace and name in the ciphertext as
authenticated additional data (AAD). If you try to apply `sealed-secret.yaml` in a
different namespace or rename the Secret, the controller rejects it with a decryption
error:

```bash
# Attempt to apply in the wrong namespace:
kubectl apply -f sealed-secret.yaml -n default
# -> error: error decrypting key: ...
```

You can override scope with `--scope=cluster-wide` (any namespace/name) or
`--scope=namespace-wide` (any name, same namespace). Use the default strict scope in
production unless you have a deliberate reason.

## Hardening preview

- **Rotate the controller key** periodically (`kubeseal --rotate-keys`) — old Secrets
  stay decryptable with archived keys; new ones use the new key.
- **Back up the private key** (it lives in `kubectl get secret -n kube-system -l
  sealedsecrets.bitnami.com/sealed-secrets-key`) — losing it means losing the ability
  to unseal any SealedSecret encrypted with the old public key.
- **Never commit** the `kubeseal --fetch-cert` output either — it's just the public
  key, but publishing it lets an attacker craft valid ciphertexts for any namespace/name
  they want, which they could then use to trick a cluster into materialising Secrets
  under their control.
