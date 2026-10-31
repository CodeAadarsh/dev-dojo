#!/usr/bin/env bash
# Installs metrics-server (needed for `kubectl top` and HPA). On kind the
# kubelet serving certs are self-signed, so metrics-server must be told to
# skip TLS verification — otherwise it sits NotReady forever.
set -euo pipefail

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "Patching metrics-server for kind (--kubelet-insecure-tls)…"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s
echo "✓ metrics-server ready. Give it ~30s to collect, then: kubectl top nodes && kubectl top pods -A"
