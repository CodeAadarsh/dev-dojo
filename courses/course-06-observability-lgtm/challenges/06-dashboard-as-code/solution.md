# Solution — Dashboard as Code

A ConfigMap that the Grafana sidecar will auto-import:

```yaml
# grafana-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dojo-request-rate
  namespace: dojo-dash
  labels:
    grafana_dashboard: "1"    # sidecar key — must be exactly this label
data:
  request-rate.json: |
    {
      "title": "Dojo Request Rate",
      "uid": "dojo-request-rate-001",
      "schemaVersion": 38,
      "refresh": "30s",
      "panels": [
        {
          "id": 1,
          "title": "Scrape Target Up Rate",
          "type": "timeseries",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            {
              "expr": "sum(rate(up[5m]))",
              "legendFormat": "up targets/s"
            }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 }
        }
      ]
    }
```

Apply and verify:

```bash
kubectl apply -f grafana-dashboard.yaml
bash courses/course-06-observability-lgtm/challenges/06-dashboard-as-code/verify.sh
```

## Why each piece matters

- **`grafana_dashboard: "1"` label** — this is the ConfigMap selector the kube-prometheus-stack Grafana sidecar watches. The value must be the string `"1"`. The sidecar is configured in the Helm chart via `grafana.sidecar.dashboards.label` (default: `grafana_dashboard`) and `grafana.sidecar.dashboards.labelValue` (default: `"1"`). Deviate from this and the sidecar ignores your ConfigMap.
- **`data` key naming** — the sidecar copies the value of each `data` key to a file in Grafana's provisioning directory. The key name becomes the filename. Using `.json` as a suffix is conventional but not required by the verifier.
- **`"panels"` array** — this is required by the Grafana dashboard JSON schema. Without it, Grafana will silently fail to import (it validates schema on import, not when the sidecar writes the file). A panel needs at minimum `id`, `title`, `type`, and `gridPos`.
- **`"uid"` field** — without a `uid`, Grafana generates one at import time, which means re-importing the same dashboard creates a duplicate instead of updating. For GitOps, pin it to a stable string.
- **`schemaVersion: 38`** — this tells Grafana which migration path to run on import. Use 38 for Grafana 10.x (what kube-prometheus-stack ships with recent Helm chart versions).

## Confirm the import in Grafana

After applying, give the sidecar 30 seconds to detect the ConfigMap, then open Grafana:

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# http://localhost:3000  (admin / admin)
# Dashboards → Browse → look for "Dojo Request Rate"
```

If it doesn't appear, check the sidecar logs:

```bash
kubectl -n monitoring logs deploy/kps-grafana -c grafana-sc-dashboard | tail -20
```

## Hardening preview

In a real cluster you'd want:
- A dedicated namespace (`monitoring` or a team namespace) so the sidecar's RBAC scope is known.
- Dashboard JSON stored in a ConfigMap created by your CI pipeline from a `.json` file in the repo — `kubectl create configmap dojo-request-rate --from-file=dashboard.json -l grafana_dashboard=1 -n dojo-dash --dry-run=client -o yaml | kubectl apply -f -`.
- The `uid` kept stable across environments so Grafana links and bookmarks survive re-deploys.
