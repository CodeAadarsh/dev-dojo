#!/usr/bin/env bash
# Verifier for "Token Bucket Rate Limiter".
# Activates the local venv and runs pytest; prints the flag only on full green.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-token-bucket-rate-limiter"
FLAG='KUBE{token_bucket_rate_limiter}'

fail() { echo "✗ $1"; exit 1; }

[[ -d "$WORK" ]] || fail "work directory not found — run setup.sh first"
cd "$WORK"
[[ -f "ratelimiter.py" ]] || fail "ratelimiter.py missing — run setup.sh again"
[[ -f "test_ratelimiter.py" ]] || fail "test_ratelimiter.py missing — run setup.sh again"
[[ -x ".venv/bin/python" ]] || fail ".venv not found — run inside $WORK: python3 -m venv .venv && source .venv/bin/activate && pip install pytest"

.venv/bin/python -m pytest test_ratelimiter.py -v || fail "tests failed — fix TokenBucketLimiter in ratelimiter.py"

echo
echo "All rate-limiter tests passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
