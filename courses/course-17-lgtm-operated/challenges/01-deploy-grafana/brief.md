# Deploy Grafana with a Live Datasource

You get paged at 2 AM: "dashboards are broken." You dig in and find that the Grafana pod was reinstalled by another team member — and nobody provisioned any datasources into the new instance. Every dashboard shows `Data source not found`. The fix is not "log in and click Add Datasource." That breaks the next reinstall too.

The durable pattern is **GitOps datasource provisioning via Grafana's sidecar**: a ConfigMap labelled `grafana_datasource: "1"` is discovered and hot-loaded by a sidecar container running alongside Grafana — no Grafana restart, no UI clicking, no state that lives only in the pod's sqlite.

## Prerequisites

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

A running kind cluster with at least **4 GB** allocated to Docker (Settings → Resources).

## Mission

Install Grafana via the `grafana/grafana` Helm chart into namespace `dojo-lgtm`, and provision a datasource via a labeled ConfigMap. The verifier passes when:

1. A Helm release exists in `dojo-lgtm` whose name contains `grafana`.
2. A ConfigMap in `dojo-lgtm` has label `grafana_datasource=1`.
3. The `grafana` Deployment has `readyReplicas >= 1`.

## Why this matters

Datasources provisioned through the UI live in Grafana's internal SQLite database inside the pod. The moment you `helm upgrade --reset-values` or the pod is evicted, they're gone. ConfigMap-based provisioning is declarative, diffable, and gitops-compatible — it's how every Grafana deployment above hobby scale should work. The sidecar (`grafana-sc-datasources`) watches the Kubernetes API for ConfigMaps with the magic label and injects them into `/etc/grafana/provisioning/datasources/` live.

## Hint on values

The chart's sidecar is enabled by setting `sidecar.datasources.enabled: true` in your Helm values. The ConfigMap you create must sit in the **same namespace** as Grafana and carry the label `grafana_datasource: "1"` (string `"1"`, not boolean). The data key must be a YAML file that follows [Grafana's datasource provisioning schema](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources).

A minimal Prometheus datasource to provision (Prometheus itself doesn't need to be running for the ConfigMap check to pass):

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.dojo-lgtm.svc:9090
    isDefault: true
```

## Verification

```bash
bash courses/course-17-lgtm-operated/challenges/01-deploy-grafana/verify.sh
```
