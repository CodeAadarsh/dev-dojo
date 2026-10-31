#!/usr/bin/env bash
# Plants reference materials for the Rate Limiter Design challenge.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="04-rate-limiter-design"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/algorithm-matrix.md" << 'EOF'
# Rate Limiting Algorithm Comparison Matrix

Fill in this table as you analyse each algorithm against the three constraints.
Replace each "?" with ✓ (satisfies), ✗ (fails), or a brief note.

| Algorithm      | Distributed? | Burst-tolerant? | O(1) memory/key? | Notes |
|----------------|:---:|:---:|:---:|-------|
| Fixed window   |  ?  |  ?  |  ?  |       |
| Sliding log    |  ?  |  ?  |  ?  |       |
| Leaky bucket   |  ?  |  ?  |  ?  |       |
| Token bucket   |  ?  |  ?  |  ?  |       |

---

## Constraint definitions (for reference)

**Distributed**: state that is meaningful only on a single pod fails when requests for
the same key hit different pods. Your implementation must use shared state (e.g., Redis)
or a gossip/merge protocol.

**Burst-tolerant**: a client that has been quiet for T seconds has "earned" up to
T × rate tokens of capacity. A single bursty request batch can consume that capacity
without being throttled. Contrast with a fixed-rate smoother that ignores accumulated
capacity entirely.

**O(1) memory/key**: storing a log of N recent request timestamps uses O(N) memory.
At 100 req/s per key, and 10 M keys, N grows large quickly. The algorithm must use
a constant-size state record per key — typically a counter + a timestamp (< 16 bytes).
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : analyse algorithm-matrix.md and identify the single algorithm"
echo "                 that satisfies all three constraints. Fill in the table."
echo "                 Then submit the flag in the platform."
echo
echo "Reference file : $WORK/algorithm-matrix.md"
echo
echo "No code required — this is a reasoning challenge."
