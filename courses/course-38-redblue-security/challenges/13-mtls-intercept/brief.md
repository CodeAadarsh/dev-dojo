# mTLS Intercept — Prove the Lateral Path Is Encrypted

Two services are talking. `frontend` calls `backend`. Right now, that traffic is plaintext HTTP. An attacker who can intercept the network traffic (by being on the same node, via ARP spoofing, or by compromising a network component) can read every request.

This challenge asks you to configure TLS between `frontend` and `backend`, then prove that a rogue pod cannot see the plaintext payload — it only sees encrypted bytes.

## Setup

Both services are deployed in `dojo-sec-mtls`. Currently they communicate over HTTP. A test Secret with TLS credentials is pre-generated.

## Mission

1. Mount the TLS cert and key into the `backend` pod
2. Configure `backend` to serve HTTPS instead of HTTP
3. Configure `frontend` to call `backend` with `--cacert` (verify the server cert)
4. Prove it works: `frontend` can reach `backend` over HTTPS
5. Prove it's encrypted: a rogue pod using plain `curl http://backend...` gets a TLS error
6. Run the verifier

## Rules of Engagement

- Namespace: `dojo-sec-mtls`
- Backend service: `backend-svc`
- TLS credentials pre-generated in Secret `tls-creds` in `dojo-sec-mtls`
- Run the verifier: `bash verify.sh`
