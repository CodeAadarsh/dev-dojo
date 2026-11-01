#!/usr/bin/env bash
# Verifier for "Safe Node-Pool Upgrade".
# Parses pdb.yaml and deployment.yaml with python3+pyyaml and asserts the
# upgrade-safety properties. Prints the flag only when all checks pass.
# Prerequisites: python3 + pyyaml (pip3 install pyyaml)
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-safe-upgrade"
FLAG='KUBE{safe_node_pool_upgrade_zero_downtime}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                   || fail "work directory missing — run setup.sh first"
[ -f "$WORK/pdb.yaml" ]          || fail "pdb.yaml not found in $WORK — run setup.sh first"
[ -f "$WORK/deployment.yaml" ]   || fail "deployment.yaml not found in $WORK — run setup.sh first"
command -v python3 >/dev/null 2>&1 || fail "python3 not found in PATH"

export WORK

python3 - << 'PYEOF'
import sys, os, re

try:
    import yaml
except ImportError:
    print("✗ pyyaml not installed — run: pip3 install pyyaml")
    sys.exit(1)

WORK = os.environ.get('WORK', '')
errors = []
ok_msgs = []

# ── pdb.yaml ─────────────────────────────────────────────────────────────────
try:
    with open(os.path.join(WORK, 'pdb.yaml')) as fh:
        pdb_doc = yaml.safe_load(fh)
except Exception as exc:
    print(f"✗ failed to parse pdb.yaml: {exc}")
    sys.exit(1)

if not pdb_doc or pdb_doc.get('kind') != 'PodDisruptionBudget':
    errors.append("pdb.yaml: kind must be PodDisruptionBudget")
else:
    spec = pdb_doc.get('spec') or {}
    min_avail = spec.get('minAvailable')
    if min_avail is None:
        errors.append("pdb.yaml: spec.minAvailable is required")
    elif isinstance(min_avail, int) and min_avail >= 1:
        ok_msgs.append(f"pdb.yaml: spec.minAvailable={min_avail} (integer)")
    elif isinstance(min_avail, str) and re.match(r'^\d+%$', min_avail) and int(min_avail[:-1]) >= 1:
        ok_msgs.append(f"pdb.yaml: spec.minAvailable={min_avail} (percentage)")
    else:
        errors.append(
            f"pdb.yaml: spec.minAvailable must be an integer >= 1 or a percentage "
            f"like \"50%\" (got: {min_avail!r})"
        )

# ── deployment.yaml ───────────────────────────────────────────────────────────
try:
    with open(os.path.join(WORK, 'deployment.yaml')) as fh:
        deploy_doc = yaml.safe_load(fh)
except Exception as exc:
    print(f"✗ failed to parse deployment.yaml: {exc}")
    sys.exit(1)

if not deploy_doc or deploy_doc.get('kind') != 'Deployment':
    errors.append("deployment.yaml: kind must be Deployment")
else:
    containers = (deploy_doc.get('spec', {})
                             .get('template', {})
                             .get('spec', {})
                             .get('containers', []))
    if not containers:
        errors.append("deployment.yaml: spec.template.spec.containers is empty")
    else:
        probe = containers[0].get('readinessProbe')
        if probe:
            ok_msgs.append("deployment.yaml: containers[0].readinessProbe is set")
        else:
            errors.append(
                "deployment.yaml: containers[0] must have a readinessProbe — "
                "without it Kubernetes sends traffic to pods before they are warm"
            )

    deploy_spec = deploy_doc.get('spec', {}) or {}
    strategy = deploy_spec.get('strategy', {}) or {}
    strategy_type = strategy.get('type', 'RollingUpdate')
    if strategy_type != 'RollingUpdate':
        errors.append(
            f"deployment.yaml: spec.strategy.type must be RollingUpdate (got: {strategy_type!r})"
        )
    else:
        rolling = strategy.get('rollingUpdate', {}) or {}
        max_unavail = rolling.get('maxUnavailable')
        if max_unavail in (0, '0', '0%'):
            ok_msgs.append(
                f"deployment.yaml: spec.strategy.rollingUpdate.maxUnavailable={max_unavail!r} "
                f"(zero-downtime rollout)"
            )
        else:
            errors.append(
                f"deployment.yaml: spec.strategy.rollingUpdate.maxUnavailable must be 0 or "
                f"\"0%\" to guarantee zero downtime during drains (got: {max_unavail!r})"
            )

# ── result ────────────────────────────────────────────────────────────────────
if errors:
    for e in errors:
        print(f"✗ {e}")
    sys.exit(1)

for m in ok_msgs:
    print(f"✓ {m}")
PYEOF

echo
echo "All upgrade-safety checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
