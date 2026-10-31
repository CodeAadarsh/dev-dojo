# Grafana & Correlating Signals

> **Module 05 · Course 06** — A Grafana dashboard is not a collection of panels. It is a decision-making surface. This module covers the mechanics of datasources, variables, and panel wiring — then the part that actually earns your salary: correlating a metrics spike with the right log lines and the right trace in a single click, without manually copy-pasting timestamps.

You already have Prometheus, Loki, and Tempo running. This module makes them talk to each other through Grafana.

---

## Datasource wiring

Every panel pulls from exactly one datasource. Grafana discovers datasources from its config — either the UI or `grafana.ini` / provisioned YAML. With kube-prometheus-stack, Prometheus and Alertmanager are provisioned automatically. Add Loki and Tempo in the Helm values:

```yaml
# helm values — grafana.additionalDataSources
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      uid: loki
      url: http://loki.monitoring.svc.cluster.local:3100
      jsonData:
        maxLines: 1000
        derivedFields:
          - name: TraceID
            matcherRegex: '"traceId":"(\w+)"'
            url: '$${__value.raw}'
            datasourceUid: tempo    # opens Tempo when the field is clicked
    - name: Tempo
      type: tempo
      uid: tempo
      url: http://tempo.monitoring.svc.cluster.local:3100
      jsonData:
        tracesToLogsV2:
          datasourceUid: loki
          filterByTraceID: true
          filterBySpanID: false
        serviceMap:
          datasourceUid: prometheus
        lokiSearch:
          datasourceUid: loki
        nodeGraph:
          enabled: true
```

The `uid` fields matter — other datasources reference them by UID for the cross-linking, so keep them short and stable (`loki`, `tempo`, `prometheus`).

---

## Dashboards, template variables, and panels

### Dashboard JSON and provisioning

Grafana dashboards are JSON. In a GitOps setup, you provision them via ConfigMaps mounted into the Grafana pod:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dojo-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # label watched by the sidecar provisioner
data:
  dojo-overview.json: |
    { ...dashboard JSON... }
```

The kube-prometheus-stack ships a `grafana.sidecar.dashboards` sidecar that watches ConfigMaps with label `grafana_dashboard: "1"` and hot-loads them — no pod restart needed.

### Template variables

Variables turn a static dashboard into a reusable one. They appear as dropdowns at the top and are referenced in every query as `$variable`.

The four most useful variable types:

| Type | Definition | Use for |
|------|-----------|---------|
| `query` | PromQL / LogQL / Tempo query result | `namespace`, `pod`, `service_name` — values from live data |
| `constant` | Fixed string | Environment tag, cluster name |
| `textbox` | Free text input | Ad-hoc filter string |
| `interval` | Time step ($__interval) | Rate function step — critical for correct `rate()` |

Example: a `namespace` variable backed by a Prometheus label query:

```
label_values(kube_pod_info, namespace)
```

Reference it in a panel:

```promql
sum(rate(http_requests_total{namespace="$namespace"}[$__rate_interval]))
```

Always use `$__rate_interval` (not `$__interval`) for `rate()` and `increase()` — it is at least `4 * scrape_interval`, which prevents the "not enough samples in range" error that produces gaps in graphs.

### Panel types and when to use each

| Panel | Best for | Gotcha |
|-------|---------|--------|
| Time series | Metrics over time | Default; stack carefully — stacked series hide individual drops |
| Stat / Big number | Single current value (uptime, error rate) | Misleads without a sparkline — always enable "Show graph" |
| Table | Multi-dim comparisons, log field extraction | Column transforms are applied in order — move the wrong step and data disappears |
| Logs | Loki log stream | "Deduplication" is on by default — turn off if you want raw line counts |
| Traces | Tempo trace explorer | Requires Tempo datasource; the panel renders the span waterfall inline |
| Node Graph | Service topology from span metrics | Requires `serviceMap.datasourceUid` set on the Tempo datasource |

---

## Correlating metrics, logs, and traces

This is the payoff. The goal is: see a metric spike → land on the right logs → open the trace responsible, without ever leaving Grafana or manually copy-pasting a timestamp.

### Path 1: Metrics → Traces via exemplars

A histogram panel (e.g. `http_server_duration_seconds`) in Grafana shows individual data points from Prometheus when exemplars are enabled. Each exemplar point carries `{traceId}`. Click "Query with exemplars" in the panel; Grafana calls Tempo directly for that traceId. This works in both Explore and dashboard panels.

In the panel editor, enable it under **Panel options → Data links** — or use the "Exemplars" toggle in the Prometheus datasource query editor.

### Path 2: Logs → Traces via derived fields

The `derivedFields` config on the Loki datasource (shown in the datasource wiring section above) scans every log line for the `matcherRegex`. When the traceId pattern matches, Grafana renders it as a clickable link that opens Tempo. This means a structured JSON log line like:

```json
{"level":"error","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","msg":"payment failed"}
```

…produces a "Tempo" button in the log panel with no extra configuration beyond the derived field regex.

### Path 3: Traces → Logs via Tempo's Loki integration

When viewing a trace in Tempo (via Explore or the Traces panel), Grafana shows a "Logs for this span" button if `tracesToLogsV2.datasourceUid` is set. It issues a Loki query like:

```logql
{job="myapp"} | json | traceId="4bf92f3577b34da6a3ce929d0e0e4736"
```

This requires that your log lines contain `traceId` and that the Loki stream labels or structured metadata make the query performant.

### The correlation workflow in practice

```
Prometheus panel: error rate spike at 14:32:05
  │
  └─ click exemplar data point
       │
       └─ Grafana opens Tempo trace: "payment POST /v2/charge  1.8s  ERROR"
            │
            └─ click "Logs for this span"
                 │
                 └─ Loki returns the 3 log lines from that span with the stack trace
```

No timestamp juggling. No grep. This is what makes LGTM better than having three separate tools.

---

## Alerting in Grafana (Unified Alerting)

Grafana's Unified Alerting (GA since Grafana 9) can alert directly from Grafana-managed rules in addition to Prometheus AlertManager rules. Use it when:
- You need to alert on Loki queries (LogQL-based alerts not supported by Prometheus).
- You want a single alert management UI instead of juggling both Alertmanager config and Grafana config.

> For Prometheus-managed alerts, prefer Prometheus PrometheusRule CRDs (covered in the next module) — they are version-controlled as Kubernetes objects. Grafana alerting is best for Loki/Tempo-based rules.

Creating a Grafana alert:

1. In the panel editor, click **Alert** tab → **Create alert rule from this panel**.
2. Reduce the time series to a scalar (e.g. `Last`) and set the threshold condition.
3. Assign it to a folder and an evaluation group (controls evaluation interval — minimum 10s).
4. Set contact points (Slack, PagerDuty, etc.) and notification policies.

The Grafana alert state machine: `Normal → Pending (for N minutes) → Firing`. The `Pending` period prevents single-scrape blips from paging you.

---

## Debugging Grafana & correlation

Almost every Grafana issue is a datasource config problem, a variable scoping issue, or a time range mismatch. Start with "no data" — it is almost always one of these three.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Panel shows "No data" on a query that works in Prometheus | Time range in the panel is outside the data retention window | Set dashboard time range to "Last 1h"; check Prometheus retention (`--storage.tsdb.retention.time`) |
| Variable dropdown is empty | Query datasource wrong, or label has no values in selected time range | In variable editor, hit "Run query" manually; check that the `label_values()` metric exists |
| `$namespace` variable doesn't filter the panel | Variable referenced as `$namespace` but panel query uses `namespace=~"$namespace"` vs `namespace="$namespace"` | Use `=~` for multi-select variables (they emit a `var1\|var2` regex); use `=` only for single-select |
| Rate/increase panels show gaps at regular intervals | `rate()` window smaller than `2 * scrape_interval` | Replace `[$__interval]` with `[$__rate_interval]` in all `rate()` and `increase()` calls |
| Logs panel shows timestamps in wrong timezone | Browser timezone vs UTC mismatch | Dashboard Settings → Timezone → set to "Browser" or explicitly to UTC; match your log format |
| Exemplar points visible in panel but "Query with exemplars" returns no trace | Tempo datasource UID in the Prometheus datasource's `exemplarTraceIdDestinations` is wrong | In Datasource settings → Prometheus → Exemplars: set "Data source" to the Tempo datasource |
| Trace panel shows spans but "Logs for this span" button is missing | `tracesToLogsV2` not set in the Tempo datasource config | Add `tracesToLogsV2.datasourceUid: loki` to the Tempo datasource jsonData |
| Grafana alerts firing but no notification received | No contact point assigned to the notification policy, or the policy's matcher doesn't match | Go to Alerting → Notification policies and trace the policy tree; confirm the alert labels match |

### Exact diagnostic commands

Check whether the Prometheus datasource is reachable from Grafana:

```bash
kubectl -n monitoring exec -it deploy/kps-grafana -- \
  wget -qO- http://prometheus-operated.monitoring.svc.cluster.local:9090/-/healthy
```

Test a Loki query from the CLI to confirm data exists before blaming Grafana:

```bash
kubectl -n monitoring port-forward svc/loki 3101:3100 &
curl -s 'http://localhost:3101/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="dojo-tracing"}' \
  --data-urlencode 'start=1h' \
  --data-urlencode 'limit=5' | \
  python3 -c "import sys,json; r=json.load(sys.stdin); print(len(r['data']['result']), 'streams')"
```

Check exemplar storage is enabled and has data in Prometheus:

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query_exemplars' \
  --data-urlencode 'query=http_server_duration_seconds_bucket' \
  --data-urlencode 'start=-1h' | \
  python3 -c "import sys,json; r=json.load(sys.stdin); print(sum(len(s.get('exemplars',[])) for s in r.get('data',[])), 'exemplars')"
```

Check Grafana provisioned datasources:

```bash
kubectl -n monitoring exec -it deploy/kps-grafana -- \
  wget -qO- --header='Authorization: Basic YWRtaW46YWRtaW4=' \
  http://localhost:3000/api/datasources | \
  python3 -c "import sys,json; [print(d['name'], d['uid'], d['type']) for d in json.load(sys.stdin)]"
```

> **War story.** After adding Tempo to the SAP dojo cluster, the "Query with exemplars" button appeared in Prometheus panels but clicking it always returned "Trace not found." The Tempo datasource was healthy — `curl localhost:3100/api/search` returned traces. The bug was a UID mismatch: the Tempo datasource had been provisioned with `uid: Tempo` (capital T) in the Helm values, but the Prometheus datasource's `exemplarTraceIdDestinations[0].datasourceUid` was set to `tempo` (lowercase). Grafana's datasource lookup is case-sensitive on UID. The fix: standardize all datasource UIDs to lowercase in the Helm values and redeploy. The lesson: UIDs are contracts — treat them like environment variable names, not labels.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Explain why `$__rate_interval` is always correct for `rate()` panels and `$__interval` sometimes produces gaps.
2. State when to use `=~` vs `=` for a template variable in a PromQL query.
3. Describe the three correlation paths between metrics, logs, and traces in Grafana and which datasource config enables each.
4. Explain derived fields on the Loki datasource: what the `matcherRegex` does and what clicking the resulting link triggers.
5. Reproduce the war-story UID mismatch in one sentence and state the fix.
6. Run the CLI command that confirms whether exemplars are stored in Prometheus for a given metric.
7. Explain why Grafana's "Pending" period in alert rules prevents false pages during a single bad scrape.
8. Describe how to hot-load a new Grafana dashboard into kube-prometheus-stack without restarting the Grafana pod.

→ Next up: **Alerting, SLOs & Cardinality at Scale** — burn-rate SLO alerts, recording rules for high-traffic SLIs, and taming high cardinality before it bankrupts your TSDB.
