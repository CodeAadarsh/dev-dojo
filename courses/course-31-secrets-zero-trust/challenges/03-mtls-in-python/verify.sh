#!/usr/bin/env bash
# Verifier for "Mutual TLS in Python".
# Writes a hidden pytest suite to a temp dir, runs it against the learner's
# mtls_lab.py, and prints the flag only when every check passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-mtls-in-python"
FLAG='KUBE{mtls_trust_the_cert_not_the_network}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/mtls_lab.py" ] || fail "mtls_lab.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest cryptography"
fi

HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_mtls_hidden.py" << 'PYEOF'
import sys
import os
import ssl
import socket
import threading
import time

sys.path.insert(0, os.environ["DOJO_WORK"])

import pytest
from mtls_lab import create_ca, create_signed_cert, server_ssl_context, client_ssl_context


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start_echo_server(ctx: ssl.SSLContext, port: int) -> threading.Thread:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(3)
    srv.settimeout(3.0)

    def _serve():
        try:
            raw_conn, _ = srv.accept()
            with ctx.wrap_socket(raw_conn, server_side=True) as tls:
                data = tls.recv(1024)
                tls.sendall(data)
        except Exception:
            pass
        finally:
            srv.close()

    t = threading.Thread(target=_serve, daemon=True)
    t.start()
    return t


def _connect(ctx: ssl.SSLContext, port: int, retries: int = 30) -> bytes:
    for _ in range(retries):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as raw:
                with ctx.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                    tls.sendall(b"ping")
                    return tls.recv(1024)
        except ConnectionRefusedError:
            time.sleep(0.05)
    raise ConnectionRefusedError(f"port {port} not ready after {retries} retries")


def test_valid_client_connects(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path), "ca-v")
    srv_cert, srv_key = create_signed_cert("server-v", ca_cert, ca_key, str(tmp_path))
    cli_cert, cli_key = create_signed_cert("client-v", ca_cert, ca_key, str(tmp_path))

    srv_ctx = server_ssl_context(srv_cert, srv_key, ca_cert)
    cli_ctx = client_ssl_context(cli_cert, cli_key, ca_cert)

    port = _free_port()
    _start_echo_server(srv_ctx, port)
    time.sleep(0.05)
    data = _connect(cli_ctx, port)
    assert data == b"ping", "server must echo back the client's message"


def test_no_client_cert_rejected(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path), "ca-nc")
    srv_cert, srv_key = create_signed_cert("server-nc", ca_cert, ca_key, str(tmp_path))

    srv_ctx = server_ssl_context(srv_cert, srv_key, ca_cert)

    # Client that presents no cert and does not verify the server
    no_cert_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    no_cert_ctx.check_hostname = False
    no_cert_ctx.verify_mode = ssl.CERT_NONE

    port = _free_port()
    _start_echo_server(srv_ctx, port)
    time.sleep(0.05)
    with pytest.raises(ssl.SSLError):
        _connect(no_cert_ctx, port)


def test_wrong_ca_cert_rejected(tmp_path):
    ca_cert, ca_key = create_ca(str(tmp_path), "ca-wc")
    srv_cert, srv_key = create_signed_cert("server-wc", ca_cert, ca_key, str(tmp_path))

    evil_ca_cert, evil_ca_key = create_ca(str(tmp_path), "evil-ca-wc")
    evil_cli_cert, evil_cli_key = create_signed_cert(
        "evil-client-wc", evil_ca_cert, evil_ca_key, str(tmp_path)
    )

    srv_ctx = server_ssl_context(srv_cert, srv_key, ca_cert)
    evil_ctx = client_ssl_context(evil_cli_cert, evil_cli_key, evil_ca_cert)

    port = _free_port()
    _start_echo_server(srv_ctx, port)
    time.sleep(0.05)
    with pytest.raises(ssl.SSLError):
        _connect(evil_ctx, port)
PYEOF

if DOJO_WORK="$WORK" "$PYTEST" "$HIDDEN_DIR/test_mtls_hidden.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — fix your implementation, run the visible tests first: cd $WORK && .venv/bin/pytest tests/ -v"
fi
