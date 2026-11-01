# Mutual TLS in Python

A platform engineer is reviewing the service mesh configuration and asks:

> "Every pod has an Envoy sidecar doing mTLS. What happens if a service bypasses the sidecar and calls another service's port directly?"

Without mTLS enforced at the application layer, bypassing the sidecar bypasses all authentication. With mTLS at the application layer, the server demands a valid client certificate signed by the cluster's CA — no cert, no connection, regardless of how the traffic arrived.

This challenge strips Envoy out of the picture. You implement mutual TLS in pure Python to understand exactly what the sidecar does at the TLS handshake level. Once you've done it by hand, reading an Istio `PeerAuthentication` policy or an SPIFFE SVID makes immediate sense.

## How mTLS differs from regular TLS

Regular TLS: **client verifies server identity** (is this really api.example.com?).

Mutual TLS: **both sides verify each other**:
- Server verifies client: "does this client hold a cert signed by our CA?"
- Client verifies server: "does this server hold a cert signed by our CA?"

Neither connection completes without both checks passing. In a zero-trust network, every workload has an identity (SPIFFE SVID / X.509 cert). The network is not trusted; the cert is.

## Prerequisites

```bash
pip install pytest cryptography
```

The `ssl` module is stdlib. `cryptography` is for cert generation only.

## What `setup.sh` plants

```
~/.kube-dojo-work/03-mtls-in-python/
├── mtls_lab.py          # four stubbed functions — implement these
└── tests/
    ├── __init__.py
    └── test_visible.py  # structure checks you can run locally
```

## Mission

Implement the four functions in `mtls_lab.py`:

| Function | Contract |
|----------|---------|
| `create_ca(directory, common_name)` | Generate a self-signed CA cert + key in `directory`. Return `(ca_cert_path, ca_key_path)`. |
| `create_signed_cert(common_name, ca_cert_path, ca_key_path, directory)` | Generate a keypair, sign with the CA. Return `(cert_path, key_path)`. |
| `server_ssl_context(cert_path, key_path, ca_cert_path)` | Return an `ssl.SSLContext` with `verify_mode = ssl.CERT_REQUIRED` (rejects clients with no cert or wrong-CA cert). |
| `client_ssl_context(cert_path, key_path, ca_cert_path)` | Return an `ssl.SSLContext` that presents the client cert and verifies the server. |

The verify script runs a hidden test suite that:

1. Calls your `create_ca` and `create_signed_cert` to build a real PKI.
2. Starts an echo server in a thread with your `server_ssl_context`.
3. **Asserts a valid client connects** successfully.
4. **Asserts a client presenting no cert is rejected** (`ssl.SSLError`).
5. **Asserts a client presenting a cert signed by a different CA is rejected** (`ssl.SSLError`).

## Local test run

```bash
cd ~/.kube-dojo-work/03-mtls-in-python
python3 -m venv .venv && . .venv/bin/activate
pip install pytest cryptography
pytest tests/ -v
```

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/03-mtls-in-python/verify.sh
```

## Why `CERT_REQUIRED` is the critical line

`ssl.CERT_REQUIRED` on the server context is what makes this *mutual* TLS. Without it, the server accepts any connection and you have ordinary one-way TLS. One line changes the security model:

```python
ctx.verify_mode = ssl.CERT_REQUIRED   # mTLS — reject uncertified clients
ctx.verify_mode = ssl.CERT_NONE       # one-way TLS — any client connects
```

In Istio, `PeerAuthentication` with `mtls: mode: STRICT` sets the equivalent of `CERT_REQUIRED` on every Envoy sidecar. `PERMISSIVE` is `CERT_NONE` — it accepts both. Understanding this at the socket level makes `STRICT` vs `PERMISSIVE` debates much less abstract.
