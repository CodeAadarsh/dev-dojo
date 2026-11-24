# Zero Trust with SPIFFE/SPIRE — Cryptographic Workload Identity

> **Module 07 · Course 38** — "Trust the network" is the old model. Zero Trust says: trust nothing by default, verify everything cryptographically. This module covers SPIFFE (the standard), SPIRE (the implementation), and how they replace IP-based trust with short-lived X.509 certificates that prove workload identity.

---

## The Problem: IP-Based Trust Is Broken

In the previous modules you saw that:
- NetworkPolicy can restrict which pods can reach which pods
- But a compromised pod inside a "trusted" IP range bypasses all of that
- Backend services that say "if the caller's IP is in 10.0.0.0/8, trust it" are trivially fooled by any compromised pod in the cluster

What we need is **cryptographic proof of identity** — not "where did this request come from?" but "can you prove WHO you are?"

```
Old model (network trust):
  Frontend pod → Backend service
  "I'll accept requests from any pod in the frontend subnet"
  Problem: ANY pod in that subnet passes, including compromised ones

Zero trust model (cryptographic identity):
  Frontend pod → (presents X.509 cert) → Backend service
  "I'll accept requests from pods that can prove they are the
   frontend ServiceAccount in the production namespace"
  Problem solved: stolen IP or compromised pod can't forge the cert
```

---

## SPIFFE: The Standard

SPIFFE (Secure Production Identity Framework For Everyone) is an open standard for workload identity. It defines two things:

### 1. The SPIFFE ID — A URI That Names a Workload

```
spiffe://trust-domain/path/to/workload

Examples:
spiffe://production.example.com/ns/frontend/sa/web-server
spiffe://staging.example.com/ns/backend/sa/api-service
spiffe://cluster1.internal/k8s-workload/production/api-server
```

The trust domain is your org's identifier. The path encodes the workload's namespace and ServiceAccount.

### 2. The SVID — An X.509 Certificate Encoding the SPIFFE ID

```
X.509 SVID (SPIFFE Verifiable Identity Document):
  Subject:        CN=api-server
  SubjectAltName: URI:spiffe://production.example.com/ns/backend/sa/api-server
  Issuer:         SPIRE Intermediate CA
  ValidFrom:      2024-01-15 10:00:00
  ValidTo:        2024-01-15 11:00:00   ← 1 hour validity!
  KeyUsage:       digitalSignature, keyEncipherment
```

The critical property: **SVIDs are short-lived** (typically 1 hour). This means:
- Compromised credentials expire quickly
- No need for certificate revocation (let them expire)
- Automatic rotation by the SPIRE agent

---

## SPIRE: The Implementation

SPIRE (SPIFFE Runtime Environment) has two components:

```
                    SPIRE Server
                    ─────────────
                    ┌───────────────────────────────────┐
                    │  - Stores workload registry entries │
                    │  - Issues SVIDs to attested agents  │
                    │  - Has its own CA (or delegates to  │
                    │    Vault PKI)                       │
                    └────────────────┬──────────────────┘
                                     │
                     ┌───────────────┼───────────────┐
                     │               │               │
                  Node 1          Node 2          Node 3
                  ──────          ──────          ──────
              SPIRE Agent     SPIRE Agent     SPIRE Agent
              ───────────     ───────────     ───────────
              ┌─────────┐     ┌─────────┐     ┌─────────┐
              │Workload │     │Workload │     │Workload │
              │  API    │     │  API    │     │  API    │
              └────┬────┘     └────┬────┘     └────┬────┘
                   │               │               │
              ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
              │Pod A    │    │Pod B    │    │Pod C    │
              │frontend │    │backend  │    │database │
              └─────────┘    └─────────┘    └─────────┘
```

### Node Attestation

Before a SPIRE Agent can get SVIDs for pods, it must prove it is running on a legitimate Kubernetes node. It does this via node attestation:

```
SPIRE Agent on Node 1:
  "I am running on this K8s node. Here's proof:"
  → Presents the node's kubelet-signed certificate
  → Or AWS instance identity document (for AWS)
  → Or GCP instance identity token (for GCP)

SPIRE Server:
  Validates the proof (checks signature against K8s CA)
  Issues a node SVID: spiffe://prod/spire/agent/k8s_psat/cluster1/node1
```

### Workload Attestation

Once the agent has a node SVID, pods can request SVIDs from it:

```
Pod (via Workload API, Unix socket):
  "I need a SVID. I am the frontend pod."

SPIRE Agent:
  Looks at the caller's PID
  Checks /proc/PID/ for cgroup membership
  Maps cgroup → pod UID → K8s ServiceAccount
  Checks workload registry: "frontend SA in production ns gets this SPIFFE ID"
  Issues SVID: spiffe://prod/ns/production/sa/frontend
```

```bash
# Install SPIRE in a kind cluster:
kubectl apply -f https://github.com/spiffe/spire/releases/download/v1.9.0/spire.yaml

# Wait for SPIRE server and agents to start:
kubectl wait --for=condition=ready pod \
  -l app=spire-server -n spire --timeout=120s
kubectl wait --for=condition=ready pod \
  -l app=spire-agent -n spire --timeout=120s

# Register a workload entry:
kubectl exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://production.example.com/ns/production/sa/api-server \
  -parentID spiffe://production.example.com/spire/agent/k8s_psat/cluster1 \
  -selector k8s:ns:production \
  -selector k8s:sa:api-server \
  -ttl 3600

# Check registered entries:
kubectl exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server entry show
```

---

## mTLS: Mutual TLS Using SVIDs

Once pods have SVIDs, they use them for mutual TLS. mTLS is different from regular TLS:

```
Regular TLS:
  Client → Server
  Server proves identity to client (server cert)
  Client is anonymous

mTLS:
  Client ←→ Server
  Server proves identity to client (server cert)
  Client proves identity to server (client cert)
  BOTH sides are authenticated
```

```
frontend pod                              backend pod
(SVID: spiffe://prod/ns/prod/sa/frontend) (SVID: spiffe://prod/ns/prod/sa/backend)
         │                                         │
         │  TLS handshake                          │
         ├──────────────────────────────────────► │
         │  "Here's my SVID cert (client cert)"    │
         │ ◄──────────────────────────────────────┤
         │  "Here's MY SVID cert (server cert)"    │
         │                                         │
Both sides verify:
  - Cert is signed by SPIRE intermediate CA
  - SPIFFE ID in the cert matches the expected workload
  - Cert is not expired (hourly rotation catches compromised pods fast)
```

```go
// Go application using SPIFFE SDK for mTLS (simplified):
source, err := workloadapi.NewX509Source(ctx)
// source gives you auto-rotating SVID + trusted bundle

tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeID(
    spiffeid.RequireIDFromString("spiffe://prod/ns/prod/sa/backend"),
))
// Now any HTTP client using this config will:
// 1. Present the frontend SVID as the client cert
// 2. Only accept servers with the backend's SPIFFE ID
```

---

## Istio / Cilium Integration

You don't need to modify application code if you use a service mesh that handles SPIFFE/mTLS automatically:

### Istio + SPIFFE

Istio's control plane (Istiod) is SPIFFE-compatible. Each Envoy sidecar gets a SVID and uses it for mTLS between all pods automatically:

```bash
# Enable mTLS in a namespace (strict mode):
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT     # All traffic in this namespace must use mTLS
EOF

# AuthorizationPolicy: only allow frontend to reach backend:
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: backend-allow-only-frontend
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/production/sa/frontend"
        # ^ This is a SPIFFE ID without the spiffe:// prefix
        # Only the frontend ServiceAccount can reach the backend
EOF
```

### Cilium + SPIFFE

Cilium's eBPF-based network can enforce SPIFFE identity at the network layer without sidecars:

```yaml
# CiliumNetworkPolicy using SPIFFE identity:
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-spiffe-policy
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    # Cilium + SPIRE validates the SPIFFE SVID at the network level
```

---

## Why SPIFFE Defeats Lateral Movement

Revisit Module 04's lateral movement chain with SPIFFE in place:

```
Compromised frontend pod
  Has SVID: spiffe://prod/ns/production/sa/frontend
         │
         │  Tries to reach backend service
         │  Presents frontend SVID as client cert
         ▼
Backend service (mTLS STRICT mode):
  "Your SPIFFE ID is spiffe://prod/ns/production/sa/frontend"
  "My AuthorizationPolicy says I only accept
   spiffe://prod/ns/production/sa/api-server"
  → 403 RBAC_DENIED
         │
         ▼
Attacker's lateral movement STOPS HERE
Even though the pods are on the same network,
the backend refuses the connection because the
identity doesn't match.
```

The stolen SA token still allows API server calls. But service-to-service calls now require a valid, unexpired SVID that the attacker cannot forge (they don't have the SPIRE private key).

---

## SPIFFE + Vault

SPIRE integrates with HashiCorp Vault to use Vault as the SVID-signing CA:

```bash
# Configure Vault as SPIRE's upstream CA:
kubectl exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server bundle show -format spiffe
# → Shows the trust bundle (root cert)

# SPIRE config (server.conf) pointing to Vault:
# UpstreamAuthority "vault" {
#   vault_addr = "https://vault.vault.svc.cluster.local:8200"
#   pki_mount_point = "pki_spire"
#   cert_role = "spire-server"
#   token_auth {
#     token = "${VAULT_TOKEN}"
#   }
# }
```

This means SVIDs are ultimately signed by Vault's CA, giving you centralized certificate management + SPIFFE's workload attestation.

---

## Checkpoint

You're ready for Module 08 when you can answer:

1. What is the SPIFFE URI format, and what do each of the three parts mean?
2. What is an SVID and why is its short validity period (1 hour) a security feature rather than an inconvenience?
3. What is node attestation and why does SPIRE require it before issuing pod SVIDs?
4. How is mTLS different from regular TLS? What additional guarantee does it provide?
5. If a backend service uses STRICT mTLS with an AuthorizationPolicy requiring a specific SPIFFE ID, can a compromised pod with a different SVID connect? Why not?
6. What is workload attestation? How does SPIRE know which SPIFFE ID to give a specific pod?
7. How does Istio's `PeerAuthentication: STRICT` relate to SPIFFE SVIDs?
8. What happens to traffic if the SPIRE server goes down but the agent already has cached SVIDs?
9. Why doesn't SPIFFE need certificate revocation lists (CRLs)?
10. What is the difference between SPIFFE (the standard) and SPIRE (the implementation)?

➡ Next: **Secrets Management with Vault** — dynamic credentials, PKI, and the Vault agent sidecar pattern.
