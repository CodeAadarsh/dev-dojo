#!/usr/bin/env bash
# Module 05 — Cloud IAM & Metadata Service Lab
# Fake IMDS server serving mock AWS metadata responses
set -euo pipefail

NS="dojo-lab-cloud"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: imds-nginx-conf
  namespace: $NS
data:
  nginx.conf: |
    events {}
    http {
      server {
        listen 80;

        # AWS IMDS v1 paths
        location /latest/meta-data/ {
          return 200 "ami-id\nhostname\niam/\ninstance-id\ninstance-type\nlocal-ipv4\npublic-ipv4\n";
          add_header Content-Type text/plain;
        }
        location /latest/meta-data/instance-id {
          return 200 "i-0abc123def456789";
          add_header Content-Type text/plain;
        }
        location /latest/meta-data/instance-type {
          return 200 "m5.large";
          add_header Content-Type text/plain;
        }
        location /latest/meta-data/iam/ {
          return 200 "info\nsecurity-credentials/\n";
          add_header Content-Type text/plain;
        }
        location /latest/meta-data/iam/security-credentials/ {
          return 200 "eks-node-role";
          add_header Content-Type text/plain;
        }
        location /latest/meta-data/iam/security-credentials/eks-node-role {
          return 200 '{"Code":"Success","Type":"AWS-HMAC","AccessKeyId":"ASIAXXXXXXXXXXX","SecretAccessKey":"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY","Token":"AQoXnyc4lcK4W9JD5//////////wEaoAK...IMDS_CRED_TOKEN","Expiration":"2024-01-15T08:00:00Z"}';
          add_header Content-Type application/json;
        }
        location /latest/meta-data/iam/info {
          return 200 '{"Code":"Success","LastUpdated":"2024-01-15T00:00:00Z","InstanceProfileArn":"arn:aws:iam::123456789012:instance-profile/eks-node-role","InstanceProfileId":"AIPAXXXXXXXXXXX"}';
          add_header Content-Type application/json;
        }
        location /latest/user-data {
          return 200 "#!/bin/bash\nset -ex\n/etc/eks/bootstrap.sh production-cluster";
          add_header Content-Type text/plain;
        }
        location / { return 404 "Not found"; }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fake-imds
  namespace: $NS
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
        - name: conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
      volumes:
      - name: conf
        configMap:
          name: imds-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: fake-imds
  namespace: $NS
spec:
  selector:
    app: fake-imds
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
  namespace: $NS
  labels:
    app: app
spec:
  containers:
  - name: app
    image: curlimages/curl:8.10.1
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "Cloud IAM lab ready. Namespace: $NS"
echo ""
echo "IMDS exercises (run from inside app-pod):"
echo "  kubectl exec app-pod -n $NS -- sh"
echo ""
echo "  # List IAM roles available:"
echo "  curl -s http://fake-imds/latest/meta-data/iam/security-credentials/"
echo ""
echo "  # Steal the IAM credentials:"
echo "  curl -s http://fake-imds/latest/meta-data/iam/security-credentials/eks-node-role"
echo ""
echo "  # Enumerate instance metadata:"
echo "  curl -s http://fake-imds/latest/meta-data/"
echo ""
echo "Defense: Create a NetworkPolicy blocking egress to 169.254.169.254/32"
