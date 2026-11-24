#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-registry"

echo "==> Setting up challenge: Registry Boss"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Instructions ConfigMap
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-instructions
  namespace: dojo-docker-registry
data:
  username: "dojo"
  password: "docker-master"
  hint: |
    1. Generate htpasswd: docker run --rm httpd:2.4 htpasswd -Bbn dojo docker-master > /tmp/htpasswd
    2. Create Secret: kubectl create secret generic registry-auth --from-file=htpasswd=/tmp/htpasswd -n dojo-docker-registry --dry-run=client -o yaml | kubectl apply -f -
    3. Deploy registry:2.8.3 Deployment with the auth env vars + volume mount for the secret
    4. Create a ClusterIP Service registry-svc on port 5000
    5. Port-forward and docker push an image
    6. Create docker-registry imagePullSecrets
    7. Deploy registry-consumer pod using your image
    8. Annotate the registry Deployment: dojo.docker/registry-verified=true
EOF

echo ""
echo "==> Namespace dojo-docker-registry is ready."
echo ""
echo "    Auth credentials: username=dojo  password=docker-master"
echo ""
echo "    Steps:"
echo "      1. Generate htpasswd file"
echo "      2. Create Secret 'registry-auth' from the htpasswd file"
echo "      3. Deploy registry:2.8.3 Deployment named 'registry' with auth"
echo "      4. Create ClusterIP Service 'registry-svc' on port 5000"
echo "      5. Port-forward and push an image"
echo "      6. Create imagePullSecrets"
echo "      7. Deploy Pod 'registry-consumer' that pulls from your registry"
echo "      8. Annotate: kubectl annotate deployment registry dojo.docker/registry-verified=true -n dojo-docker-registry"
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/15-registry-boss/verify.sh"
