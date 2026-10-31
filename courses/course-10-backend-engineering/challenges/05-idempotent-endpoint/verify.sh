#!/usr/bin/env bash
# Verifier for "Idempotent Endpoint".
# Activates the local venv and runs pytest; prints the flag only on full green.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-idempotent-endpoint"
FLAG='KUBE{idempotency_key_once_and_only_once}'

fail() { echo "✗ $1"; exit 1; }

[[ -d "$WORK" ]] || fail "work directory not found — run setup.sh first"
cd "$WORK"
[[ -f "main.py" ]] || fail "main.py missing — run setup.sh again"
[[ -f "test_idempotency.py" ]] || fail "test_idempotency.py missing — run setup.sh again"
[[ -x ".venv/bin/python" ]] || fail ".venv not found — run inside $WORK: python3 -m venv .venv && source .venv/bin/activate && pip install fastapi pytest httpx"

.venv/bin/python -m pytest test_idempotency.py -v || fail "tests failed — implement idempotency key handling in main.py"

echo
echo "All idempotency tests passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
