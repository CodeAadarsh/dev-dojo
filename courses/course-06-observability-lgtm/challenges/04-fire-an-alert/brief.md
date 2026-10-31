# Fire an Alert

Your team's SRE review found this in your runbook: *"Manually check Grafana every morning to see if the scrape targets are down."* That's not alerting — that's vigilance theater.

A real alerting rule is evaluated continuously by Prometheus. When the expression is truthy for longer than the `for` duration, Prometheus fires the alert and routes it to Alertmanager (and from there to PagerDuty / Slack / whatever you have on call). The rule lives in a `PrometheusRule` CRD that the kube-prometheus-stack operator watches — you author the YAML, the stack picks it up automatically.

## Prereq

The `kube-prometheus-stack` must be installed:

```bash
bash labs/bootstrap/install-monitoring.sh
```

## Mission

Create a `PrometheusRule` resource in namespace `dojo-alert` that meets **all** of these conditions:

1. `apiVersion: monitoring.coreos.com/v1`, `kind: PrometheusRule`.
2. Label `release: kps` on the resource (so the Prometheus CRD selector picks it up — the stack installs with release label `kps`).
3. At least one group under `spec.groups[].rules[]` that is an **alerting rule** (has an `alert:` field, not `record:`).
4. The rule's `expr` is non-empty and syntactically sensible — a valid PromQL expression. A useful baseline: `up == 0` fires when any scrape target goes down.
5. The rule has a `for:` field (e.g. `for: 1m`) — this is the sustain window that separates a real outage from a blip.
6. The rule has a `labels:` block containing at least a `severity` key (e.g. `severity: warning` or `severity: critical`).
7. The rule has an `annotations:` block with at least a `summary` key.

The verifier checks for the existence and shape of the PrometheusRule object — it does **not** require the alert to be in a firing state in Prometheus (the kube-prometheus-stack needs time to reload rules).

## Why a 'for' duration is not optional

Without `for`, Prometheus fires the alert the instant the expression is truthy — even for a 200ms network hiccup. With `for: 1m`, it must stay truthy for a full minute before paging anyone. The difference between a useful alert and alert fatigue is almost always in the `for` field and the quality of the expression. You'll feel this in the SLO challenge next.

## Namespacing

Work in `dojo-alert`. Run `setup.sh` to create it.
