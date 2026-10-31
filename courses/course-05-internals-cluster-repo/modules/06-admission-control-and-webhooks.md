# Admission Control & Webhooks

> **Module 06 · Course 05** — Between "the API server authenticated and authorized your request" and "the object is written to etcd" sits a gauntlet: **admission control**. This is where defaults get injected, sidecars get added, `:latest` gets rejected, and Pod Security gets enforced. It's the most powerful policy surface in Kubernetes — and the one most likely to let *you* brick your own cluster. This module walks the admission chain end to end, then goes deep on the modern, webhook-free option (ValidatingAdmissionPolicy with CEL) and the failure modes that take clusters down.

You've been admitted or rejected by these controllers thousands of times at work (every `kubectl apply` runs the chain). What separates competent from expert is knowing the exact order, why *mutating runs before validating*, why a `failurePolicy: Fail` webhook with a down backend is a self-inflicted outage, and when to reach for built-in CEL policy instead of standing up a webhook server at all.

---

## The request lifecycle: where admission sits

```
kubectl apply
   │
   ▼
┌──────────────┐  ┌──────────────┐  ┌─────────────────── ADMISSION ───────────────────┐  ┌──────────┐
│ Authentication│→ │ Authorization │→ │  Mutating  →  (schema  →  Validating            │→ │  etcd    │
│   (who?)      │  │  (allowed?)   │  │  admission     validation)  admission            │  │ (persist)│
└──────────────┘  └──────────────┘  │  (may CHANGE)             (may only ACCEPT/REJECT) │  └──────────┘
                                     └───────────────────────────────────────────────────┘
```

The ordering is deliberate and testable:

1. **Mutating admission runs first** — it can *modify* the object (inject a sidecar, set a default resource request, add a label). Built-in mutating plugins run, then your `MutatingWebhookConfiguration` webhooks.
2. **Schema validation** runs in the middle — the object is checked against the OpenAPI schema (and CRD CEL rules).
3. **Validating admission runs last** — it can only say *yes* or *no*, never change the object. Built-in validating plugins, then `ValidatingAdmissionPolicy` (CEL), then your `ValidatingWebhookConfiguration` webhooks.

Why this order? Because validation must see the **final** object. If validation ran before mutation, a mutating webhook could inject something that violates policy *after* the check passed. Mutate first, then validate the result — so the thing you persist is exactly the thing you approved.

> A single webhook config can be both: a mutating webhook may also be re-invoked. Set `reinvocationPolicy: IfNeeded` when one mutating webhook's output should be seen by another (e.g. a sidecar injector must run before a policy that patches the sidecar). Ordering *within* a phase is not guaranteed, so never assume webhook A runs before webhook B.

---

## Built-in admission controllers

Dozens ship compiled into the API server and run on the chain by default (tune with `--enable-admission-plugins` / `--disable-admission-plugins`). The ones you actually reason about:

| Controller | Phase | What it does |
|---|---|---|
| `NamespaceLifecycle` | validating | blocks creates in terminating/missing namespaces |
| `LimitRanger` | mutating | injects default resource requests/limits from a `LimitRange` |
| `ResourceQuota` | validating | rejects creates that would exceed a `ResourceQuota` |
| `ServiceAccount` | mutating | auto-mounts the SA token, sets `default` SA |
| `DefaultStorageClass` | mutating | stamps the default StorageClass onto PVCs with none |
| `PodSecurity` | validating | enforces Pod Security Standards per namespace (see below) |
| `MutatingAdmissionWebhook` | mutating | calls out to *your* mutating webhooks |
| `ValidatingAdmissionWebhook` | validating | calls out to *your* validating webhooks |

The last two are the extension points — they're how everything from Istio sidecar injection to Kyverno hooks into the chain.

---

## Pod Security Admission: the built-in baseline

PSA replaced the old PodSecurityPolicy. It's a built-in validating controller configured entirely with **namespace labels** — no webhook, no CRD. Three standards (`privileged` → `baseline` → `restricted`) and three modes (`enforce`, `audit`, `warn`):

```bash
# enforce the restricted profile; also warn on the (future) latest version
kubectl label ns dojo-apps \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted
```

Now a Pod that runs as root, requests privilege escalation, or mounts the host network is rejected at admission with a precise message. The expert move is `warn`/`audit` *first* to see what would break, then flip to `enforce` — turning on `restricted` cold in a busy namespace rejects half your workloads instantly.

---

## ValidatingAdmissionPolicy: CEL, built-in, no webhook server

This is the big modern shift (GA in 1.30). For most *validation* policy you no longer need to run a webhook server at all — you express the rule in **CEL** and the API server evaluates it in-process. No pod to keep alive, no TLS to rotate, no network hop, no `failurePolicy` outage risk from a crashed backend.

Here's a complete policy that **blocks `:latest` (and untagged) images** on Pods — the canonical example:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: block-latest-images
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps", ""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "pods", "statefulsets", "daemonsets", "replicasets"]
  validations:
    - expression: >-
        !object.spec.template.spec.containers.exists(c,
          c.image.endsWith(':latest') || !c.image.contains(':'))
      message: "images must be pinned to an explicit tag; ':latest' and untagged images are rejected"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: block-latest-images-binding
spec:
  policyName: block-latest-images
  validationActions: ["Deny"]           # or Warn / Audit while rolling out
  matchResources:
    namespaceSelector:
      matchLabels:
        dojo-policy: enforced            # scope it; don't blanket the whole cluster
```

The policy/binding split is the point: the **policy** defines the rule once, the **binding** chooses *where* it applies and *how hard* (`Deny` vs `Warn` vs `Audit`). You can bind the same policy to one namespace in `Audit` mode and another in `Deny`, which is exactly how you roll out safely.

A cleaner CEL expression for just the common cases (bare Pods *and* the Pod template under workloads need separate policies, or match the `pods` resource directly):

```yaml
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest') && c.image.contains(':'))"
      message: "pin images to an explicit tag; ':latest'/untagged is rejected"
```

CEL also gives you `variables`, `object` (the incoming object), `oldObject` (on UPDATE), `request` (userInfo, operation), and `params` (a referenced config object) — enough for the large majority of policy without ever shipping a binary.

---

## Validating & mutating webhooks: how they intercept

When CEL isn't enough (you need to call an external system, do complex cross-object logic, or mutate), you register a webhook. A `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` tells the API server: "for these resources+operations, POST an `AdmissionReview` to this HTTPS endpoint and obey the response."

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy.dojo.example.com
webhooks:
  - name: image-policy.dojo.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail                 # ← the loaded gun (see Debugging)
    timeoutSeconds: 5                    # ← keep SHORT
    namespaceSelector:                   # ← SCOPE IT — never match everything
      matchLabels: { dojo-policy: enforced }
    rules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
    clientConfig:
      service:
        namespace: dojo-webhooks
        name: image-policy-svc
        path: /validate
      caBundle: <base64-CA-that-signed-the-webhook-serving-cert>
```

The flow: API server serializes the (already-mutated) object into an `AdmissionReview`, POSTs it over TLS, your server returns `{"response": {"allowed": false, "status": {"message": "..."}}}`, and the API server honors it. Mutating webhooks instead return a base64 **JSONPatch** that the API server applies.

**Decision guide:**

| Need | Reach for |
|---|---|
| Reject based on object fields (even cross-field, CEL-expressible) | **ValidatingAdmissionPolicy** (no server) |
| Mutate / inject defaults, sidecars | **MutatingWebhook** (or policy engine) |
| Call external system, complex logic, generate resources | **Webhook** or a **policy engine** |
| Fleet-wide policy-as-code with reporting | **Kyverno** or **OPA Gatekeeper** |

### Policy engines: Kyverno vs OPA Gatekeeper

You rarely hand-write webhook servers in practice — you install a policy engine that *is* the webhook and you feed it policies as CRs:

- **Kyverno** — policies are Kubernetes YAML (no new language). Great for validate/mutate/generate (e.g. auto-create a NetworkPolicy per namespace). Lower learning curve; Kubernetes-native feel.
- **OPA Gatekeeper** — policies in **Rego** via `ConstraintTemplate` + `Constraint`. More powerful/expressive for complex logic, steeper curve, strong audit mode that reports *existing* violations, not just new ones.

Both register as webhooks, so both inherit every failure mode below. For simple "block `:latest`" rules, the built-in `ValidatingAdmissionPolicy` now beats reaching for either.

---

## Debugging admission control

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| **Everything** hangs — can't create pods, nodes, even in kube-system | `failurePolicy: Fail` webhook whose backend is down/unreachable | Delete the webhook config; narrow its `namespaceSelector`; exclude kube-system |
| `apply` slow by exactly N seconds then works | webhook timing out, `failurePolicy: Ignore` | Fix/scale the webhook backend; drop `timeoutSeconds` |
| `x509: certificate signed by unknown authority` on admit | `caBundle` doesn't match the webhook's serving cert | Regenerate `caBundle` from the serving CA; cert-manager `ca-injector` can auto-fill |
| Policy silently not enforced | binding in `Audit`/`Warn`, or selector doesn't match | Check `validationActions` / webhook `namespaceSelector` labels |
| Pods rejected "violates PodSecurity restricted" | namespace labeled `enforce=restricted` | Fix the Pod securityContext, or relax the ns label after review |
| Mutating webhook change not visible to another webhook | no re-invocation | set `reinvocationPolicy: IfNeeded` |
| CEL policy errors on some objects | expression assumes a field that's absent | guard with `has(object.spec.x)` / use `?` optionals |

Diagnose each with the exact commands:

```bash
# list every admission webhook — the first thing to check when the cluster "won't let you do anything"
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# which webhook matches, and is it Fail-closed?
kubectl get validatingwebhookconfiguration <name> \
  -o jsonpath='{range .webhooks[*]}{.name}{" failurePolicy="}{.failurePolicy}{" timeout="}{.timeoutSeconds}{" ns-selector="}{.namespaceSelector}{"\n"}{end}'

# is the webhook's backing service even up?
kubectl -n dojo-webhooks get svc,endpoints,pods
kubectl -n dojo-webhooks logs deploy/image-policy-svc --tail=50

# see the admission decision in the API server's own voice
kubectl apply -f some-pod.yaml --dry-run=server 2>&1 | tail

# CEL policy evaluation / binding state
kubectl get validatingadmissionpolicy block-latest-images -o yaml | grep -A3 status:
kubectl get validatingadmissionpolicybinding

# PodSecurity: what's enforced on a namespace?
kubectl get ns dojo-apps -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security

# THE ESCAPE HATCH when a webhook has bricked the cluster:
kubectl delete validatingwebhookconfiguration <name>
kubectl delete mutatingwebhookconfiguration <name>
```

> **War story.** A security team rolled out a validating webhook to enforce image signing, with `failurePolicy: Fail` (correct for security — fail *closed*) and a `rules` block matching `resources: ["pods"]` on `operations: ["CREATE"]` with **no `namespaceSelector`**. It worked beautifully for a week. Then the webhook's own Deployment got rescheduled during a node drain — and here's the trap: the webhook's pods *are pods*, so the API server called the (now-down) webhook to admit the webhook's own replacement pods. `failurePolicy: Fail` meant those creates were rejected. The webhook couldn't come up because admitting it required the webhook to be up. Nothing could schedule — not the webhook, not CoreDNS, not anything — a total, self-locking control-plane outage. Recovery was `kubectl delete validatingwebhookconfiguration` (which still worked, because *that* verb wasn't gated), then re-applying with a `namespaceSelector` that excluded `kube-system` and the webhook's own namespace, plus a liveness-driven `objectSelector`. Three rules were burned in forever: **(1)** always scope admission webhooks with a `namespaceSelector` that excludes system namespaces and the webhook's own; **(2)** a `Fail`-closed webhook must never be in its own admission path; **(3)** keep `timeoutSeconds` low (≤5s) so a slow backend degrades instead of hanging every write in the cluster.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Draw the request lifecycle and place mutating vs validating admission in order — and explain *why* mutating must run before validating.
2. Name four built-in admission controllers and say whether each mutates or validates.
3. Configure Pod Security Admission on a namespace with the three modes, and explain why you roll out with `warn`/`audit` before `enforce`.
4. Write a `ValidatingAdmissionPolicy` + binding that blocks `:latest` images with CEL, and explain why the policy/binding split lets you roll out in `Audit` then `Deny`.
5. Explain how a validating webhook intercepts a request (AdmissionReview round-trip) and how a mutating one differs (returns a JSONPatch).
6. Explain the `failurePolicy: Fail` + down-backend outage, the self-admission trap, and the three mitigations (scope with selectors, keep webhooks out of their own path, short timeouts).
7. Say when a built-in CEL policy beats installing Kyverno/Gatekeeper, and one thing each policy engine does that CEL can't.

➡ You've now seen the control plane from etcd's bytes up through the admission gauntlet. Next course segments put you in the operator's seat: cluster lifecycle (kubeadm upgrades, cordon/drain) and repository management.
