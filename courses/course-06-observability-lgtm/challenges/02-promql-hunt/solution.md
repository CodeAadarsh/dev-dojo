# Solution — PromQL Hunt

The flag is `KUBE{promql_reads_the_label}`.

## How the flag is embedded

`setup.sh` serves this exact text from nginx at `/metrics`:

```
# HELP dojo_flag_info Static info metric carrying the challenge flag.
# TYPE dojo_flag_info gauge
dojo_flag_info{challenge="promql-hunt",flag="KUBE{promql_reads_the_label}"} 1
```

A ServiceMonitor wires this endpoint into kube-prometheus-stack. After one scrape interval (~15 s), the time-series is in Prometheus's TSDB with the `flag` label attached.

## Extraction path 1 — Prometheus UI

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# open http://localhost:9090 → Graph
# query: dojo_flag_info
```

The result row shows:

```
dojo_flag_info{challenge="promql-hunt", flag="KUBE{promql_reads_the_label}", ...} 1
```

Read the `flag` label value — that's the flag.

## Extraction path 2 — Prometheus HTTP API

```bash
curl -s 'http://localhost:9090/api/v1/query?query=dojo_flag_info' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['data']['result'][0]['metric']['flag'])"
# -> KUBE{promql_reads_the_label}
```

## Extraction path 3 — kubectl direct (no Prometheus needed)

Since the flag is in a ConfigMap that the pod serves:

```bash
kubectl -n dojo-obs get configmap promql-hunt-metrics -o jsonpath='{.data.metrics}'
```

That outputs the raw metrics text with the flag visible. This is the "fallback" path — no Prometheus required.

## Why label cardinality matters at scale

The `dojo_flag_info` metric has two static labels: `challenge` and `flag`. Each unique label combination is a distinct time-series in Prometheus's TSDB. If this label were something like `user_id` with millions of distinct values, Prometheus would create millions of time-series — blowing up memory and write amplification. That's high cardinality: the single biggest operational risk in a large Prometheus deployment.

In the LGTM pipeline at SAP (100 GB+/day), label cardinality governance is a first-class concern: every new metric gets a cardinality review before it ships to the long-term store.
