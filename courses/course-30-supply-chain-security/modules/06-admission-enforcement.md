# Admission Enforcement

> **Module 06 · Course 30** — Signing images proves provenance. Admission enforcement makes that proof *mandatory*. Without it, signing is a paper audit trail — a developer can always `kubectl run` an unsigned image and nothing stops it. Admission webhooks are the last gate between the API server and a running workload.

This module covers the three main enforcement tools (Kyverno, Sigstore policy-controller, Connaisseur), the critical `enforce` vs `audit` tradeoff, and the failure modes that have bricked production deployments.

---

## How admission webhooks work

Every time an object is created or updated in Kubernetes, the API server calls registered webhooks before writing to etcd:

```
kubectl apply              API server
     │                         │
     ▼                         │
   auth/z ──────────────────▶  │
                               │──▶ MutatingAdmissionWebhook (e.g. Kyverno mutate)
                               │       └── can rewrite the object
                               │──▶ ValidatingAdmissionWebhook (e.g. Kyverno verify)
                               │       └── allow or deny
                               │
                     write to etcd (or reject)
```

A `ValidatingWebhookConfiguration` tells the API server: "for these resource kinds and operations, call my webhook endpoint; if it returns `Allowed: false`, reject the request."

The critical field is `failurePolicy`:
- `failurePolicy: Fail` — if the webhook is unreachable, **deny the request**. Safe but operationally sharp: webhook outage = admission outage.
- `failurePolicy: Ignore` — if the webhook is unreachable, **allow the request**. Safe for development, insecure for production: webhook outage = enforcement silently disabled.

Choose `Fail` for production enforcement of security policies. The availability implication is real — design for it (see Debugging below).

---

## Kyverno verifyImages

[Kyverno](https://kyverno.io/) is a Kubernetes-native policy engine. Its `verifyImages` rule calls cosign internally to verify signatures and attestations before admitting a Pod.

### Installation

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set replicaCount=3              # HA — critical for failurePolicy: Fail
```

### A complete verifyImages policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-supply-chain
  annotations:
    policies.kyverno.io/description: >
      Require every image from ghcr.io/myorg to carry a valid cosign keyless
      signature from the release workflow. Block :latest and unapproved registries.
spec:
  validationFailureAction: Enforce   # Enforce = deny; Audit = log only
  background: true                   # also audit existing workloads
  rules:

    # ── 1. verify signature ────────────────────────────────────────────────
    - name: check-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
          skipImageReferences:
            - "ghcr.io/myorg/dojo-debug:*"   # explicit exception, not a wildcard escape
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/myorg/*/(.github/workflows/release.yml)@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: "https://rekor.sigstore.dev"

    # ── 2. require SLSA provenance attestation ────────────────────────────
    - name: check-provenance
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
          attestations:
            - predicateType: "https://slsa.dev/provenance/v0.2"
              attestors:
                - entries:
                    - keyless:
                        subject: "https://github.com/myorg/*/(.github/workflows/release.yml)@refs/heads/main"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor:
                          url: "https://rekor.sigstore.dev"
              conditions:
                - all:
                    - key: "{{ builder.id }}"
                      operator: Equals
                      value: "https://github.com/myorg/myapp/.github/workflows/release.yml"

    # ── 3. block :latest ──────────────────────────────────────────────────
    - name: block-latest-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Pinning to :latest is not allowed. Use an explicit tag or digest."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ element.image }}"
                    operator: Contains
                    value: ":latest"
                  - key: "{{ element.image }}"
                    operator: NotContains
                    value: ":"

    # ── 4. registry allow-list ────────────────────────────────────────────
    - name: restrict-registries
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Images must come from ghcr.io/myorg or registry.k8s.io."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotStartsWith
                    value: "ghcr.io/myorg/"
                  - key: "{{ element.image }}"
                    operator: NotStartsWith
                    value: "registry.k8s.io/"
```

This single policy does four things: verifies signatures, verifies provenance attestations, blocks `:latest`, and restricts registries. Each rule is independent — a pod fails admission if any rule denies it.

### How Kyverno resolves the image reference

Kyverno rewrites the image reference in the Pod spec to a digest after verification. This is a mutation: the pod that runs has `image: ghcr.io/myorg/myapp@sha256:...` even if the manifest said `:v1.0.0`. This pins the running workload to the exact digest that was verified — a rolling restart can't silently pull a different layer.

---

## Sigstore policy-controller

The [Sigstore policy-controller](https://github.com/sigstore/policy-controller) is cosign's native Kubernetes enforcement component. It uses a `ClusterImagePolicy` CRD instead of Kyverno policies.

```bash
helm install policy-controller sigstore/policy-controller \
  --namespace cosign-system --create-namespace
```

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-signed-images
spec:
  images:
    - glob: "ghcr.io/myorg/**"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: "https://github.com/myorg/.*/.github/workflows/release.yml@refs/heads/main"
```

policy-controller is lighter than Kyverno (single-purpose) and integrates natively with Fulcio/Rekor. Trade-off: it only does image verification — you'll need a second tool for general Kubernetes policy (PodSecurity, network policies, etc.). Kyverno does both.

### Connaisseur (brief)

[Connaisseur](https://github.com/sse-secure-systems/connaisseur) is a third enforcement option, with a focus on Notary v2 and cosign, and a simpler config surface than Kyverno. It's worth knowing the name if you encounter it in enterprise contexts, but for new installations Kyverno or policy-controller are the current defaults.

---

## Enforce vs audit: choosing the right mode

The first time a team deploys an image verification policy in `Enforce` mode, they discover which workloads they forgot to sign. The `Audit` mode lets you find those without breaking anything:

```yaml
# Phase 1: discover — Audit logs violations but does not block
spec:
  validationFailureAction: Audit

# Phase 2: enforce — block unsigned images
spec:
  validationFailureAction: Enforce
```

Check what audit mode caught before switching:

```bash
kubectl get policyreports -A
kubectl get clusterpolicyreport -o jsonpath='{.results[*].message}' | tr ' ' '\n' | sort | uniq
```

A sensible rollout:
1. Deploy in `Audit` mode. Check `policyreports` for 1–2 weeks.
2. Fix every violation (sign the image, add a justified exception).
3. Switch to `Enforce` on non-production first.
4. Switch to `Enforce` on production with `failurePolicy: Fail` and Kyverno in HA mode.

---

## Registry allow-lists

A registry allow-list enforces that only approved image sources can run. This stops:
- A developer pulling `hacker.io/malicious:latest` directly into the cluster
- Typosquatting attacks (e.g., `gcr.io/k8s-proj` vs `registry.k8s.io`)
- Images from Docker Hub (high surface area, no signing enforced)

The `restrict-registries` rule above does this. The list you maintain should be:
- Your organisation's registry (GHCR, ECR, Artifact Registry)
- `registry.k8s.io` — for system components
- Optionally `quay.io/jetstack` or similar for known-good ecosystem components

Do not add `docker.io` to the allow-list unless you sign everything you use from there.

---

## Debugging Admission Enforcement

Admission policies fail in two directions: they block things they shouldn't (too strict), or they pass things they shouldn't (misconfigured / audit mode). Both are dangerous in different ways.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| All Pod creates fail with `webhook: connection refused` or timeout | Kyverno pods are down or `failurePolicy: Fail` on a failing webhook | Check `kubectl -n kyverno get pods`; if Kyverno is down, the webhook must be temporarily set to `failurePolicy: Ignore` or deleted to restore admission. Long-term: run 3 replicas on separate nodes |
| Pod fails with `image signature verification failed: no signatures found` | Image was not signed, or signed with different identity/key | Run `cosign tree <image>` to confirm signatures exist; check that the `subject` and `issuer` in the policy match the OIDC claims used at signing time |
| Policy set to `Enforce` but unsigned images run fine | Policy matches the wrong resource scope, or `background: true` doesn't cover new pods | Confirm `validationFailureAction: Enforce`; check the `match` block; test with `kubectl apply --dry-run=server` |
| Policy correctly blocks prod but dev namespace is unaffected | Policy has a `namespaceSelector` or `match.namespaces` that excludes dev | Intentional if you added an exception; unintentional if the selector is wrong — audit with `kubectl describe clusterpolicy` |
| `cosign verify` passes manually but Kyverno still denies | Kyverno's internal cosign library version or Rekor URL differs | Check Kyverno's `verifyImages` logs: `kubectl -n kyverno logs -l app=kyverno | grep verifyImages`; confirm `rekor.url` in the policy matches what you used to sign |
| After adding an exception (`skipImageReferences`), more images bypass than expected | Glob pattern is too broad (e.g., `ghcr.io/myorg/debug:*` matches unexpected images) | Be explicit; prefer exact tags or digest refs in skip lists |

### Diagnose a blocked deployment end-to-end

```bash
# step 1 — see the actual webhook denial message
kubectl describe pod <pod-name> -n <ns>
# look at Events: "Failed" + "Error from server: admission webhook ... denied"

# step 2 — check Kyverno policy reports
kubectl get polr -n <ns> -o wide
kubectl describe polr -n <ns>

# step 3 — dry-run to test the policy without applying
kubectl apply -f pod.yaml --dry-run=server 2>&1

# step 4 — temporarily switch to Audit to see what passes
kubectl patch clusterpolicy verify-supply-chain \
  --type=merge -p '{"spec":{"validationFailureAction":"Audit"}}'
# (remember to switch back!)

# step 5 — check Kyverno's own logs for the cosign call
kubectl -n kyverno logs -l app.kubernetes.io/name=kyverno \
  --since=5m | grep -E "verif|cosign|ERROR"
```

### Managing legitimate exceptions

Not every image in the cluster will be signed (system components, operator images, etc.). Never use a blanket `skipImageReferences: ["*"]` — that defeats the policy entirely. Instead:

```yaml
skipImageReferences:
  - "registry.k8s.io/*"             # k8s system components — trusted by registry source
  - "quay.io/jetstack/cert-manager-controller:v1.14.5"   # exact version, not wildcard
```

Document every exception in the policy annotation. Exceptions that can't be justified should be fixed by signing the image.

> **War story.** A platform team deployed a Kyverno `verifyImages` policy in `Enforce` mode with `failurePolicy: Fail` on a Friday afternoon. The rollout looked clean — all three Kyverno pods were running. Saturday morning: an automated Argo CD sync tried to roll out a new app version. It hit a Kyverno pod that was in the middle of a liveness-probe-triggered restart (a known Kyverno issue under load). The sync failed, Argo CD marked the app `Degraded`, and the on-call engineer couldn't redeploy anything — every Pod create hit the degraded webhook. The fix at 2am was `kubectl -n kyverno scale deploy kyverno --replicas=5` and a patch to add a `podDisruptionBudget` requiring at least 2 Kyverno pods healthy at all times. The lesson: `failurePolicy: Fail` is the right choice for security, but it means Kyverno availability is now *load-bearing for your cluster*. Treat it like a core system component: HA, PDB, monitored, and with a documented emergency bypass procedure.

---

## Checkpoint

You're ready for the admission challenges when you can, without looking anything up:

1. Explain the difference between `failurePolicy: Fail` and `failurePolicy: Ignore` at the webhook level, and which is correct for a production security policy.
2. Write (from memory) a Kyverno `verifyImages` rule that requires a keyless signature from a GitHub Actions release workflow. Name the three fields inside `keyless` you must configure.
3. Explain why Kyverno rewrites image references to digests after verification, and what attack this prevents.
4. Describe how to roll out an enforcement policy safely without bricking production on day one.
5. Given that `cosign verify` passes manually but Kyverno still denies the pod, name the first log command you run and what you're looking for.
6. State when a `skipImageReferences` exception is justified, and what the minimum specificity of the pattern should be.
7. What is the operational dependency you implicitly accept when you set `failurePolicy: Fail` on a Kyverno webhook?

➡ Next up: **Securing the Build & CI** — enforcement at admission is the last gate, but the real leverage is making the thing worth verifying: a hermetic, reproducible build with no static credentials.
