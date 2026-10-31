# Solution — Fire an Alert

A PrometheusRule that satisfies every verifier check:

```yaml
# alert-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dojo-target-down
  namespace: dojo-alert
  labels:
    release: kps          # matches the Prometheus CRD selector installed by install-monitoring.sh
spec:
  groups:
    - name: dojo.availability
      interval: 30s
      rules:
        - alert: TargetDown
          expr: up == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Scrape target {{ $labels.job }} is down"
            description: "Instance {{ $labels.instance }} of job {{ $labels.job }} has been unreachable for more than 1 minute."
```

Apply and verify:

```bash
kubectl apply -f alert-rule.yaml
bash courses/course-06-observability-lgtm/challenges/04-fire-an-alert/verify.sh
```

## Why each field matters

- **`release: kps`** — the kube-prometheus-stack installs Prometheus with a CRD selector that matches labels including `release: kps`. Without this label, the Prometheus operator ignores the PrometheusRule entirely. Check what selector your stack uses with: `kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}'`.
- **`expr: up == 0`** — the `up` metric is emitted by Prometheus itself for every scrape target. `up == 0` means the target is not reachable. This is the most universally useful single-expression alert in any Prometheus deployment.
- **`for: 1m`** — without this, a 2-second network blip pages your on-call. The `for` field is the noise floor of your alerting system. Set it too short → alert fatigue. Set it too long → slow detection. 1–5 minutes is a typical starting point for availability.
- **`labels.severity`** — Alertmanager uses label-based routing. A `severity: critical` alert can route to PagerDuty; `warning` can route to Slack. Without it you can't differentiate routing paths.
- **`annotations.summary`** — this is the one-line message the on-call engineer reads in the notification at 3 AM. `{{ $labels.job }}` is Prometheus template syntax that substitutes the actual label value at fire time.

## The operator's view

After applying, the operator reloads Prometheus config within ~30 seconds (configurable via `--config-reloader-*` flags). Watch it pick up the rule:

```bash
kubectl -n monitoring get prometheusrule -A   # your new rule should appear
```

To see if the alert would fire (requires Prometheus port-forward):

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# open http://localhost:9090/alerts — TargetDown will be listed
```

## Hardening preview

A rule that passes this verifier is a correct rule — but a *good* alerting rule also has:
- An `inhibit_rules` in Alertmanager config to suppress child alerts when a parent fires.
- A `runbook_url` annotation pointing to an actual runbook (so the on-call knows what to do).
- A `for` duration tuned to your actual MTTR and SLO budget, not just "1m because it's tidy."
