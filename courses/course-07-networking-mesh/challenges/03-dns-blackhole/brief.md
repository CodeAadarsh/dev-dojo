# DNS Resolves, Endpoints Don't Lie

An engineer pushes a hotfix at 02:00. The deployment goes green. Dashboards go red. Health checks start timing out, but `nslookup api-svc.dojo-dns` returns an IP. "DNS is fine!" they say. "The service is broken!" you say. Who is right?

Both of you — and neither of you. **DNS resolves the ClusterIP of the Service. The ClusterIP is just a virtual IP rule in iptables/eBPF. If the Service has no Endpoints, kube-proxy never writes a real destination and every connection hangs silently.**

This is the most common Kubernetes "why is DNS not working" bug report, and the answer is almost never DNS.

## Scenario

The setup script deploys:
- A `backend` pod in `dojo-dns` (running nginx on port 80, labelled `app=backend,version=v2`).
- A Service `api-svc` that has a **deliberate mismatch**: it selects `app=backend,version=v1` and targets port `8080` instead of `80`.

The result: `nslookup api-svc` returns an IP, but `curl http://api-svc` hangs forever.

## Mission

1. **Diagnose** the root cause using only `kubectl` and a throwaway netshoot pod (no SSH to nodes).
2. **Fix** the Service so its selector matches the actual pod labels and its `targetPort` matches the container port.
3. Confirm the Service now has non-empty Endpoints.

The verifier checks that `api-svc` in `dojo-dns` has at least one ready endpoint.

## Debugging guide

```bash
# Step 1 — check endpoints first, not DNS
kubectl -n dojo-dns get endpoints api-svc
# -> NAME      ENDPOINTS   AGE
# -> api-svc   <none>      ...  ← the smoking gun

# Step 2 — what labels does the pod actually have?
kubectl -n dojo-dns get pods --show-labels

# Step 3 — what selector does the Service use?
kubectl -n dojo-dns get svc api-svc -o yaml | grep -A5 selector

# Step 4 — launch a netshoot pod to confirm the hang
kubectl run -n dojo-dns --rm -it netshoot --image=nicolaka/netshoot:v0.13 -- \
  curl -m 3 http://api-svc
# -> curl: (28) Connection timed out  ← confirms endpoint is missing, not DNS
```

## Target state (what verify.sh checks)

The Service `api-svc` in `dojo-dns` must have at least one ready endpoint (non-empty `ENDPOINTS` column).

Fix the Service's `spec.selector` and/or `spec.ports[].targetPort` to match the pod that is actually running.
