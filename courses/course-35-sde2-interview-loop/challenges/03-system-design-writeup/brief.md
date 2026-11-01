# System Design: Rate Limiter

A staff engineer at Razorpay is reviewing your design doc before the full-panel design interview. She comments: *"Your design doesn't say what you're trading off. 'Use Redis' is a component choice, not a design decision. What are you giving up? What would break first under load? What would you do differently at 10× scale?"*

This drill is a 45-minute design round in writing. You'll produce a design document in `design.md` that a senior engineer could actually review — covering the full spectrum from requirements to trade-offs.

The verifier checks structure, not style. It will reject your doc if required sections are missing, if there's no numeric capacity estimate, or if there's no explicit trade-off statement. The rest is your thinking.

## Context

`setup.sh` creates your work directory with a structured `design.md` template:

```
~/.kube-dojo-work/03-system-design-writeup/
└── design.md     # template with section headings; fill each one out
```

## Prerequisites

Python 3 in PATH. No packages.

## The Prompt

> **Design a distributed rate limiter.**
>
> The system will be used as a shared infrastructure service at a company with 500 engineers. It must support per-user, per-IP, and per-API-key rate limiting with configurable limits. The payment API calls it on every transaction.
>
> Target scale: **50 000 requests/second** peak, **10 million** unique rate-limit keys tracked at any time, **99.9% availability**, and latency overhead of **< 5 ms p99** added to any request.

You have 45 minutes. Set your timer. Open `design.md` and fill in every section.

## What SDE-2 Means in a Design Round

An SDE-1 design describes *what* to build. An SDE-2 design explains *why* this choice and *what you're giving up*. Interviewers at Razorpay/PhonePe/Uber assess SDE-2 candidates on:

1. **Structured thinking under time pressure.** Can you cover all six areas in 45 minutes without prompting?
2. **Capacity fluency.** Do your numbers make sense? Are they derived, not guessed?
3. **Trade-off articulation.** "We chose Token Bucket over Leaky Bucket because..." is a design statement. "We used Redis" is not.
4. **Failure mode awareness.** What breaks under network partition? Under Redis OOM? Under a thundering herd?

## Required Sections (the verifier checks these)

Your `design.md` must contain all of the following headings (exact wording):

```
## Requirements
## Capacity Estimate
## API Design
## Data Model
## High-Level Design
## Trade-offs and Bottlenecks
```

The verifier also checks that:
- The document contains at least one number with a unit (e.g. `50000 req/s`, `5 ms`, `10M keys`) — your capacity section must be quantitative.
- The document contains at least one explicit trade-off statement (the phrase `trade-off` or `tradeoff` or `versus` or `instead of` appears in the Trade-offs section).

## Suggested Structure Per Section

**Requirements (2–3 min):** Functional: what must the system do? Non-functional: latency, availability, accuracy targets. Out of scope: billing, multi-tenancy auth, reporting.

**Capacity Estimate (3–5 min):** Derive from the spec. 50K req/s × 5 ms budget — what does that mean for a Redis call? At 10M keys, how much memory does a token-bucket entry need? What's the storage footprint?

**API Design (2 min):** Not a REST tutorial. Just: `check_and_consume(key, limit, window) -> (allowed: bool, remaining: int, reset_at: timestamp)`. What does the caller need?

**Data Model (3–5 min):** What do you store per key? How do you represent the algorithm state (token count + last refill time, or a sliding window list of timestamps)? What's the Redis data structure?

**High-Level Design (10–15 min):** Where does the rate limiter sit (client-side SDK, API gateway, sidecar, standalone service)? What algorithm — fixed window, sliding window log, token bucket, leaky bucket? How does the distributed counter work? What's the failure mode when the limiter is unavailable (fail-open vs fail-closed)?

**Trade-offs and Bottlenecks (5 min):** This is the section that levels you. At least one explicit trade-off: "Token bucket is memory-efficient but allows bursts up to limit at the start of each window — for the payment API, this is acceptable because..." At least one bottleneck: what breaks at 10× scale? What's your headroom?

## Debugging Common Design Mistakes

**"I used Redis."** That's a component. State *what Redis data structure*, *why that structure*, and *what operation*. For a token bucket: `HSET key count N last_refill T` and atomic update via Lua script. For a sliding window: `ZADD key timestamp member` + `ZCOUNT key (now-window) now`.

**"99.9% availability."** What's your Redis deployment for that? Single instance is ~99.7% (roughly one downtime event per month). You need at least a Redis Sentinel or Cluster setup, and a decision on what to do when the limiter is unavailable — fail-open (allow all traffic) vs fail-closed (block all traffic). State which you'd choose for a payment API and why.

**Missing race condition analysis.** The naive read-then-write is not atomic. Two concurrent requests reading `count=99` both see headroom and both increment to 100 — now you're at 101. The fix: Redis Lua script (atomic), or Redis `INCR` + `EXPIRE`, or optimistic locking. State which you chose and why.

**No failure mode.** What happens when your rate limiter adds > 5ms? Circuit breaker pattern: if the rate limiter call itself starts failing or timing out, fall back to a local in-memory counter with a grace period. State this explicitly.

## Verify

```bash
bash courses/course-35-sde2-interview-loop/challenges/03-system-design-writeup/verify.sh
```

Required sections present + numeric estimate + explicit trade-off → flag printed.
