# Mimir Remote-Write with Multi-Tenant OrgID

The platform team just handed you a Jira: "We need long-term Prometheus metrics retention beyond 15 days without paying Grafana Cloud prices. Evaluate Mimir on the existing kind cluster." You've seen Mimir in passing — it's the horizontally-scalable TSDB that Grafana Cloud itself runs — but this is your first time operating it.

The hardest part isn't the Helm install. It's the **`X-Scope-OrgID`** header. Mimir is multi-tenant by design: every write and every query must carry this header or it gets rejected with a 401. Prometheus remote_write lets you set it as a custom header. Get that wrong and you'll spend an hour debugging why Prometheus can't push even though the endpoint is reachable.

## Prerequisites

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

A kind cluster with **≥ 5 GB** Docker memory. `mimir-distributed` deploys multiple components even in its smallest configuration — expect 8–10 pods.

## Mission

The verifier passes when **all three** conditions hold:

1. A Helm release for Mimir exists in namespace `dojo-lgtm` (release name matches `mimir`).
2. A Deployment or StatefulSet named or matching `mimir` exists in `dojo-lgtm`.
3. A ConfigMap in `dojo-lgtm` named `prometheus-remote-write-config` contains **both** the Mimir endpoint URL and the string `X-Scope-OrgID` (or `orgid` / `org_id`).

> Note: the verifier checks authored configuration — it does NOT require a live Prometheus instance pushing to Mimir. The goal is to prove you understand how the remote_write + org ID wiring works.

## Why X-Scope-OrgID matters

Mimir separates tenants by a string orgID. Every ingest request to `/api/v1/push` and every query to `/prometheus/api/v1/query` is scoped to one tenant by this header. If you omit it, Mimir returns `401 Unauthorized: no org id` (or routes to a default tenant if `multitenancy_enabled: false` — but that's not the production path).

In a real multi-team environment:

| Team | orgID | What they see |
|------|-------|---------------|
| Platform | `platform` | Only platform's metrics |
| App A | `app-a` | Only app-a's metrics |
| App B | `app-b` | Only app-b's metrics |

The orgID is not a security control by itself (Mimir doesn't authenticate the header — it trusts the caller), but it is the data-isolation mechanism. Grafana Cloud adds authentication in front; on-prem you add an auth proxy or Kubernetes NetworkPolicy.

## The remote_write config pattern

In a Prometheus `prometheus.yaml` (or a `PrometheusSpec` CRD):

```yaml
remote_write:
  - url: http://mimir-nginx.dojo-lgtm.svc/api/v1/push
    headers:
      X-Scope-OrgID: "dojo-lab"
    queue_config:
      max_shards: 1          # keep it small for kind
      max_samples_per_send: 500
```

Alternatively, if using the kube-prometheus-stack's `Prometheus` CR:

```yaml
spec:
  remoteWrite:
    - url: http://mimir-nginx.dojo-lgtm.svc/api/v1/push
      headers:
        X-Scope-OrgID: "dojo-lab"
```

For this challenge, the ConfigMap approach (storing the config as YAML data) is sufficient — you are authoring the config, not necessarily running Prometheus.

## Verification

```bash
bash courses/course-17-lgtm-operated/challenges/03-mimir-remote-write/verify.sh
```
