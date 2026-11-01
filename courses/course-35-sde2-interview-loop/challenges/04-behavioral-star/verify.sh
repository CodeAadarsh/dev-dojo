#!/usr/bin/env bash
# Verifier for "Behavioral Interviews: STAR Stories with Quantified Impact".
# Parses stories.md with python3 (no packages) and prints the flag only when:
#   - at least 2 "## Story N:" sections exist
#   - each of the first two stories contains all four STAR markers
#   - each Result section contains at least one digit (quantified result)
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="04-behavioral-star"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{star_stories_show_impact}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/stories.md" ]   || fail "stories.md not found — run setup.sh first"

cd "$WORK"

python3 - << 'PYEOF'
import re, sys

with open('stories.md', 'r') as fh:
    content = fh.read()

# Split on ## Story headers; keep only segments that start with one.
raw_parts = re.split(r'(?=^## Story)', content, flags=re.MULTILINE)
stories = [p.strip() for p in raw_parts if re.match(r'^## Story', p.strip())]

if len(stories) < 2:
    print('✗ Need at least 2 story sections starting with "## Story N:" — found', len(stories))
    sys.exit(1)

MARKERS = ['**Situation:**', '**Task:**', '**Action:**', '**Result:**']

def content_after(marker, text):
    """Return everything after the marker up to the next marker or end."""
    idx = text.find(marker)
    if idx == -1:
        return None
    after = text[idx + len(marker):]
    # Trim at the next STAR marker so we don't bleed into the next section.
    for other in MARKERS:
        if other == marker:
            continue
        cut = after.find(other)
        if cut != -1:
            after = after[:cut]
    return after.strip()

errors = []

for i, story in enumerate(stories[:2]):
    n = i + 1
    for marker in MARKERS:
        if marker not in story:
            errors.append(f'Story {n}: missing marker "{marker}"')

    if not errors:
        result_text = content_after('**Result:**', story)
        # Reject unfilled template: no content at all (or only HTML comments).
        stripped = re.sub(r'<!--.*?-->', '', result_text or '', flags=re.DOTALL).strip()
        if not stripped:
            errors.append(
                f'Story {n}: **Result:** section is empty — fill it in with your outcome.'
            )
        elif not re.search(r'\d', stripped):
            errors.append(
                f'Story {n}: **Result:** must include at least one number '
                f'(e.g. "reduced alerts by 40%", "saved 3 hours/week"). '
                f'Found no digits in: {stripped[:120]!r}'
            )

if errors:
    for e in errors:
        print('✗', e)
    sys.exit(1)

print('ok  Story 1: all four STAR markers present, Result quantified.')
print('ok  Story 2: all four STAR markers present, Result quantified.')
sys.exit(0)
PYEOF

if [ $? -eq 0 ]; then
    echo
    echo "Both STAR stories verified. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "stories.md has issues — fix them and retry"
fi
