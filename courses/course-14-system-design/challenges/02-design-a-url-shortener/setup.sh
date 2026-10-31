#!/usr/bin/env bash
# Plants the "Design a URL Shortener" starter into the work directory.
# Idempotent — re-running does not overwrite an existing design.md.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-design-a-url-shortener"
mkdir -p "$WORK"

# Only write the starter if the learner hasn't already created a design.md
if [ ! -f "$WORK/design.md" ]; then
cat > "$WORK/design.md" << 'MDEOF'
# URL Shortener Design

<!--
  Fill in every section. verify.sh checks:
    1. All five ## headings are present (Requirements, Capacity, API, Data Model, Scaling)
    2. The document mentions a sound ID scheme: base62, counter, or hash
  A strong answer explains *why* each choice fits the stated scale target.
-->

## Requirements

<!-- Functional requirements: what does the service do?
     Non-functional: latency SLA, availability target, scale (DAU or QPS). -->

## Capacity

<!-- Derive from your scale target:
     writes/sec, reads/sec, storage/year, bandwidth.
     Show your arithmetic. -->

## API

<!-- At minimum:
     POST /shorten  — request body, response body, status codes
     GET /{code}    — redirect target, status code (301 vs 302 and why)
     Include error cases. -->

## Data Model

<!-- Table schema or document shape.
     Which database and why.
     How are short codes generated? (base62 / counter / hash — name one and defend it) -->

## Scaling

<!-- Cache layer: what you cache, key, TTL.
     Horizontal read scaling.
     Write bottleneck at the ID generator: how do you solve it at 100K writes/sec?
     Hot-key handling (a viral URL hammering the cache). -->
MDEOF
fi

echo
echo "Work directory : $WORK"
echo
echo "Task           : fill every section of design.md so verify.sh passes."
echo
echo "  Required sections (level-2 headings):"
echo "    ## Requirements"
echo "    ## Capacity"
echo "    ## API"
echo "    ## Data Model"
echo "    ## Scaling"
echo
echo "  The Data Model section must mention one of: base62, counter, or hash."
echo
echo "Verify + flag  : bash courses/course-14-system-design/challenges/02-design-a-url-shortener/verify.sh"
