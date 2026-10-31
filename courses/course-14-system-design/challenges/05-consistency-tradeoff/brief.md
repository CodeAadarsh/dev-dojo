# Strong vs. Eventual: Pick the Right Consistency Model

An architecture review ping lands in your DMs: *"We're running both the bank ledger and the social feed on the same Cassandra cluster with eventual consistency. Is that a problem?"*

Yes. One of those is a catastrophic consistency bug waiting to happen. The other is fine. Your job is to explain why, pick the correct model for each, and name the concrete failure mode you'd get if you picked wrong.

## The two services

Both services are part of the same fintech app. Both are under heavy load during market hours. Both are deployed across three availability zones.

### Service A — BankLedger

- Handles user account balances and inter-account transfers.
- `POST /transfer` deducts `amount` from the sender's balance and credits the receiver.
- Clients call `GET /balance` immediately after a transfer to confirm the deduction.
- Edge case that MUST NOT happen: a user has ₹1000 in their account, fires two concurrent `POST /transfer` requests of ₹800 each to different bank nodes. Under eventual consistency, both reads see the pre-deduction balance and both transfers are accepted — the account goes to ₹−600.
- Current SLA: 99.9% availability, P99 latency ≤ 200ms.

### Service B — TrendFeed

- Tracks per-post like and retweet counts for the social feed.
- `POST /like/{post_id}` increments a counter.
- `GET /likes/{post_id}` returns the current count.
- Edge case that is acceptable: user A sees a post with 10,014 likes; user B, in a different region, sees 10,013. They converge within ~200ms.
- Current SLA: 99.99% availability, P99 latency ≤ 50ms.

## Mission

For **each service**, answer:

1. Which CAP properties does the workload require (CP or AP)?
2. Which consistency model is correct: **strong (linearizable)** or **eventual**?
3. What is the exact failure mode if you choose the wrong model?

Then submit the flag that encodes both correct answers. The flag format is
`KUBE{<balance_answer>_for_<balance_service>_<like_answer>_for_<likes_service>}`.

The setup script plants `scenario.md` with additional data points. The solution walks through the full CAP analysis.

## Why this matters

Getting eventual consistency wrong in a ledger is a business-ending bug — it's not just data corruption, it is money created from nothing. Getting strong consistency wrong in a social feed makes your feed slower and less available than your competitors'. Both mistakes have happened in production at scale.

The asymmetry is important: you can tolerate a stale like count. You cannot tolerate a negative bank balance. The SLA numbers in the two services already hint at the answer — notice which one demands four nines of availability vs which one demands only three.
