#!/usr/bin/env bash
# Verifier for "Matrix Builds and Dependency Cache".
# Parses .github/workflows/ci.yml with python3+pyyaml and asserts:
#   1. at least one job
#   2. strategy.matrix has a key with >= 2 values
#   3. a cache step is present (actions/cache or setup-python with cache)
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-matrix-and-cache"
FLAG='KUBE{matrix_builds_and_cache}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"

WF="$WORK/.github/workflows/ci.yml"
[ -f "$WF" ] || fail "workflow file not found at .github/workflows/ci.yml — create it inside $WORK"

python3 - "$WF" << 'PYEOF'
import yaml, sys

path = sys.argv[1]
try:
    with open(path) as f:
        d = yaml.safe_load(f)
except Exception as e:
    print(f"✗ YAML parse error: {e}")
    sys.exit(1)

if not isinstance(d, dict):
    print("✗ workflow is not a YAML mapping at the top level")
    sys.exit(1)

jobs = d.get('jobs') or {}
if not jobs:
    print("✗ workflow has no jobs")
    sys.exit(1)

found_matrix = False
found_cache = False

for job_name, job in jobs.items():
    if not isinstance(job, dict):
        continue

    strategy = job.get('strategy') or {}
    matrix = strategy.get('matrix') or {}
    for key, val in matrix.items():
        if isinstance(val, list) and len(val) >= 2:
            found_matrix = True

    steps = job.get('steps') or []
    for step in steps:
        if not isinstance(step, dict):
            continue
        uses = (step.get('uses') or '')
        with_val = step.get('with') or {}

        if 'actions/cache' in uses:
            found_cache = True

        if 'setup-python' in uses and with_val.get('cache'):
            found_cache = True

if not found_matrix:
    print("✗ no strategy.matrix found with >= 2 entries")
    print("  add 'strategy:\\n  matrix:\\n    python-version: [\"3.11\", \"3.12\"]' to a job")
    sys.exit(1)

if not found_cache:
    print("✗ no cache step found")
    print("  add 'cache: pip' to your setup-python step, or use actions/cache@v4")
    sys.exit(1)

print("ok: matrix (>=2 entries) and cache step both verified")
PYEOF

PARSE_EXIT=$?
[ "$PARSE_EXIT" -eq 0 ] || fail "workflow structure check failed — see errors above"

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
