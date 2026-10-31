# Pick the Right Rate-Limiting Algorithm

The platform team opens a Jira ticket: *"Our public API is being abused by bursty clients and one bad actor can degrade service for everyone. We need rate limiting on the gateway — 100 req/s per API key, with room for short spikes. The API tier runs across 20 pods; we can use a shared Redis for coordination."*

An intern suggests a sliding-log algorithm. A senior engineer says token bucket. The tech lead asks for a written justification before any code is written.

You are the tech lead.

## Constraints

The winning algorithm must satisfy **all three** simultaneously:

| # | Constraint | Details |
|---|------------|---------|
| 1 | **Distributed** | Rate limiting state must work correctly when spread across 20 stateless API pods. Counters cannot be pod-local. |
| 2 | **Burst-tolerant** | A client that has been idle for 5 seconds should be allowed to fire up to 3× its average rate in a short spike, then be throttled back. The algorithm must model "saved-up capacity." |
| 3 | **Low memory** | The system tracks 10 million API keys. State per key must be measurable in a handful of bytes — not proportional to the number of requests in a recent window. |

## The four candidates

You must evaluate each of these — no algorithm gets a free pass:

- **Fixed window** — count requests per discrete time bucket (e.g., 100/min).
- **Sliding log** — keep a timestamped log of every recent request; evict entries outside the window.
- **Leaky bucket** — model a bucket that leaks at a constant rate; incoming requests add to the queue.
- **Token bucket** — tokens accumulate at a fixed rate up to a cap; each request consumes one token.

## Mission

Work through the tradeoff matrix (reference `algorithm-matrix.md` planted by `setup.sh`). Identify the **single algorithm** that satisfies all three constraints. Every incorrect algorithm fails on at least one — name which constraint it violates and why.

When you have your answer, submit the flag that encodes it. The flag format is `KUBE{<answer>}` where `<answer>` describes the winning algorithm and the key property that makes it burst-tolerant with O(1) memory.

The solution walks through the full analysis if you want to check your reasoning.

## Why this is a design decision, not a trivia question

Picking the wrong algorithm shows up in production metrics, not in unit tests:

- **Fixed window** lets a client fire 200 requests in 2 seconds (100 at the end of window N, 100 at the start of window N+1) — double the stated limit — for any client that learns your window boundary.
- **Sliding log** is memory-accurate but at 10M keys × 100 req/s the log grows to gigabytes in Redis before TTL cleanup catches up.
- **Leaky bucket** at exactly 100 req/s never allows accumulated capacity — a client that's been idle and fires 300 legitimate requests in a flash sale sees 200 queued with growing latency, not 300 accepted.

Real implementations — AWS API Gateway, Stripe's rate limiter, GitHub's API — converge on one answer for these constraints.
