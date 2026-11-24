#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-supply"

echo "==> Setting up: Supply Chain Inject"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# SBOM v1.2.3 — clean build
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sbom-v1-2-3
  namespace: dojo-sec-supply
  annotations:
    dojo.challenge/image: "company/webapp:v1.2.3"
    dojo.challenge/note: "Clean SBOM — no injected packages"
data:
  alpine-3.19.1: "source=alpine-linux,license=MIT,hash=sha256:abc123"
  curl-8.5.0-r0: "source=alpine-linux,license=MIT,hash=sha256:def456"
  libssl3-3.1.4-r5: "source=alpine-linux,license=OpenSSL,hash=sha256:ghi789"
  ca-certificates-20240226-r0: "source=alpine-linux,license=MPL-2.0,hash=sha256:jkl012"
  nodejs-20.11.0-r0: "source=alpine-linux,license=MIT,hash=sha256:mno345"
  npm-10.2.4-r0: "source=alpine-linux,license=MIT,hash=sha256:pqr678"
  python3-3.11.9-r0: "source=alpine-linux,license=PSF,hash=sha256:stu901"
  musl-1.2.4-r4: "source=alpine-linux,license=MIT,hash=sha256:vwx234"
EOF

# SBOM v1.2.4 — tampered build with injected package
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sbom-v1-2-4
  namespace: dojo-sec-supply
  annotations:
    dojo.challenge/image: "company/webapp:v1.2.4"
    dojo.challenge/note: "TAMPERED — contains an injected package"
data:
  alpine-3.19.1: "source=alpine-linux,license=MIT,hash=sha256:abc123"
  curl-8.5.0-r0: "source=alpine-linux,license=MIT,hash=sha256:def456"
  libssl3-3.1.4-r5: "source=alpine-linux,license=OpenSSL,hash=sha256:ghi789"
  ca-certificates-20240226-r0: "source=alpine-linux,license=MPL-2.0,hash=sha256:jkl012"
  nodejs-20.11.0-r0: "source=alpine-linux,license=MIT,hash=sha256:mno345"
  npm-10.2.4-r0: "source=alpine-linux,license=MIT,hash=sha256:pqr678"
  python3-3.11.9-r0: "source=alpine-linux,license=PSF,hash=sha256:stu901"
  musl-1.2.4-r4: "source=alpine-linux,license=MIT,hash=sha256:vwx234"
  audit-logger-1.2.3: "KUBE{sbom_diff_reveals_injected_package}"
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: investigation-notes
  namespace: dojo-sec-supply
data:
  method: |
    To find the injected package:
    1. List all keys in sbom-v1-2-3
    2. List all keys in sbom-v1-2-4
    3. The key that's in v1.2.4 but NOT in v1.2.3 is the injected package
    4. Its value is the flag

    With kubectl:
    kubectl get configmap sbom-v1-2-3 -n dojo-sec-supply -o jsonpath='{.data}' | tr ',' '\n' | grep -o '"[^"]*":'
    kubectl get configmap sbom-v1-2-4 -n dojo-sec-supply -o jsonpath='{.data}' | tr ',' '\n' | grep -o '"[^"]*":'
  note: |
    The package name 'audit-logger-1.2.3' should raise red flags:
    - Not from alpine-linux (the base image)
    - Unusual name that mimics a legitimate-sounding package
    - Was NOT in the previous build's SBOM
    Real attackers inject packages that sound legitimate: 'util-lib', 'crypto-helper', etc.
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Read SBOMs and find the difference:"
echo "    kubectl get configmap sbom-v1-2-3 -n $NAMESPACE -o jsonpath='{.data}'"
echo "    kubectl get configmap sbom-v1-2-4 -n $NAMESPACE -o jsonpath='{.data}'"
echo ""
echo "    The flag is the VALUE of the injected package's key in sbom-v1-2-4"
