#!/usr/bin/env bash
# Verifier for "Variables and Outputs".
# Runs terraform init + apply with defaults, checks output and file,
# verifies the validation rule rejects an invalid filename, then destroys.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-variables-and-outputs"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{variables_outputs_validated}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found — run setup.sh first"
[ -f "$WORK/variables.tf" ] || fail "variables.tf not found — run setup.sh first"
[ -f "$WORK/outputs.tf" ] || fail "outputs.tf not found — run setup.sh first"

cd "$WORK"

echo "==> terraform init"
terraform init -input=false -upgrade || fail "terraform init failed"

echo "==> terraform apply (default variables)"
terraform apply -auto-approve || fail "terraform apply failed — run 'terraform validate' and 'terraform plan' for details"

TARGET="$WORK/output/greeting.txt"
[ -f "$TARGET" ] || fail "output/greeting.txt does not exist after apply — check that filename uses var.output_filename"

CONTENT=$(cat "$TARGET")
[ "$CONTENT" = "Hello, variables!" ] || fail "file content mismatch — expected 'Hello, variables!' got '$CONTENT'"

EXPECTED="$WORK/output/greeting.txt"
GOT=$(terraform output -raw result_path 2>/dev/null)
[ -n "$GOT" ] || fail "output 'result_path' is not defined or is empty — check outputs.tf"
[ "$GOT" = "$EXPECTED" ] || fail "result_path mismatch — expected '$EXPECTED' got '$GOT'"

echo "==> checking validation rule rejects non-.txt filenames"
terraform plan -var "output_filename=evil.csv" >/dev/null 2>&1 \
  && fail "validation rule missing — 'evil.csv' should have been rejected; add a validation block to output_filename"
echo "   validation rule works"

echo "==> terraform destroy"
terraform destroy -auto-approve || true

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
