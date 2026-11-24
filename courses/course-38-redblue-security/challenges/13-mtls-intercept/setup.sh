#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-mtls"

echo "==> Setting up: mTLS Intercept"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Generate self-signed TLS certificate for backend.dojo-sec-mtls.svc
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tls-gen-script
  namespace: dojo-sec-mtls
data:
  gen.sh: |
    #!/bin/sh
    # Generate self-signed CA and server cert for backend
    openssl genrsa -out /certs/ca.key 2048
    openssl req -new -x509 -key /certs/ca.key -out /certs/ca.crt -days 365 \
      -subj "/CN=dojo-sec-mtls-ca"

    openssl genrsa -out /certs/server.key 2048
    openssl req -new -key /certs/server.key -out /certs/server.csr \
      -subj "/CN=backend-svc.dojo-sec-mtls.svc"
    openssl x509 -req -in /certs/server.csr \
      -CA /certs/ca.crt -CAkey /certs/ca.key -CAcreateserial \
      -out /certs/server.crt -days 365 \
      -extfile <(printf "subjectAltName=DNS:backend-svc.dojo-sec-mtls.svc,DNS:backend-svc")
    echo "TLS certs generated"
EOF

# Generate certs via a Job and store them in a Secret
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: tls-gen
  namespace: dojo-sec-mtls
spec:
  template:
    spec:
      restartPolicy: OnFailure
      volumes:
      - name: certs
        emptyDir: {}
      - name: script
        configMap:
          name: tls-gen-script
          defaultMode: 0755
      initContainers:
      - name: gen
        image: alpine/openssl:3.1.4
        command: [sh, /script/gen.sh]
        volumeMounts:
        - name: certs
          mountPath: /certs
        - name: script
          mountPath: /script
      containers:
      - name: store
        image: bitnami/kubectl:latest
        command:
        - sh
        - -c
        - |
          kubectl create secret generic tls-creds \
            --from-file=tls.crt=/certs/server.crt \
            --from-file=tls.key=/certs/server.key \
            --from-file=ca.crt=/certs/ca.crt \
            -n dojo-sec-mtls \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "TLS secret stored"
        volumeMounts:
        - name: certs
          mountPath: /certs
EOF

echo "[*] Waiting for TLS generation job..."
kubectl wait --for=condition=complete job/tls-gen -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
  echo "[!] TLS gen job may still be running..."

# Deploy backend (nginx, initially HTTP — learner upgrades to HTTPS)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-config
  namespace: dojo-sec-mtls
data:
  nginx-http.conf: |
    events {}
    http {
      server {
        listen 80;
        location / {
          add_header Content-Type text/plain;
          return 200 "backend: plaintext HTTP response\n";
        }
        location /flag {
          add_header Content-Type text/plain;
          return 200 "KUBE{mtls_encrypts_the_lateral_path}\n";
        }
      }
    }
  nginx-tls.conf: |
    events {}
    http {
      server {
        listen 443 ssl;
        ssl_certificate     /etc/tls/tls.crt;
        ssl_certificate_key /etc/tls/tls.key;
        location / {
          add_header Content-Type text/plain;
          return 200 "backend: TLS-encrypted response\n";
        }
        location /flag {
          add_header Content-Type text/plain;
          return 200 "KUBE{mtls_encrypts_the_lateral_path}\n";
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-sec-mtls
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      volumes:
      - name: nginx-conf
        configMap:
          name: backend-config
      - name: tls
        secret:
          secretName: tls-creds
          optional: true
      containers:
      - name: backend
        image: nginx:alpine
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/
        - name: tls
          mountPath: /etc/tls
          readOnly: true
        command: [nginx, -g, "daemon off;", -c, /etc/nginx/nginx-tls.conf]
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: dojo-sec-mtls
spec:
  selector:
    app: backend
  ports:
  - name: https
    port: 443
    targetPort: 443
  - name: http
    port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-sec-mtls
  labels:
    app: frontend
spec:
  containers:
  - name: frontend
    image: alpine/curl:latest
    command: [sleep, "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: rogue-pod
  namespace: dojo-sec-mtls
  labels:
    app: rogue
spec:
  containers:
  - name: rogue
    image: alpine/curl:latest
    command: [sleep, "3600"]
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Backend serves HTTPS on port 443 (TLS) and HTTP on port 80"
echo "    Backend service: backend-svc.dojo-sec-mtls.svc"
echo ""
echo "    Test TLS: kubectl exec -n $NAMESPACE frontend -- curl -sk https://backend-svc/flag"
echo "    Test HTTP intercept: kubectl exec -n $NAMESPACE rogue-pod -- curl -s http://backend-svc/flag"
echo ""
echo "    Run: bash verify.sh"
