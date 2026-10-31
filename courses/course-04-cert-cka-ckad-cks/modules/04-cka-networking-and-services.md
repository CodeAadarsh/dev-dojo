# CKA: Services & Networking

> **Module 04 · Course 04** — Networking is ~20% of the CKA and the single most common place people lose time. The exam doesn't ask you to *explain* kube-proxy; it asks you to make traffic reach a pod and to fix it when it doesn't. This module is drill-oriented.

## The model in one picture

```
client ──▶ Service (stable VIP) ──▶ Endpoints (ready pod IPs) ──▶ Pod
                 ▲ selector matches pod labels      ▲ gated by readinessProbe
Ingress ──▶ Service ──▶ ...     (L7 HTTP routing in front of Services)
```

Two rules decide almost every exam networking task:
1. A **Service routes to pods whose labels match its `selector`** — nothing else.
2. A pod only becomes an **Endpoint** when it is **Ready** (readiness probe passing, or no probe).

## Service types (know when to use each)

| Type | Reaches pods via | Use for |
|------|------------------|---------|
| ClusterIP (default) | in-cluster VIP | internal service-to-service |
| NodePort | `<nodeIP>:30000-32767` | exposing without a LB (labs, on-prem) |
| LoadBalancer | external LB (cloud) / MetalLB | internet-facing in cloud |
| Headless (`clusterIP: None`) | DNS returns pod IPs directly | StatefulSets, client-side LB |
| ExternalName | CNAME to external DNS | aliasing an external service |

Imperative generators (exam speed):

```bash
kubectl expose deploy web --port=80 --target-port=8080            # ClusterIP
kubectl expose deploy web --port=80 --type=NodePort
kubectl create ingress web --rule="demo.local/*=web:80"
```

## DNS you must have memorized

```
<service>.<namespace>.svc.cluster.local          # a Service
<pod-ip-dashed>.<namespace>.pod.cluster.local     # a Pod
```

From a pod, `web` resolves in the same namespace; `web.other-ns` crosses namespaces. CoreDNS runs in `kube-system`.

## Ingress

An **Ingress resource** is just routing rules; it does nothing without an **Ingress controller** running (install on kind: `bash labs/bootstrap/install-ingress.sh`, reachable at `http://localhost:8080`). Exam tasks: create an Ingress with a host/path rule pointing at a Service, often with `pathType: Prefix`.

## NetworkPolicy (also CKS)

Default is **allow-all**. A policy that selects a pod flips that pod to **deny** for the direction(s) named, then whitelists. Classic default-deny-ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: app }
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

> kind's default CNI (kindnet) does **not enforce** NetworkPolicy. For real enforcement, recreate the cluster with Calico. The exam cluster *does* enforce.

## Debugging networking

| Symptom | Likely cause | Diagnose |
|---------|--------------|----------|
| Service works but no traffic | selector ≠ pod labels | `kubectl get endpoints <svc>` → empty? |
| Endpoints empty | pods not Ready, or wrong `targetPort` | `kubectl describe svc`, check readiness |
| DNS name won't resolve | wrong namespace, CoreDNS down, `ndots` | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| Ingress 404 | no controller, wrong host/path/pathType | `kubectl get ingress`, controller logs |
| Ingress 503 | backend Service has no endpoints | check the Service first |

The one command that resolves most of it:

```bash
kubectl get endpoints <service>     # empty = your selector/labels/readiness is wrong
kubectl run t --rm -it --image=nicolaka/netshoot -- bash   # curl/dig from inside the cluster
```

> **War story:** a "down" service with healthy-looking pods. `kubectl get endpoints` showed zero backends. The Deployment's pods were labelled `app: api` but someone had edited the Service selector to `app: api-v2` during a rename. Thirty seconds with `get endpoints` versus an hour of staring at pod logs.

## Checkpoint

1. Expose a Deployment as ClusterIP and NodePort imperatively.
2. From `get endpoints`, explain why a Service has no backends and fix it.
3. Write the FQDN of a Service in another namespace.
4. Create an Ingress rule and say what else must be running for it to work.
5. Write a default-deny-ingress NetworkPolicy and name the CNI caveat on kind.

➡ Next: **CKA: Storage** — PV/PVC binding and why your pod is stuck Pending.
