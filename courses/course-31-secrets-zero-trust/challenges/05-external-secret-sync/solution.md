# Solution — External Secrets Operator: Declare a Sync

The flag is `KUBE{external_secret_operator_synced}`.

## Step 1 — Verify ESO is installed

```bash
kubectl get deployment external-secrets -n external-secrets
kubectl api-resources | grep external-secrets
# should list: secretstores, externalsecrets, clustersecretstores, etc.
```

If the CRDs are not present, setup.sh did not complete — rerun it.

## Step 2 — Apply the SecretStore

Save as `secretstore.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: dojo-store
  namespace: dojo-secrets
spec:
  provider:
    fake:
      data:
        - key: /dojo/app/api-key
          value: "fake-api-key-value"
```

```bash
kubectl apply -f secretstore.yaml
# secretstore.external-secrets.io/dojo-store created
```

**Why `fake`?** The `fake` provider is ESO's built-in test backend — it serves static
key/value pairs without requiring an external secrets manager. This lets you learn the
declaration structure without standing up Vault, AWS Secrets Manager, or GCP Secret
Manager first.

**`SecretStore` vs `ClusterSecretStore`:** A `SecretStore` is namespace-scoped — the
ExternalSecrets that reference it must be in the same namespace. A `ClusterSecretStore`
is cluster-wide. Use namespace-scoped stores in production unless you have a deliberate
cross-namespace use case.

## Step 3 — Apply the ExternalSecret

Save as `externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: dojo-app-secret
  namespace: dojo-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: dojo-store
    kind: SecretStore
  target:
    name: dojo-synced-app
    creationPolicy: Owner
  data:
    - secretKey: api_key
      remoteRef:
        key: /dojo/app/api-key
```

```bash
kubectl apply -f externalsecret.yaml
# externalsecret.external-secrets.io/dojo-app-secret created
```

## Step 4 — Observe the reconciliation

```bash
kubectl get externalsecret dojo-app-secret -n dojo-secrets
# NAME               STORE        REFRESH INTERVAL   STATUS         READY
# dojo-app-secret    dojo-store   1h                 SecretSynced   True
```

With the `fake` provider the sync happens immediately:

```bash
kubectl get secret dojo-synced-app -n dojo-secrets
# NAME              TYPE     DATA   AGE
# dojo-synced-app   Opaque   1      5s

kubectl get secret dojo-synced-app -n dojo-secrets \
  -o jsonpath='{.data.api_key}' | base64 -d; echo
# fake-api-key-value
```

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Wrong API group (`k8s.io` instead of `external-secrets.io`) | `no matches for kind SecretStore` | Use `apiVersion: external-secrets.io/v1beta1` |
| `ClusterSecretStore` in the `secretStoreRef` but applied a `SecretStore` | ESO logs `StoreNotFound` | Match kind: either both `SecretStore` or both `ClusterSecretStore` |
| `refreshInterval: 0` | ESO reconciles once then marks `Ready=False` | Use a positive duration string: `1h`, `5m` |
| `creationPolicy: None` | Operator does not create the target Secret | Use `Owner` (ESO owns the Secret lifecycle) or `Merge` |

## Attacker's view

An ExternalSecret declaration in Git reveals the *path* in the backend, not the value.
An attacker who can `kubectl get externalsecret` learns which secrets the service needs
and which store they come from — useful for a targeted Vault credential theft. Restrict
`get/list` on `externalsecrets` to the owning team's service account only.
