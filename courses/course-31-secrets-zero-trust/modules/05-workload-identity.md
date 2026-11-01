# Workload Identity & mTLS

> **Module 05 · Course 31** — Passwords for services are as broken as passwords for humans. A credential stored in a Secret is a secret that can be copied, exfiltrated, or forgotten in a git history. This module dismantles the long-lived-cred model and replaces it with identity: a workload proves *what it is* using a cryptographic assertion that expires in minutes, not years.

You already know Kubernetes Secrets are base64-not-encrypted. The deeper problem is that a static DB password or API key has no expiry and no binding to a specific workload — if it leaks, it works forever and from anywhere. The answer is workload identity: give each service a short-lived, cryptographically verifiable identity instead of a password.

---

## The no-long-lived-credentials principle

A long-lived credential has three failure modes that a workload identity eliminates:

| Problem | Long-lived cred | Short-lived identity |
|---------|-----------------|----------------------|
| Leaked to git | Valid until manually rotated (often: forever) | Expires in minutes; revocation is already baked in |
| Stolen from a running pod | Usable from anywhere by anyone | Bound to the workload's SVID/OIDC audience; replay fails |
| Rotated on a human schedule | Gaps of days/months; rotation often skipped | Automatic: the issuance system re-attests every TTL |

The principle: **a credential's blast radius should be proportional to the narrowness of its binding and inversely proportional to its TTL.** A cert that expires in one hour, scoped to `spiffe://prod/ns/payments/sa/gateway`, is a hundred times safer than `PGPASSWORD=hunter2` in a Secret.

---

## SPIFFE and SPIRE

**SPIFFE** (Secure Production Identity Framework For Everyone) is the standard. It defines:

- **SVID** (SPIFFE Verifiable Identity Document) — the identity assertion. In practice this is an X.509 cert or a JWT with a `sub` claim in URI form: `spiffe://<trust-domain>/<path>`.
- **Trust domain** — an administrative boundary, e.g. `spiffe://prod.example.com`. A trust domain is a root of trust; cross-domain trust requires explicit federation.
- **Workload API** — the Unix-socket gRPC API that a workload calls to receive its SVID without any credentials. Zero bootstrapping secret: the agent uses the platform (Kubernetes, AWS, etc.) to attest the workload before issuing the SVID.

**SPIRE** is the CNCF reference implementation of SPIFFE:

```
┌──────────────────────────────────────── cluster ─────────────────────────────────────────┐
│                                                                                           │
│   ┌─ SPIRE Server ──────────────────┐     ┌─ Node A ─────────────────────────────────┐  │
│   │  CA (signs SVIDs)               │     │                                          │  │
│   │  registration entries (who→what)│◄────│  SPIRE Agent (DaemonSet)                 │  │
│   │  federation config              │     │    ├── attests node → receives node cert  │  │
│   └─────────────────────────────────┘     │    └── Workload API (unix socket)         │  │
│                                           │         ▲                                 │  │
│                                           │   ┌─ payments-pod ─────────────────────┐  │  │
│                                           │   │  process calls Workload API        │  │  │
│                                           │   │  receives SVID (cert + key)        │  │  │
│                                           │   │  TTL: 1 h; auto-rotated before exp │  │  │
│                                           │   └────────────────────────────────────┘  │  │
│                                           └──────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### Attestation

Attestation is how SPIRE proves a workload is what the registration entry says. On Kubernetes, the SPIRE Agent uses the node's service account token to verify with the API server that the pod claiming `payments` identity actually *is* a pod in namespace `payments` running service account `gateway`. No human injects a bootstrap secret — the platform is the root of trust.

Registration entries map a *selector* (node selector + pod SA + namespace) to a SPIFFE ID:

```bash
spire-server entry create \
  -spiffeID spiffe://prod.example.com/ns/payments/sa/gateway \
  -parentID  spiffe://prod.example.com/spire/agent/k8s_psat/dojo-worker \
  -selector  k8s:ns:payments \
  -selector  k8s:sa:gateway \
  -ttl       3600
```

The workload calls the Workload API (via the SPIRE CSI driver or a Unix-domain socket mounted by the agent):

```python
import pyspiffe
# or: let your sidecar / service-mesh do this automatically
svid = workload_api_client.fetch_x509_svid()
# svid.leaf  -> PEM cert, valid for 1h, SAN = spiffe://prod.../payments/sa/gateway
# svid.private_key -> ephemeral private key; never stored, never logged
```

---

## Mutual TLS

Ordinary TLS is one-directional: the *client* verifies the *server's* cert. Mutual TLS (**mTLS**) means both sides present a cert and both sides verify the peer.

```
Client (SVID: spiffe://prod/ns/frontend/sa/webapp)
  │   → ClientHello
  │   ← ServerHello + Server cert (spiffe://prod/ns/backend/sa/api)
  │   → Client cert (spiffe://prod/ns/frontend/sa/webapp)
  │   ← CertificateVerify + Finished
  │   ══ mTLS session ══
```

What mTLS buys you that a network policy cannot:

- **Identity is in the cert, not the IP.** A pod can move nodes, get a new IP, or have its namespace recycled; the SVID is still `spiffe://prod/ns/payments/sa/gateway`.
- **Interception requires the private key**, which lives only in memory, expires with the cert, and is never written to disk.
- **AuthZ can use the SPIFFE ID.** Your service mesh's authorization policy says "allow requests from `spiffe://prod/ns/frontend/sa/webapp`" — not "allow from `10.0.0.0/8`".

In Istio, once mTLS is on (PeerAuthentication `STRICT`), you write authz in terms of principals:

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: payments-allow-gateway
  namespace: payments
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/gateway/sa/envoy-gateway"
```

No CIDR. No port-range allow-all. The identity is the access credential.

---

## Short-lived certs in practice

The operational concern people raise: *"If certs expire in an hour, what happens when the rotation fails?"*

The answer is: you build rotation into the workload lifecycle from day one, so a cert that is 55 minutes old is a normal operating condition, not an emergency.

```
 0m          55m    60m   65m
 │──── valid ────│rot│──── new cert ────
                  ↑
            SPIRE Agent auto-rotates before expiry
            (by default, at 50% of TTL = 30 min into a 1h cert)
```

The SPIRE agent will deliver a new cert without restarting your process — the Workload API push-notifies your process, which is why service-mesh sidecars handle rotation transparently.

Key operational invariants:

1. **Clock sync is not optional.** A 1-hour cert means NTP drift of a few minutes can cause premature rejection. Run chrony/ntpd on every node; alert on drift > 30 s.
2. **Cert TTL > cert rotation lead time.** If your TTL is 10 minutes but SPIRE Server is temporarily unreachable, the agent can't rotate in time. Size TTL to accommodate your service's restart tolerance.
3. **Don't cache the cert past its expiry.** TLS libraries that cache the peer's cert after the handshake need to be told to re-verify on reconnect.

---

## OIDC federation to cloud (IRSA & Workload Identity)

Service accounts issue OIDC tokens. Cloud providers trust those tokens if the cluster's OIDC issuer is registered with the provider. This eliminates IAM access keys in Pods entirely.

### AWS — IRSA (IAM Roles for Service Accounts)

```
Pod presents SA token → AWS STS → validates against cluster OIDC issuer → returns short-lived AWS creds
```

```bash
# annotate the service account
kubectl annotate sa payments-sa \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/PaymentsRole \
  -n payments

# IAM trust policy (only tokens from this SA in this cluster are accepted)
# {
#   "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/<oidc-url>" },
#   "Condition": {
#     "StringEquals": {
#       "<oidc-url>:sub": "system:serviceaccount:payments:payments-sa"
#     }
#   }
# }
```

The Pod never holds an `AWS_ACCESS_KEY_ID`. The AWS SDK fetches creds from the OIDC token projected into `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`, which has a TTL of 86400 s and is auto-rotated.

### GCP — Workload Identity

GCP uses the same OIDC flow but binds to a GCP service account via an IAM policy binding:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  gsa-payments@project.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:project.svc.id.goog[payments/payments-sa]"
```

---

## Kubernetes service account tokens — what changed in 1.21+

Pre-1.21: service account tokens were eternal JWTs stored as Secrets. They never expired and had no audience binding — any process in the cluster that could read the Secret could impersonate the SA forever.

Post-1.21 (bound tokens):

```yaml
volumes:
- name: kube-api-access
  projected:
    sources:
    - serviceAccountToken:
        expirationSeconds: 3600   # re-issued before expiry by kubelet
        audience: https://kubernetes.default.svc   # audience binds the token
        path: token
```

```bash
# check what your pod is actually getting
kubectl exec -n payments deploy/gateway -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['exp'], d['aud'])"
```

Old tokens have no `exp`, no `aud`. New tokens expire. If you see a token without `exp`, you're running something pre-1.20 or using the legacy token projection — fix it.

---

## Debugging Workload Identity

SVID and cert issues produce opaque TLS errors at the application layer. Work down from symptom.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `x509: certificate has expired or is not yet valid` from a 1-hour cert | Clock skew between nodes; cert just-expired before rotation succeeded | `chronyc tracking` on both nodes; check SPIRE Agent logs for rotation errors; verify NTP sync in your node's `systemd-timesyncd` |
| `x509: certificate signed by unknown authority` after cert rotation | Client cached the old trust bundle; didn't re-fetch from Workload API | Restart client, or verify the workload uses the push-notification path (not a one-time fetch) from the SPIRE Workload API |
| `spiffe: peer has trust domain prod-us, want prod-eu` | Federation between trust domains not configured; cross-region call hit wrong SPIRE Server | Add a federation entry on both SPIRE Servers; or unify to one trust domain if the split is artificial |
| SA token rejected by AWS STS: `WebIdentityErr: token audience not in the list` | Token's `aud` doesn't match the OIDC issuer URL registered in IAM | Confirm the `audience` field in the projected volume matches the cluster's OIDC issuer URL |
| IRSA creds still in pod after SA re-annotation | Cached STS creds in `~/.aws/credentials` or instance metadata override; SDK not using `WebIdentityTokenFile` | Confirm `AWS_WEB_IDENTITY_TOKEN_FILE` env var is set by the EKS admission webhook; clear cached creds |
| `registration entry not found` from SPIRE Agent | Pod selector in the entry doesn't match the actual pod labels/SA | `spire-server entry show -spiffeID <svid>`; compare selectors; re-create the entry |

### The exact debugging sequence for cert expiry

```bash
# 1. confirm the cert's validity window
kubectl exec -n dojo-payments deploy/gateway -- \
  openssl s_client -connect payments-backend:8443 </dev/null 2>/dev/null | \
  openssl x509 -noout -dates

# 2. check the SPIRE agent's rotation log on the node
kubectl -n spire logs daemonset/spire-agent | grep -E "rotation|renew|error" | tail -20

# 3. check clock skew between nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
# if nodes have drifted, you'll see rotation timestamps far in the future or past
# fix: kubectl debug node/<name> --image=busybox -it -- chronyc tracking

# 4. force a re-attest (last resort)
kubectl -n spire delete pod -l app=spire-agent --field-selector spec.nodeName=<node>
```

> **War story.** A payment service at a previous project started throwing `certificate has expired` errors at 03:14 UTC — reliably, every night, for three nights running. The cert TTL was 24 hours. The SPIRE agent was rotating at 23:59 UTC (50% of TTL = 12 hours before expiry), successfully. The bug: the *client* side was an HTTP connection pool that cached the TLS handshake indefinitely and never re-connected. The cert the client held expired at 03:14. The fix was a single `MaxConnectionAge` setting on the gRPC client — not a SPIRE problem at all. The lesson: when you get `certificate expired` on a short-lived cert, check the *consumer* of the cert (is it re-connecting?) before blaming the *issuer*.

---

## Checkpoint

You're ready for the challenges when you can:

1. Explain why a 1-hour SVID is safer than a static API key even if both are exfiltrated, and name the specific property of a short-lived cert that limits blast radius.
2. Sketch the SPIRE attestation flow: what replaces the bootstrap secret, and which two components participate on each node.
3. State the three selectors that uniquely identify a Kubernetes workload in a SPIRE registration entry.
4. Describe how IRSA eliminates `AWS_ACCESS_KEY_ID` from pods, and name the two places the cluster OIDC issuer URL must match.
5. Check whether a pod's SA token is a legacy eternal token or a bound token (the one-liner using `base64 -d` + Python).
6. Diagnose a `certificate has expired` error: the three places to look before blaming the issuer.
7. Explain, in one sentence, why mTLS authorization policies bound to SPIFFE IDs survive pod rescheduling but IP-based ACLs don't.

➡ Next up: **Zero-Trust Networking** — extending the identity-based model from individual service calls to the whole network topology, and seeing where NetworkPolicy falls short.
