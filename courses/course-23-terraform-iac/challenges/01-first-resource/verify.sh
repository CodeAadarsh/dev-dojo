#!/usr/bin/env bash
# Verifier for "Your First Resource".
# Runs terraform init + apply, checks the output file, destroys, prints flag.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-first-resource"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{local_file_resource_applies}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found in $WORK — run setup.sh first"

cd "$WORK"

echo "==> terraform init"
terraform init -input=false -upgrade || fail "terraform init failed — check that main.tf has a valid required_providers block"

echo "==> terraform apply"
terraform apply -auto-approve || fail "terraform apply failed — run 'terraform validate' and 'terraform plan' to see errors"

TARGET="$WORK/output/hello.txt"
[ -f "$TARGET" ] || fail "output/hello.txt does not exist after apply — check the filename argument in main.tf"

CONTENT=$(cat "$TARGET")
[ "$CONTENT" = "Hello, Terraform!" ] || fail "content mismatch — expected 'Hello, Terraform!' got '$CONTENT'"

echo "==> terraform destroy"
terraform destroy -auto-approve || true

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
