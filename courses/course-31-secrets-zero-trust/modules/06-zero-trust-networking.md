# Zero-Trust Networking

> **Module 06 · Course 31** — "The network is trusted" is an assumption that makes every other security control weaker. This module replaces IP-location trust with identity-based authorization and shows you how to apply it incrementally — from Kubernetes NetworkPolicy through service-mesh mTLS and authz policies, all the way to the BeyondCorp model.

The implicit assumption baked into most traditional architectures: traffic inside the VPC is safe. A service binding on `0.0.0.0` inside the cluster expects only legitimate callers. This assumption fails the moment any workload is compromised, any lateral movement succeeds, or any attacker reaches an internal IP — which cloud-native architectures make easier, not harder.

---

## Never trust, always verify

The zero-trust axiom: **grant access based on who the requester is and what they need, not where they are.** IP address is a property of location; location is increasingly meaningless in a world of cloud, containers, and NAT.

The concrete transition:

```
Before (perimeter model)
  Internet → [Firewall] → Internal network (trusted)
               └── everything inside can talk to everything else

After (zero-trust)
  Every connection is authenticated + authorized regardless of source IP
               └── a compromised pod inside the cluster cannot reach payments/ by default
```

This is not a destination — it's a direction. Most teams implement it layer by layer:

1. **Layer 3/4 — NetworkPolicy:** deny by default; allow only declared paths.
2. **Layer 7 — service-mesh mTLS:** authenticate the workload identity; make authz policies talk about SPIFFE IDs, not IPs.
3. **Access tier — BeyondCorp/ZTNA:** extend the same model to human access, removing the VPN entirely.

---

## Default-deny and microsegmentation with NetworkPolicy

Kubernetes allows all pod-to-pod traffic by default. A `default-deny` NetworkPolicy is the starting point:

```yaml
# applies to all pods in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-payments
spec:
  podSelector: {}          # matches ALL pods
  policyTypes:
  - Ingress
  - Egress
```

With this in place, **nothing talks to anything** in `dojo-payments` until you explicitly allow it. You then add targeted allow rules:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-to-api
  namespace: dojo-payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: gateway
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: dojo-gateway
    ports:
    - protocol: TCP
      port: 8443
```

### What NetworkPolicy cannot do

NetworkPolicy is Layer 3/4 — it knows source pods and ports. It cannot:

- Distinguish HTTP `GET /read` from `POST /admin` on the same port.
- Authenticate that the source pod's *process* is actually `gateway` and not malware injected after deployment.
- Apply rules to traffic leaving the cluster (needs an egress proxy or cloud-level VPC rule).
- Enforce if your CNI plugin doesn't implement NetworkPolicy (check: `kubectl get networkpolicies -A` should not return `"no resources found"` when you're running Cilium/Calico/kindnet with NetworkPolicy enabled).

> **Verify your CNI supports NetworkPolicy** — `kindnet` (default) only supports simple NetworkPolicy from kind 0.19+. For full Layer 7, install Cilium:
> ```bash
> helm install cilium cilium/cilium --version 1.16.0 \
>   --namespace kube-system --set nodeinit.enabled=true
> ```

---

## The east-west blind spot

"East-west" traffic is pod-to-pod, service-to-service inside the cluster. It is the *largest* attack surface and the least-often audited.

```
North-south: Internet → Ingress → your pods   (visible, logged)
East-west:   pod-A    → pod-B    (invisible by default, not logged, not authenticated)
```

After a lateral movement from a compromised `frontend` pod, an attacker can call any service that doesn't enforce mTLS. The services that don't are usually the ones that "shouldn't be reachable" — which was never actually enforced.

To find your current east-west exposure:

```bash
# list NetworkPolicies per namespace
kubectl get networkpolicies -A

# for a namespace without a default-deny policy, all pods are reachable:
kubectl get networkpolicies -n <namespace> --no-headers | grep "default-deny" || \
  echo "WARNING: no default-deny in <namespace>"

# audit: which namespaces have zero NetworkPolicies?
for ns in $(kubectl get ns -o name | sed 's|namespace/||'); do
  count=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
  [ "$count" -eq 0 ] && echo "NO POLICY: $ns"
done
```

---

## Service-mesh mTLS and authorization policies

A service mesh (Istio, Linkerd, Cilium) injects a sidecar proxy into each pod. The sidecar intercepts all traffic and enforces mTLS transparently — the application doesn't change; the proxy negotiates the cert handshake.

### Istio: enabling strict mTLS cluster-wide

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # cluster-wide when in root namespace
spec:
  mtls:
    mode: STRICT
```

In `STRICT` mode, any pod without a sidecar (or with an invalid cert) cannot reach mesh services at all. This is the enforcement that makes a SPIFFE ID meaningful at the network layer.

### Authorization by identity, not IP

With mTLS established, you know the caller's SPIFFE ID. Your AuthorizationPolicy names it:

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: payments-api-authz
  namespace: dojo-payments
spec:
  selector:
    matchLabels:
      app: payments-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/dojo-gateway/sa/envoy-gateway"
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/charge", "/api/v1/refund"]
```

This policy says: only `envoy-gateway` in namespace `dojo-gateway` can POST to those two paths. Every other caller — even from inside the cluster — gets a 403. The `principals` field maps directly to the SPIFFE ID's path component.

### Linkerd: simpler, lower overhead

Linkerd's authorization model is lighter. You use `AuthorizationPolicy` + `MeshTLSAuthentication`:

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: payments-callers
  namespace: dojo-payments
spec:
  identities:
  - "envoy-gateway.dojo-gateway.serviceaccount.identity.linkerd.cluster.local"
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: payments-api-allow
  namespace: dojo-payments
spec:
  targetRef:
    group: core
    kind: Service
    name: payments-api
  requiredAuthenticationRefs:
  - name: payments-callers
    kind: MeshTLSAuthentication
```

---

## The BeyondCorp model

BeyondCorp (Google, 2014) extended zero-trust to *human access*: no VPN; every request to every internal application is authenticated by identity and checked against a policy. The VPN perimeter disappears.

The architecture:

```
User device (managed/unmanaged) → Identity-Aware Proxy
                                       ↓
                            authenticate user (SSO/MFA)
                            check device posture
                            evaluate access policy
                                       ↓
                             allow/deny specific app
```

On Kubernetes, this maps to:

- **Identity-Aware Proxy (IAP):** GCP Cloud IAP, AWS Verified Access, or Pomerium in front of internal Ingresses.
- **Device posture:** integration with your MDM (Jamf, Intune) — the IAP checks whether the device is managed and patched before allowing access.
- **Per-application policies:** instead of "you're on VPN therefore you can reach everything," it's "you authenticated, your device is managed, your group has `payments-admin` role → allowed to this specific service."

The Kubernetes-native lever for BeyondCorp-style human access is annotating Ingresses to require authentication:

```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-url: "https://auth.example.com/oauth2/auth"
  nginx.ingress.kubernetes.io/auth-signin: "https://auth.example.com/oauth2/start"
```

Or using Pomerium as the auth proxy in front of internal services, replacing `kubectl port-forward` with a policy-enforced connection.

---

## Debugging Zero-Trust Networking

Debugging zero-trust failures is harder than debugging connectivity failures because the error often looks like the connection succeeded at Layer 4 but was rejected at Layer 7 with a 403 — or the connection is completely silent (no RST, no ICMP unreachable) because the CNI dropped it.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod can reach a service it shouldn't after you added `default-deny` | CNI plugin doesn't enforce NetworkPolicy (e.g. kindnet on older kind, or Flannel) | Check with `kubectl get daemonset -n kube-system` for `cilium` or `calico`; switch CNI if absent |
| Service B can be called from pod A even after `STRICT` mTLS | Sidecar injection not enabled in that namespace (`istio-injection=enabled` label missing) | `kubectl label namespace dojo-payments istio-injection=enabled`; restart pods |
| 403 from a service-mesh AuthorizationPolicy you thought was allow-all | Implicit deny: an AuthorizationPolicy exists → all traffic not explicitly matched is denied | Add a catch-all `ALLOW` or audit which `AuthorizationPolicy` objects exist in the namespace |
| mTLS connection `peer certificate is expired` in mesh logs | Cert rotation gap: sidecar cert (from Citadel/CA) expired while pod was isolated from the mesh CA | `istioctl proxy-status`; check `istio-proxy` logs for `DEGRADED`; restart the sidecar |
| `NetworkPolicy` allows port 443 but traffic is still dropped | Over-broad `egress` deny; the `dnsPort: 53 UDP` egress is also blocked, so DNS fails before TLS | Add an explicit `egress` rule allowing port 53 UDP to `kube-dns`; DNS is always the victim |
| East-west traffic works fine from a debug pod that bypasses the mesh | The debug pod has no sidecar; mTLS in `STRICT` mode only blocks injected sidecars from calling each other; a bare pod is outside the mesh | Expected behavior in STRICT mode — add sidecar to debug pod, or use `istioctl experimental describe pod` |

### The exact debugging sequence for an implicit-deny 403

```bash
# 1. find which AuthorizationPolicy is matching (or not matching) the request
istioctl authz check pod/<pod-name>.<namespace>

# 2. look at the envoy access log for the source pod
kubectl -n dojo-gateway logs deploy/envoy-gateway -c istio-proxy | \
  grep -E '"403"|"RBAC: access denied"' | tail -20

# 3. compare the principal in the log against the policy
# access log line: [principal=spiffe://cluster.local/ns/X/sa/Y]
kubectl -n dojo-payments get authorizationpolicy -o yaml | grep principal

# 4. verify the destination pod has a valid cert
istioctl proxy-status | grep <pod-name>

# 5. for NetworkPolicy drops (silent, no error):
kubectl run netcheck --rm -it --image=nicolaka/netshoot \
  --overrides='{"spec":{"serviceAccountName":"gateway"}}' \
  -n dojo-gateway -- curl -v http://payments-api.dojo-payments:8443/health
# if it hangs after SYN → NetworkPolicy is dropping at CNI
```

> **War story.** A staging environment had been running without incidents for a month. When we added `PeerAuthentication` with `STRICT` mTLS, the load balancer health-checks started failing intermittently. The health-check came from the cloud load balancer — an external IP — which, by definition, has no sidecar and no SPIFFE ID. `STRICT` mode caused the mesh to reject the plain-TCP health check because it didn't present a client cert. The fix was a `PeerAuthentication` scoped to the health-check path with `mode: DISABLE`, or switching the health-check to use a mesh-internal probe pod. The lesson: zero-trust is incompatible with "the network is a trusted channel" assumptions — and load-balancer health-checks are the most common hidden assumption. Audit every external probe before enabling `STRICT`.

---

## Checkpoint

You're ready for the challenges when you can:

1. State what "default-deny" means at the NetworkPolicy layer and write the four-line `podSelector: {}` YAML from memory.
2. Explain, in one sentence, why IP-based ACLs break when pods move nodes, and what property of mTLS fixes this.
3. Identify two things a Kubernetes NetworkPolicy cannot enforce that a service-mesh authorization policy can.
4. Find every namespace in your cluster that has no NetworkPolicy with a one-liner `for` loop over `kubectl get ns`.
5. Explain what happens to traffic in an Istio mesh namespace where `PeerAuthentication` is `STRICT` but sidecar injection was never enabled — and how you'd diagnose it.
6. Write an Istio `AuthorizationPolicy` that allows only `POST` requests from a specific service account to two specific paths, and name the exact field that maps to a SPIFFE ID.
7. Describe the east-west blind spot: why it exists, why it's larger than the north-south surface, and what the cheapest first fix is.

➡ Next up: **Operational Secrets Hygiene** — rotation, leak detection, audit trails, and incident response for the moment a secret escapes.
