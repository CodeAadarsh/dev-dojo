#!/usr/bin/env bash
# Plants the "PromQL Hunt" scenario: an nginx pod serving a custom /metrics
# page that carries the flag in a dojo_flag_info label, plus a Service and
# ServiceMonitor so kube-prometheus-stack scrapes it.
set -euo pipefail

NS=dojo-obs
FLAG_VALUE='KUBE{promql_reads_the_label}'

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# ConfigMap: the metrics text served at /metrics
kubectl -n "$NS" create configmap promql-hunt-metrics \
  --from-literal=metrics="# HELP dojo_flag_info Static info metric carrying the challenge flag.
# TYPE dojo_flag_info gauge
dojo_flag_info{challenge=\"promql-hunt\",flag=\"${FLAG_VALUE}\"} 1" \
  --dry-run=client -o yaml | kubectl apply -f -

# ConfigMap: nginx config that serves the metrics file at /metrics
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: promql-hunt-nginx-conf
  namespace: dojo-obs
data:
  default.conf: |
    server {
        listen 8080;
        root /usr/share/nginx/html;
        location /metrics {
            default_type text/plain;
            try_files /metrics =404;
        }
        location / {
            return 200 'promql-hunt target\n';
            add_header Content-Type text/plain;
        }
    }
YAML

# Deployment: nginx serving the metrics ConfigMap
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promql-hunt-app
  namespace: dojo-obs
  labels:
    app: promql-hunt-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: promql-hunt-app
  template:
    metadata:
      labels:
        app: promql-hunt-app
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 8080
              name: metrics
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d
            - name: metrics-content
              mountPath: /usr/share/nginx/html
      volumes:
        - name: nginx-conf
          configMap:
            name: promql-hunt-nginx-conf
        - name: metrics-content
          configMap:
            name: promql-hunt-metrics
YAML

# Service exposing the metrics port
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: promql-hunt-app
  namespace: dojo-obs
  labels:
    app: promql-hunt-app
spec:
  selector:
    app: promql-hunt-app
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
YAML

# ServiceMonitor so kube-prometheus-stack scrapes this pod
cat <<'YAML' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: promql-hunt-app
  namespace: dojo-obs
spec:
  selector:
    matchLabels:
      app: promql-hunt-app
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'promql-hunt-app' serves a custom /metrics page."
echo "  Service + ServiceMonitor are wired — Prometheus will scrape within ~15s."
echo
echo "  Port-forward Prometheus and query for the flag:"
echo "    kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090"
echo "    # open http://localhost:9090 → Graph → query: dojo_flag_info"
