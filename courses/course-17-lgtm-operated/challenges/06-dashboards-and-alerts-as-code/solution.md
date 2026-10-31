# Solution: Dashboards and Alerts as Code

## Part 1 — Dashboard as a ConfigMap

### 1a. Create the dashboard JSON

Save this as `dojo-slo-dashboard.json`:

```json
{
  "title": "Dojo SLO",
  "uid": "dojo-slo-01",
  "schemaVersion": 36,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Error Rate (5xx / total)",
      "gridPos": { "x": 0, "y": 0, "w": 8, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))",
          "legendFormat": "error rate"
        }
      ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] } }
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Request Rate by Status",
      "gridPos": { "x": 0, "y": 4, "w": 24, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "sum by(status) (rate(http_requests_total[5m]))",
          "legendFormat": "{{status}}"
        }
      ]
    }
  ]
}
```

### 1b. Ship it as a ConfigMap

The data value must be a JSON *string* (the file content), not an embedded object:

```bash
kubectl -n dojo-lgtm create configmap dojo-slo-dashboard \
  --from-file=dojo-slo-dashboard.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml \
  | kubectl apply -f -
```

Or as a declarative manifest:

```yaml
# dashboard-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dojo-slo-dashboard
  namespace: dojo-lgtm
  labels:
    grafana_dashboard: "1"
data:
  dojo-slo-dashboard.json: |
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
          "targets": [{ "expr": "vector(0.02)", "legendFormat": "error rate" }]
        }
      ]
    }
```

```bash
kubectl apply -f dashboard-cm.yaml
```

## Part 2a — Alert rule as a PrometheusRule (if prometheus-operator is installed)

```yaml
# prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dojo-slo-alerts
  namespace: dojo-lgtm
  labels:
    app: kube-prometheus-stack
    release: prometheus
spec:
  groups:
    - name: dojo.slo
      interval: 30s
      rules:
        - alert: HighErrorRate
          expr: |
            sum(rate(http_requests_total{status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total[5m])) > 0.01
          for: 2m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Error rate above 1% for 2 minutes"
            description: "Current error rate: {{ $value | humanizePercentage }}"
        - alert: ServiceDown
          expr: up{job="dojo-api"} == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "dojo-api is down"
```

```bash
kubectl apply -f prometheusrule.yaml
kubectl -n dojo-lgtm get prometheusrule
```

## Part 2b — Alert rule as a Grafana provisioning ConfigMap (no prometheus-operator needed)

```yaml
# alerts-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dojo-alert-rules
  namespace: dojo-lgtm
  labels:
    grafana_alerts: "1"
data:
  dojo-alerts.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: dojo.slo
        folder: Dojo Alerts
        interval: 1m
        rules:
          - uid: dojo-high-error-rate
            title: HighErrorRate
            condition: C
            data:
              - refId: A
                datasourceUid: prometheus
                model:
                  expr: >
                    sum(rate(http_requests_total{status=~"5.."}[5m]))
                    / sum(rate(http_requests_total[5m]))
              - refId: C
                datasourceUid: __expr__
                model:
                  type: threshold
                  conditions:
                    - evaluator:
                        params: [0.01]
                        type: gt
                      unaryOperator: and
                      query:
                        params: [A]
            noDataState: NoData
            execErrState: Alerting
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: Error rate above 1% for 2 minutes
```

```bash
kubectl apply -f alerts-cm.yaml
```

## Run the verifier

```bash
bash courses/course-17-lgtm-operated/challenges/06-dashboards-and-alerts-as-code/verify.sh
```

## Why this is the correct pattern

Two failure modes this solves:

1. **Database wipe / migration.** Grafana's internal SQLite (default) is not backed up. Every manual dashboard is gone on the next PVC reclaim or Helm upgrade that nukes the PV. ConfigMap-provisioned dashboards recreate themselves on startup.

2. **Drift between environments.** A dashboard tuned in staging that never made it to production is an incident waiting to happen — the alert you rely on during an outage doesn't exist there. With ConfigMaps in Git, the same manifest deploys to every environment and the diff is auditable in PRs.

The attacker's view: ConfigMaps are readable by any pod in the same namespace with `get` on `configmaps`. If your alert rules reference internal service names, CIDR ranges, or thresholds that hint at your capacity, they're intelligence. RBAC scope and namespace isolation matter here.
