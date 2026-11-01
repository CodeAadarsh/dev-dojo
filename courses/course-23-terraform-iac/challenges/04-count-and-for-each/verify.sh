#!/usr/bin/env bash
# Verifier for "Iterate With for_each".
# Runs terraform apply, checks that exactly 3 per-key files exist with the
# expected content, asserts service_count output == 3, then destroys.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="04-count-and-for-each"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{for_each_maps_the_world}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found in $WORK — run setup.sh first"

cd "$WORK"

echo "→ initialising..."
terraform init -input=false -upgrade >/dev/null 2>&1 || fail "terraform init failed — check internet connectivity for provider download"

echo "→ applying..."
terraform apply -auto-approve >/dev/null 2>&1 || fail "terraform apply failed — check your HCL syntax (terraform validate)"

# ── file existence checks ─────────────────────────────────────────────────────
for svc in auth-service payment-service catalog-service; do
  FILE="$WORK/output/${svc}.txt"
  [ -f "$FILE" ] || fail "output/${svc}.txt not found — check filename in your for_each resource"
done

# ── content checks ────────────────────────────────────────────────────────────
check_content() {
  local key="$1"
  local desc="$2"
  local file="$WORK/output/${key}.txt"
  grep -q "Service: ${key}" "$file" || fail "${key}.txt: expected 'Service: ${key}' — got: $(head -1 "$file")"
  grep -q "Description: ${desc}" "$file" || fail "${key}.txt: expected 'Description: ${desc}' — got: $(sed -n '2p' "$file")"
}

check_content "auth-service"    "Handles authentication and token issuance"
check_content "payment-service" "Processes transactions and refunds"
check_content "catalog-service" "Manages product listings and inventory"

# ── output checks ─────────────────────────────────────────────────────────────
FILE_COUNT=$(find "$WORK/output" -name "*.txt" | wc -l | tr -d ' ')
[ "$FILE_COUNT" -eq 3 ] || fail "expected 3 .txt files in output/, found $FILE_COUNT"

TF_COUNT=$(terraform output -raw service_count 2>/dev/null)
[ "$TF_COUNT" = "3" ] || fail "output.service_count should be 3, got '$TF_COUNT'"

echo "→ destroying..."
terraform destroy -auto-approve >/dev/null 2>&1

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
