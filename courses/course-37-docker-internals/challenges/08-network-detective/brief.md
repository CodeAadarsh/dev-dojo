# Network Detective

The `frontend` pod in `dojo-docker-network` has been failing to reach the `backend` service for 20 minutes. Users are seeing 502 errors. The backend pods are Running. The frontend pod is Running. The Service exists.

Something is wrong with the network wiring. Your job is to find it and fix it.

## Mission

Fix the network configuration so that the Service `backend-svc` correctly routes traffic to the `backend` pods. The verifier checks:

1. Service `backend-svc` has the correct selector (`app=backend`)
2. The Service has at least one endpoint (a backend pod IP is listed)
3. The `frontend` pod is Running

## Why This Happens: Services, Selectors, and Endpoints

A Kubernetes Service does not directly connect to pods. It has a **selector** — a label query. kube-proxy watches for pods matching that selector and builds an **Endpoints** object (a list of pod IPs and ports). iptables rules (or eBPF on modern clusters) route traffic from the Service ClusterIP to those pod IPs.

```
Client → Service ClusterIP
         │
         ├── [Selector: app=backend]
         │
         └── Endpoints: [10.244.0.5:80, 10.244.0.6:80]
                              │
                     iptables DNAT rule
                              │
                       backend pod
```

If the selector doesn't match any pod labels, the Endpoints object is empty. All traffic to the Service ClusterIP goes nowhere — connection refused.

## The Diagnostic Pattern

```bash
# Step 1: check if endpoints are populated
kubectl get endpoints backend-svc -n dojo-docker-network
# NAME          ENDPOINTS   AGE
# backend-svc   <none>      5m    ← empty = selector mismatch

# Step 2: compare selector to pod labels
kubectl get service backend-svc -n dojo-docker-network -o jsonpath='{.spec.selector}'
kubectl get pods -n dojo-docker-network --show-labels
```

## Setup

```bash
bash courses/course-37-docker-internals/challenges/08-network-detective/setup.sh
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/08-network-detective/verify.sh
```
