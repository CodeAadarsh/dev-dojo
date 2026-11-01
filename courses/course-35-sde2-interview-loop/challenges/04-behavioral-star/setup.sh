#!/usr/bin/env bash
# Plants the STAR stories template into the work directory.
# Idempotent: re-running overwrites stories.md if it still contains the
# placeholder markers (i.e., has not been filled in), but preserves user edits.
set -euo pipefail

SLUG="04-behavioral-star"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# Only write stories.md if it does not yet exist (preserve user progress).
if [ ! -f "$WORK/stories.md" ]; then
cat > "$WORK/stories.md" << 'MDEOF'
# STAR Stories

<!-- Instructions
  - Do not rename the ## Story headings.
  - Write your own content below each bold marker (replace the placeholder comment).
  - **Result:** MUST contain at least one number, percentage, or concrete metric.
  - Use "I", not "we", throughout Action.
-->

---

## Story 1: A Conflict

**Situation:**

<!-- Set the scene: team, project, timeline, what was at stake. One paragraph. -->

**Task:**

<!-- Your specific responsibility in this situation — what were you personally accountable for? -->

**Action:**

<!-- The steps *you* personally took to address the conflict. Use "I", not "we". -->

**Result:**

<!-- What changed because of your actions? Include at least one number: percentage, count, duration, currency, etc. -->

---

## Story 2: A Failure

**Situation:**

<!-- Describe the project or decision that went wrong. Be specific about what was happening. -->

**Task:**

<!-- What were you trying to accomplish or responsible for in that context? -->

**Action:**

<!-- What did *you* do — during the failure and in response to it? Name your specific steps. -->

**Result:**

<!-- What was the outcome, and what changed afterwards? Quantify where possible. -->
MDEOF

echo "  Created $WORK/stories.md"
else
  echo "  stories.md already exists — not overwritten."
fi

echo
echo "Work directory : $WORK"
echo
echo "Task           : fill in both stories in stories.md."
echo "                 Each story needs:"
echo "                   - the four markers: **Situation:** **Task:** **Action:** **Result:**"
echo "                   - at least one number in each Result section"
echo "                   - 'I' not 'we' in Action"
echo
echo "Verify + flag  : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/verify.sh"
