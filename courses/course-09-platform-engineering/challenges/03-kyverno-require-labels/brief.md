# Kyverno: Require Pod Labels

Your observability team has been complaining for months: half the pods in the cluster have no `team` label, so cost attribution and Grafana dashboards are garbage. The security team has the same complaint about the `app` label — it's the selector used by NetworkPolicies and ServiceMonitors.

The fix isn't a wiki page. It's a policy that makes non-compliant pod creation impossible.

## Prerequisites

Kyverno must be installed in the cluster. If it isn't:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.6 \
  --set admissionController.replicas=1
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=120s
```

## Mission

Author a `ClusterPolicy` named `require-pod-labels` in **Enforce mode** that:

1. Targets all `Pod` objects in namespace `dojo-policy` only.
2. Requires the label `app` to be present and non-empty.
3. Requires the label `team` to be present and non-empty.
4. Emits a clear error message when either label is missing.

The verifier checks that:

- A `ClusterPolicy` named `require-pod-labels` exists.
- Its `spec.validationFailureAction` is `Enforce`.
- It has at least one rule that matches `Pod` resources.
- The rule's `validate.pattern` (or CEL expression) checks for both `app` and `team` labels.
- A pod submitted *without* the required labels is actually denied (live admission test).
- A pod submitted *with* both labels is admitted.

## Rules of engagement

- Work in namespace `dojo-policy` (setup.sh creates it).
- The `ClusterPolicy` is cluster-scoped but its match should be scoped to namespace `dojo-policy` via `match.any[*].resources.namespaces`.
- Do not restrict the policy to specific label *values* — any non-empty string is valid.
- Test your policy before running the verifier: try `kubectl -n dojo-policy run bad --image=nginx:1.27-alpine` — it should be denied. Then try with `--labels=app=web,team=alpha` — it should succeed.

## Why this matters

Every downstream system that segments by `app` or `team` — Prometheus, Loki, Grafana, cost allocation tools — assumes those labels exist. A policy at the admission layer is the only reliable enforcement point: documentation gets ignored, code review misses it, but admission webhooks don't.
