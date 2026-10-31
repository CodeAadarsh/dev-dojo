# Solution — Ship Loki in Monolithic Mode

## Step 1: Write a minimal singleBinary values file

```yaml
# loki-values.yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false          # disable multi-tenancy for the lab
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  persistence:
    enabled: true
    size: 5Gi

# Zero out the microservice components — they default to replicas > 0
# in recent chart versions and will steal schedulable capacity on kind.
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

# Expose via ClusterIP only (port-forward for access)
gateway:
  enabled: false
```

## Step 2: Install

```bash
kubectl create namespace dojo-lgtm --dry-run=client -o yaml | kubectl apply -f -

helm install loki grafana/loki \
  -n dojo-lgtm \
  -f loki-values.yaml \
  --version 6.16.0
```

Wait for the StatefulSet to roll out:

```bash
kubectl -n dojo-lgtm rollout status statefulset/loki
```

## Step 3: Push a log line and query it back

```bash
# Port-forward Loki's HTTP port
kubectl -n dojo-lgtm port-forward svc/loki 3100:3100 &
PF_PID=$!

# Push a log entry via the push API
NOW=$(date +%s)000000000
curl -s -X POST http://localhost:3100/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"job\":\"dojo\",\"env\":\"lab\"},\"values\":[[\"${NOW}\",\"hello from kube-dojo\"]]}]}"

# Query it back with LogQL
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="dojo"}' \
  --data-urlencode "start=$(($(date +%s) - 120))000000000" \
  --data-urlencode "end=$(date +%s)000000000" | python3 -m json.tool

kill $PF_PID
```

You should see `"hello from kube-dojo"` in the JSON response values array.

## Step 4: Verify and get the flag

```bash
bash courses/course-17-lgtm-operated/challenges/02-deploy-loki/verify.sh
```

## Why `auth_enabled: false` in the lab

With `auth_enabled: true` (the default for multi-tenant Loki), every push and query must carry an `X-Scope-OrgID` HTTP header. That's correct for production — it's how Grafana Labs isolates tenants in Grafana Cloud — but it adds friction to a lab where there's only one user. Challenge 03 (Mimir) does exercise `X-Scope-OrgID` properly, so you will encounter it; just not here.

## Debugging singleBinary

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod stuck `Pending` | PVC can't bind — no StorageClass or disk full | `kubectl -n dojo-lgtm get pvc`; kind ships `standard` StorageClass backed by hostpath |
| Pod `CrashLoopBackOff`, logs show `mkdir: can't create directory: permission denied` | fsGroup / security context incompatible with hostpath | Add `podSecurityContext.fsGroup: 10001` to your values |
| Push returns `429 Too Many Requests` | Ingester rate limit hit | Add `ingester.max_streams_per_user: 0` under `loki.limits_config` (disables limit for lab) |
| Query returns empty even after push | Schemaconfig `from` date is in the future | Set `from: "2024-01-01"` (any past date works) |

> **War story.** Deployed Loki for a cost-cutting PoC at SAP — we set `auth_enabled: false` and `replication_factor: 1` exactly as above, but forgot to zero out `read.replicas` and `write.replicas`. The chart deployed 6 extra component pods that Loki's SingleBinary mode doesn't need. The cluster ran for 3 hours before anyone noticed the `write` pods were `Pending` on resource constraints and the read path was intermittently routing to the correct binary but sometimes hitting the headless write replicas. Setting all three to 0 (read, write, backend) is not optional when `deploymentMode: SingleBinary`.

## Connecting Loki to Grafana

Once Loki is running, add it as a datasource in the same way as challenge 01:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-ds-loki
  namespace: dojo-lgtm
  labels:
    grafana_datasource: "1"
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.dojo-lgtm.svc:3100
        jsonData:
          maxLines: 1000
```

```bash
kubectl apply -f grafana-ds-loki.yaml
```

The `grafana-sc-datasources` sidecar picks it up immediately — no Grafana restart.
