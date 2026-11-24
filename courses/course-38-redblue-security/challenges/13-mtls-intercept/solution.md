# Solution — mTLS Intercept

## The Problem

Plaintext east-west traffic inside a cluster is a real attack surface. If an attacker can exec into any pod in the same namespace (or on the same node with network access), they can intercept HTTP traffic — tokens, passwords, session data.

mTLS solves two problems at once:
1. **Encryption**: traffic is TLS-encrypted, intercept = ciphertext
2. **Mutual authentication**: both client and server present certificates — a rogue `interceptor` pod can't participate even if it can reach the socket

## Solution A — Istio PeerAuthentication (Recommended)

If the cluster has Istio installed (check: `kubectl get pods -n istio-system`):

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

`STRICT` mode means: Istio's Envoy sidecar requires a valid mTLS handshake before forwarding any traffic. The interceptor pod would need a valid SPIFFE identity signed by Istio's trust domain to participate.

Annotate and create ConfigMap:
```bash
kubectl annotate deployment frontend backend \
  dojo.mtls/status=mtls-enforced \
  -n dojo-sec-mtls --overwrite

kubectl create configmap mtls-config \
  -n dojo-sec-mtls \
  --from-literal=method=istio-peer-authentication \
  --from-literal=mode=STRICT
```

## Solution B — cert-manager + nginx mTLS (No Service Mesh)

```bash
# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.0/cert-manager.yaml

# 2. Create a self-signed CA
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: dojo-ca
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dojo-mtls-ca
  namespace: dojo-sec-mtls
spec:
  isCA: true
  commonName: dojo-mtls-ca
  secretName: dojo-mtls-ca-secret
  issuerRef:
    name: dojo-ca
    kind: ClusterIssuer
EOF

# 3. Issue a certificate for backend
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: backend-cert
  namespace: dojo-sec-mtls
spec:
  secretName: backend-tls
  commonName: backend-svc.dojo-sec-mtls.svc.cluster.local
  dnsNames:
  - backend-svc.dojo-sec-mtls.svc.cluster.local
  issuerRef:
    name: dojo-mtls-ca
    kind: Issuer
EOF
```

Then configure nginx in backend to use `ssl_verify_client on` with the CA cert. (More complex than Istio — prefer service mesh for production.)

## Verify mTLS is Working (Istio)

```bash
# From frontend pod — this should work (fronted has a valid SPIFFE identity)
kubectl exec -n dojo-sec-mtls deploy/frontend -- \
  curl -s http://backend-svc/

# From the interceptor pod — this should fail if mTLS STRICT is enforced
# (interceptor has no Istio sidecar by default, so it uses plain TCP)
kubectl exec -n dojo-sec-mtls interceptor -- \
  curl -s http://backend-svc/
# → connection reset / upstream connect error
```

**Flag:** `KUBE{mtls_encrypts_the_lateral_path}`

## Why mTLS Beats Network Policies Alone

NetworkPolicies block TCP connections at the IP level. But they don't prevent an authorized pod (e.g., one the attacker compromised) from intercepting traffic.

mTLS provides **cryptographic identity** — a pod without a valid certificate (signed by the cluster CA) can't complete the TLS handshake, regardless of its IP address. Combined with NetworkPolicies, this is defense in depth:

- NetworkPolicy: IP-level controls who can connect
- mTLS: TLS-level controls that the connecting party is who it claims to be
