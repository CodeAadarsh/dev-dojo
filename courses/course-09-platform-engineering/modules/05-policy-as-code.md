# Policy-as-Code

> **Module 05 · Course 09** — RBAC controls *who* can do what. Policy controls *what* they're allowed to produce. These are complementary, not redundant: RBAC can prevent a developer from running `kubectl apply` as cluster-admin, but it cannot stop them from submitting a `hostNetwork: true` pod in a namespace they legitimately own. Policy-as-code closes that gap at the admission layer — before anything reaches etcd.

This module covers three policy engines: Kyverno (admission + mutation + generation, YAML-native), OPA Gatekeeper (ConstraintTemplates + Rego, expressive for complex logic), and the built-in `ValidatingAdmissionPolicy` (Kubernetes 1.28+ GA, CEL, zero external dependencies). Plus CI testing techniques that catch policy violations before they reach the cluster.

---

## The admission chain

Every object submitted to Kubernetes passes through this chain before being persisted:

```
kubectl apply
     │
     ▼
API server: Authentication + Authorization (RBAC)
     │   ← "can this user do this verb on this resource?"
     ▼
Mutating admission webhooks              ← Kyverno mutate, Istio sidecar inject
     │
     ▼
Object schema validation (OpenAPI)
     │
     ▼
Validating admission webhooks            ← Kyverno validate, OPA Gatekeeper
     │
     ▼
ValidatingAdmissionPolicy (built-in CEL) ← 1.26 beta, 1.28 GA, in-process
     │
     ▼
etcd
```

Mutating webhooks fire before validating ones — a sidecar injector (mutate) runs first, then Gatekeeper validates the post-injection object. The architectural risk is **webhook failure**: if your policy engine is down and `failurePolicy: Fail` is set, the entire admission chain for your resource types stops. We cover this in Debugging.

---

## Kyverno

Kyverno is a Kubernetes-native policy engine. Policies are Kubernetes objects — no new language to learn, no Rego, no CEL (unless you want it). That's its main advantage for teams that live in YAML.

### Install

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.6 \
  --set admissionController.replicas=1   # 1 for dojo; use 3 for production HA
```

### Validate: block what shouldn't exist

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce   # "Enforce" → deny; "Audit" → log only
  background: true                   # also scan existing resources
  rules:
    - name: privileged-containers
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kyverno"]
      validate:
        message: "Privileged mode is not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false | !exists"
```

The `=(field)` syntax means "if this field exists, it must match — if it's absent, the check passes." The `!exists` idiom on `privileged` handles pods that omit `securityContext` entirely (the default is `false`, so they're fine). Without it, you'd get false positives on every pod that doesn't set an explicit security context.

> **Audit vs Enforce.** `Enforce` blocks admission (HTTP 403). `Audit` allows the resource through but records a `PolicyReport` entry. **Always start with `Audit`.** Watch the policy reports for a few days to understand blast radius. Only then flip to `Enforce`. Blind `Enforce` on an existing cluster has bricked CI pipelines and production deployments — see Debugging.

### Mutate: inject what should always be there

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-resource-requests
spec:
  rules:
    - name: add-requests-if-absent
      match:
        any:
          - resources:
              kinds: ["Pod"]
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(cpu): 100m      # + prefix: only add if the field is absent
                    +(memory): 128Mi
```

The `+(field)` prefix is Kyverno's "add-if-absent" syntax — it never overrides explicit values set by the developer. This is the safety net for teams that forget requests, without foot-gunning teams that size theirs deliberately.

### Generate: create objects alongside others

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-namespace-networkpolicy
spec:
  rules:
    - name: add-default-deny
      match:
        any:
          - resources:
              kinds: ["Namespace"]
              selector:
                matchLabels:
                  team: "?*"    # any namespace that has a 'team' label
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-all
        namespace: "{{request.object.metadata.name}}"
        synchronize: true    # keep in sync; delete the generated object if the policy is deleted
        data:
          spec:
            podSelector: {}
            policyTypes: ["Ingress", "Egress"]
```

`generate` fires when a matching resource is created (and, with `background: true`, retroactively on existing resources). `synchronize: true` makes it a genuine enforcement mechanism — manual deletion of the generated NetworkPolicy is reconciled back.

### Policy reports

```bash
kubectl get policyreport -A           # namespace-scoped results
kubectl get clusterpolicyreport       # cluster-scoped results

# Show only failures
kubectl get policyreport -n my-ns \
  -o jsonpath='{.results[?(@.result=="fail")].resources}' | tr ',' '\n'

# Which pods are failing a specific rule?
kubectl get policyreport -A -o jsonpath='{range .items[*]}{range .results[?(@.rule=="require-labels")]}{.resources[0].name}{"\n"}{end}{end}'
```

Policy reports are CRDs installed by Kyverno. In `Audit` mode, every admission request that *would have been blocked* creates a `fail` entry. Combine with `kubectl get events --sort-by=.lastTimestamp` to trace the timeline of policy violations during a deploy.

### CI testing with `kyverno test`

The `kyverno` CLI runs policies against fixture manifests without a cluster:

```bash
brew install kyverno

# Project structure
policies/
  disallow-privileged.yaml
tests/
  bad-pod.yaml          # should FAIL
  good-pod.yaml         # should PASS
  kyverno-test.yaml     # test manifest

# tests/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: disallow-privileged
policies:
  - ../../policies/disallow-privileged.yaml
resources:
  - bad-pod.yaml
  - good-pod.yaml
results:
  - policy: disallow-privileged-containers
    rule: privileged-containers
    resource: bad-pod
    result: fail
  - policy: disallow-privileged-containers
    rule: privileged-containers
    resource: good-pod
    result: pass

# run in CI (zero cluster dependency)
kyverno test tests/
```

The `results` array is an assertion set — the test fails if any actual admission result doesn't match the expected. Commit policies and tests together; CI catches regressions before they hit the cluster.

---

## OPA Gatekeeper

Gatekeeper uses the Rego language for richer cross-object logic. Steeper learning curve than Kyverno; more expressive for policies that need to consult multiple objects or external data.

### Install

```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.16.3/deploy/gatekeeper.yaml
```

### ConstraintTemplate + Constraint

Gatekeeper separates policy *logic* (ConstraintTemplate, Rego) from policy *configuration* (Constraint, YAML parameters):

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdisallowedtags
spec:
  crd:
    spec:
      names:
        kind: K8sDisallowedTags
      validation:
        openAPIV3Schema:
          type: object
          properties:
            tags:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdisallowedtags
        violation[{"msg": msg}] {
          container := input_containers[_]
          endswith(container.image, concat(":", ["", input.parameters.tags[_]]))
          msg := sprintf("container <%v> uses a disallowed tag", [container.name])
        }
        input_containers[c] { c := input.review.object.spec.containers[_] }
        input_containers[c] { c := input.review.object.spec.initContainers[_] }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDisallowedTags
metadata:
  name: no-latest-tag
spec:
  enforcementAction: deny     # deny | warn | dryrun
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "DaemonSet", "StatefulSet"]
  parameters:
    tags: ["latest"]
```

A single ConstraintTemplate is reusable across multiple Constraints with different `parameters`. The `violation` rule fires on each offending container and produces a separate audit entry.

Test with `conftest`:

```bash
brew install conftest
# policies/ contains .rego files
# manifests/ contains your Kubernetes YAML
conftest test --policy policies/ manifests/
```

---

## ValidatingAdmissionPolicy (built-in CEL)

Since Kubernetes 1.28 (GA), you can write admission policies in CEL directly in the API server — no webhook, no external controller, no availability risk:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-privileged-pods
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        !has(object.spec.containers) ||
        object.spec.containers.all(c,
          !has(c.securityContext) ||
          !has(c.securityContext.privileged) ||
          c.securityContext.privileged == false
        )
      messageExpression: >-
        "Privileged containers not allowed: " +
        object.spec.containers.filter(c, has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged).map(c, c.name).join(", ")
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-privileged-pods-binding
spec:
  policyName: deny-privileged-pods
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kyverno"]
```

`ValidatingAdmissionPolicy` runs in-process in the API server — no webhook round-trip, no external HTTP calls, no availability dependency. The trade-off: CEL expressions are limited to the submitted object (no cross-object lookups, no side effects, no mutation, no generation). Use it for structural checks; use Kyverno/Gatekeeper for anything requiring cross-object correlation or generation.

The `messageExpression` field (CEL string) replaces static `message` with a dynamic one that names the offending containers — an underused improvement that saves significant debugging time.

---

## Debugging policy-as-code

The most dangerous failure mode isn't a policy blocking something bad — it's a policy blocking something good, silently, in a way that looks like a network error.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `kubectl apply` fails with `admission webhook denied` | Policy is in `Enforce` mode and the resource violates a rule | Fix the manifest per the error message; verify the policy intent was correct |
| All deployments failing in CI, no clear error | Policy webhook down + `failurePolicy: Fail` | `kubectl -n kyverno get pods`; scale back up; temporarily patch webhook to `failurePolicy: Ignore` |
| Policy in `Enforce` mode but violations still get through | `validationFailureAction: Audit` (not `Enforce`) set on the live policy | `kubectl get clusterpolicy <name> -o jsonpath='{.spec.validationFailureAction}'` |
| Policy reports show false positives — correct pods flagged | `match.any` criteria too broad; `=(field)` syntax misapplied | `kyverno test` against the flagged resource locally to isolate which rule fires |
| `background: true` audit not scanning existing pods | Kyverno reports only new admissions by default in some versions | Set `background: true` explicitly; check Kyverno version |
| Gatekeeper constraint violation count = 0 despite obvious violations | Gatekeeper audit sync hasn't included this resource kind | Add resource kind to Gatekeeper config `spec.sync.syncOnly` |
| `ValidatingAdmissionPolicy` error message is not helpful | Using static `message` instead of dynamic `messageExpression` | Switch to `messageExpression` with a CEL string that names the offending field |
| Policy works on `Pod` but misses Deployment-created pods | Rule targets `Deployment` not `Pod` — Deployment spec validation doesn't cover the pod template's runtime behaviour | Target `Pod` kind in `match.any`; Kyverno intercepts pod creation by the replica set controller too |

### Diagnose each — the exact commands

**Policy not firing:**

```bash
# Check the actual live enforcement mode
kubectl get clusterpolicy disallow-privileged-containers \
  -o jsonpath='{.spec.validationFailureAction}'

# Dry-run a policy-violating pod against the server
kubectl run bad --image=nginx:1.27-alpine \
  --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx:1.27-alpine",
    "securityContext":{"privileged":true}}]}}' \
  --dry-run=server 2>&1

# Check webhook registrations — is Kyverno's webhook present?
kubectl get validatingwebhookconfigurations | grep -i kyverno
kubectl get mutatingwebhookconfigurations | grep -i kyverno
```

**Emergency: failurePolicy bricking deployments:**

```bash
# Confirm failurePolicy=Fail is set
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{.webhooks[0].failurePolicy}'

# Are Kyverno admission controller pods up?
kubectl -n kyverno get pods
kubectl -n kyverno rollout status deploy/kyverno-admission-controller

# Emergency: change to Ignore to restore deployments (fix Kyverno then revert)
kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

**Gatekeeper: audit violation details:**

```bash
# Violation count per constraint
kubectl get constraints \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,VIOLATIONS:.status.totalViolations'

# See exactly which resources violate a specific constraint
kubectl get k8sdisallowedtags no-latest-tag \
  -o jsonpath='{.status.violations[*].message}' | tr ' ' '\n'
```

> **War story.** An SRE at a fintech rolled out Kyverno to staging on a Friday with `validationFailureAction: Enforce` on a policy requiring all pods to carry a `team` label. Their DB migration job — auto-created by their ORM framework — had no such label. Saturday morning: all schema migrations were blocked by the policy, none of the weekend batch processes had run, and the on-call engineer spent two hours tracing the failure before finding the webhook deny in the events. The three rules we follow now: (1) **start in `Audit`**; (2) run `kyverno test` in CI on every policy change; (3) **never promote a policy to `Enforce` on a Friday**. A policy change is a production change. Treat it like one.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Name the three types of Kyverno rules and what each does at admission time.
2. Explain the difference between `Audit` and `Enforce` and when to use each.
3. Write the `match.any` block for a Kyverno rule targeting only `Pod` resources.
4. Explain why `failurePolicy: Fail` is dangerous, and what the one-line emergency mitigation is.
5. Describe the two-object pattern in OPA Gatekeeper (what holds logic, what holds configuration).
6. Write the CEL expression that checks `privileged == false` while being safe if `securityContext` is absent.
7. Explain what `kyverno test` is testing and where the expected results are declared.
8. Describe why a Kyverno `generate` policy with `synchronize: true` is stronger than a scaffold script.

➡ Next up: the **Kyverno Require Labels** challenge — you'll author a ClusterPolicy that enforces label presence on all pods in a namespace, then verify it blocks non-compliant submissions.
