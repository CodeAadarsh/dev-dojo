# SPIFFE/SPIRE Attestation — Solution

## Approach

The flag is embedded in the SPIFFE ID of the workload's X.509 SVID (certificate), stored in the `workload-svid` Secret.

---

## Steps

### Step 1: Check the cert generator job completed

```bash
kubectl get job spiffe-cert-generator -n dojo-sec-spiffe
# Should show: COMPLETIONS 1/1
```

### Step 2: Get the SPIFFE ID directly from the secret field

```bash
kubectl get secret workload-svid -n dojo-sec-spiffe \
  -o jsonpath='{.data.spiffe-id}' | base64 -d
```

Output:
```
spiffe://dojo-cluster.local/ns/dojo-sec-spiffe/sa/KUBE_spiffe_svid_proves_workload_id
```

The service account name is `KUBE_spiffe_svid_proves_workload_id`. Translate to flag format: `KUBE{spiffe_svid_proves_workload_id}`.

**Flag:** `KUBE{spiffe_svid_proves_workload_id}`

---

### Alternative: Decode the X.509 Certificate Directly

```bash
# Extract the cert PEM
kubectl get secret workload-svid -n dojo-sec-spiffe \
  -o jsonpath='{.data.svid\.crt}' | base64 -d > /tmp/svid.crt

# Parse it and find the SPIFFE SAN
openssl x509 -in /tmp/svid.crt -noout -text | grep "URI:"
```

Output:
```
URI:spiffe://dojo-cluster.local/ns/dojo-sec-spiffe/sa/KUBE_spiffe_svid_proves_workload_id
```

---

## Understanding SPIFFE in Production

### SPIRE Architecture

```
┌─────────────────── Kubernetes Cluster ─────────────────────┐
│                                                              │
│  ┌────────────────┐           ┌────────────────────────┐   │
│  │  SPIRE Server  │           │  Pod A                  │   │
│  │  (StatefulSet) │           │  ┌──────────────────┐   │   │
│  │                │           │  │  Workload         │   │   │
│  │  - Trust bundle│◄──────────│  │  SVID: 1h TTL     │   │   │
│  │  - Issue SVIDs │  attest   │  │  spiffe://id/a    │   │   │
│  │  - Rotate certs│           │  └──────────────────┘   │   │
│  └───────▲────────┘           └────────────────────────┘   │
│          │                                                    │
│  ┌───────┴────────┐           ┌────────────────────────┐   │
│  │  SPIRE Agent   │           │  Pod B                  │   │
│  │  (DaemonSet)   │           │  ┌──────────────────┐   │   │
│  │                │           │  │  Workload         │   │   │
│  │  - K8s node    │           │  │  SVID: 1h TTL     │   │   │
│  │    attestation │           │  │  spiffe://id/b    │   │   │
│  │  - Pod workload│           │  └──────────────────┘   │   │
│  │    attestation │           └────────────────────────┘   │
│  └────────────────┘                                          │
└──────────────────────────────────────────────────────────────┘
```

### How Service A authenticates to Service B

1. Service A presents its SVID (X.509 cert) in a mTLS handshake
2. Service B validates: cert signed by SPIRE CA, SPIFFE ID matches expected caller
3. No IP-based trust, no network-level assumptions

### Istio + SPIFFE

Istio's service mesh uses SPIFFE identities under the hood. Every sidecar gets an SVID from Istio's internal CA (Citadel/istiod). mTLS between all pods is automatic. `AuthorizationPolicy` rules can reference `principals` using SPIFFE IDs:

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: payments-access
spec:
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/frontend/sa/checkout-api"
        # Only the checkout-api service can call payments
```
