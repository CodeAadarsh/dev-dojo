#!/usr/bin/env bash
# Plants the "Rate Limiter Design" template into the work directory.
# Idempotent — re-running does NOT overwrite an existing design.md so
# your work is preserved.
set -euo pipefail

SLUG="03-system-design-writeup"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── design.md template — only written if it does not exist ──────────────────
if [ ! -f "$WORK/design.md" ]; then
cat > "$WORK/design.md" << 'MDEOF'
# Rate Limiter — System Design

> Fill in each section. The verifier checks that all six headings are present,
> that you have at least one numeric capacity estimate with a unit, and that
> you include an explicit trade-off statement in the Trade-offs section.
> Delete these instructions before submitting.

## Requirements

### Functional
- <!-- e.g. limit requests per user / IP / API key with configurable window -->

### Non-Functional
- <!-- latency, availability, accuracy, consistency requirements -->

### Out of Scope
- <!-- billing, auth, reporting, etc. -->

## Capacity Estimate

<!-- Derive from the spec: 50 000 req/s peak, 10M unique keys, <5ms p99 overhead.
     Show your arithmetic. Include at least one number with a unit. -->

## API Design

<!-- What does the caller invoke? What does it return?
     e.g. check_and_consume(key, limit, window_seconds) -> (allowed, remaining, reset_at) -->

## Data Model

<!-- What is stored per key? Which Redis data structure?
     e.g. HASH {count: N, last_refill: T} for token bucket
          SORTED SET of timestamps for sliding window log -->

## High-Level Design

<!-- Where does the rate limiter sit? What algorithm?
     How does distributed counting work (atomic ops, Lua script)?
     Failure mode: fail-open vs fail-closed? -->

## Trade-offs and Bottlenecks

<!-- At least one explicit trade-off (use the word "trade-off", "versus", or "instead of").
     At least one bottleneck analysis: what breaks at 10× scale?
     e.g. "Token bucket versus sliding window log: ..."
          "At 500K req/s, the Redis write path becomes the bottleneck because ..." -->
MDEOF
fi

echo
echo "Work directory : $WORK"
echo
echo "Task           : fill in design.md covering all six required sections."
echo "                 The verifier checks structure + a numeric estimate + a trade-off."
echo
echo "Files:"
echo "  design.md  — template; fill it in"
echo
echo "Verify + flag  : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/verify.sh"
