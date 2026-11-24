# Policy as Code — OPA Gatekeeper and Kyverno

> **Module 10 · Course 38** — The scanner found a critical CVE. The developer committed a privileged container. The intern deployed an image with no resource limits. All three made it to production because nothing at the cluster level said "no." Policy as Code means you define your security rules in code, version-control them, and have the cluster enforce them automatically — on every single `kubectl apply`, forever. OPA Gatekeeper and Kyverno are the two main systems that do this. This module covers both.

---

## The Admission Control Layer

When you run `kubectl apply -f pod.yaml`, the request flows through Kubernetes admission:

```
kubectl apply                   Kubernetes API Server
      │                                │
      ▼                                ▼
    API request          ┌─────────────────────────────────────┐
    arrives              │   Admission Controllers (in order)   │
                         │                                       │
                         │  1. Authentication (who are you?)     │
                         │  2. Authorization (RBAC can-you?)     │
                         │  3. Mutating admission webhooks       │  ← Kyverno mutate
                         │     (modify the object)               │
                         │  4. Schema validation                 │
                         │  5. Validating admission webhooks     │  ← OPA Gatekeeper
                         │     (allow or deny)                   │  ← Kyverno validate
                         └─────────────────────────────────────┘
                                        │
                                        ▼
                                   etcd (stored)
                                        │
                                        ▼
                               Scheduler → kubelet
                               Pod starts on node
```

The admission webhooks are HTTP endpoints. When a resource is created/updated, the API server sends the object to every registered webhook. Each webhook returns: allow or deny (with a reason). If any denies: the apply fails with an error message explaining why.

---

## OPA Gatekeeper

**OPA** (Open Policy Agent) is a general-purpose policy engine. It uses a language called **Rego** to define policies. **Gatekeeper** is the Kubernetes integration layer — it registers the admission webhook and translates K8s resources into OPA evaluations.

### Architecture

```
kubectl apply (privileged pod)
      │
      ▼
API server → Gatekeeper ValidatingWebhookConfiguration
      │
      ▼
Gatekeeper controller
  reads all Constraints and their ConstraintTemplates
  evaluates the resource against each policy
  if any violation → deny with message
      │
      ▼
"Error: pod violates ConstraintTemplate 'BlockPrivileged': containers must not be privileged"
```

### The Two-Object Pattern

OPA Gatekeeper requires 2 Kubernetes resources per policy:

**1. ConstraintTemplate** — the policy logic (Rego code)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: blockprivilegedcontainer
spec:
  crd:
    spec:
      names:
        kind: BlockPrivilegedContainer   # Creates a new CRD type
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package blockprivilegedcontainer

      violation[{"msg": msg}] {
        # Evaluate each container in the pod
        container := input.review.object.spec.containers[_]
        # If the securityContext says privileged: true
        container.securityContext.privileged == true
        # Then create a violation with this message
        msg := sprintf("Container '%v' must not be privileged", [container.name])
      }

      violation[{"msg": msg}] {
        # Also check initContainers
        container := input.review.object.spec.initContainers[_]
        container.securityContext.privileged == true
        msg := sprintf("InitContainer '%v' must not be privileged", [container.name])
      }
```

**2. Constraint** — where and how to apply the template

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: BlockPrivilegedContainer   # Must match CRD created by the ConstraintTemplate
metadata:
  name: block-privileged-containers
spec:
  enforcementAction: deny    # deny | warn | dryrun
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]         # Apply to Pods
    - apiGroups: ["apps"]
      kinds: ["Deployment", "DaemonSet", "StatefulSet"]   # Also Deployments etc.
  # Optional: scope to specific namespaces
  # namespaces: [production, staging]
```

---

## Rego — The Policy Language

Rego is a declarative query language. Its logic is "backwards" compared to imperative code:

```
# Rego philosophy:
# You DEFINE what a violation IS, not what to check for.
# If the violation set is non-empty, the policy fires.

package blockprivilegedcontainer

# This is a "violation" — a rule that generates a set of messages
violation[{"msg": msg}] {
  # This block says: "this is a violation IF all these conditions are true"
  
  container := input.review.object.spec.containers[_]
  # _    = any index (Rego's wildcard — evaluates for ALL containers)
  # input.review.object = the K8s resource being admitted
  
  container.securityContext.privileged == true
  # If this field is true, the conditions are all met → violation fires
  
  msg := sprintf("Container '%v' must not be privileged", [container.name])
  # The message to show in the error
}

# Multiple violation rules → ANY of them firing = policy violation
```

**Testing Rego locally:**

```bash
# Install opa CLI
brew install opa

# test.rego — your policy
# test_data.json — fake K8s admission review object

# Test a good pod (should have 0 violations):
opa eval \
  --data test.rego \
  --input good_pod.json \
  'data.blockprivilegedcontainer.violation'
# Output: []  ← no violations

# Test a bad pod (should have 1 violation):
opa eval \
  --data test.rego \
  --input bad_pod.json \
  'data.blockprivilegedcontainer.violation'
# Output: [{"msg": "Container 'nginx' must not be privileged"}]
```

---

## Gatekeeper Enforcement Modes

```yaml
spec:
  enforcementAction: deny     # Hard block — apply fails with error
  enforcementAction: warn     # Soft warning — apply succeeds but shows warning
  enforcementAction: dryrun   # Audit only — violations logged but not blocked
```

**Audit mode (dryrun)** is used to see what WOULD be blocked without breaking anything. Check violations:

```bash
kubectl get constraint block-privileged-containers -o yaml
# .status.violations lists existing resources that violate the policy
```

---

## Common OPA Policies

**1. No latest tag:**

```rego
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Container '%v' uses :latest tag — pin to a digest or specific version", [container.name])
}
```

**2. Require resource limits:**

```rego
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf("Container '%v' must have CPU limits", [container.name])
}
```

---

## Kyverno

Kyverno is a Kubernetes-native policy engine — policies are written in YAML, not a separate language. It's simpler for most cases than OPA.

### ClusterPolicy — Block Privileged Containers

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: Enforce   # Enforce | Audit
  background: true                   # Also scan existing resources
  rules:
  - name: disallow-privileged-containers
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "Privileged containers are not allowed."
      pattern:
        spec:
          containers:
          - =(securityContext):   # = means optional field, pattern applies if present
              =(privileged): "false | null"
              # Must be false or absent — cannot be true
```

### Kyverno Mutation — Auto-add Security Context

Kyverno can automatically ADD fields to resources, not just reject them:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-security-context
spec:
  rules:
  - name: add-nonroot
    match:
      any:
      - resources:
          kinds: [Pod]
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - (name): "*"            # Match all containers
            securityContext:
              allowPrivilegeEscalation: false
              runAsNonRoot: true
              runAsUser: 65534     # nobody
```

This automatically adds the security context to every pod — developers don't have to remember to do it.

### Kyverno Image Verification with cosign

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  rules:
  - name: verify-cosign-signature
    match:
      any:
      - resources:
          kinds: [Pod]
    verifyImages:
    - imageReferences: ["ghcr.io/myorg/*"]
      attestors:
      - count: 1
        entries:
        - keyless:
            subject: "https://github.com/myorg/myrepo/.github/workflows/build.yml@refs/heads/main"
            issuer: "https://token.actions.githubusercontent.com"
            rekor:
              url: https://rekor.sigstore.dev
      # Pod with unsigned image from ghcr.io/myorg/ → DENIED
      # Pod with valid cosign signature → ALLOWED
```

---

## OPA Gatekeeper vs Kyverno

| Feature | OPA Gatekeeper | Kyverno |
|---------|---------------|---------|
| Policy language | Rego (separate DSL) | YAML (K8s-native) |
| Learning curve | Higher | Lower |
| Expressiveness | Very high | High |
| Mutation support | No (validate only) | Yes (validate + mutate + generate) |
| Image verification | No (need external) | Built-in with cosign |
| Testing | `opa test` / `conftest` | `kyverno test` |
| Resource count | 2 objects per policy | 1 object per policy |
| Community | CNCF graduated | CNCF incubating |
| Best for | Complex logic, existing OPA infra | Simpler policies, all-in-one |

---

## Admission Control Architecture Diagram

```
kubectl apply -f pod.yaml
      │
      ▼
API Server
  │
  ├──► MutatingAdmissionWebhooks (in order)
  │     ├─ Kyverno mutate webhook
  │     │   └─ adds securityContext, labels, etc.
  │     └─ Other webhooks (Vault injector, etc.)
  │
  ├──► Schema validation (CRD spec)
  │
  └──► ValidatingAdmissionWebhooks (all in parallel)
        ├─ OPA Gatekeeper webhook
        │   └─ evaluates Rego constraints
        ├─ Kyverno validate webhook
        │   └─ evaluates ClusterPolicy rules
        └─ Kube-apiserver built-in admission
            (PodSecurityAdmission, etc.)

If ANY deny → 403 Forbidden with message
If ALL allow → stored in etcd → scheduled
```

---

## Checkpoint

1. What is the difference between a mutating admission webhook and a validating admission webhook?
2. What two Kubernetes resources do you need to create to enforce a policy with OPA Gatekeeper?
3. In Rego, what does the `_` (underscore) mean when used as an array index?
4. What does the `violation[{"msg": msg}]` pattern mean in a Rego policy?
5. What are the three `enforcementAction` options in OPA Gatekeeper and what does each do?
6. What is the difference between a Kyverno `validate` rule and a `mutate` rule?
7. How does Kyverno's `verifyImages` rule enforce container image signing?
8. If you want to automatically add `runAsNonRoot: true` to every pod, which tool is simpler: OPA or Kyverno? Why?
9. What command would you run to test a Rego policy against a sample K8s admission request locally?
10. Write a Kyverno ClusterPolicy (in YAML) that blocks pods from using `hostNetwork: true`.

➡ Next: **CIS Hardening and Incident Response** — after you've blocked attacks with policies, you also need to know how to find and clean up after the ones that got through.
