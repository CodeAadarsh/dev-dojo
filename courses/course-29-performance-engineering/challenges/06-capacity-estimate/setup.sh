#!/usr/bin/env bash
# Plants the "Capacity Estimate" starter project into the work directory.
# Idempotent — re-running overwrites skeleton files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-capacity-estimate"
mkdir -p "$WORK"

# ── spec.json ─────────────────────────────────────────────────────────────────
cat > "$WORK/spec.json" << 'JSONEOF'
{
  "scenario": "API gateway — flash sale capacity sizing",
  "target_qps": 800,
  "p99_service_time_ms": 12,
  "slo_headroom_fraction": 0.25,
  "notes": [
    "P99 service time was measured under 40% load; treat it as the per-request work unit.",
    "SLO headroom: keep each instance utilisation at or below (1 - slo_headroom_fraction).",
    "required_instances must be an integer (round up with math.ceil).",
    "max_sustainable_qps is a float: required_instances * effective_rps_per_instance."
  ]
}
JSONEOF

# ── answers.py skeleton ───────────────────────────────────────────────────────
cat > "$WORK/answers.py" << 'PYEOF'
"""
answers.py — fill in your computed values.

Read spec.json, apply the capacity formula, then set the two variables below.

Formula:
  max_rps_per_instance = 1000 / spec["p99_service_time_ms"]
  effective_rps        = max_rps_per_instance * (1 - spec["slo_headroom_fraction"])
  required_instances   = math.ceil(spec["target_qps"] / effective_rps)   # int
  max_sustainable_qps  = required_instances * effective_rps               # float
"""
import math

REQUIRED_INSTANCES: int = 0       # replace with your answer
MAX_SUSTAINABLE_QPS: float = 0.0  # replace with your answer
PYEOF

# ── checker.py (visible) ──────────────────────────────────────────────────────
cat > "$WORK/checker.py" << 'PYEOF'
"""checker.py — visible checker; run this before verify.sh to see where you stand."""
import json
import math
import sys

with open("spec.json") as f:
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

ok = True

if abs(n - correct_n) > 1:
    print(f"  REQUIRED_INSTANCES  = {n}  (expected ~{correct_n}, tolerance ±1)")
    ok = False
else:
    print(f"  REQUIRED_INSTANCES  = {n}  correct")

if q == 0.0 or abs(q - correct_q) / correct_q > 0.10:
    print(f"  MAX_SUSTAINABLE_QPS = {q}  (expected ~{correct_q:.1f}, tolerance ±10%)")
    ok = False
else:
    print(f"  MAX_SUSTAINABLE_QPS = {q}  correct")

if ok:
    print("\nAll correct. Run verify.sh for the flag.")
else:
    print("\nFix answers.py and re-run checker.py.")
    sys.exit(1)
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : compute the two values in $WORK/answers.py"
echo
echo "Development loop:"
echo "  cd $WORK"
echo "  python3 checker.py          # instant feedback"
echo
echo "Verify + flag   : bash courses/course-29-performance-engineering/challenges/06-capacity-estimate/verify.sh"
