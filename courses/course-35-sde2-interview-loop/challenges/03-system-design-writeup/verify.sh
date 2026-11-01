#!/usr/bin/env bash
# Verifier for "System Design: Rate Limiter".
# Parses design.md with python3 and checks:
#   1. All six required section headings are present.
#   2. The document contains at least one numeric value with a unit
#      (capacity estimate must be quantitative).
#   3. The Trade-offs section contains an explicit trade-off statement.
# Prints the flag only when all checks pass.
set -uo pipefail

SLUG="03-system-design-writeup"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{rate_limiter_design_tradeoffs}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/design.md" ]    || fail "design.md not found in $WORK — run setup.sh first"

command -v python3 >/dev/null 2>&1 || fail "python3 not found in PATH"

python3 - "$WORK/design.md" << 'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = f.read()

# Strip HTML comments — the template embeds hints inside <!-- --> blocks.
# All checks run on stripped content so template placeholders never satisfy them.
content = re.sub(r'<!--.*?-->', '', raw, flags=re.DOTALL)

errors = []

REQUIRED_HEADINGS = [
    "## Requirements",
    "## Capacity Estimate",
    "## API Design",
    "## Data Model",
    "## High-Level Design",
    "## Trade-offs and Bottlenecks",
]

for heading in REQUIRED_HEADINGS:
    if heading not in content:
        errors.append(f"missing required heading: '{heading}'")

# Numeric capacity estimate — must appear outside HTML comments.
# Matches patterns like: 50000 req/s, 5ms, 10M keys, 50 GB, 1024 bytes, etc.
numeric_with_unit = re.search(
    r'\b\d[\d,\.]*\s*(?:req/s|rps|ms|us|ns|MB|GB|TB|GiB|TiB|MiB|KB|KiB|bytes?|keys?|M\s+keys?|K\s+req|million|billion)',
    content,
    re.IGNORECASE
)
if not numeric_with_unit:
    errors.append(
        "no numeric capacity estimate with a unit found outside HTML comments "
        "(e.g. '50000 req/s', '5ms', '10M keys', '50 GB')"
    )

# Explicit trade-off statement in the Trade-offs section — outside HTML comments.
tradeoff_section_match = re.search(
    r'## Trade-offs and Bottlenecks(.*?)(?=^## |\Z)',
    content,
    re.DOTALL | re.MULTILINE
)
if tradeoff_section_match:
    tradeoff_body = tradeoff_section_match.group(1)
    has_tradeoff = re.search(
        r'\b(trade-?off|versus|instead of|rather than|compared to|at the cost of)\b',
        tradeoff_body,
        re.IGNORECASE
    )
    if not has_tradeoff:
        errors.append(
            "Trade-offs section must contain an explicit trade-off statement "
            "(use 'trade-off', 'versus', 'instead of', or similar)"
        )
else:
    errors.append("Trade-offs and Bottlenecks section not found or empty")

# Minimum content check on comment-stripped text — rejects the bare template.
word_count = len(content.split())
if word_count < 120:
    errors.append(
        f"design.md appears incomplete ({word_count} words after stripping template comments — "
        "aim for at least 120 words of actual content)"
    )

if errors:
    for e in errors:
        print(f"  x  {e}")
    print()
    print("Fix the issues above and retry.")
    sys.exit(1)

print("  ok  all six required headings present")
print("  ok  numeric capacity estimate found")
print("  ok  explicit trade-off statement found")
print("  ok  document has sufficient content")
PYEOF

if [ $? -eq 0 ]; then
    echo
    echo "Design verified. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "design.md did not pass all checks — see above"
fi
