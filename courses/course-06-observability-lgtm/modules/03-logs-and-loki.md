# Logs & Loki

> **Module 03 · Course 06** — Loki's tagline is "like Prometheus, but for logs." The analogy is closer than it sounds: Loki indexes labels and stores compressed log chunks, just as Prometheus indexes labels and stores sample chunks. If you understood the Prometheus cardinality lesson, half of Loki is already clear to you.

This module covers the architectural trade-offs, LogQL from stream selectors to metric queries, and the failure modes that produce no logs, bloated indexes, and painfully slow queries.

---

## Label-based indexing vs full-text search

Traditional log systems (Elasticsearch, Splunk, OpenSearch) index every word in every log line. Searching `"billing service"` scans an inverted index of all tokens — fast for ad-hoc search, expensive to build and store.

Loki does **not** index log content. It indexes only **labels** — small, low-cardinality key-value pairs attached to a log stream at ingest time.

```
┌──────────────────────── Loki architecture ─────────────────────────────┐
│                                                                         │
│  Agent (promtail / grafana-agent)                                       │
│  ┌────────────┐  attaches labels: {namespace, pod, container, app}     │
│  │  tail logs │ ──────────────────────────────────────►  Loki ingest   │
│  └────────────┘                                                         │
│                                                                         │
│  Loki                                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Index (BoltDB/Shipper or TSDB)                                  │  │
│  │  {namespace="billing", pod="api-7f9d"} → chunk file pointers     │  │
│  │                                                                   │  │
│  │  Chunks (compressed, object store or local)                      │  │
│  │  raw log lines for each stream, in time order                    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  At query time:                                                         │
│  1. LogQL stream selector → look up matching chunks from index         │
│  2. For each chunk → decompress, scan lines for filter expression      │
│  3. Return matching lines (log query) or aggregate (metric query)      │
└─────────────────────────────────────────────────────────────────────────┘
```

**Consequences of this design:**

- Ingest is cheap. No per-word indexing means dramatically lower write amplification than Elasticsearch — Loki can handle 100 GB+/day on modest hardware.
- Filtering within a stream is a **full scan of compressed chunks** for that stream. `|= "error"` does not use an index. It reads every chunk matching the stream selector and scans for the substring.
- The more selective your **stream selector** (the labeled part), the fewer chunks Loki reads. A stream selector that matches one pod reads far less than one that matches all pods in a namespace.
- Labels are the *only* index. If you search by something that isn't a label, you're paying a full-scan cost. This changes how you think about what to put in a label vs. what to leave in the log line.

---

## LogQL: stream selectors

Every LogQL query starts with a **stream selector** — a set of label matchers in `{}`. This is the indexed part of the query:

```logql
{namespace="billing"}                              # all logs in the billing namespace
{namespace="billing", pod=~"api-.+"}              # all api-* pods in billing
{namespace="billing", container="app", app="web"} # specific container
```

The matchers follow the same syntax as Prometheus label matchers:

| Operator | Meaning | Example |
|----------|---------|---------|
| `=` | exact equality | `namespace="billing"` |
| `!=` | not equal | `level!="debug"` |
| `=~` | regex match | `pod=~"api-.+"` |
| `!~` | regex not-match | `container!~"istio.*"` |

A stream selector must include at least one `=` (non-regex, non-negation) matcher or Loki will refuse the query (too broad, no index starting point).

---

## LogQL: filter expressions and parsers

After the stream selector, you add **pipeline stages** separated by `|`:

```logql
{namespace="billing"}
  |= "error"                       # substring match (case-sensitive)
  |~ "timeout|connection refused"  # regex match
  != "healthcheck"                 # substring exclusion
  !~ "GET /ping"                   # regex exclusion
```

**Parser stages** — interpret the log line structure so you can filter on extracted fields:

```logql
{namespace="billing"}
  | json                           # parse each line as JSON
  | level="error"                  # filter on extracted field
  | method="POST"

{namespace="billing"}
  | logfmt                         # parse logfmt key=value lines
  | duration > 500ms               # filter on parsed duration field
  | status_code >= 400

{namespace="billing"}
  | pattern `<method> <path> <status> <duration>`   # fixed-structure pattern
  | status = "500"
```

After parsing, you can use `| line_format` to reshape the output:

```logql
{namespace="billing"}
  | json
  | line_format "{{.level}} {{.msg}} traceID={{.trace_id}}"
```

---

## LogQL: metric queries

LogQL can also produce metrics from log streams — essentially turning a filter into a rate or count:

```logql
# error rate per pod (lines/second)
rate(
  {namespace="billing"} |= "error" [5m]
)

# 5xx rate from parsed JSON logs
sum by (pod) (
  rate(
    {namespace="billing"} | json | status_code >= 500 [5m]
  )
)

# count of unique error messages in the last 1 hour
count_over_time(
  {namespace="billing"} | json | level="error" [1h]
)
```

Metric queries return instant/range vectors — you can graph them in Grafana as time series, use them for alerting (via Prometheus → ruler, or Loki ruler), or display as stat panels.

> **Log metric queries are expensive when the stream selector is broad.** `rate({namespace="billing"}[5m])` reads every log chunk in the billing namespace for 5 minutes to count lines. On a high-throughput namespace this is a full table scan. Always narrow the stream selector first, then filter.

---

## The cardinality trap

This is the single most common Loki operational failure. Loki's index is built on label cardinality, and high cardinality labels cause index bloat, out-of-memory errors on the ingestor, and query timeouts.

**Good label — low cardinality:**

```yaml
namespace: billing          # ~10-100 distinct values across a cluster
pod: api-7f9d8b-xyz         # ~100-1000 distinct values (bounded by replica count)
container: app              # ~5-20 distinct values
level: error                # 4-5 values
```

**Bad label — high cardinality:**

```yaml
trace_id: "3f8a0c1..."          # millions of distinct values — one per request
user_id: "u-12345"              # millions of distinct values
request_id: "req-abc123"        # millions of distinct values
```

Each unique label combination is a **stream**. One stream per trace ID means millions of streams, each with a tiny handful of log lines — Loki's index explodes, ingestors OOM, and queries grind to a halt.

**The rule:** labels should describe *where* a log line came from (namespace, pod, container, app, environment). Content-derived values — trace IDs, user IDs, request IDs — belong **inside the log line as structured fields**, not as labels.

```yaml
# Correct: trace_id as a structured field in the log line JSON, not a label
log line: {"level":"info","msg":"handled","trace_id":"3f8a0c1...","duration_ms":47}
labels:   {namespace="billing", pod="api-7f9d8b-xyz", container="app"}
```

Then query by trace ID using a filter after parsing:

```logql
{namespace="billing"} | json | trace_id="3f8a0c1b2d4e5f6a"
```

This reads only the chunks for the `billing` namespace stream, then scans for the trace ID. Expensive for a full-namespace scan, but correct. If you need fast trace lookup, use Tempo (covered in Module 04) — tracing is Loki's worst use case.

---

## Promtail and Grafana Agent

Log lines don't get to Loki on their own. An **agent** runs on every node (DaemonSet), tails container log files, attaches labels, and ships to Loki.

Two options:

**Promtail** — the original Loki agent, simple, widely deployed:

```yaml
# promtail ConfigMap excerpt
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
    pipeline_stages:
      - docker: {}            # parse Docker JSON log wrapper
      - labels:
          level:              # extract "level" field as a label (keep cardinality low)
```

**Grafana Agent** — newer, supports metrics + logs + traces in one binary; uses the same River/Alloy config format:

```river
// agent.river
loki.source.kubernetes "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

In the kube-prometheus-stack, promtail is the default agent bundled with the Loki Helm chart. Install Loki + promtail:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install loki grafana/loki-stack \
  -n monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.persistence.enabled=false \
  --wait --timeout 8m
```

Verify promtail is shipping:

```bash
kubectl -n monitoring logs daemonset/loki-promtail | grep "level=info" | tail -10
# look for: "Sending batch" or "Successfully sent chunk"
```

---

## Structured logging

Loki's parser stages (`| json`, `| logfmt`) extract fields from log lines so you can filter on them. This only works if your logs are structured.

**Unstructured (hard to filter, no field extraction):**

```
2024-01-15 12:34:56 ERROR billing-service Request failed: timeout after 5001ms for user u-12345
```

**Structured JSON (fully filterable):**

```json
{"timestamp":"2024-01-15T12:34:56Z","level":"error","service":"billing","msg":"request failed","error":"timeout","duration_ms":5001,"user_id":"u-12345","trace_id":"3f8a0c1b"}
```

**Structured logfmt (readable + filterable):**

```
ts=2024-01-15T12:34:56Z level=error service=billing msg="request failed" error=timeout duration_ms=5001
```

With structured logging, you can do:

```logql
{namespace="billing"} | json | duration_ms > 1000 | level="error"
{namespace="billing"} | logfmt | error="timeout"
```

Without it, every query is a substring filter — no type-aware comparisons like `> 1000`.

**What to include in structured log fields vs labels:**

| Dimension | Labels (index) | Log fields (inline) |
|-----------|---------------|---------------------|
| Where the log came from | namespace, pod, container, app, env | — |
| Business context | — | user_id, tenant_id, order_id |
| Trace correlation | — | trace_id, span_id |
| Severity | level (if low cardinality: error/warn/info/debug) | — |
| Request detail | — | method, path, status_code, duration_ms |

---

## Debugging Loki

### No logs appearing

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Grafana Explore returns "No logs found" for a running pod | Promtail DaemonSet pod on that node is not running | `kubectl -n monitoring get pods -l app=promtail -o wide` — is there a pod on every node? |
| Promtail logs show `level=error` with `connection refused` | Wrong Loki endpoint URL in promtail config | Check `kubectl -n monitoring get configmap loki-promtail -o yaml` for the `url:` field |
| Logs visible in Grafana for some pods, not others | Promtail relabel_configs drop those pods | Add a `pod` label in the relabel config; check `__meta_kubernetes_pod_annotation_*` for an opt-in annotation |
| Log lines appear in Loki but Grafana shows nothing | Wrong time range selected; Grafana and Loki on different timezones | Set Grafana to UTC; check Loki's `--target` time alignment |
| `too many outstanding requests` in Loki logs | Querier overloaded | Reduce parallelism in queries, add more querier replicas, or use recording rules |

### Label explosion (cardinality trap hit)

**Symptoms:** Loki ingestor OOMKilled; `rpc error: code = ResourceExhausted`; query returns `max streams` error; Grafana shows `stream limit exceeded`.

**Diagnose:**

```bash
# How many active streams does Loki know about?
kubectl -n monitoring port-forward svc/loki 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/label' | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']
print('Labels:', len(data), data[:20])
"

# For each label, how many distinct values are there?
curl -s 'http://localhost:3100/loki/api/v1/label/trace_id/values' | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']
print('trace_id values:', len(data))
"
```

If any label has more than ~10,000 distinct values, it's the culprit. Remove it from labels and put it in the log line body.

**Fix in promtail:** remove the offending label from `pipeline_stages.labels`:

```yaml
pipeline_stages:
  - json: {}
  - labels:
      level:            # keep — low cardinality
      # trace_id:       # REMOVE — high cardinality, keep in log body
```

### Slow LogQL queries

| Symptom | Cause | Fix |
|---------|-------|-----|
| Query takes 30+ seconds, then times out | Stream selector too broad (matches millions of chunks) | Add more labels to the stream selector to narrow the chunk set |
| Regex filter `|~` is slow | Regex scan on every log line in the matched streams | Use `|=` substring filter first to reduce lines, then apply the regex |
| `|json` parser is slow on huge streams | Parsing every line to filter on one field | Pre-filter with `|=` substring on a known-unique string before `|json` |
| Metric queries over large time ranges time out | Too many chunks to aggregate | Shorten the time range; use Loki recording rules (`ruler`) for SLOs |

**Pattern for high-performance LogQL:** narrow first, then parse, then filter:

```logql
# slow: parses every line in namespace before filtering on level
{namespace="billing"} | json | level="error"

# faster: substring pre-filter reduces lines before json parsing
{namespace="billing"} |= `"level":"error"` | json | level="error"
```

The substring `|=` runs on the raw compressed chunks without parsing — much cheaper than `| json` for a first pass.

> **War story.** At SAP, Loki ingestors started OOMKilling every 6 hours. Memory kept climbing until the pod hit its 2 GB limit. The cardinality metric (`loki_ingester_streams_created_total`) was growing at 50k/hour. We traced it to a promtail pipeline stage that had been added quietly: `- labels: {correlation_id: ""}` — extracting a UUID from every log line's JSON body as a Loki label. Each unique correlation ID was a new stream. After 6 hours that was ~1.8 million streams in memory. The fix took 10 minutes: remove the `correlation_id` from `labels`, leave it in the JSON body, query with `| json | correlation_id="..."` instead. Memory stabilized under 300 MB. The lesson: treat every label addition to your promtail config as a potential OOM. Check `loki_ingester_streams_created_total` 10 minutes after any config change.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain why Loki does not index log content and what the performance implication is for filtering on log body text.
2. Write a LogQL query that returns all error-level logs from the `billing` namespace where `duration_ms > 500`, using the JSON parser.
3. Write a LogQL metric query that returns the per-pod error line rate over the last 5 minutes.
4. Name three labels that are good Loki label candidates and three that are cardinality traps — explain the criterion.
5. Diagnose a `stream limit exceeded` error in Loki — what command tells you how many distinct values a label has, and what do you do when it's in the millions?
6. Explain the "narrow first, then parse" pattern for LogQL — why is `|=` cheaper than `| json | field="value"` for an initial filter?
7. State the difference between promtail and Grafana Agent, and explain when you'd choose one over the other.
8. Given "no logs appearing for pod X in Grafana," list the three places you look first and the exact commands.

➡ Next up: **Module 04 — Tracing & Tempo** — distributed traces, OpenTelemetry instrumentation, and correlating traces with the metrics and logs you can now query.
