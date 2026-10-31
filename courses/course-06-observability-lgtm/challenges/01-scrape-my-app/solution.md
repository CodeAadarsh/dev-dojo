# Solution — Scrape My App

The flag is `KUBE{service_monitor_wires_the_scrape}`.

Two objects fix this: a `Service` (tells kube-proxy and DNS where to find the pods), and a `ServiceMonitor` (tells the Prometheus Operator to configure a scrape job for that Service).

## The manifests

```yaml
# svc.yaml — expose the metrics port with a stable name
apiVersion: v1
kind: Service
metadata:
  name: example-metrics-app
  namespace: dojo-obs
  labels:
    app: example-metrics-app
spec:
  selector:
    app: example-metrics-app
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
---
# servicemonitor.yaml — tell Prometheus Operator to scrape this Service
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: example-metrics-app
  namespace: dojo-obs
spec:
  selector:
    matchLabels:
      app: example-metrics-app
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Apply both:

```bash
kubectl apply -f svc.yaml -f servicemonitor.yaml
bash courses/course-06-observability-lgtm/challenges/01-scrape-my-app/verify.sh
```

## Why each piece is necessary

**Named port on the Service.** The ServiceMonitor references the port by *name* (`port: metrics`), not by number. That way, if the pod's containerPort changes, the ServiceMonitor doesn't break — a named port acts as a stable contract between the Service and the monitor.

**`spec.selector.matchLabels` on the ServiceMonitor.** The Prometheus Operator watches for ServiceMonitors and translates them into Prometheus scrape configs. The `selector` here is how the operator decides *which Service(s)* to include. A ServiceMonitor with an empty selector would match every Service in the namespace — almost never what you want.

**Namespace.** The ServiceMonitor lives in the same namespace as the Service (`dojo-obs`). If you ever want the Prometheus Operator (in `monitoring`) to discover ServiceMonitors in other namespaces, add `spec.namespaceSelector.any: true` (or list specific namespaces) to the `Prometheus` CR. The default kube-prometheus-stack watches all namespaces, so this works without any change to the `Prometheus` CR for this lab.

## Confirming it works end-to-end (after scrape interval)

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# wait ~30s for the first scrape, then:
# open http://localhost:9090/targets — look for 'dojo-obs/example-metrics-app'
# query: example_http_requests_total
```

## Attacker's view

A ServiceMonitor with an overly broad selector (e.g., `matchLabels: {}`) silently adds every Service in scope to Prometheus's scrape pool. In a multi-tenant cluster that can exfiltrate metrics from other teams' services and inflate Prometheus storage. Always scope ServiceMonitors tightly.
