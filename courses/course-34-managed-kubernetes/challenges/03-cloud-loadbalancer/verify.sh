#!/usr/bin/env bash
# Verifier for "Cloud LoadBalancer — Internal NLB with IP Target Mode".
# Parses service.yaml with python3+pyyaml.
# Prints the flag only when all structural checks pass.
# Exit 0 = solved, Exit 1 = not yet.
set -euo pipefail

SLUG="03-cloud-loadbalancer"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{nlb_internal_cross_zone_ip}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]               || fail "work directory missing — run setup.sh first"
[ -f "$WORK/service.yaml" ]  || fail "service.yaml not found — run setup.sh first"

python3 - << PYEOF
import sys, yaml

def fail(msg):
    print(f"x  {msg}")
    sys.exit(1)

with open("$WORK/service.yaml") as f:
    svc = yaml.safe_load(f)

if not svc:
    fail("service.yaml is empty or invalid YAML")

if svc.get("kind") != "Service":
    fail(f"service.yaml: kind must be Service (found: '{svc.get('kind')}')")

svc_type = (svc.get("spec") or {}).get("type", "")
if svc_type != "LoadBalancer":
    fail(
        f"service.yaml: spec.type must be LoadBalancer (found: '{svc_type}'). "
        "ClusterIP and NodePort do not provision a cloud load balancer."
    )

annotations = (svc.get("metadata") or {}).get("annotations") or {}

PREFIX = "service.beta.kubernetes.io/aws-load-balancer-"

# 1 — LBC controller selection
lb_type = annotations.get(f"{PREFIX}type", "")
if lb_type != "external":
    fail(
        f"Missing or wrong annotation '{PREFIX}type'. "
        f"Set it to 'external' to use the AWS Load Balancer Controller (found: '{lb_type}'). "
        "The in-tree value 'nlb' does not support IP mode on EKS 1.27+."
    )

# 2 — internal scheme
scheme = annotations.get(f"{PREFIX}scheme", "")
if scheme != "internal":
    fail(
        f"Missing or wrong annotation '{PREFIX}scheme'. "
        f"Set it to 'internal' for a private LB not reachable from the internet (found: '{scheme}')."
    )

# 3 — IP target type
target_type = annotations.get(f"{PREFIX}nlb-target-type", "")
if target_type != "ip":
    fail(
        f"Missing or wrong annotation '{PREFIX}nlb-target-type'. "
        f"Set it to 'ip' to route directly to pod IPs (found: '{target_type}'). "
        "Without this, traffic goes through kube-proxy on nodes and Network Policies cannot inspect source IP."
    )

# 4 — cross-zone
cross_zone = str(annotations.get(f"{PREFIX}cross-zone-load-balancing-enabled", "")).lower()
if cross_zone != "true":
    fail(
        f"Missing or wrong annotation '{PREFIX}cross-zone-load-balancing-enabled'. "
        f"Set it to 'true' (found: '{cross_zone}'). "
        "Without cross-zone, AZs with fewer pods receive proportionally more traffic."
    )

svc_name = (svc.get("metadata") or {}).get("name", "unnamed")
print(f"OK  Service '{svc_name}' — kind: Service, spec.type: LoadBalancer")
print(f"OK  {PREFIX}type: {lb_type}")
print(f"OK  {PREFIX}scheme: {scheme}")
print(f"OK  {PREFIX}nlb-target-type: {target_type}")
print(f"OK  {PREFIX}cross-zone-load-balancing-enabled: {cross_zone}")
PYEOF

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
