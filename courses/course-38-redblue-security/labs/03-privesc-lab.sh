#!/usr/bin/env bash
# Module 03 — Privilege Escalation Lab
# Creates a privileged pod and a pod with hostPath: / for escalation exercises
set -euo pipefail

NS="dojo-lab-privesc"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: $NS
  labels:
    app: privesc
    type: privileged
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      privileged: true
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  restartPolicy: Always
---
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-pod
  namespace: $NS
  labels:
    app: privesc
    type: hostpath
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    volumeMounts:
    - name: host-root
      mountPath: /host
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  volumes:
  - name: host-root
    hostPath:
      path: /
  restartPolicy: Always
---
apiVersion: v1
kind: Pod
metadata:
  name: capabilities-pod
  namespace: $NS
  labels:
    app: privesc
    type: capabilities
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      capabilities:
        add:
        - SYS_ADMIN
        - NET_ADMIN
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  restartPolicy: Always
EOF

echo "Privilege escalation lab ready. Namespace: $NS"
echo ""
echo "Exercises:"
echo "  1. kubectl exec privileged-pod -n $NS -- id  (should be root)"
echo "  2. kubectl exec hostpath-pod -n $NS -- ls /host/etc  (host filesystem)"
echo "  3. kubectl exec hostpath-pod -n $NS -- chroot /host id  (host root)"
echo "  4. kubectl exec capabilities-pod -n $NS -- capsh --print  (extra caps)"
echo "  5. kubectl exec hostpath-pod -n $NS -- cat /host/etc/kubernetes/admin.conf  (kubelet creds)"
