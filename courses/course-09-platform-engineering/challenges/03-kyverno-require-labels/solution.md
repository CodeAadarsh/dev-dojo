# Solution — Kyverno: Require Pod Labels

The solution is a single `ClusterPolicy` object that validates pod labels at admission.

```yaml
# require-pod-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pod-labels
  annotations:
    policies.kyverno.io/title: Require Pod Labels
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-required-labels
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["dojo-policy"]
      validate:
        message: "Pod must have both 'app' and 'team' labels. Found: {{ request.object.metadata.labels }}."
        pattern:
          metadata:
            labels:
              app: "?*"    # ?* = at least one character, non-empty
              team: "?*"
```

Apply and test:

```bash
kubectl apply -f require-pod-labels.yaml

# Should be denied
kubectl -n dojo-policy run bad --image=nginx:1.27-alpine
# Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#   Pod must have both 'app' and 'team' labels...

# Should succeed
kubectl -n dojo-policy run good \
  --image=nginx:1.27-alpine \
  --labels=app=web,team=alpha
# pod/good created

# Run the verifier
bash courses/course-09-platform-engineering/challenges/03-kyverno-require-labels/verify.sh
```

## Why each piece matters

**`validationFailureAction: Enforce`** — this is the only mode that actually blocks. `Audit` (the safe default during rollout) allows the resource through and only records a PolicyReport entry. Once you've run in Audit for a week and confirmed blast radius, flip to Enforce.

**`match.any[*].resources.namespaces: ["dojo-policy"]`** — scopes the ClusterPolicy to one namespace. A `ClusterPolicy` is cluster-scoped and would, by default, apply to every namespace in the cluster. The `namespaces` list (or `namespaceSelector`) is your blast radius control.

**`?*` pattern syntax** — Kyverno's `?` matches exactly one character, `*` matches zero-or-more. Together `?*` means "at least one character" — a non-empty string. An empty string (`""`) would fail this check. If you want to validate specific values (e.g., `team` must be one of `alpha`, `beta`, `platform`), use `anyPattern` instead of `pattern`.

**`background: true`** — Kyverno will also scan *existing* pods against this rule and create PolicyReport entries for any that fail. This lets you find pre-existing violations even for resources that were created before the policy.

## Attacker's view / escape hatch

A team can bypass this policy by setting `team: x app: x` — technically compliant, practically useless for attribution. Real enforcement uses a secondary policy that validates label *values* against an approved set (or uses an OPA Gatekeeper constraint with a Rego expression that looks up valid team names from a ConfigMap). The label requirement is the necessary foundation; value validation is the hardening layer on top.

## Hardening preview

Once label enforcement is in place, the next step is using those labels everywhere consistently:

```yaml
# NetworkPolicy that uses the 'app' label as a stable selector
spec:
  podSelector:
    matchLabels:
      app: web   # always present — your policy guarantees this

# PrometheusRule that groups alerts by 'team' label
# relabelings:
#   - sourceLabels: [__meta_kubernetes_pod_label_team]
#     targetLabel: team
```

Without the label policy, every downstream system that relies on these labels is built on sand.
