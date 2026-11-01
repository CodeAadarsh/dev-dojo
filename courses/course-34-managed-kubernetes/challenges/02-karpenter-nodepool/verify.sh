#!/usr/bin/env bash
# Verifier for "Karpenter NodePool — Spot + Consolidation".
# Parses nodepool.yaml and ec2nodeclass.yaml with python3+pyyaml.
# Prints the flag only when all structural checks pass.
# Exit 0 = solved, Exit 1 = not yet.
set -euo pipefail

SLUG="02-karpenter-nodepool"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{karpenter_spot_plus_consolidation}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                     || fail "work directory missing — run setup.sh first"
[ -f "$WORK/nodepool.yaml" ]       || fail "nodepool.yaml not found — run setup.sh first"
[ -f "$WORK/ec2nodeclass.yaml" ]   || fail "ec2nodeclass.yaml not found — run setup.sh first"

python3 - << PYEOF
import sys, yaml

def fail(msg):
    print(f"x  {msg}")
    sys.exit(1)

# ── NodePool ──────────────────────────────────────────────────────────────────
with open("$WORK/nodepool.yaml") as f:
    np = yaml.safe_load(f)

if not np:
    fail("nodepool.yaml is empty or invalid YAML")

if np.get("kind") != "NodePool":
    fail(f"nodepool.yaml: kind must be NodePool (found: '{np.get('kind')}')")

api_version = np.get("apiVersion", "")
if not api_version.startswith("karpenter.sh/"):
    fail(f"nodepool.yaml: apiVersion must start with 'karpenter.sh/' (found: '{api_version}')")

requirements = (
    (np.get("spec") or {})
    .get("template", {})
    .get("spec", {})
    .get("requirements", [])
)
if not requirements:
    fail("nodepool.yaml: spec.template.spec.requirements must have at least one entry")

# Check for capacity-type requirement that includes spot
has_spot = False
for req in requirements:
    key = req.get("key", "")
    values = req.get("values", [])
    if "capacity-type" in key and isinstance(values, list) and "spot" in values:
        has_spot = True
        break

if not has_spot:
    fail(
        "nodepool.yaml: requirements must include a capacity-type entry with 'spot' in values "
        "(e.g. key: karpenter.k8s.aws/capacity-type, operator: In, values: [spot, on-demand])"
    )

limits = (np.get("spec") or {}).get("limits") or {}
if not limits:
    fail("nodepool.yaml: spec.limits must be set")

cpu_limit = limits.get("cpu")
mem_limit = limits.get("memory")

if not cpu_limit:
    fail("nodepool.yaml: spec.limits.cpu must be set (e.g. \"1000\")")
if not mem_limit:
    fail("nodepool.yaml: spec.limits.memory must be set (e.g. \"4000Gi\")")

disruption = (np.get("spec") or {}).get("disruption") or {}
if not disruption:
    fail("nodepool.yaml: spec.disruption must be set")

consolidation_policy = disruption.get("consolidationPolicy")
consolidate_after    = disruption.get("consolidateAfter")
ttl_empty            = disruption.get("ttlSecondsAfterEmpty")   # v1beta1 compat

if not consolidation_policy and not ttl_empty:
    fail(
        "nodepool.yaml: spec.disruption.consolidationPolicy must be set "
        "(e.g. WhenEmptyOrUnderutilized or WhenEmpty)"
    )
if not consolidate_after and not ttl_empty:
    fail(
        "nodepool.yaml: spec.disruption.consolidateAfter must be set "
        "(e.g. 30s) to enable active consolidation"
    )

np_name = (np.get("metadata") or {}).get("name", "unnamed")
print(f"OK  NodePool '{np_name}' — kind and apiVersion verified")
print(f"OK  capacity-type includes 'spot'")
print(f"OK  spec.limits — cpu: {cpu_limit}, memory: {mem_limit}")
print(f"OK  spec.disruption — policy: {consolidation_policy or 'ttl-based'}, consolidateAfter: {consolidate_after or ttl_empty}")

# ── EC2NodeClass ──────────────────────────────────────────────────────────────
with open("$WORK/ec2nodeclass.yaml") as f:
    nc = yaml.safe_load(f)

if not nc:
    fail("ec2nodeclass.yaml is empty or invalid YAML")

if nc.get("kind") != "EC2NodeClass":
    fail(f"ec2nodeclass.yaml: kind must be EC2NodeClass (found: '{nc.get('kind')}')")

nc_spec = nc.get("spec") or {}

ami_terms = nc_spec.get("amiSelectorTerms") or []
if not ami_terms:
    fail("ec2nodeclass.yaml: spec.amiSelectorTerms must have at least one entry (e.g. alias: al2023@latest)")

subnet_terms = nc_spec.get("subnetSelectorTerms") or []
if not subnet_terms:
    fail("ec2nodeclass.yaml: spec.subnetSelectorTerms must have at least one entry")

sg_terms = nc_spec.get("securityGroupSelectorTerms") or []
if not sg_terms:
    fail("ec2nodeclass.yaml: spec.securityGroupSelectorTerms must have at least one entry")

nc_name = (nc.get("metadata") or {}).get("name", "unnamed")
print(f"OK  EC2NodeClass '{nc_name}' — kind verified")
print(f"OK  amiSelectorTerms: {len(ami_terms)} term(s)")
print(f"OK  subnetSelectorTerms: {len(subnet_terms)} term(s)")
print(f"OK  securityGroupSelectorTerms: {len(sg_terms)} term(s)")
PYEOF

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
