#!/usr/bin/env bash
# Verifier for "Capacity Estimate".
# Checks answers.py against the strict capacity formula.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-capacity-estimate"
FLAG='KUBE{capacity_math_prevents_overload}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]             || fail "work directory missing — run setup.sh first"
[ -f "$WORK/answers.py" ]  || fail "answers.py not found — run setup.sh first"
[ -f "$WORK/spec.json" ]   || fail "spec.json not found — run setup.sh first"

PYTHON=""
if [ -f "$WORK/.venv/bin/python3" ]; then
    PYTHON="$WORK/.venv/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="python3"
else
    fail "python3 not found"
fi

TMPFILE=$(mktemp /tmp/cap_check_XXXXXX.py)
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" << 'PYEOF'
import json
import math
import sys
import os

work = os.environ.get("WORK", ".")
sys.path.insert(0, work)

with open(os.path.join(work, "spec.json")) as f:
    spec = json.load(f)

target_qps   = spec["target_qps"]
svc_ms       = spec["p99_service_time_ms"]
headroom     = spec["slo_headroom_fraction"]

max_rps      = 1000.0 / svc_ms
eff_rps      = max_rps * (1 - headroom)
correct_n    = math.ceil(target_qps / eff_rps)
correct_q    = correct_n * eff_rps

import answers
n = answers.REQUIRED_INSTANCES
q = answers.MAX_SUSTAINABLE_QPS

errors = []

if not isinstance(n, int):
    errors.append(f"REQUIRED_INSTANCES must be an int, got {type(n).__name__}")
elif abs(n - correct_n) > 1:
    errors.append(
        f"REQUIRED_INSTANCES={n} is outside tolerance "
        f"[{correct_n-1}, {correct_n+1}] (correct={correct_n})"
    )

if q == 0.0:
    errors.append("MAX_SUSTAINABLE_QPS is still 0.0 — fill in your answer")
elif abs(q - correct_q) / correct_q > 0.10:
    errors.append(
        f"MAX_SUSTAINABLE_QPS={q:.1f} is outside 10% tolerance "
        f"(correct={correct_q:.1f})"
    )

if errors:
    for e in errors:
        print(f"  {e}")
    sys.exit(1)

print(f"  REQUIRED_INSTANCES  : {n}  (correct={correct_n})")
print(f"  MAX_SUSTAINABLE_QPS : {q}  (correct={correct_q:.1f})")
PYEOF

if WORK="$WORK" $PYTHON "$TMPFILE"; then
    echo
    echo "Capacity math correct. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "wrong answers — fix answers.py (run checker.py for guidance) and retry"
fi
