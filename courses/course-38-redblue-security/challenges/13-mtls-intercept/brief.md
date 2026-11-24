# Challenge 13 — mTLS Intercept

**Difficulty:** Hard | **Type:** Verifier | **Est. Time:** 60 min

---

## Situation

Service `frontend` is talking to service `backend` over **plaintext HTTP**. No encryption. No mutual authentication.

You placed a rogue pod `interceptor` on the same network. You can read the traffic.

The `intercept-proof` ConfigMap shows what the interceptor captured — real credentials, tokens, plaintext request bodies.

Your job: enforce **mutual TLS (mTLS)** between frontend and backend so the same attack is impossible. Both sides must present certificates and verify each other.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/13-mtls-intercept/setup.sh
```

---

## Your Goal

1. Enforce mTLS between `frontend` and `backend` in namespace `dojo-sec-mtls`
2. Annotate both Deployments as mTLS-enforced:
   ```bash
   kubectl annotate deployment frontend backend \
     dojo.mtls/status=mtls-enforced \
     -n dojo-sec-mtls
   ```
3. Create a ConfigMap `mtls-config` documenting your approach:
   ```bash
   kubectl create configmap mtls-config \
     -n dojo-sec-mtls \
     --from-literal=method=istio-peer-authentication \
     --from-literal=mode=STRICT
   ```

---

## Verifier

```bash
bash courses/course-38-redblue-security/challenges/13-mtls-intercept/verify.sh
```

---

## Approaches

**Option A — Istio** (if the cluster has Istio):
```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: enforce-mtls
  namespace: dojo-sec-mtls
spec:
  mtls:
    mode: STRICT
EOF
```

**Option B — Cert-manager + manual sidecar** (no service mesh):
Create a CA using cert-manager, issue certificates for both services, configure nginx sidecars to require client certificates.

**Option C — Cilium** (if the cluster uses Cilium CNI):
```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: mtls-required
  namespace: dojo-sec-mtls
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingressDeny:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    authentication:
      mode: "required"
EOF
```

---

## What You'll Learn

- Why plaintext east-west traffic is a lateral movement enabler
- mTLS: not just encryption, but mutual authentication (both sides prove identity)
- Service mesh PeerAuthentication vs CNI-level enforcement
- Zero trust networking: never trust, always verify — even inside the cluster
