# Solution: Tempo — Ship the Trace Receiver

## 1. Add the Grafana Helm repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

## 2. Inspect the default Tempo values

```bash
helm show values grafana/tempo | grep -A 20 receivers
```

The default `config.yaml` embedded in the chart enables only Jaeger and Zipkin. OTLP is present as a stub but not activated — `endpoint: ""` means no listener binds. You need to set non-empty endpoints to enable the receiver.

## 3. Install Tempo with OTLP enabled

### Option A — `--set` flags (fastest for the lab)

```bash
helm install tempo grafana/tempo \
  -n dojo-lgtm \
  --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317 \
  --set tempo.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318
```

### Option B — values file (the real-world approach, version-controlled)

```yaml
# tempo-values.yaml
tempo:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

```bash
helm install tempo grafana/tempo -n dojo-lgtm -f tempo-values.yaml
```

## 4. Verify the Service exposes OTLP ports

```bash
kubectl -n dojo-lgtm get svc tempo -o jsonpath='{.spec.ports[*].port}{"\n"}'
# expect: ... 4317 4318 ...
```

If the ports are missing, the chart version you installed may use a different values path. Check with:

```bash
helm get values tempo -n dojo-lgtm
helm get manifest tempo -n dojo-lgtm | grep -A5 'kind: Service'
```

## 5. Run the verifier

```bash
bash courses/course-17-lgtm-operated/challenges/04-tempo-traces/verify.sh
```

## Why the OTLP receiver must be explicit

Tempo ships with OTLP compiled in but _not configured by default_ for a good reason: if you enable the gRPC listener on 4317 but don't configure TLS, any client with network access can push traces. In a multi-tenant environment that means one tenant's noise drowns another's. Grafana's default-off design forces you to make a deliberate choice — and in production you'd pair this with an Alloy/OTel Collector in front of Tempo that authenticates senders (see challenge 05).

## Hardening preview

In production, you would:
1. Set `tempo.server.http_listen_address: 127.0.0.1` to bind the internal API locally only.
2. Front the OTLP port with an OTel Collector (challenge 05) that enforces auth via `otlpexporter` + mTLS.
3. Enable object storage (`tempo.storage.trace.backend: s3`) instead of the default in-cluster local disk.
4. Set `tempo.compactor.compaction.block_retention: 72h` to avoid unbounded disk growth in the lab.
