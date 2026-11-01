# Solution — Behavioral Interviews: STAR Stories with Quantified Impact

The flag is `KUBE{star_stories_show_impact}`.

Below are two complete example stories that pass the verifier. These use a backend/platform SDE context; adapt the specifics to your own experience. The structure matters more than the industry.

---

## Story 1: A Conflict — Engineering Timeline vs. Product Deadline

**Situation:**

Three weeks before our Q3 launch, the product manager requested a new real-time leaderboard feature to be included in the release. The frontend was already in QA and the backend team (three engineers including me) had capacity for roughly five more days of work. The requested feature would take at minimum eight to ten days to build safely.

**Task:**

I was the backend lead for that sprint and responsible for signing off on scope changes. I needed to either find a path to deliver the feature safely or make the case for descoping it with clear reasoning, not just a "no."

**Action:**

I ran a quick spike — about four hours — to prototype two implementation options: a naive polling approach that could ship in three days but would add ~200 ms latency per page load under load, and a WebSocket-based approach that was right architecturally but needed eight days. I quantified both in a one-page doc with a load test result and cost estimate. I presented this to the PM and engineering manager in a 30-minute meeting: "Here's what three days gets you, here's what eight days gets you, here's the data." I proposed shipping the polling version behind a feature flag, labeling it as a known tech-debt item with a Q4 payoff slot already booked.

**Result:**

The PM accepted the scoped version. We shipped on time. The polling implementation handled launch load without issue — p99 latency on that endpoint stayed under 180 ms at 3,000 concurrent users. The WebSocket refactor was delivered in Q4, reducing that latency to 22 ms. The approach also became the team's standard for scope conflicts: prototype, quantify, propose — not just escalate.

---

## Story 2: A Failure — Silent Data Loss in a Migration Script

**Situation:**

I was migrating 1.2 million user records from a legacy monolith database to a new service's Postgres schema. The migration was scheduled for a low-traffic weekend window.

**Task:**

I owned the migration script end-to-end: writing it, testing it on a staging copy, coordinating the cut-over, and monitoring the first 24 hours post-migration.

**Action:**

I wrote a Python migration script, tested it on a 50,000-row sample in staging, and ran it in production. The migration completed in under two hours with no reported errors. I signed off and closed the incident ticket.

Four days later, a customer support ticket revealed that approximately 4,200 records (0.35%) had their `preferences` JSON column silently truncated to an empty object `{}`. The root cause was a column-length mismatch between the source and destination schemas that my staging test had missed because the staging sample contained no rows with large preference objects.

I escalated immediately, drafted a rollback plan (we had a full backup), and ran a secondary script to restore the affected records from the backup. I wrote a post-mortem documenting the failure mode, the missed test coverage, and three process changes.

**Result:**

Affected records were fully restored within 6 hours of discovery — zero permanent data loss. The post-mortem introduced two changes that the team adopted: (1) migration staging tests must sample from the top 1% by row size in addition to random rows, and (2) all migration scripts must emit a row-level checksum comparison before committing. In the 18 months since, the team ran 7 more migrations with zero silent data issues.

---

## What makes these pass

**Story 1:**
- Situation: specific context, clear tension (scope vs. time).
- Task: ownership named explicitly.
- Action: concrete individual steps — spike, doc, meeting, proposal. "I" throughout.
- Result: numbers — 200 ms vs. 22 ms, 3,000 concurrent users, Q4 delivery. Quantified.

**Story 2:**
- Takes full ownership. Zero blame-shifting.
- Action during the failure and after both present.
- Result: 4,200 records restored in 6 hours (0 permanent data loss), 2 adopted process changes, 7 subsequent migrations with zero recurrence.

## Adapting for different companies

| Company | Behavioral dimensions they weight heavily |
|---------|------------------------------------------|
| Atlassian | Customer impact, team health, "play open" (transparency) |
| Uber | Technical depth, "go get it" initiative, data-driven decisions |
| Grafana | Open-source mindset, async communication, user trust |
| Razorpay | Speed, ownership, zero-to-one execution |
| Microsoft | Growth mindset, learning from failure, inclusive team behavior |

Swap the framing of your Result to match the company's dimensions: Atlassian wants to hear about customer impact, Razorpay wants to hear about speed, Microsoft wants to hear about what you changed in yourself.
