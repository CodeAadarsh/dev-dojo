#!/usr/bin/env bash
# Plants the "ConfigMap Gone Wrong" scenario: a ConfigMap whose key does not
# match the filename nginx serves, so the custom page never loads.
set -euo pipefail

NS=dojo-config

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The content is correct (it contains the DOJO_CONFIG_OK marker) but it is
# stored under the key 'home.html'. Projected as a volume, that becomes the
# filename /usr/share/nginx/html/home.html — nginx looks for index.html and
# finds none, so it answers 403 Forbidden.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-content
  namespace: dojo-config
data:
  home.html: |
    <!doctype html>
    <html>
      <head><title>Dojo Config</title></head>
      <body>
        <h1>Served from a ConfigMap</h1>
        <p>DOJO_CONFIG_OK</p>
      </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-config
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
      volumes:
        - name: content
          configMap:
            name: web-content
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  ConfigMap 'web-content' holds the page under key 'home.html' (not 'index.html'),"
echo "  mounted at nginx's docroot — so the pod answers 403 instead of the custom page."
echo "  Make nginx serve the 'DOJO_CONFIG_OK' page, then run verify.sh:"
echo "    bash courses/course-01-ops-security/challenges/06-configmap-gone-wrong/verify.sh"
