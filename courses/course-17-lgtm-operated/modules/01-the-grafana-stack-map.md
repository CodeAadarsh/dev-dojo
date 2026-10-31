# The Grafana LGTM Stack, Mapped

> **Module 01 · Course 17** — Before you operate a stack, you need to know what each component actually does, where its boundary with its neighbors is, and when to reach for the monolithic tarball versus the ten-component microservices Helm chart. This module draws the map.

You've used Grafana to browse dashboards and maybe written a PromQL query. That's the 10% you can see. The other 90% — where data lands, how it's indexed, what the compactor is doing at 3 AM, and why your query is slow — is what this course covers.

---

## The signal taxonomy before the stack

The LGTM stack names itself after four telemetry signals. Know the line between them before you wire anything:

| Signal | Type | Cardinality axis | Primary query concern |
|--------|------|------------------|-----------------------|
| Metrics (M) | numeric time-series | number of unique label combinations | PromQL / rate calculations |
| Logs (L) | unstructured / structured text streams | number of unique stream label sets | full-text search, parsing overhead |
| Traces (T) | request-scoped spans with parent-child links | span count × label count | latency attribution, service graph |
| Profiles (P) | sampled CPU/heap/goroutine stack snapshots | number of profiled processes × sample rate | flamegraph, regressed allocation sites |

Grafana's LGTM acronym is backwards from the dependency order: **L**oki + **G**rafana + **T**empo + **M**imir. Pyroscope covers Profiles and sits alongside them.

---

## Component roles

```
┌────────────────────────── telemetry producers ───────────────────────────────┐
│  your services (Prometheus exporter, OTLP emitter, pprof endpoint)           │
└───────────┬──────────────────────────┬───────────────────────────────────────┘
            │ metrics (remote_write)    │ logs / traces / profiles (OTLP / push)
            ▼                          ▼
┌───────────────────────┐  ┌──────────────────────────────────────────────────┐
│   Grafana Alloy /     │  │              same Alloy / OTel Collector          │
│   OTel Collector      │  │  relabels, batches, routes, tail-samples          │
│  (pipeline edge)      │  └───────────────┬───────────────┬───────────────────┘
└──────────┬────────────┘                  │               │
           │ remote_write                   │ OTLP push     │
           ▼                               ▼               ▼
   ┌──────────────┐           ┌─────────────────┐  ┌──────────────────┐
   │    Mimir     │           │      Loki        │  │     Tempo         │
   │ (metrics)    │           │    (logs)        │  │    (traces)       │
   └──────┬───────┘           └────────┬─────────┘  └───────┬──────────┘
          │                            │                     │
          └────────────────────────────┼─────────────────────┘
                                       │  all three flush to
                                       ▼
                            ┌──────────────────────┐
                            │   Object Storage      │
                            │  (S3 / GCS / MinIO)   │
                            └──────────────────────┘
                                       │
                                       ▼
                            ┌──────────────────────┐
                            │   Grafana (frontend)  │
                            │  datasources, alerts, │
                            │  dashboards-as-code   │
                            └──────────────────────┘
                            ┌──────────────────────┐
                            │   Pyroscope           │
                            │  (continuous profiling│
                            └──────────────────────┘
```

### Grafana — the query and visualization plane

Grafana doesn't store anything (except its own metadata — dashboards, alerts, users). Every panel points at a *datasource*, which is an API endpoint Grafana queries at render time. You can point a single Grafana instance at Mimir, Loki, Tempo, Pyroscope, and a dozen other datasources simultaneously. The Explore view is your operator's debugging console.

When to reach for it: always — Grafana is the unified UI regardless of which backend you're operating.

### Mimir — metrics at scale

Prometheus is great until you need multi-tenancy, long-term retention, or horizontal scale on the write path. Mimir is a horizontally-scalable, multi-tenant Prometheus-compatible backend. It speaks the Prometheus remote-write protocol on the way in and the Prometheus HTTP API on the way out. Grafana queries it as a "Prometheus" datasource.

When to reach for it: any time you have more than one Prometheus instance, need >30d retention without exploding disk, or need tenant isolation. If you're operating Mimir for Grafana Labs customers, you'll be tuning this path constantly.

### Loki — logs without full-text indexing

Loki's key design constraint: **it only indexes labels on log streams, not the log content itself**. This keeps storage cheap and write throughput high, but it shifts the cost to query time — a label-only filter returns cheaply; a `|= "some-string"` full-text filter scans chunks. Understanding that trade-off is the only thing you need to know to avoid every Loki performance mistake.

When to reach for it: when you want log aggregation with PromQL-like query patterns (LogQL) and you're already running the Grafana stack. Not the right choice if you need sub-second full-text search on high-cardinality free-form text — that's Elasticsearch territory.

### Tempo — distributed tracing

Tempo stores spans, not time-series. The write path is cheap — accept OTLP or Zipkin or Jaeger over gRPC/HTTP, shard by trace ID, write chunks to object storage. The query path is expensive: finding a trace by attribute (e.g., `status=error`) requires reading index shards; finding by trace ID directly is O(1). Tempo's query language is TraceQL.

The power move: **trace exemplars**. A Prometheus metric can carry an exemplar — a pointer to the trace ID of the request that generated that metric sample. Grafana stitches this: click a spike in your error-rate panel, Grafana jumps to the trace for that exact request.

When to reach for it: you have distributed services and want to understand latency between them. If you only have one service, standard logging is sufficient.

### Pyroscope — continuous profiling

Pyroscope periodically snapshots CPU/memory/goroutine stacks across your fleet and stores the stack profiles as flamegraph-ready data. Unlike ad-hoc `pprof` dumps, it runs continuously, so you can say "what was consuming CPU at 14:37:12 on Wednesday?" and get a flamegraph.

When to reach for it: profiling is the last signal you add, when you know *that* something is slow but not *where in the code*. At Grafana Labs, Pyroscope runs on the Grafana platform itself — they dog-food it.

### Alloy / OTel Collector — the telemetry pipeline edge

**Alloy** is Grafana's distribution of the OpenTelemetry Collector with an Alloy-syntax configuration language on top. It runs as a DaemonSet (one per node) or a standalone Deployment depending on role:

- **DaemonSet mode**: collect node-level metrics, host logs from `/var/log`, forward to Mimir/Loki/Tempo.
- **Gateway mode**: receive OTLP from all services in the cluster, fan out to multiple backends, apply tail-sampling to traces.

The vanilla OpenTelemetry Collector (without Alloy's extensions) is also a valid choice; they speak the same OTLP protocol. Alloy gives you better Kubernetes-native service discovery and Grafana-specific receivers.

---

## Deployment modes: monolithic vs microservices

Every LGTM component ships in two modes. This decision is almost always about cluster size and operational overhead, not features.

### Monolithic (single binary)

All roles run as one process in one Pod. Good for:

- Local development (kind cluster).
- Low-traffic clusters where you don't need to scale ingesters independently.
- Getting the stack running in < 30 min.

```yaml
# Mimir monolithic — one Deployment, all roles
args:
  - -target=all
  - -config.file=/etc/mimir/mimir.yaml
```

### Microservices

Each role is its own Deployment. You scale ingesters separately from queriers, apply resource limits per component, and upgrade them in a rolling fashion without coordinating a monolith restart.

```
Distributor → Ingester (3× stateful) → Store-Gateway → Querier ← Query-Frontend
                                    ↓
                              Object Storage (every 2h block flush)
```

The Helm chart (`grafana/mimir-distributed`) ships the microservices mode by default with sensible replica counts for each component. Use it in production or any cluster where you care about availability during upgrades.

| Decision factor | Monolithic | Microservices |
|----------------|------------|---------------|
| Ops overhead | Minimal | High — more Deployments, more StatefulSets, more PodDisruptionBudgets |
| Scale axis | Vertical only | Horizontal per-component |
| Right for kind dojo | Yes | Yes, but needs ≥ 4 GB Docker RAM |
| Right for production | Only for very small clusters | Yes |

### The key insight: these aren't different products

Monolithic and microservices modes run the same binary with `-target=all` vs `-target=distributor`, etc. You can migrate from monolithic to microservices without any data migration — they share the same block format on object storage.

---

## Object storage as the common substrate

Mimir, Loki, and Tempo all use the same pattern: an **in-memory write buffer (ingesters)** flushes to an **object store (S3/GCS/MinIO/Azure Blob)** in periodic blocks. Queriers then read from both the live ingesters and the cold object store.

```
Write path:   Alloy → Distributor → Ingester (writes WAL + in-memory)
                                           ↓ flush every 2h
                                  Object Storage (immutable blocks)

Read path:    Grafana → Querier → ingesters (hot, <2h data)
                              → Store-Gateway → Object Storage (cold, >2h data)
```

In the kind dojo you'll use MinIO (`bitnami/minio:2024.11.7`) as a local S3-compatible target. In real clusters it's S3 or GCS. The configs only differ in the endpoint and credential fields — the block format is identical.

---

## Debugging: picking the wrong deployment mode and under-provisioned ingesters

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pods OOMKilled with default monolith Helm values | Monolith's memory defaults assume more RAM than your kind node has | Lower `resources.limits.memory`, or set `replication_factor=1` for single-replica lab mode |
| Querier timeout but ingesters healthy | Store-gateway can't fetch blocks — MinIO bucket doesn't exist or creds wrong | `kubectl -n dojo-mimir logs -l app.kubernetes.io/component=store-gateway \| grep -i error`; verify bucket exists |
| Ingester ring stuck in `JOINING` > 5 min | Previous ingester crashed during token registration; ring state stale | Delete the stuck ingester pod; ring entry expires after `ring_heartbeat_timeout` |
| Microservices: Distributor crashes with `too many unhealthy instances` | Ingesters not yet Ready; distributor health-checks fail during startup | Wait for all ingesters to reach `ACTIVE` in the ring before scaling the distributor |
| Missing data after a clean kind delete+recreate | MinIO was ephemeral (emptyDir); all blocks lost | Mount MinIO on a `hostPath` PVC with `Retain` policy |
| Grafana datasource "connected but no labels received" | `X-Scope-OrgID` header missing from datasource config | Edit datasource; add `httpHeaderName1: X-Scope-OrgID`, `httpHeaderValue1: dojo-tenant` |

> **War story.** On a Loki deployment migration from monolithic to microservices mode, the migration itself was smooth — Helm upgrade, new target flags — but for six hours after the cutover, write throughput halved and queues backed up on the distributors while ingesters looked healthy. The root cause: the new chart defaults set `replication_factor: 3` but only 2 ingester pods were running (one was stuck in `Init:0/1` waiting on a PVC). The distributor was retrying failed third-replica writes with a 1s timeout, eating 30% of capacity. The fix was scaling ingesters to 3 replicas — one command — but the symptom (slow distributors) pointed nowhere near the cause (insufficient ingesters for the configured replication factor). Always assert `replication_factor` matches available ingester count before any topology change. The metric `cortex_ring_members{state="ACTIVE",component="ingester"}` going below `replication_factor` is now a P1 alert on that cluster.

---

## Checkpoint

You're ready to move on when you can:

1. Name each LGTM component, what signal it stores, and one situation where it is the wrong choice.
2. Explain the write path from Alloy DaemonSet to object storage in five sentences.
3. Choose monolithic vs microservices for a given scenario and defend the decision.
4. Explain why Loki's "only index labels, not content" design is both a strength and a footgun.
5. Describe the trace exemplar mechanism: what it is, where the exemplar lives in a Prometheus metric, and how Grafana uses it to jump from a metric spike to a specific trace.
6. State why you should never assume that deleting a kind cluster preserves your MinIO blocks.

➡ Next up: **Mimir: Metrics at Scale** — the write/read path in detail, multi-tenancy, cardinality limits, and HA dedup.
