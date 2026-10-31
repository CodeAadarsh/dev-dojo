#!/usr/bin/env bash
# Verifier for "Capacity Estimation: 100M-DAU Social Feed".
# Runs checker.py against the learner's answers.py; prints the flag only when
# all three estimates are within ±10% of the reference figures.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-capacity-estimation"
FLAG='KUBE{capacity_estimation_unlocked}'

fail() { echo "x  $1"; exit 1; }

[ -d "$WORK" ]        || fail "work directory missing — run setup.sh first"
[ -f "$WORK/answers.py" ] || fail "answers.py not found in $WORK — run setup.sh first"
[ -f "$WORK/checker.py" ] || fail "checker.py not found in $WORK — run setup.sh first"

cd "$WORK"

if python3 checker.py; then
    echo
    echo "Estimates verified. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "estimates are off — edit answers.py and retry (python3 checker.py)"
fi
