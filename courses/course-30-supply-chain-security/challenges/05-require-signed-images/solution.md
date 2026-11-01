# Solution: Require Signed Images with Kyverno

## Step 1 — Get a cosign public key

Use the key from Challenge 04, or generate a fresh pair:

```bash
mkdir -p /tmp/dojo-keys && cd /tmp/dojo-keys
cosign generate-key-pair
# Produces: cosign.key + cosign.pub
```

You only need `cosign.pub` for the policy. Get the contents:

```bash
cat cosign.pub
# -----BEGIN PUBLIC KEY-----
# MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
# -----END PUBLIC KEY-----
```

## Step 2 — Write the ClusterPolicy

Save this as `require-signed-images.yaml`, replacing the placeholder key with your actual `cosign.pub`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
  annotations:
    policies.kyverno.io/title: Require Signed Images
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/description: >-
      Blocks pods in dojo-supplychain unless every image is signed with the
      dojo cosign key. Satisfies SLSA L2 admission enforcement.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-image-signature
      match:
        resources:
          kinds:
            - Pod
          namespaces:
            - dojo-supplychain
      verifyImages:
        - imageReferences:
            - "*"
          mutateDigest: false
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE<YOUR_KEY_HERE>
                      -----END PUBLIC KEY-----
```

## Step 3 — Apply it

```bash
kubectl apply -f require-signed-images.yaml
```

## Step 4 — Verify

```bash
bash courses/course-30-supply-chain-security/challenges/05-require-signed-images/verify.sh
```

## Understanding the policy fields

**`validationFailureAction: Enforce`** — Kyverno operates in two modes. `Audit` logs violations but allows the pod to run. `Enforce` blocks the admission request outright and returns an HTTP 403 to the API client. For an image signing policy, Audit is useless as a control — you want Enforce. The trade-off is that it can block legitimate rollouts if the signing pipeline breaks, so production rollout is typically: Audit (observe) → Enforce in staging → Enforce in prod with circuit-breaker alerting.

**`background: false`** — The background controller re-evaluates existing resources on a schedule. Without this flag, Kyverno would generate policy violation events for every unsigned pod already running in the cluster (including Kyverno itself). In a dojo cluster, that's noise; in prod, it can also cause confusion between "this policy blocks new admissions" and "this policy has found 300 existing violations."

**`mutateDigest: false`** — By default Kyverno also *mutates* the Pod to pin the image to `image@sha256:...`. That's a good hardening in production (prevents tag rebasing attacks) but it can break rollouts if the registry is temporarily unreachable. Setting it to false separates the signing check from the digest mutation concern so you can reason about each independently.

**`required: true`** — Without this, if the image has no signature at all, Kyverno skips the check rather than failing. This is the field that makes the rule a hard requirement rather than a best-effort check.

## Attacker's view

With this policy in place, an attacker who can push a malicious image to your registry still can't run it without a valid cosign signature. They'd need the private key. The remaining attack surfaces are:

1. **Kyverno itself bypassed** — if someone can `kubectl create pod` with a `nodeSelector` landing on a node that doesn't route through the webhook (webhook failure policy: Ignore), the check is skipped. Set `webhooks[].failurePolicy: Fail` in the Kyverno config to make admission webhook failures block rather than allow.
2. **Policy scoping gaps** — the policy only covers `dojo-supplychain`. A workload in any other namespace is unprotected. In production, scope to all non-system namespaces or use a namespace label selector.
3. **Key rotation lag** — when you rotate the cosign key, all in-flight images signed with the old key become invalid until the policy is updated with the new key. Plan key rotation together with the policy update and have an emergency rollback procedure.

## Why `verifyImages` beats a `validate` rule

You could write a simpler `validate` rule that checks `image` matches `*@sha256:*` (digest pinning). That stops tag rebasing attacks but does not verify a signature — it confirms the image was pulled by digest, not that the digest corresponds to a key-holder-approved artifact. `verifyImages` integrates the cryptographic check: the image must exist in the registry AND have a valid cosign signature by the specified key, meaning only your CI/CD with the private key could have produced it.
