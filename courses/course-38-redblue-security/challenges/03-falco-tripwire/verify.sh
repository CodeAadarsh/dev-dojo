#!/usr/bin/env bash
set -uo pipefail

RULE_FILE="/tmp/custom-falco-rule.yaml"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: Falco Tripwire"

# Check the rule file exists
[ -f "$RULE_FILE" ] || fail "Rule file not found at $RULE_FILE — write your custom Falco rule there first"

# Check it's not empty
[ -s "$RULE_FILE" ] || fail "$RULE_FILE is empty"

# Check required fields are present
grep -q "rule:" "$RULE_FILE" || fail "Missing required field 'rule:' in $RULE_FILE"
grep -q "condition:" "$RULE_FILE" || fail "Missing required field 'condition:' in $RULE_FILE"
grep -q "output:" "$RULE_FILE" || fail "Missing required field 'output:' in $RULE_FILE"
grep -q "priority:" "$RULE_FILE" || fail "Missing required field 'priority:' in $RULE_FILE"

# Check the condition references container or container.id
grep -q "container" "$RULE_FILE" || fail "Rule condition must reference 'container' (the macro or container.id field)"

# Check the condition references ls or proc.name
grep -qE '(proc\.name|execve)' "$RULE_FILE" || fail "Rule condition must reference proc.name or evt.type = execve to detect process execution"

# Check priority is a valid value
grep -qE "priority:\s*(WARNING|ERROR|CRITICAL|INFO|DEBUG|NOTICE|ALERT|EMERGENCY)" "$RULE_FILE" || \
  fail "priority must be one of: WARNING, ERROR, CRITICAL, INFO, DEBUG, NOTICE, ALERT, EMERGENCY"

echo ""
echo "==> Custom Falco rule validated. Structure is correct."
echo "    The 3 simulated alerts show rule 'Terminal shell', 'Read sensitive file', and 'Package management'."
echo "    Your rule would catch the pre-attack reconnaissance."
echo ""
echo "KUBE{falco_sees_the_shell_spawn}"
