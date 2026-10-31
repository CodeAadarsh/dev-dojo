# Solution — Default Deny, Then Allow

## The manifests

```yaml
# netpol-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dojo-np
spec:
  podSelector: {}           # empty = matches ALL pods in the namespace
  policyTypes:
    - Ingress               # only block ingress; egress is still open
  # no ingress rules = deny all ingress
---
# netpol-allow.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: dojo-np
spec:
  podSelector:
    matchLabels:
      role: backend         # this policy guards pods labelled role=backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend  # only pods labelled role=frontend may initiate
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f netpol-deny.yaml -f netpol-allow.yaml
bash courses/course-07-networking-mesh/challenges/02-default-deny-then-allow/verify.sh
```

## Prove it works (with Calico)

After applying, confirm the `client` (role=client) is blocked:

```bash
CLIENT=$(kubectl -n dojo-np get pod -l role=client -o jsonpath='{.items[0].metadata.name}')
kubectl -n dojo-np exec "$CLIENT" -- wget -qO- --timeout=3 http://backend-svc
# -> wget: download timed out  (blocked by default-deny)
```

Relabel the client to `role=frontend` and confirm it is now allowed:

```bash
kubectl -n dojo-np label pod "$CLIENT" role=frontend --overwrite
kubectl -n dojo-np exec "$CLIENT" -- wget -qO- --timeout=3 http://backend-svc
# -> <!DOCTYPE html>...  (allowed by allow-frontend-to-backend)
```

## Why each piece matters

**`podSelector: {}`** is the secret syntax. An empty pod selector matches *every* pod in the namespace, not no pods. This is the opposite of what you might expect. Put this in a NetworkPolicy with no `ingress:` rules and you've denied all ingress to the whole namespace in one object.

**Policy types matter.** If you omit `policyTypes`, Kubernetes infers the types from the rules you write: a policy with only ingress rules implies `policyTypes: [Ingress]`. Explicitly declaring it is clearer and avoids surprises on update.

**`from.podSelector` vs `namespaceSelector`.** When the allow policy's `from` lists only a `podSelector`, it matches pods *in the same namespace* with that label. To allow cross-namespace traffic you need a `namespaceSelector` (and ideally both together, as an AND: same object `from:` entry). Putting them in separate entries is an OR.

**CNI enforcement.** NetworkPolicy objects are API server resources — the CNI plugin decides whether to enforce them. Without Calico, Cilium, or another policy-aware CNI, your policies are stored in etcd but never translated into iptables/eBPF rules. This is a common cluster misconfiguration to check during a security review.

## Hardening preview

- Add `policyTypes: [Ingress, Egress]` to the default-deny if you also want to block outbound (e.g., prevent DNS exfiltration). Add a separate allow for port 53 UDP to kube-dns if you do.
- Consider `namespaceSelector` with a namespace label to allow a monitoring namespace to scrape metrics from every namespace without modifying each namespace's policies.
- Cilium's `CiliumNetworkPolicy` / `CiliumClusterwideNetworkPolicy` extends this model to L7 (HTTP method/path) and DNS-based egress filtering — the next level after mastering L4 NetworkPolicy.
