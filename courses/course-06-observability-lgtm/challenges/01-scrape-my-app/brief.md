# Scrape My App

The on-call rotation just paged: a new service is deployed and "Prometheus isn't showing any metrics for it." You look at the app — it exposes a perfectly valid `/metrics` endpoint. Prometheus is running. But nothing shows up.

The missing link is almost always the same: **a ServiceMonitor telling Prometheus that this Service exists and how to scrape it.**

## Prereqs

kube-prometheus-stack must be installed in namespace `monitoring`:

```bash
bash labs/bootstrap/install-monitoring.sh
```

The ServiceMonitor CRD (`monitoring.coreos.com/v1`) is registered by that stack.

## Scenario

The setup script deployed `example-metrics-app` in namespace `dojo-obs`. It runs `quay.io/brancz/prometheus-example-app:v0.5.0`, which exposes a live `/metrics` endpoint on port `8080`. The Deployment exists. Nothing else does.

## Mission

Make the app scrapeable. Specifically, you must create:

1. **A `Service`** in `dojo-obs` that exposes port `8080` with a port **named `metrics`**.
2. **A `ServiceMonitor`** (`monitoring.coreos.com/v1`) in `dojo-obs` whose `spec.selector.matchLabels` targets that Service — i.e., it has at least one label key that the Service carries.

The verifier checks these two authored objects. It does **not** require Prometheus to have scraped the app yet (scrape intervals introduce lag); it validates that the wiring is correctly declared.

## Exact verifier conditions

- `kubectl -n dojo-obs get servicemonitor` returns at least one object.
- The ServiceMonitor's `spec.selector.matchLabels` is non-empty.
- `kubectl -n dojo-obs get svc` returns at least one Service with a port **named `metrics`** (or port number `8080`).

When all three pass, run the verifier:

```bash
bash courses/course-06-observability-lgtm/challenges/01-scrape-my-app/verify.sh
```

## Why this matters

A Prometheus scrape configuration has two layers in the Prometheus Operator model:

- The `ServiceMonitor` is the *intent* — "scrape this family of Services."
- The `Service` is the *target* — it resolves to pod IPs that Prometheus actually hits.

Without the ServiceMonitor, Prometheus ignores the app entirely. Without the named port, the ServiceMonitor can't reference a stable port regardless of what IP the pods end up at. Understanding this wiring is prerequisite to building any meaningful observability stack.
