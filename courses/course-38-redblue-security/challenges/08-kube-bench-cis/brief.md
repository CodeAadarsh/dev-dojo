# kube-bench CIS Hardening

You've heard about CIS Kubernetes Benchmarks but you've never actually run them against a live cluster. This challenge makes you do it properly.

kube-bench checks your cluster against the CIS Kubernetes Benchmark — the gold standard for K8s security configuration. It tests 100+ controls across the API server, etcd, kubelet, and node configuration.

In this challenge:
1. Run kube-bench against the cluster
2. Read its output from a ConfigMap
3. The verifier checks specific test IDs that should PASS on a kind cluster

## What kube-bench Tests

kube-bench organizes checks into sections:
- **1.x** — Control Plane components (API server, controller manager, scheduler)
- **2.x** — etcd
- **3.x** — Control Plane configuration
- **4.x** — Worker Nodes (kubelet)
- **5.x** — Kubernetes Policies (RBAC, pod security, network policies)

Each check: `[PASS]`, `[FAIL]`, `[WARN]`, or `[INFO]`.

## Mission

1. The setup job has already run kube-bench and stored the output
2. Read the results: `kubectl get configmap kube-bench-results -n dojo-sec-cis -o jsonpath='{.data.output}'`
3. Find which checks PASS and which FAIL
4. Understand the remediation for the FAIL checks
5. Run the verifier to confirm specific basic checks pass

## Rules of Engagement

- Namespace: `dojo-sec-cis`
- Results ConfigMap: `kube-bench-results`
- Checklist ConfigMap: `cis-checklist` (shows which checks you need to understand)
- Run the verifier: `bash verify.sh`
- Note: some checks always fail in kind clusters (they require production-only features) — that's expected

## Why This Matters

The CIS Benchmark is what auditors and compliance frameworks (SOC2, ISO 27001, PCI-DSS) reference when checking Kubernetes security posture. Passing Level 1 is the minimum bar for production clusters handling sensitive data.
