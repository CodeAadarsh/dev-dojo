# Ship Loki in Monolithic Mode

Your team adopted Grafana Cloud for logs. The bill just landed. Finance wants a self-hosted alternative on the existing kind cluster — scoped to this sprint. You have 40 minutes. The ask: "get Loki running, prove we can push a log line and query it back."

Loki's default Helm chart (`grafana/loki`) targets production: it ships as a microservices distributed system with individual ingesters, queriers, compactors, and rulers. For a kind cluster that is catastrophically over-provisioned. The right mode here is **`singleBinary`** (also called monolithic): one StatefulSet, all components in one process, local BoltDB + filesystem storage. Every Grafana Labs runbook calls this "development/testing mode" — which is exactly what a kind dojo is.

## Prerequisites

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

A kind cluster with **≥ 4 GB** Docker memory. Loki's single binary is modest, but combined with Grafana (challenge 01) it needs headroom.

## Mission

The verifier passes when **all three** conditions hold:

1. A Helm release named `loki` exists in namespace `dojo-lgtm`.
2. A Service named `loki` (or matching `loki`) exists in `dojo-lgtm`.
3. At least one pod matching `app.kubernetes.io/name=loki` is in `Running` phase.

## Why monolithic mode for kind

Loki's distributed mode runs 8–12 distinct component Deployments. On kind, each asks for its own resource requests, which quickly exhausts the Docker VM's schedulable capacity. SingleBinary packs all read/write paths into one process and one StatefulSet — you still get the full Loki API, LogQL engine, and label index; you just can't horizontally scale individual components. For a lab running 4 courses side-by-side, that is the correct tradeoff.

## Pushing a log line and querying it back

Once Loki is running, forward its port:

```bash
kubectl -n dojo-lgtm port-forward svc/loki 3100:3100 &
```

Push a log entry via the Loki push API (no logcli needed):

```bash
NOW=$(date +%s)000000000
curl -s -X POST http://localhost:3100/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"job\":\"dojo\",\"env\":\"lab\"},\"values\":[[\"${NOW}\",\"hello from kube-dojo\"]]}]}"
```

Query it back:

```bash
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="dojo"}' \
  --data-urlencode "start=$(($(date +%s) - 120))000000000" \
  --data-urlencode "end=$(date +%s)000000000" | python3 -m json.tool
```

You should see `"hello from kube-dojo"` in the response. This confirms the ingester accepted the entry and the querier can retrieve it — the two paths you care about before connecting Grafana.

## Verification

```bash
bash courses/course-17-lgtm-operated/challenges/02-deploy-loki/verify.sh
```
