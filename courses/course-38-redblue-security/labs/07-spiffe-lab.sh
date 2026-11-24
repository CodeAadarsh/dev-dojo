#!/usr/bin/env bash
# Module 07 — Zero Trust with SPIFFE/SPIRE Lab
# Deploys SPIRE quickstart (server + agent) and two workload pods
set -euo pipefail

NS="dojo-lab-spiffe"
SPIRE_NS="spire"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$SPIRE_NS" --dry-run=client -o yaml | kubectl apply -f -

# SPIRE Server
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: $SPIRE_NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-server-cluster-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-server-cluster-role-binding
subjects:
- kind: ServiceAccount
  name: spire-server
  namespace: $SPIRE_NS
roleRef:
  kind: ClusterRole
  name: spire-server-cluster-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: $SPIRE_NS
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "dojo.example.org"
      data_dir = "/run/spire/data"
      log_level = "INFO"
      ca_subject {
        country = ["IN"]
        organization = ["DOJO"]
        common_name = ""
      }
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
            "dojo-cluster" = {
              service_account_allow_list = ["spire:spire-agent"]
            }
          }
        }
      }
      KeyManager "memory" { plugin_data {} }
    }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: $SPIRE_NS
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
      containers:
      - name: spire-server
        image: ghcr.io/spiffe/spire-server:1.9.6
        args: ["-config", "/run/spire/config/server.conf"]
        resources:
          limits:
            cpu: "200m"
            memory: "256Mi"
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-data
          mountPath: /run/spire/data
      volumes:
      - name: spire-config
        configMap:
          name: spire-server
  volumeClaimTemplates:
  - metadata:
      name: spire-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: $SPIRE_NS
spec:
  selector:
    app: spire-server
  ports:
  - name: grpc
    port: 8081
    targetPort: 8081
EOF

# Two workload pods ready for SVID registration
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-a
  namespace: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-b
  namespace: $NS
---
apiVersion: v1
kind: Pod
metadata:
  name: workload-a
  namespace: $NS
  labels:
    app: workload-a
spec:
  serviceAccountName: workload-a
  containers:
  - name: app
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
---
apiVersion: v1
kind: Pod
metadata:
  name: workload-b
  namespace: $NS
  labels:
    app: workload-b
spec:
  serviceAccountName: workload-b
  containers:
  - name: app
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "SPIFFE/SPIRE lab ready."
echo "SPIRE Server: $SPIRE_NS | Workload pods: $NS"
echo ""
echo "Next steps:"
echo "  1. Wait for SPIRE server: kubectl rollout status statefulset/spire-server -n $SPIRE_NS"
echo "  2. Register workload entries via SPIRE CLI"
echo "  3. Use SPIFFE SVIDs for mTLS between workload-a and workload-b"
echo ""
echo "Register workload-a:"
echo "  kubectl exec spire-server-0 -n $SPIRE_NS -- bin/spire-server entry create \\"
echo "    -spiffeID spiffe://dojo.example.org/workload-a \\"
echo "    -parentID spiffe://dojo.example.org/agent \\"
echo "    -selector k8s:ns:$NS \\"
echo "    -selector k8s:sa:workload-a"
