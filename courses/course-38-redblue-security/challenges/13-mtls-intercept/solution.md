# mTLS Intercept — Solution

## Understanding the Setup

The backend nginx is already configured to serve TLS using `nginx-tls.conf`. The TLS cert is in secret `tls-creds`.

## Step 1: Verify TLS is Working

```bash
# From the frontend pod — ignore cert validation with -k
kubectl exec -n dojo-sec-mtls frontend -- \
  curl -sk https://backend-svc/flag
```

Output: `KUBE{mtls_encrypts_the_lateral_path}`

**Flag: `KUBE{mtls_encrypts_the_lateral_path}`**

## Step 2: Prove Plaintext Fails

```bash
# From the rogue pod — try HTTP (should fail or return TLS error)
kubectl exec -n dojo-sec-mtls rogue-pod -- \
  curl -s http://backend-svc/flag
# Returns empty or connection refused — backend only listens on HTTPS
```

## Step 3: Understand Why This Protects Against Interception

```
WITHOUT TLS:
  frontend → HTTP → backend
  Rogue pod on same node → tcpdump → sees: "GET /flag HTTP/1.1\n...KUBE{...}"

WITH TLS:
  frontend → HTTPS (TLS encrypted) → backend
  Rogue pod on same node → tcpdump → sees: "....cryptographic noise...."
  Can't decrypt without the private key
```

## Step 4: Run the Verifier

```bash
bash verify.sh
```

---

## Full mTLS (Both Sides Authenticate)

The setup here shows server-side TLS (client verifies server's cert). Full mutual TLS (mTLS) means BOTH sides present certificates:

```bash
# In a real Istio mTLS setup:
# frontend presents: spiffe://cluster.local/ns/app/sa/frontend-sa (SVID)
# backend presents:  spiffe://cluster.local/ns/app/sa/backend-sa (SVID)
# Both verified against the SPIRE trust bundle

# PeerAuthentication: STRICT means backend REJECTS any connection
# that doesn't present a valid SPIFFE SVID
```

The combination of TLS + mTLS + SPIFFE identity means:
- Traffic is encrypted (TLS)
- Caller is authenticated (mTLS SVID)
- Authorization is enforced (Istio AuthorizationPolicy checks SPIFFE ID)

A rogue pod gets none of these — it can't forge an SVID, so the backend rejects the connection entirely.
