# Dashboards and Alerts as Code

Your team's Grafana instance resets on every redeploy — someone manually created the golden SLO dashboard and forgot to export it, and now it's gone. The post-mortem action item is clear: **dashboards and alert rules must be version-controlled and auto-provisioned**, not click-ops.

Grafana supports both via Kubernetes-native objects: a sidecar process watches for labeled ConfigMaps and loads them automatically. This challenge makes you ship both.

## Mission

In namespace `dojo-lgtm`, create:

1. **A ConfigMap with label `grafana_dashboard: "1"`** whose `data` contains at least one key with a valid Grafana dashboard JSON (the JSON must include a `"panels"` array with at least one panel).

2. **An alert rule object** — either:
   - A **`PrometheusRule`** CRD (from prometheus-operator) with at least one `alert:` rule, OR
   - A **ConfigMap with label `grafana_alerts: "1"`** containing Grafana alert rule provisioning YAML (must include `groups:` and at least one entry with `alert:` or `name:` under `rules:`).

Both objects must live in `dojo-lgtm`.

## Target state — what `verify.sh` checks

1. **A ConfigMap in `dojo-lgtm`** with label `grafana_dashboard=1` exists AND its data contains the string `"panels"`.
2. **An alert rule object exists** — either a `PrometheusRule` resource in `dojo-lgtm`, OR a ConfigMap in `dojo-lgtm` with label `grafana_alerts=1` whose data contains both `groups` and `alert`.

Run `bash courses/course-17-lgtm-operated/challenges/06-dashboards-and-alerts-as-code/verify.sh` to check your work.

## Grafana sidecar provisioning — how it works

The `grafana/grafana` Helm chart ships a sidecar container (`grafana-sc-dashboard`, `grafana-sc-rules`) that watches the Kubernetes API for ConfigMaps with specific labels and writes their contents to Grafana's provisioning directories on a shared volume. No Grafana restart needed.

```
ConfigMap (label grafana_dashboard=1)
        │  sidecar watches for label changes
        ▼
grafana-sc-dashboard container
        │  writes JSON to /tmp/dashboards/<key>.json
        ▼
Grafana process  ←  file provisioner re-reads on interval
        │
        ▼  dashboard appears in UI automatically
```

The sidecar label keys must match what your Grafana Helm values set under `sidecar.dashboards.label` and `sidecar.alerts.label`. The defaults are `grafana_dashboard` and `grafana_alerts`.

## Minimum valid dashboard JSON

```json
{
  "title": "Dojo SLO",
  "uid": "dojo-slo-01",
  "schemaVersion": 36,
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Error Rate",
      "datasource": "Prometheus",
      "targets": [
        { "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))" }
      ]
    }
  ]
}
```

## Minimum valid PrometheusRule

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dojo-alerts
  namespace: dojo-lgtm
  labels:
    app: kube-prometheus-stack
spec:
  groups:
    - name: dojo.slo
      rules:
        - alert: HighErrorRate
          expr: "vector(1)"
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "Error rate above threshold (always-fires test rule)"
```

## Why this matters

Manual dashboard creation is operational debt that compounds. The moment a dashboard lives only in Grafana's SQLite/Postgres it becomes a snowflake: unreviewed, undiffed, unrecoverable after a DB wipe. Storing dashboards and alert rules as ConfigMaps gives you PRs, blame, rollback, and per-environment overrides for free — the same Git-ops discipline you already apply to your application manifests. At scale (Grafana Labs runs thousands of dashboards this way) this is the only approach that doesn't become chaos.
