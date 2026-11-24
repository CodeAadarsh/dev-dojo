#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-spiffe"

echo "==> Setting up: SPIFFE/SPIRE Attestation"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Generate a self-signed cert with a SPIFFE SAN that embeds the flag
# We use openssl via a Job to generate the cert inside the cluster
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-generator
  namespace: dojo-sec-spiffe
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cert-generator-role
  namespace: dojo-sec-spiffe
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "patch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-generator-rb
  namespace: dojo-sec-spiffe
subjects:
- kind: ServiceAccount
  name: cert-generator
  namespace: dojo-sec-spiffe
roleRef:
  kind: Role
  name: cert-generator-role
  apiGroup: rbac.authorization.k8s.io
EOF

# Job that generates a cert with SPIFFE SAN containing the flag
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: spiffe-cert-generator
  namespace: dojo-sec-spiffe
spec:
  template:
    spec:
      serviceAccountName: cert-generator
      restartPolicy: OnFailure
      containers:
      - name: generator
        image: alpine/openssl:3.1
        command: [sh, -c]
        args:
        - |
          set -e
          # Generate CA key and cert
          openssl genrsa -out /tmp/ca.key 2048 2>/dev/null
          openssl req -new -x509 -key /tmp/ca.key -out /tmp/ca.crt \
            -days 1 -subj "/CN=SPIRE CA/O=dojo-cluster.local" 2>/dev/null

          # Generate workload key
          openssl genrsa -out /tmp/workload.key 2048 2>/dev/null

          # Create a CSR with SPIFFE SAN containing the flag path
          cat > /tmp/san.cnf << 'SANCNF'
          [req]
          req_extensions = v3_req
          distinguished_name = req_distinguished_name
          [req_distinguished_name]
          [v3_req]
          subjectAltName = URI:spiffe://dojo-cluster.local/ns/dojo-sec-spiffe/sa/KUBE_spiffe_svid_proves_workload_id
          SANCNF

          openssl req -new -key /tmp/workload.key \
            -out /tmp/workload.csr \
            -subj "/CN=workload/O=dojo-sec-spiffe" \
            -config /tmp/san.cnf 2>/dev/null

          # Sign with CA, include the SAN
          openssl x509 -req -in /tmp/workload.csr \
            -CA /tmp/ca.crt -CAkey /tmp/ca.key -CAcreateserial \
            -out /tmp/workload.crt -days 1 \
            -extensions v3_req -extfile /tmp/san.cnf 2>/dev/null

          # Store as secret
          CERT_B64=$(base64 < /tmp/workload.crt | tr -d '\n')
          KEY_B64=$(base64 < /tmp/workload.key | tr -d '\n')
          CA_B64=$(base64 < /tmp/ca.crt | tr -d '\n')

          kubectl create secret generic workload-svid \
            -n dojo-sec-spiffe \
            --from-literal=svid.crt="$(cat /tmp/workload.crt)" \
            --from-literal=svid.key="$(cat /tmp/workload.key)" \
            --from-literal=bundle.crt="$(cat /tmp/ca.crt)" \
            --from-literal=spiffe-id="spiffe://dojo-cluster.local/ns/dojo-sec-spiffe/sa/KUBE_spiffe_svid_proves_workload_id" \
            --dry-run=client -o yaml | kubectl apply -f -

          echo "SVID generated and stored in secret workload-svid"
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: spiffe-reference
  namespace: dojo-sec-spiffe
data:
  how-to-decode: |
    # The SVID (certificate) is stored in secret workload-svid
    # Field: svid.crt

    # Step 1: Extract the certificate
    kubectl get secret workload-svid -n dojo-sec-spiffe \
      -o jsonpath='{.data.svid\.crt}' | base64 -d > /tmp/svid.crt

    # Step 2: Parse the certificate and find the SPIFFE SAN
    openssl x509 -in /tmp/svid.crt -noout -text | grep -A1 "Subject Alternative Name"

    # The SPIFFE ID looks like:
    # URI:spiffe://dojo-cluster.local/ns/dojo-sec-spiffe/sa/<service-name>
    # The flag is the <service-name> with underscores replaced by hyphens:
    # KUBE{spiffe_svid_proves_workload_id}

    # Step 3: Or read the pre-decoded spiffe-id field directly
    kubectl get secret workload-svid -n dojo-sec-spiffe \
      -o jsonpath='{.data.spiffe-id}' | base64 -d
EOF

echo ""
echo "==> Setup complete. Job generating the SVID..."
echo ""
echo "    Wait 30s for the cert generator job to complete, then:"
echo "    kubectl get secret workload-svid -n $NAMESPACE"
echo "    kubectl get secret workload-svid -n $NAMESPACE -o jsonpath='{.data.spiffe-id}' | base64 -d"
