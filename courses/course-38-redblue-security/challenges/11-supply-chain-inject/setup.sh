#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-supplychain"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Building dojo/app-clean:1.0 ..."
CLEAN_DIR=$(mktemp -d)
cat > "$CLEAN_DIR/package.json" <<'PKGJSON'
{
  "name": "app",
  "version": "1.0.0",
  "dependencies": {
    "express": "^4.21.0"
  }
}
PKGJSON
cat > "$CLEAN_DIR/Dockerfile" <<'DOCKERFILE'
FROM node:20-slim
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY . .
CMD ["node", "-e", "require('http').createServer((req,res)=>res.end('ok')).listen(3000)"]
DOCKERFILE
docker build -t dojo/app-clean:1.0 "$CLEAN_DIR" -q
rm -rf "$CLEAN_DIR"

echo "Building dojo/app-infected:1.1 ..."
INFECTED_DIR=$(mktemp -d)
cat > "$INFECTED_DIR/package.json" <<'PKGJSON'
{
  "name": "app",
  "version": "1.1.0",
  "dependencies": {
    "express": "^4.21.0",
    "lodash-dev-proxy": "^1.0.0"
  }
}
PKGJSON
cat > "$INFECTED_DIR/Dockerfile" <<'DOCKERFILE'
FROM node:20-slim
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --ignore-scripts || true
COPY . .
CMD ["node", "-e", "require('http').createServer((req,res)=>res.end('ok')).listen(3000)"]
DOCKERFILE
docker build -t dojo/app-infected:1.1 "$INFECTED_DIR" -q
rm -rf "$INFECTED_DIR"

# Deploy the infected version
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: $NAMESPACE
  labels:
    app: web
    dojo.challenge: "11-supply-chain-inject"
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
        image: dojo/app-infected:1.1
        imagePullPolicy: Never
        ports:
        - containerPort: 3000
        resources:
          limits:
            cpu: "200m"
            memory: "128Mi"
EOF

# Task instructions ConfigMap
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: sbom-task
  namespace: $NAMESPACE
data:
  task: |
    1. Generate SBOMs: syft dojo/app-clean:1.0 -o spdx-json > clean.json && syft dojo/app-infected:1.1 -o spdx-json > infected.json
    2. Find the extra package in infected.json
    3. kubectl create configmap sbom-diff-result -n dojo-sec-supplychain --from-literal=malicious_package=<package-name>
    4. kubectl set image deployment/app web=dojo/app-clean:1.0 -n dojo-sec-supplychain
    5. kubectl annotate namespace dojo-sec-supplychain dojo.supply-chain/status=remediated
  attack_vector: "Dependency confusion / package injection — attackers publish a malicious package with a name that shadows an internal one, or inject it into a compromised registry."
EOF

# Mark namespace as compromised initially
kubectl annotate namespace "$NAMESPACE" dojo.supply-chain/status=compromised --overwrite

echo ""
echo "Setup complete. Namespace: $NAMESPACE"
echo "Two images built: dojo/app-clean:1.0 and dojo/app-infected:1.1"
echo "The infected image has an extra package injected."
echo ""
echo "Tools needed: syft (brew install syft)"
echo "Start: syft dojo/app-clean:1.0 -o spdx-json > clean.json"
