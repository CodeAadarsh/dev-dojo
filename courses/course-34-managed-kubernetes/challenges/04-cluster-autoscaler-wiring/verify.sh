#!/usr/bin/env bash
# Verifier for "Wire the Cluster Autoscaler".
# Parses autoscaler.yaml and nodegroup.yaml with python3+pyyaml and asserts
# the required auto-discovery wiring. Prints the flag only when all checks pass.
# Prerequisites: python3 + pyyaml (pip3 install pyyaml)
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-cluster-autoscaler-wiring"
FLAG='KUBE{cluster_autoscaler_auto_discovery_wired}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                    || fail "work directory missing — run setup.sh first"
[ -f "$WORK/autoscaler.yaml" ]    || fail "autoscaler.yaml not found in $WORK — run setup.sh first"
[ -f "$WORK/nodegroup.yaml" ]     || fail "nodegroup.yaml not found in $WORK — run setup.sh first"
command -v python3 >/dev/null 2>&1 || fail "python3 not found in PATH"

export WORK

python3 - << 'PYEOF'
import sys, os

try:
    import yaml
except ImportError:
    print("✗ pyyaml not installed — run: pip3 install pyyaml")
    sys.exit(1)

WORK = os.environ.get('WORK', '')
errors = []
ok_msgs = []

# ── autoscaler.yaml ──────────────────────────────────────────────────────────
try:
    with open(os.path.join(WORK, 'autoscaler.yaml')) as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception as exc:
    print(f"✗ failed to parse autoscaler.yaml: {exc}")
    sys.exit(1)

deploy = next((d for d in docs if d and d.get('kind') == 'Deployment'), None)
if deploy is None:
    errors.append("autoscaler.yaml: no Deployment document found")
else:
    containers = (deploy.get('spec', {})
                        .get('template', {})
                        .get('spec', {})
                        .get('containers', []))
    autodisco_ok = False
    for c in (containers or []):
        for arg in (c.get('args') or []):
            s = str(arg)
            if '--node-group-auto-discovery' in s and 'k8s.io/cluster-autoscaler/enabled' in s:
                autodisco_ok = True
    if autodisco_ok:
        ok_msgs.append("autoscaler.yaml: --node-group-auto-discovery references k8s.io/cluster-autoscaler/enabled")
    else:
        errors.append(
            "autoscaler.yaml: container args must include "
            "--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled=true,..."
        )

# ── nodegroup.yaml ───────────────────────────────────────────────────────────
try:
    with open(os.path.join(WORK, 'nodegroup.yaml')) as fh:
        ng_doc = yaml.safe_load(fh)
except Exception as exc:
    print(f"✗ failed to parse nodegroup.yaml: {exc}")
    sys.exit(1)

ngs = (ng_doc or {}).get('managedNodeGroups', [])
if not ngs:
    errors.append("nodegroup.yaml: managedNodeGroups list is missing or empty")
else:
    ng = ngs[0]
    min_size = ng.get('minSize')
    max_size = ng.get('maxSize')

    if not isinstance(min_size, int) or min_size < 1:
        errors.append(
            f"nodegroup.yaml: managedNodeGroups[0].minSize must be an integer >= 1 (got: {min_size!r})"
        )
    elif not isinstance(max_size, int) or max_size <= min_size:
        errors.append(
            f"nodegroup.yaml: maxSize must be > minSize "
            f"(minSize={min_size}, maxSize={max_size})"
        )
    else:
        ok_msgs.append(
            f"nodegroup.yaml: minSize={min_size}, maxSize={max_size} — valid scaling range"
        )

    tags = ng.get('tags') or {}
    enabled_val = str(tags.get('k8s.io/cluster-autoscaler/enabled', '')).lower()
    if enabled_val == 'true':
        ok_msgs.append("nodegroup.yaml: tag k8s.io/cluster-autoscaler/enabled=true present")
    else:
        errors.append(
            'nodegroup.yaml: tags must contain k8s.io/cluster-autoscaler/enabled: "true" '
            f'(got: {tags.get("k8s.io/cluster-autoscaler/enabled")!r})'
        )

# ── result ───────────────────────────────────────────────────────────────────
if errors:
    for e in errors:
        print(f"✗ {e}")
    sys.exit(1)

for m in ok_msgs:
    print(f"✓ {m}")
PYEOF

echo
echo "All autoscaler wiring checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
