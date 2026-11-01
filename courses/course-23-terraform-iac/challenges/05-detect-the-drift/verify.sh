#!/usr/bin/env bash
# Verifier for "Detect and Fix Configuration Drift".
# Sequence: init -> apply -> mutate out-of-band -> plan (assert exit 2) ->
#           apply (restore) -> assert managed content -> destroy -> flag.
set -uo pipefail

SLUG="05-detect-the-drift"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{terraform_drift_is_real}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.tf" ] || fail "main.tf not found in $WORK — run setup.sh first"

cd "$WORK"

echo "→ initialising..."
terraform init -input=false -upgrade >/dev/null 2>&1 || fail "terraform init failed — check internet connectivity for provider download"

echo "→ applying initial config..."
terraform apply -auto-approve >/dev/null 2>&1 || fail "terraform apply failed — check your resource definition in main.tf"

[ -f "$WORK/app-config.txt" ] || fail "app-config.txt not created after apply — check the filename in your local_file resource"
grep -q "environment = production" "$WORK/app-config.txt" || fail "app-config.txt does not contain 'environment = production' — check your content value"

echo "→ simulating out-of-band mutation..."
printf 'environment = corrupted\nlog_level = debug\nreplicas = 1\n' > "$WORK/app-config.txt"

echo "→ detecting drift with terraform plan -detailed-exitcode..."
PLAN_EXIT=0
terraform plan -detailed-exitcode >/dev/null 2>&1 || PLAN_EXIT=$?
[ "$PLAN_EXIT" -eq 2 ] || fail "expected terraform plan exit code 2 (drift detected), got $PLAN_EXIT — is your resource content set to the managed value?"

echo "→ restoring via apply..."
terraform apply -auto-approve >/dev/null 2>&1 || fail "terraform apply (restore) failed"

grep -q "environment = production" "$WORK/app-config.txt" || fail "apply did not restore managed content — got: $(cat "$WORK/app-config.txt")"

echo "→ cleaning up..."
terraform destroy -auto-approve >/dev/null 2>&1

echo ""
echo "All checks passed. Submit this flag in the platform:"
echo ""
echo "    $FLAG"
