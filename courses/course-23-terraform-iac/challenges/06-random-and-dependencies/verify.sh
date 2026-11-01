#!/usr/bin/env bash
# Verifier for "Random Values and Explicit Dependencies".
# Sequence: init -> apply -> read outputs -> assert manifest contains random values
#           -> assert null_resource was created -> destroy -> flag.
set -uo pipefail

SLUG="06-random-and-dependencies"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{random_deps_in_order}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found in $WORK — run setup.sh first"

cd "$WORK"

echo "→ initialising..."
terraform init -input=false -upgrade >/dev/null 2>&1 || fail "terraform init failed — check internet connectivity for provider download"

echo "→ applying..."
terraform apply -auto-approve 2>&1 | tail -5 || fail "terraform apply failed — check your HCL syntax (terraform validate)"

[ -f "$WORK/deploy-manifest.txt" ] || fail "deploy-manifest.txt not found — check the filename in local_file.deploy_manifest"

# ── read outputs ──────────────────────────────────────────────────────────────
APP_NAME=$(terraform output -raw app_name 2>/dev/null)
BUILD_ID=$(terraform output -raw build_id 2>/dev/null)
POST_ID=$(terraform output -raw post_deploy_id 2>/dev/null)

[ -n "$APP_NAME" ] || fail "output.app_name is empty — is random_pet.app_name defined?"
[ -n "$BUILD_ID" ] || fail "output.build_id is empty — is random_id.build_id defined?"
[ -n "$POST_ID" ] || fail "output.post_deploy_id is empty — is null_resource.post_deploy created?"

# ── manifest content checks ───────────────────────────────────────────────────
grep -q "$APP_NAME" "$WORK/deploy-manifest.txt" || fail "deploy-manifest.txt does not contain the app_name ('$APP_NAME') — interpolate random_pet.app_name.id in local_file content"
grep -q "$BUILD_ID" "$WORK/deploy-manifest.txt" || fail "deploy-manifest.txt does not contain the build_id ('$BUILD_ID') — interpolate random_id.build_id.hex in local_file content"

# ── dependency order assertion ────────────────────────────────────────────────
# The manifest_content output captures what Terraform wrote; it must equal what
# is on disk, which confirms local_file resolved its random refs before null_resource ran.
MANIFEST_OUT=$(terraform output -raw manifest_content 2>/dev/null)
MANIFEST_FILE=$(cat "$WORK/deploy-manifest.txt")
[ "$MANIFEST_OUT" = "$MANIFEST_FILE" ] || fail "manifest_content output does not match deploy-manifest.txt — the file may have been written before random values were resolved"

# ── triggers check ────────────────────────────────────────────────────────────
# Verify the null_resource trigger references the manifest content (not FIXME)
grep -q "FIXME" "$WORK/main.tf" && fail "main.tf still contains FIXME stubs — fill in all three TODOs"

echo "→ cleaning up..."
terraform destroy -auto-approve >/dev/null 2>&1

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
