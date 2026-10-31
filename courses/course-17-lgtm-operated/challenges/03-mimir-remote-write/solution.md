# Solution — Mimir Remote-Write with Multi-Tenant OrgID

## Step 1: Write a small-footprint values file

`mimir-distributed` defaults to production-sized replicas. The following values shrink everything to a single replica per component and disable object storage (uses filesystem via `memberlist` — good enough for a kind lab).

```yaml
# mimir-values.yaml
mimir:
  structuredConfig:
    common:
      storage:
        backend: filesystem
        filesystem:
          dir: /data/mimir
    blocks_storage:
      backend: filesystem
      filesystem:
        dir: /data/mimir/blocks
    ingester:
      ring:
        replication_factor: 1

# Single replica for every component
alertmanager:
  enabled: false        # skip for the lab
  replicas: 1
compactor:
  replicas: 1
distributor:
  replicas: 1
ingester:
  replicas: 1
  zoneAwareReplication:
    enabled: false
querier:
  replicas: 1
query_frontend:
  replicas: 1
query_scheduler:
  replicas: 1
ruler:
  enabled: false        # skip for the lab
store_gateway:
  replicas: 1
  zoneAwareReplication:
    enabled: false

# Keep resource footprint small
global:
  extraEnvFrom: []

nginx:
  enabled: true         # the nginx gateway exposes the push/query endpoints

minio:
  enabled: false        # no object storage in the lab
```

## Step 2: Install Mimir

```bash
kubectl create namespace dojo-lgtm --dry-run=client -o yaml | kubectl apply -f -

helm install mimir grafana/mimir-distributed \
  -n dojo-lgtm \
  -f mimir-values.yaml \
  --version 5.5.1
```

This will take 2–3 minutes. Watch rollout:

```bash
kubectl -n dojo-lgtm get pods -w
```

The minimum required pods before remote_write will work: `distributor`, `ingester`, `nginx`.

## Step 3: Author the remote_write ConfigMap

```yaml
# prometheus-remote-write-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-remote-write-config
  namespace: dojo-lgtm
data:
  remote_write.yaml: |
    # Prometheus remote_write block targeting Mimir in dojo-lgtm.
    # This config is meant to be merged into a prometheus.yaml or a
    # PrometheusSpec CR's remoteWrite field.
    remote_write:
      - url: http://mimir-nginx.dojo-lgtm.svc/api/v1/push
        headers:
          X-Scope-OrgID: "dojo-lab"
        queue_config:
          max_shards: 1
          max_samples_per_send: 500
          batch_send_deadline: 5s
        metadata_config:
          send: true
          send_interval: 1m
```

```bash
kubectl apply -f prometheus-remote-write-config.yaml
```

## Step 4: Verify and get the flag

```bash
bash courses/course-17-lgtm-operated/challenges/03-mimir-remote-write/verify.sh
```

## Why the nginx gateway matters

`mimir-distributed` doesn't expose each component's port directly. The Nginx gateway (`mimir-nginx`) acts as the single ingress point:

- `POST /api/v1/push` → distributor
- `GET /prometheus/api/v1/query` → query-frontend → querier
- `/api/v1/rules` → ruler

This is the same architecture as Grafana Cloud — Nginx sits in front and routes by path. When you configure Prometheus `remote_write.url`, always point it at `mimir-nginx`, not at the distributor directly.

## Testing the actual push path

Once both Mimir and Prometheus are running (or if you already have kube-prometheus-stack installed):

```bash
# Port-forward nginx
kubectl -n dojo-lgtm port-forward svc/mimir-nginx 8080:80 &

# Push a synthetic metric manually
NOW=$(date +%s)000
curl -s -X POST http://localhost:8080/api/v1/push \
  -H 'X-Scope-OrgID: dojo-lab' \
  -H 'Content-Type: application/x-protobuf' \
  -H 'X-Prometheus-Remote-Write-Version: 0.1.0' \
  --data-binary @<(printf '\x00') || true
# (A real push uses protobuf; curl is just for connectivity verification)

# Query what arrived
curl -s -G http://localhost:8080/prometheus/api/v1/label/__name__/values \
  -H 'X-Scope-OrgID: dojo-lab' | python3 -m json.tool
```

## Debugging

| Symptom | Cause | Fix |
|---------|-------|-----|
| Prometheus logs `server returned HTTP status 401` | `X-Scope-OrgID` header missing | Add `headers: {X-Scope-OrgID: "your-tenant"}` to the remote_write block |
| Ingester pods `CrashLoopBackOff`, logs show `memberlist: error joining cluster` | Zone-aware replication enabled with replicas=1 | Set `ingester.zoneAwareReplication.enabled: false` and `replication_factor: 1` |
| Compactor `CrashLoopBackOff` with filesystem errors | `/data/mimir` not writable | Add `securityContext.runAsUser: 0` or ensure the PV is writable by the mimir user (10001) |
| `mimir-nginx` 502 on `/api/v1/push` | Distributor not ready yet | Wait; check `kubectl -n dojo-lgtm get pods -l "app.kubernetes.io/component=distributor"` |

> **War story.** Rolled out mimir-distributed at SAP for a PoC — set `replication_factor: 3` (the default) without reading that it requires 3 ingester replicas in *different* zones. The ingesters came up, the distributor started, but every push returned `500 Internal Server Error: not enough live replicas`. The fix was setting `ingester.zoneAwareReplication.enabled: false` and `replication_factor: 1`. For a single-cluster kind lab, zone-aware replication is not just unnecessary — it actively prevents the cluster from functioning.

## Attacker's view

Mimir's `X-Scope-OrgID` is a trust header — Mimir doesn't sign or verify it, it just routes on it. In a bare deployment, any pod in the cluster can push metrics tagged as `org: finance` or query any tenant's data. The production fix is an authentication proxy (Grafana Enterprise's auth, or a custom Envoy filter) that maps the authenticated identity to an orgID and injects the header, preventing callers from self-assigning arbitrary tenants.
