# Solution — Mutual TLS in Python

Complete `mtls_lab.py` implementation.

```python
import ssl
import os
import datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa


def create_ca(directory: str, common_name: str = "dojo-ca") -> tuple:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_path = os.path.join(directory, f"{common_name}-key.pem")
    cert_path = os.path.join(directory, f"{common_name}-cert.pem")
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    return cert_path, key_path


def create_signed_cert(
    common_name: str,
    ca_cert_path: str,
    ca_key_path: str,
    directory: str,
) -> tuple:
    with open(ca_key_path, "rb") as f:
        ca_key = serialization.load_pem_private_key(f.read(), password=None)
    with open(ca_cert_path, "rb") as f:
        ca_cert = x509.load_pem_x509_certificate(f.read())

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    key_path = os.path.join(directory, f"{common_name}-key.pem")
    cert_path = os.path.join(directory, f"{common_name}-cert.pem")
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    return cert_path, key_path


def server_ssl_context(
    server_cert_path: str,
    server_key_path: str,
    ca_cert_path: str,
) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(server_cert_path, server_key_path)
    ctx.load_verify_locations(ca_cert_path)
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def client_ssl_context(
    client_cert_path: str,
    client_key_path: str,
    ca_cert_path: str,
) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(client_cert_path, client_key_path)
    ctx.load_verify_locations(ca_cert_path)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx
```

## Why each piece is correct

**`BasicConstraints(ca=True)` on the CA cert.**
This X.509 extension marks the cert as a CA, which means OpenSSL will accept it as a trust anchor for verifying other certs. Without it, `load_verify_locations` may load the file but the verification chain will fail. It must also be `critical=True` — a non-critical `ca=False` extension can be ignored by some implementations.

**`issuer_name(ca_cert.subject)` on signed certs.**
The issuer field of a signed cert must match the subject of the CA cert exactly. Python's `ssl` module's chain validation checks this. If you set `issuer_name(name)` (i.e., the leaf's own subject) you've created a self-signed cert that won't chain to your CA.

**`ssl.PROTOCOL_TLS_SERVER` vs `ssl.PROTOCOL_TLS_CLIENT`.**
These two constants set sensible defaults for each role. `PROTOCOL_TLS_SERVER` starts in server mode; `PROTOCOL_TLS_CLIENT` starts in client mode with `verify_mode = CERT_REQUIRED` and `check_hostname = True` already set. We override `check_hostname = False` because the test uses `127.0.0.1`, not a DNS name that would match a cert's Common Name.

**`ctx.verify_mode = ssl.CERT_REQUIRED` on the server.**
This is the single line that makes TLS mutual. Without it (`ssl.CERT_NONE` or `ssl.CERT_OPTIONAL`), the server completes the handshake even if the client presents nothing. With `CERT_REQUIRED`, the server sends a `CertificateRequest` during the handshake and aborts with `certificate_required` if the client can't respond with a valid cert.

**`_free_port()` in the tests.**
The hidden test picks ephemeral ports with `bind(('127.0.0.1', 0))` to avoid conflicts. Each test function gets its own port so tests can run in parallel without collisions.

## The wrong-CA rejection path

When the client presents a cert signed by `evil-ca` but the server only trusts `dojo-ca`, the TLS handshake fails at the server's chain verification step — the server sends `alert certificate unknown` and the client raises `ssl.SSLError`. The ciphertext exchange never starts. This is the zero-trust invariant: network path is irrelevant; identity is proven by the certificate chain.

## Attacker's view

In a cluster running Istio in PERMISSIVE mode, an attacker who has compromised a pod can send raw HTTP to any other pod's port. In STRICT mode (the equivalent of `CERT_REQUIRED`), the attacker would also need a valid mTLS certificate — which means their traffic must come through an Envoy sidecar, which won't forward for an identity that isn't registered in the mesh. The attack surface shrinks to "compromise an enrolled workload identity," not "compromise any network path."

## Verify

```bash
cd ~/.kube-dojo-work/03-mtls-in-python
. .venv/bin/activate
pytest tests/ -v
bash courses/course-31-secrets-zero-trust/challenges/03-mtls-in-python/verify.sh
```
