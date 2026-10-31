#!/usr/bin/env bash
# Verifier for "Design a URL Shortener".
# Checks that design.md contains all five required headings and mentions
# a sound ID generation scheme. Prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-design-a-url-shortener"
FLAG='KUBE{url_shortener_designed}'

fail() { echo "x  $1"; exit 1; }

[ -d "$WORK" ]           || fail "work directory missing — run setup.sh first"
[ -f "$WORK/design.md" ] || fail "design.md not found in $WORK — run setup.sh first"

cd "$WORK"

pass=true

check_heading() {
    local heading="$1"
    if grep -qi "^## ${heading}" design.md; then
        echo "  ok section '## ${heading}' found"
    else
        echo "  x  section '## ${heading}' missing (must be a level-2 markdown heading)"
        pass=false
    fi
}

echo "Checking required sections..."
check_heading "Requirements"
check_heading "Capacity"
check_heading "API"
check_heading "Data Model"
check_heading "Scaling"

echo
echo "Checking ID scheme..."
if grep -qiE 'base62|counter|hash' design.md; then
    echo "  ok ID scheme mentioned (base62 / counter / hash)"
else
    echo "  x  ID scheme not mentioned — describe in '## Data Model' how short codes are generated"
    pass=false
fi

echo

if [ "$pass" = "true" ]; then
    echo "Design document passes all checks. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "design.md is incomplete — fix the missing items above and retry"
fi
