# Dashboard as Code

Your team has 14 Grafana dashboards. Half of them exist only in Grafana's database, created by clicking around the UI. When a new team member joins, they get a link and a prayer. When the Grafana pod is deleted, three dashboards vanish. The on-call rotation is held together with screenshots saved in Confluence.

The fix is treating dashboards as code. The `kube-prometheus-stack` ships a **Grafana sidecar container** that watches for ConfigMaps labeled `grafana_dashboard: "1"` across all namespaces (or a specific namespace, depending on your values). When it finds one, it imports the JSON into Grafana automatically — no UI clicks, no manual imports, full GitOps.

## Prereq

The `kube-prometheus-stack` must be installed:

```bash
bash labs/bootstrap/install-monitoring.sh
```

## Mission

Create a `ConfigMap` in namespace `dojo-dash` that meets **all** of these conditions:

1. Has the label `grafana_dashboard: "1"` (the Grafana sidecar watches for this exact label).
2. Has at least one data key whose value is a JSON string containing a `"panels"` key at the top level (Grafana dashboard JSON schema requires this).
3. The `"panels"` value must be a JSON array with at least one element.

The verifier checks for the ConfigMap's label and JSON structure. It does **not** require Grafana to have actually imported it (that requires the sidecar to scan, which takes up to 30 seconds after creation).

## Dashboard JSON structure

A minimal Grafana dashboard JSON has this shape:

```json
{
  "title": "My Dashboard",
  "uid": "dojo-001",
  "schemaVersion": 38,
  "panels": [
    {
      "id": 1,
      "title": "Request Rate",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "sum(rate(up[5m]))",
          "legendFormat": "up targets"
        }
      ],
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
    }
  ]
}
```

Put this JSON as the value of a data key in your ConfigMap (e.g. `data.dashboard.json: '<json here>'`).

## Why this pattern exists

Grafana has two storage modes for dashboards: database (the default UI flow) and provisioning (read from a directory on disk at startup, or watched live by the sidecar). The sidecar approach is provisioning-as-a-service: the Grafana sidecar monitors Kubernetes for ConfigMaps with the right label and writes them to the provisioning directory at runtime. This means:

- **GitOps** — dashboard JSON lives in your repo, goes through PR review, is deployed with the same pipeline as your app.
- **Disaster recovery** — delete and recreate Grafana, the dashboards come back automatically.
- **Multi-team** — each team owns their dashboard ConfigMaps in their own namespace.

## Namespacing

Work in `dojo-dash`. Run `setup.sh` to create it.
