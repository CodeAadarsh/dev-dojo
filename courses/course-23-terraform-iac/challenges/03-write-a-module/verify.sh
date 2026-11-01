#!/usr/bin/env bash
# Verifier for "Write a Reusable Module".
# Runs terraform init + apply, checks the output file and root output, then destroys.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="03-write-a-module"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{reusable_module_built}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found — run setup.sh first"
[ -f "$WORK/outputs.tf" ] || fail "outputs.tf not found — run setup.sh first"
[ -f "$WORK/modules/filemaker/variables.tf" ] || fail "modules/filemaker/variables.tf not found — run setup.sh first"
[ -f "$WORK/modules/filemaker/main.tf" ] || fail "modules/filemaker/main.tf not found — run setup.sh first"
[ -f "$WORK/modules/filemaker/outputs.tf" ] || fail "modules/filemaker/outputs.tf not found — run setup.sh first"

cd "$WORK"

echo "==> terraform init"
terraform init -input=false -upgrade || fail "terraform init failed — check that module source path and provider block are correct"

echo "==> terraform apply"
terraform apply -auto-approve || fail "terraform apply failed — run 'terraform validate' and 'terraform plan' to see errors"

TARGET="$WORK/output/message.txt"
[ -f "$TARGET" ] || fail "output/message.txt does not exist after apply — check that the module creates the file at \${var.output_dir}/message.txt"

CONTENT=$(cat "$TARGET")
[ "$CONTENT" = "Hello from the module!" ] || fail "file content mismatch — expected 'Hello from the module!' got '$CONTENT'"

EXPECTED="$WORK/output/message.txt"
GOT=$(terraform output -raw created_path 2>/dev/null)
[ -n "$GOT" ] || fail "root output 'created_path' is not defined or is empty — check outputs.tf and ensure it references module.filemaker.file_path"
[ "$GOT" = "$EXPECTED" ] || fail "created_path mismatch — expected '$EXPECTED' got '$GOT'"

echo "==> terraform destroy"
terraform destroy -auto-approve || true

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
