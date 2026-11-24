# SPIFFE/SPIRE Attestation

You've heard it before: "never trust the network." But what does that actually mean for service-to-service communication inside Kubernetes? Even inside your cluster, a compromised pod could impersonate another service if authentication is based on IP addresses or namespace names alone.

SPIFFE (Secure Production Identity Framework For Everyone) and SPIRE (the reference implementation) solve this with **cryptographic workload identity**. Every pod gets a short-lived X.509 certificate bound to its identity — `spiffe://cluster.local/ns/payments/sa/payments-api`. Services verify these certificates, not network location.

## The SVID (SPIFFE Verifiable Identity Document)

```
SPIFFE ID:  spiffe://cluster.local/ns/payments/sa/payments-api
            ┌──────────────────────────────────────────────────┐
            │  X.509 certificate (SVID)                        │
            │  Subject: spiffe://cluster.local/ns/pay../sa/api │
            │  Issued by: SPIRE Intermediate CA                │
            │  Valid for: 1 hour (auto-renewed)                │
            │  Bound to: pod UID, node attestation             │
            └──────────────────────────────────────────────────┘
```

A service receiving a request validates:
1. The TLS certificate is signed by our SPIRE CA
2. The SPIFFE ID in the certificate matches the caller's expected identity
3. The certificate hasn't expired

No IP-based trust. No "if request comes from this namespace, allow it."

## Mission

1. The SPIRE agent is running as a DaemonSet in `dojo-sec-spiffe`
2. A simulated workload pod has been issued an SVID
3. Find the SVID stored in the namespace and decode the SPIFFE ID from it
4. The flag is embedded in the SPIFFE ID's service name field — decode the certificate to find it

## Target State

- Read the SVID from the `workload-svid` Secret in namespace `dojo-sec-spiffe`
- Decode the base64-encoded certificate
- Parse the Subject Alternative Name to find the SPIFFE ID
- The flag is part of the SPIFFE ID path
