#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-imds"

echo "==> Setting up: IMDS Credential Theft"

# Idempotent namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- IMDS simulation: nginx serving fake AWS IMDS responses ---

# ConfigMap with nginx config to serve IMDS paths
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: fake-imds-nginx-conf
  namespace: dojo-sec-imds
data:
  nginx.conf: |
    events {}
    http {
      server {
        listen 80;

        location /latest/meta-data/ {
          add_header Content-Type text/plain;
          return 200 "ami-id\nami-launch-index\nami-manifest-path\nhostname\niam/\ninstance-id\ninstance-type\nlocal-ipv4\nplacement/\npublic-ipv4\n";
        }

        location /latest/meta-data/iam/ {
          add_header Content-Type text/plain;
          return 200 "info\nsecurity-credentials/\n";
        }

        location /latest/meta-data/iam/security-credentials/ {
          add_header Content-Type text/plain;
          return 200 "node-role\n";
        }

        location /latest/meta-data/iam/security-credentials/node-role {
          add_header Content-Type application/json;
          return 200 '{
  "Code": "Success",
  "LastUpdated": "2026-11-25T00:00:00Z",
  "Type": "AWS-HMAC",
  "AccessKeyId": "ASIAREDTEAM1337DOJO",
  "SecretAccessKey": "KUBE{imds_creds_live_on_169_254_169_254}",
  "Token": "FakeSTS//////////SimulatedSessionToken==",
  "Expiration": "2026-11-25T06:00:00Z"
}';
        }

        location /latest/meta-data/instance-id {
          add_header Content-Type text/plain;
          return 200 "i-0dojo1337abcdef01";
        }

        location / {
          return 404;
        }
      }
    }
EOF

# Deploy fake IMDS pod
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fake-imds
  namespace: dojo-sec-imds
  labels:
    app: fake-imds
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fake-imds
  template:
    metadata:
      labels:
        app: fake-imds
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-conf
        configMap:
          name: fake-imds-nginx-conf
EOF

# Service for fake IMDS
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: fake-imds-svc
  namespace: dojo-sec-imds
spec:
  selector:
    app: fake-imds
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

# --- Attacker foothold pod ---
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: attacker-foothold
  namespace: dojo-sec-imds
  annotations:
    dojo.red-team/technique: T1552.005
    dojo.red-team/description: "Cloud Instance Metadata API credential theft"
spec:
  containers:
  - name: attacker
    image: curlimages/curl:8.10.1
    command: ["sleep", "3600"]
  restartPolicy: Always
EOF

# MITRE reference configmap
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mitre-reference
  namespace: dojo-sec-imds
data:
  technique: "T1552.005 — Unsecured Credentials: Cloud Instance Metadata API"
  description: "Adversaries may attempt to access the Cloud Instance Metadata API to collect credentials and other sensitive data."
  url: "https://attack.mitre.org/techniques/T1552/005/"
  hint: "The IMDS service is simulated at http://fake-imds-svc — curl its endpoints to discover the flag"
EOF

echo ""
echo "==> Setup complete. Scenario ready."
echo ""
echo "    You are inside pod 'attacker-foothold' in namespace '$NAMESPACE'."
echo "    The cloud IMDS service is simulated at http://fake-imds-svc"
echo ""
echo "    Get a shell: kubectl exec -it attacker-foothold -n $NAMESPACE -- sh"
echo "    Then probe:  curl http://fake-imds-svc/latest/meta-data/"
echo ""
echo "    The flag is hidden in the IAM credential response. Find it."
