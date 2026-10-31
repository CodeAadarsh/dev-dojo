#!/usr/bin/env bash
# Plants the findings template for the "Spot the Bottleneck" challenge.
# Idempotent — safe to re-run (overwrites findings.txt if unmodified).
set -euo pipefail

SLUG="06-spot-the-bottleneck"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/findings.txt" << 'EOF'
# Bottleneck Findings — Spot the Bottleneck

Fill in every section below. The verifier checks this file for specific keywords.
Remove every TODO line and replace with your analysis.

---

## Bottleneck

<!-- In 1-2 sentences: name the exact component that is the bottleneck and
     why it saturates under load. Be specific — name the component from the
     architecture diagram. -->

TODO


## Root cause

<!-- What design decision caused the bottleneck? Why does adding more API pods
     make things worse, not better? -->

TODO


## Fix

<!-- Describe the solution in concrete terms. Name the technology or pattern
     (e.g. read replicas, connection pooling, caching). Explain how queries
     would be routed differently after the fix. -->

TODO


## Trade-off

<!-- What does your fix cost? (replication lag, consistency guarantees,
     operational complexity, money?) Be specific. -->

TODO
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : read the architecture in brief.md, then fill in"
echo "                 findings.txt (all four sections, no TODOs remaining)."
echo
echo "Findings file  : $WORK/findings.txt"
echo
echo "Verify + flag  : bash courses/course-14-system-design/challenges/06-spot-the-bottleneck/verify.sh"
