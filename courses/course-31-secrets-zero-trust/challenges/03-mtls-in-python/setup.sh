#!/usr/bin/env bash
# Plants the "Mutual TLS in Python" skeleton into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
# Does not require a Kubernetes cluster.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-mtls-in-python"
mkdir -p "$WORK/tests"

# ── mtls_lab.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/mtls_lab.py" << 'PYEOF'
# mtls_lab.py — implement the four functions below
# stdlib: ssl, socket, os, datetime
# pip:    cryptography  (cert generation only)
import ssl
import os
import datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa


def create_ca(directory: str, common_name: str = "dojo-ca") -> tuple:
    """
    Generate a self-signed CA keypair and write it to directory.
    Returns (ca_cert_path, ca_key_path) — both absolute file paths.

    The cert must have BasicConstraints(ca=True) so it can sign other certs.
    Key size: 2048 bits.  Validity: 365 days.
    """
    raise NotImplementedError


def create_signed_cert(
    common_name: str,
    ca_cert_path: str,
    ca_key_path: str,
    directory: str,
) -> tuple:
    """
    Generate a keypair for common_name, sign it with the given CA, and write
    both files to directory.
    Returns (cert_path, key_path) — both absolute file paths.

    Key size: 2048 bits.  Validity: 365 days.
    BasicConstraints(ca=False).
    """
    raise NotImplementedError


def server_ssl_context(
    server_cert_path: str,
    server_key_path: str,
    ca_cert_path: str,
) -> ssl.SSLContext:
    """
    Return an ssl.SSLContext configured for a server that REQUIRES a valid
    client certificate (mutual TLS).

    Requirements:
    - Load server_cert_path + server_key_path as the server's identity.
    - Load ca_cert_path as the trusted CA for verifying client certs.
    - Set verify_mode = ssl.CERT_REQUIRED.
    """
    raise NotImplementedError


def client_ssl_context(
    client_cert_path: str,
    client_key_path: str,
    ca_cert_path: str,
) -> ssl.SSLContext:
    """
    Return an ssl.SSLContext configured for a client that presents its cert
    and verifies the server cert against the CA.

    Requirements:
    - Load client_cert_path + client_key_path as the client's identity.
    - Load ca_cert_path as the trusted CA for verifying the server cert.
    - Set check_hostname = False (lab uses 127.0.0.1, not a DNS hostname).
    - Set verify_mode = ssl.CERT_REQUIRED (verify server cert).
    """
    raise NotImplementedError
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
# test_visible.py — structure checks you can run locally before the hidden verifier
import sys
import os
import ssl
import tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from mtls_lab import create_ca, create_signed_cert, server_ssl_context, client_ssl_context


def test_create_ca_returns_two_existing_paths(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path))
    assert os.path.isfile(ca_cert), "create_ca must return a valid cert file path"
    assert os.path.isfile(ca_key), "create_ca must return a valid key file path"


def test_create_signed_cert_returns_two_paths(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path))
    cert, key = create_signed_cert("test-server", ca_cert, ca_key, str(tmp_path))
    assert os.path.isfile(cert)
    assert os.path.isfile(key)


def test_server_context_requires_client_cert(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path))
    srv_cert, srv_key = create_signed_cert("srv", ca_cert, ca_key, str(tmp_path))
    ctx = server_ssl_context(srv_cert, srv_key, ca_cert)
    assert isinstance(ctx, ssl.SSLContext)
    assert ctx.verify_mode == ssl.CERT_REQUIRED, \
        "server_ssl_context must set verify_mode = ssl.CERT_REQUIRED for mTLS"


def test_client_context_is_ssl_context(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path))
    cli_cert, cli_key = create_signed_cert("cli", ca_cert, ca_key, str(tmp_path))
    ctx = client_ssl_context(cli_cert, cli_key, ca_cert)
    assert isinstance(ctx, ssl.SSLContext)
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the four functions in mtls_lab.py"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest cryptography"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-31-secrets-zero-trust/challenges/03-mtls-in-python/verify.sh"
