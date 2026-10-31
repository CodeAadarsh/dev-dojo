# Solution — DNS Resolves, Endpoints Don't Lie

## Diagnosis

The fast path to root cause:

```bash
kubectl -n dojo-dns get endpoints api-svc
# NAME      ENDPOINTS   AGE
# api-svc   <none>      ...   ← empty = no matching pods
```

Empty endpoints means the Service selector matches zero pods. Find the real labels:

```bash
kubectl -n dojo-dns get pods --show-labels
# NAME            READY   LABELS
# backend-xxx     1/1     app=backend,version=v2,...

kubectl -n dojo-dns get svc api-svc -o jsonpath='{.spec.selector}' ; echo
# {"app":"backend","version":"v1"}   ← mismatch: v1 vs v2
```

The second bug — targetPort:

```bash
kubectl -n dojo-dns get svc api-svc -o jsonpath='{.spec.ports[0].targetPort}' ; echo
# 8080   ← nginx listens on 80, not 8080
```

## Fix

Patch both fields:

```bash
kubectl -n dojo-dns patch svc api-svc --type=merge -p \
  '{"spec":{"selector":{"app":"backend","version":"v2"},"ports":[{"name":"http","port":80,"targetPort":80}]}}'
```

Or apply a corrected manifest:

```yaml
# api-svc-fixed.yaml
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: dojo-dns
spec:
  selector:
    app: backend
    version: v2          # matches the running pod
  ports:
    - name: http
      port: 80
      targetPort: 80     # matches the containerPort
```

```bash
kubectl apply -f api-svc-fixed.yaml
kubectl -n dojo-dns get endpoints api-svc
# api-svc   10.244.x.x:80   ...  ← now populated
bash courses/course-07-networking-mesh/challenges/03-dns-blackhole/verify.sh
```

## Why DNS is almost never the problem

When `nslookup <service>` returns an IP, DNS is working. The ClusterIP it returns is a virtual address — no real socket is bound to it. kube-proxy (or eBPF) translates it to a real pod IP only when there are Endpoints. No Endpoints = kube-proxy writes no DNAT rules = every connection to that IP silently hangs or resets.

The diagnostic order for "my service is unreachable":

1. `kubectl get endpoints <svc>` — if `<none>`, stop here, the rest is irrelevant.
2. Check the selector vs. pod labels: `kubectl get pods --show-labels` + `kubectl get svc -o yaml | grep -A5 selector`.
3. Check the port: `targetPort` must match the actual `containerPort`, not the Service `port`.
4. Only once Endpoints are non-empty: test DNS resolution and L7 routing.

## Attacker's view

A Service with `<none>` endpoints is invisible to traffic but still occupies the ClusterIP space. An attacker who can create or modify a Service could redirect traffic away from a real backend by changing its selector — a silent man-in-the-middle within the cluster's virtual network, no NetworkPolicy required. RBAC on Service objects matters.
