#!/usr/bin/env bash
# Verifier for "IRSA / Workload Identity — Scoped Pod Access".
# Parses serviceaccount.yaml and deployment.yaml with python3+pyyaml.
# Prints the flag only when all structural checks pass.
# Exit 0 = solved, Exit 1 = not yet.
set -euo pipefail

SLUG="01-irsa-workload-identity"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{irsa_not_node_wide_creds}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                        || fail "work directory missing — run setup.sh first"
[ -f "$WORK/serviceaccount.yaml" ]    || fail "serviceaccount.yaml not found — run setup.sh first"
[ -f "$WORK/deployment.yaml" ]        || fail "deployment.yaml not found — run setup.sh first"

python3 - << PYEOF
import sys, yaml

def fail(msg):
    print(f"x  {msg}")
    sys.exit(1)

with open("$WORK/serviceaccount.yaml") as f:
    sa = yaml.safe_load(f)

if not sa:
    fail("serviceaccount.yaml is empty or invalid YAML")

if sa.get("kind") != "ServiceAccount":
    fail(f"serviceaccount.yaml: kind must be ServiceAccount (found: '{sa.get('kind')}')")

sa_name = (sa.get("metadata") or {}).get("name", "")
if not sa_name:
    fail("serviceaccount.yaml: metadata.name is required")
if sa_name == "default" or sa_name.startswith("TODO"):
    fail(f"serviceaccount.yaml: name must not be 'default' or the stub placeholder (found: '{sa_name}')")

annotations = (sa.get("metadata") or {}).get("annotations") or {}
irsa_arn   = annotations.get("eks.amazonaws.com/role-arn", "")
wi_email   = annotations.get("iam.gke.io/gcp-service-account", "")

if not irsa_arn and not wi_email:
    fail("serviceaccount.yaml: add 'eks.amazonaws.com/role-arn' (IRSA) or 'iam.gke.io/gcp-service-account' (GKE WI) annotation")

if irsa_arn:
    if not str(irsa_arn).startswith("arn:aws:iam::"):
        fail(f"IRSA annotation must start with 'arn:aws:iam::' (found: '{irsa_arn}')")
    if ":role/" not in str(irsa_arn):
        fail(f"IRSA annotation must include ':role/<role-name>' (found: '{irsa_arn}')")
    ann_label = f"IRSA  eks.amazonaws.com/role-arn: {irsa_arn}"
else:
    if "@" not in str(wi_email) or ".iam.gserviceaccount.com" not in str(wi_email):
        fail(f"GKE WI annotation must look like '<name>@<project>.iam.gserviceaccount.com' (found: '{wi_email}')")
    ann_label = f"GKE WI  iam.gke.io/gcp-service-account: {wi_email}"

print(f"OK  ServiceAccount '{sa_name}' — kind verified")
print(f"OK  Annotation: {ann_label}")

with open("$WORK/deployment.yaml") as f:
    deploy = yaml.safe_load(f)

if not deploy:
    fail("deployment.yaml is empty or invalid YAML")

if deploy.get("kind") != "Deployment":
    fail(f"deployment.yaml: kind must be Deployment (found: '{deploy.get('kind')}')")

deploy_name = (deploy.get("metadata") or {}).get("name", "unnamed")
used_sa = (
    (deploy.get("spec") or {})
    .get("template", {})
    .get("spec", {})
    .get("serviceAccountName", "")
)

if not used_sa:
    fail("deployment.yaml: spec.template.spec.serviceAccountName is missing")
if used_sa == "default":
    fail("deployment.yaml: serviceAccountName must not be 'default' — that inherits node-wide credentials")
if used_sa != sa_name:
    fail(
        f"deployment.yaml: serviceAccountName '{used_sa}' does not match "
        f"the ServiceAccount name '{sa_name}' — they must be identical"
    )

print(f"OK  Deployment '{deploy_name}' — kind verified")
print(f"OK  serviceAccountName: '{used_sa}' matches ServiceAccount '{sa_name}'")
PYEOF

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
