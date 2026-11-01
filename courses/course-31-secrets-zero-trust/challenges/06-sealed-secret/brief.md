# Sealed Secrets: Commit a Secret Safely

The GitOps team has a hard rule: **everything that creates cluster state must be a YAML
file in Git.** A new team member pointed out the obvious problem: "So we just put the
plaintext passwords in Git?" That question led to a 30-minute argument and a spike on
three tools. Sealed Secrets won the vote because it requires zero external dependencies
beyond the controller already running in the cluster.

The asymmetric trick is why this works: **only the cluster can unseal.** The `kubeseal`
CLI encrypts with the controller's *public* key. The ciphertext travels through Git and
through `kubectl apply` safely because nobody outside the cluster has the matching
private key. The controller holds the private key and materialises the real Secret when
it sees the `SealedSecret` resource.

## Prerequisites

You need a running kind cluster (`kind-dojo`), the Sealed Secrets controller, and the
`kubeseal` CLI. Run setup:

```bash
bash courses/course-31-secrets-zero-trust/challenges/06-sealed-secret/setup.sh
```

`setup.sh` installs the controller via Helm and creates namespace `dojo-sealed`.

Install `kubeseal` (macOS):

```bash
brew install kubeseal
```

Or download the binary from https://github.com/bitnami-labs/sealed-secrets/releases
(match the version the controller reports: `kubeseal --version`).

## Mission

1. **Create a plaintext Secret manifest** (do not `kubectl apply` it — it must never
   touch the cluster in plaintext):

   ```bash
   kubectl create secret generic dojo-app-creds \
     --namespace=dojo-sealed \
     --from-literal=db_password=hunter2 \
     --dry-run=client -o yaml > /tmp/plaintext-secret.yaml
   ```

2. **Seal it** with `kubeseal` to produce a `SealedSecret` CR:

   ```bash
   kubeseal --format=yaml < /tmp/plaintext-secret.yaml > sealed-secret.yaml
   ```

3. **Apply the SealedSecret** to the cluster:

   ```bash
   kubectl apply -f sealed-secret.yaml
   ```

4. **Confirm the controller unsealed it** — a Kubernetes `Secret` named
   `dojo-app-creds` should appear in `dojo-sealed` within seconds.

The `verify.sh` checks:
- A `SealedSecret` (bitnami.com) exists in `dojo-sealed` named `dojo-app-creds`.
- A native `Secret` named `dojo-app-creds` was produced by the controller in `dojo-sealed`.

## Why the ciphertext is safe to commit

`kubeseal` uses hybrid encryption: it generates a random DEK (data encryption key),
encrypts each Secret value with the DEK using AES-GCM, then encrypts the DEK with the
controller's RSA-OAEP public key. The resulting YAML is safe in Git — without the
private key it cannot be decrypted. The ciphertext is also **scope-bound**: by default
`kubeseal` binds to the namespace and Secret name, so the ciphertext for
`dojo-sealed/dojo-app-creds` cannot be replayed in another namespace or under a
different Secret name.

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/06-sealed-secret/verify.sh
```
