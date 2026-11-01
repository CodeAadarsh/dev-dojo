# External Secrets Operator: Declare a Sync

The platform team is migrating 40 microservices off `kubectl create secret`. The
new contract is: **no plaintext secret lands in Git; every service declares what it
needs and the External Secrets Operator fetches it at sync time.** A new hire opened
a PR with an ExternalSecret that referenced the wrong API group — the operator never
reconciled it and the service was down for 20 minutes in staging before anyone
noticed.

Your task is to get the declaration right: author a `SecretStore` that names a backend
and an `ExternalSecret` that maps keys from that backend into a Kubernetes `Secret`.

## Prerequisites

You need a running kind cluster (`kind-dojo`) and the External Secrets Operator
installed. Run setup:

```bash
bash courses/course-31-secrets-zero-trust/challenges/05-external-secret-sync/setup.sh
```

`setup.sh` creates namespace `dojo-secrets` and installs the ESO Helm chart if not
already present (it uses the `fake` provider backend so no real secrets manager is
needed).

## Mission

In namespace `dojo-secrets`, apply both of the following objects. The verifier checks
the objects — **not** whether a real sync happened (the `fake` provider requires
additional config to produce a real Secret; your job is the declaration structure).

### 1. SecretStore

- Kind: `SecretStore` (API group: `external-secrets.io/v1beta1`)
- Namespace: `dojo-secrets`
- Name: `dojo-store`
- Provider: `fake` with at least one static data entry:

  ```yaml
  provider:
    fake:
      data:
        - key: /dojo/app/api-key
          value: "fake-api-key-value"
  ```

### 2. ExternalSecret

- Kind: `ExternalSecret` (API group: `external-secrets.io/v1beta1`)
- Namespace: `dojo-secrets`
- Name: `dojo-app-secret`
- `spec.refreshInterval`: `1h`
- `spec.secretStoreRef.name`: `dojo-store`
- `spec.secretStoreRef.kind`: `SecretStore`
- `spec.target.name`: `dojo-synced-app` (the Kubernetes Secret the operator will create)
- `spec.data` mapping:

  ```yaml
  data:
    - secretKey: api_key
      remoteRef:
        key: /dojo/app/api-key
  ```

Apply both objects, then run the verifier.

## Why this matters

The separation of concerns here is the whole point:

- The **SecretStore** is a cluster-scoped (or namespace-scoped) connection spec — it
  tells ESO which backend to talk to and how to authenticate. Ops owns this.
- The **ExternalSecret** is a developer-facing declaration — "I need this secret from
  that store, map it to this Kubernetes Secret." Dev owns this.
- The Kubernetes Secret the operator creates is **ephemeral** — it can be deleted and
  recreated from the source of truth. It never needs to live in Git.

Getting the API group right (`external-secrets.io`, not `k8s.io`) and the `kind:
SecretStore` vs `ClusterSecretStore` distinction right are where most first-timers
get stuck. `kubectl get externalsecrets -n dojo-secrets` shows the reconciliation
status; `kubectl describe externalsecret dojo-app-secret -n dojo-secrets` shows why it
hasn't synced.

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/05-external-secret-sync/verify.sh
```
