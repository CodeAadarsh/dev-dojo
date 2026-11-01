#!/usr/bin/env bash
# Plants the "Your First Resource" starter into the work directory.
# Idempotent — safe to re-run; does not delete any existing work.
set -euo pipefail

SLUG="01-first-resource"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/output"

cat > "$WORK/main.tf" << 'HCLEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Mission: fill in the two arguments below so Terraform creates
# output/hello.txt with the content "Hello, Terraform!\n".
#
# Hints:
#   filename — absolute path on disk. Use "${path.module}/output/hello.txt"
#              so the path is stable regardless of where you run terraform.
#   content  — the file body as a string. "\n" is a literal newline in HCL.

resource "local_file" "greeting" {
  filename = ""  # <- replace with the correct path expression
  content  = ""  # <- replace with the correct content string
}
HCLEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : fill in the local_file resource in main.tf"
echo "                 so that output/hello.txt is created with content:"
echo "                 'Hello, Terraform!' (plus trailing newline)"
echo
echo "Prerequisites  : terraform 1.5+"
echo "Quick check    : terraform version"
echo
echo "When ready     : bash courses/course-23-terraform-iac/challenges/01-first-resource/verify.sh"
