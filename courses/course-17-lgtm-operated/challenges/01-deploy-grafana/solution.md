# Solution — Deploy Grafana with a Live Datasource

## Step 1: Create a values file with the sidecar enabled

```yaml
# grafana-values.yaml
sidecar:
  datasources:
    enabled: true   # starts grafana-sc-datasources alongside Grafana
    label: grafana_datasource
    labelValue: "1"

persistence:
  enabled: false    # keep it stateless for the lab — no PVC needed

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

# Expose via NodePort for easy curl from the host
service:
  type: NodePort
```

## Step 2: Install the chart

```bash
kubectl create namespace dojo-lgtm --dry-run=client -o yaml | kubectl apply -f -

helm install grafana grafana/grafana \
  -n dojo-lgtm \
  -f grafana-values.yaml \
  --version 8.5.1
```

Pin the chart version — `grafana/grafana` moves fast and the sidecar field paths can shift between majors.

## Step 3: Create the datasource ConfigMap

```yaml
# grafana-ds-prometheus.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-ds-prometheus
  namespace: dojo-lgtm
  labels:
    grafana_datasource: "1"   # <-- the magic label; value MUST be the string "1"
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-operated.dojo-lgtm.svc:9090
        isDefault: true
        jsonData:
          timeInterval: "15s"
```

```bash
kubectl apply -f grafana-ds-prometheus.yaml
```

The `grafana-sc-datasources` sidecar uses a watch on the Kubernetes API for ConfigMaps with this label. It writes the YAML to `/etc/grafana/provisioning/datasources/` inside the Grafana container — no restart required.

## Step 4: Verify and get the flag

```bash
bash courses/course-17-lgtm-operated/challenges/01-deploy-grafana/verify.sh
```

## Why the sidecar pattern beats UI provisioning

| Method | Survives pod restart | GitOps-safe | Multi-instance |
|--------|---------------------|-------------|----------------|
| UI "Add datasource" | No — stored in pod SQLite | No | No — per-instance config |
| `grafana.ini` provisioning file | Yes (if baked in image) | Yes | Yes |
| **Sidecar ConfigMap** | **Yes** | **Yes** | **Yes — per-namespace** |

The sidecar pattern also composes with dashboards-as-code: the same mechanism (`grafana_dashboard: "1"`) hot-loads dashboard JSON from ConfigMaps. You end up with Grafana state that is entirely expressed as Kubernetes objects — reviewable, diffable, namespaced.

## Attacker's view

If a ConfigMap in `dojo-lgtm` with `grafana_datasource=1` can be written by any service account in the namespace, an attacker with `create configmaps` permissions can inject a datasource pointing at an external server they control — Grafana will POST dashboard queries there, leaking metric names, label values, and query patterns. In production, RBAC on ConfigMap creation in the Grafana namespace is non-negotiable.
