# Solution — Ban the Latest

The flag is `KUBE{cel_policy_bans_the_latest_tag}`.

Two objects. One is the rule; one turns it on. Apply both:

```yaml
# ban-latest.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ban-latest-image
spec:
  failurePolicy: Fail                 # if the policy errors, deny — fail closed
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]             # core group: Pods
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
      - apiGroups:   ["apps"]         # apps group: Deployments (catch it early)
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  variables:
    # A Pod's container spec is object.spec; a Deployment's is object.spec.template.spec.
    - name: podSpec
      expression: "has(object.spec.template) ? object.spec.template.spec : object.spec"
    # Check init + regular containers together (ephemeral too, if present).
    - name: allContainers
      expression: >-
        variables.podSpec.containers +
        (has(variables.podSpec.initContainers) ? variables.podSpec.initContainers : [])
  validations:
    - expression: >-
        variables.allContainers.all(c,
          c.image.contains(':') && !c.image.endsWith(':latest'))
      message: "images must use an immutable tag: ':latest' and untagged images are rejected"
      reason: Invalid
---
# ban-latest-binding.yaml  — the switch; without this the policy enforces NOTHING
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ban-latest-binding
spec:
  policyName: ban-latest-image
  validationActions: ["Deny"]         # Deny = reject; also valid: Warn, Audit
  matchResources:
    namespaceSelector:
      matchLabels:
        dojo-policy: enforce           # setup.sh labeled dojo-admission with this
```

```bash
kubectl apply -f ban-latest.yaml -f ban-latest-binding.yaml
bash courses/course-05-internals-cluster-repo/challenges/02-validating-admission-policy/verify.sh
```

## Prove it by hand

```bash
kubectl -n dojo-admission run bad  --image=nginx:latest      --restart=Never --dry-run=server
# Error ... admission webhook ... denied the request:
#   images must use an immutable tag: ':latest' and untagged images are rejected

kubectl -n dojo-admission run good --image=nginx:1.27-alpine --restart=Never --dry-run=server
# pod/good created (server dry run)

# Deployments are caught before any Pod is ever created:
kubectl -n dojo-admission create deploy bad-deploy --image=redis:latest --dry-run=server
# denied by the same policy
```

## Why each piece is correct

- **Policy + Binding are two objects.** The `ValidatingAdmissionPolicy` is just a *definition*; the `ValidatingAdmissionPolicyBinding` is what activates it, chooses the action (`Deny`/`Warn`/`Audit`), and scopes it. This separation is deliberate: you can ship one audited policy and bind it with `Warn` in staging and `Deny` in prod, or bind it to different namespace sets, without touching the rule.
- **`validationActions: ["Deny"]`** is the enforcement. `Warn` returns the message as a warning header but still admits — perfect for a soak period before you flip to `Deny`. `Audit` writes to the audit log only.
- **CEL `object`** is the incoming resource. The `has(object.spec.template)` ternary lets one policy cover both Pods (`object.spec.containers`) and Deployments (`object.spec.template.spec.containers`) — matching Deployments too means the user gets the rejection on `kubectl apply deploy`, not a silently-stuck rollout whose ReplicaSet can't create Pods.
- **`.all(c, ...)`** short-circuits to `false` the moment any container violates the rule, so a single bad sidecar fails the whole object.
- **`c.image.contains(':')`** rejects *untagged* images (`nginx`), because an untagged reference resolves to `:latest` implicitly — the exact footgun you're banning. `!c.image.endsWith(':latest')` rejects the explicit form. A `@sha256:...` digest contains `:` and does not end with `:latest`, so pinned-by-digest images (the gold standard) pass.
- **`failurePolicy: Fail`** fails closed: if CEL hits a runtime error, the request is denied rather than waved through. For a security control, fail-closed is the safe default.
- **`namespaceSelector` on the binding** scopes enforcement to `dojo-admission` via its `dojo-policy=enforce` label — the rest of the cluster is untouched, which is how you roll a policy out gradually.

## Known refinement (and why the lab keeps it simple)

`contains(':')` treats a registry port as a "tag" — `registry.local:5000/app` would pass the untagged check even though it has no tag. Production-grade policies parse the *last* path segment after the final `/` before testing for a tag, or use a `matchExpression`/regex. The lab's rule is exact for the images the verifier uses (`nginx:latest` vs `nginx:1.27-alpine`) and keeps the CEL readable; tightening the untagged-vs-port distinction is a worthwhile exercise once the basic policy passes.

## The attacker's / bypass view

- **This is an admission-time control, not a runtime one.** Objects that already existed before the policy was bound are not re-evaluated — the policy only fires on CREATE/UPDATE. Enforce early, and audit existing workloads separately.
- **Mutating admission runs *before* validating admission.** A mutating webhook (or a defaulting controller) could rewrite an image after your policy would have seen it — but with VAP in the validating phase you see the final object, so a mutating step that *adds* a `:latest` image still gets caught. Ordering matters; know which phase you're in.
- **Scope is only as tight as the binding.** A `namespaceSelector` that matches a label any namespace owner can set themselves is bypassable by simply not setting the label. For a real "no `:latest` anywhere" guarantee, bind cluster-wide (omit the selector) and carve out exceptions explicitly.
- **CEL has no I/O.** It cannot call a registry to check whether a tag is mutable — it reasons only about the image *string*. That's a feature (fast, no network in the request path) and a limit (it trusts the reference text). Pair it with an image-signature/admission policy (e.g. Sigstore policy-controller) if you need provenance, not just immutability.
