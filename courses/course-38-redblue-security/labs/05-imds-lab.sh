#!/usr/bin/env bash
# Lab 05: Cloud IAM & IMDS — simulated IMDS endpoint using a mock server
set -euo pipefail

NAMESPACE="dojo-sec-imds"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NAMESPACE" -f - <<'EOF'
# Mock IMDS server — returns fake AWS-style credentials
apiVersion: v1
kind: ConfigMap
metadata:
  name: imds-mock-data
  namespace: dojo-sec-imds
data:
  # Fake IAM role response
  iam-role: |
    eks-node-group-role
  # Fake credentials response
  credentials: |
    {
      "Code": "Success",
      "LastUpdated": "2024-01-15T10:30:00Z",
      "Type": "AWS-HMAC",
      "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
      "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "Token": "AQoDYXdzEJr//////////wEaoAKL...",
      "Expiration": "2024-01-15T16:30:00Z"
    }
---
# Mock IMDS server pod (uses Python to simulate 169.254.169.254)
apiVersion: v1
kind: Pod
metadata:
  name: imds-mock-server
  namespace: dojo-sec-imds
  labels:
    app: imds-mock
spec:
  containers:
  - name: mock
    image: python:3.11-alpine
    command:
    - python3
    - -c
    - |
      from http.server import HTTPServer, BaseHTTPRequestHandler
      import json

      class IMDS(BaseHTTPRequestHandler):
          def log_message(self, fmt, *args): pass
          def do_GET(self):
              self.send_response(200)
              self.send_header('Content-Type', 'application/json')
              self.end_headers()
              if 'security-credentials' in self.path and not self.path.endswith('/'):
                  role = self.path.split('/')[-1]
                  self.wfile.write(json.dumps({
                    "Code": "Success",
                    "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
                    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                    "Token": "AQoDYXdzEJr_FAKE_TOKEN_FOR_LAB",
                    "Expiration": "2099-01-15T16:30:00Z"
                  }).encode())
              elif 'security-credentials' in self.path:
                  self.wfile.write(b'eks-node-group-role')
              else:
                  self.wfile.write(json.dumps({"message": "IMDS mock server"}).encode())

      HTTPServer(('0.0.0.0', 8080), IMDS).serve_forever()
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: imds-mock-svc
  namespace: dojo-sec-imds
spec:
  selector:
    app: imds-mock
  ports:
  - port: 80
    targetPort: 8080
---
# Attacker foothold — can reach the mock IMDS service
apiVersion: v1
kind: Pod
metadata:
  name: foothold
  namespace: dojo-sec-imds
spec:
  containers:
  - name: shell
    image: alpine:3.20
    command: [sleep, "86400"]
    env:
    - name: MOCK_IMDS_HOST
      value: "imds-mock-svc.dojo-sec-imds.svc.cluster.local"
EOF

kubectl wait --for=condition=ready pod/imds-mock-server -n "$NAMESPACE" --timeout=90s
kubectl wait --for=condition=ready pod/foothold -n "$NAMESPACE" --timeout=90s

echo ""
echo "IMDS lab ready."
echo "Entry: kubectl exec -n $NAMESPACE foothold -it -- sh"
echo "Goal:  curl http://\$MOCK_IMDS_HOST/latest/meta-data/iam/security-credentials/"
echo "Note:  In a real cluster, this would be 169.254.169.254"
echo "       The mock server simulates AWS IMDSv1 responses"
