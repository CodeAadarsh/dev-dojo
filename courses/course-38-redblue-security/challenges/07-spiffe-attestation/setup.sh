#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-spiffe"

echo "==> Setting up: SPIFFE Attestation"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy SPIRE using official quickstart manifests
# SPIRE Server
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: dojo-sec-spiffe
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-server-role
rules:
- apiGroups: [""]
  resources: [nodes, pods]
  verbs: [get, list, watch]
- apiGroups: [authentication.k8s.io]
  resources: [tokenreviews]
  verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-server-binding
subjects:
- kind: ServiceAccount
  name: spire-server
  namespace: dojo-sec-spiffe
roleRef:
  kind: ClusterRole
  name: spire-server-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server-conf
  namespace: dojo-sec-spiffe
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "cluster.local"
      data_dir = "/run/spire/data"
      log_level = "INFO"
      ca_ttl = "24h"
      default_svid_ttl = "1h"
    }
    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }
      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "kube-dojo" = {
              service_account_whitelist = ["dojo-sec-spiffe:spire-agent"]
              kube_config_file = ""
              use_token_review_api_validation = true
            }
          }
        }
      }
      KeyManager "memory" {
        plugin_data {}
      }
      Notifier "k8sbundle" {
        plugin_data {
          namespace = "dojo-sec-spiffe"
        }
      }
    }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: dojo-sec-spiffe
  labels:
    app: spire-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spire-server
  serviceName: spire-server
  template:
    metadata:
      labels:
        app: spire-server
    spec:
      serviceAccountName: spire-server
      shareProcessNamespace: true
      containers:
      - name: spire-server
        image: ghcr.io/spiffe/spire-server:1.9.6
        args: ["-config", "/run/spire/config/server.conf"]
        ports:
        - containerPort: 8081
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-data
          mountPath: /run/spire/data
      volumes:
      - name: spire-config
        configMap:
          name: spire-server-conf
      - name: spire-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: dojo-sec-spiffe
spec:
  selector:
    app: spire-server
  ports:
  - name: grpc
    port: 8081
    targetPort: 8081
EOF

# Target workload SA and pod
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spiffe-sa
  namespace: dojo-sec-spiffe
---
apiVersion: v1
kind: Pod
metadata:
  name: spiffe-workload
  namespace: dojo-sec-spiffe
  labels:
    app: spiffe-workload
spec:
  serviceAccountName: spiffe-sa
  containers:
  - name: workload
    image: busybox
    command: [sleep, "3600"]
EOF

echo "[*] Waiting for SPIRE server..."
kubectl wait --for=condition=Ready pod -l app=spire-server -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
  echo "[!] SPIRE server may still be starting..."

# Plant the flag in a ConfigMap (revealed by verify.sh)
FLAG_B64=$(printf '%s' 'KUBE{spiffe_svid_proves_workload_identity}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spiffe-reward
  namespace: $NAMESPACE
data:
  flag_b64: $FLAG_B64
  hint: "Register the workload entry in SPIRE, then run verify.sh"
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    SPIRE server: kubectl get pod -n $NAMESPACE -l app=spire-server"
echo "    Register workload: see brief.md for the spire-server entry create command"
echo "    Then run: bash verify.sh"
