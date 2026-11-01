# Company-Specific Prep

> **Module 05 · Course 35** — Three months of LeetCode and system-design practice, then the first Grafana Labs round opens with a live Prometheus query debug. The interviewer's post-round slack: *"Strong fundamentals, never used our product."* Loop ended there. Tailoring is not an optional polish step — it is table stakes at Tier-1.

You are targeting Grafana Labs, Uber, Atlassian, Razorpay, PhonePe, and Microsoft. These are six genuinely different companies with different hiring philosophies, different signal hierarchies, and different "what SDE-2 means here" definitions. The mistake is treating them as interchangeable wrappers around the same leetcode interview.

This module is a company-by-company breakdown of what each organisation actually tests, what they are looking for at SDE-2, and how to convert your existing work experience into their vocabulary.

---

## Reading the job description as a signal

Before anything else: the JD is the brief, not marketing copy.

Every JD is a prioritised list of what the team currently needs. Parse it this way:

1. **First paragraph / headline** — the team's pain point. Not "we're building great products" — what is actually broken or scaling.
2. **Required bullets** — the non-negotiables. If they ask for "experience with distributed tracing," a blank here is a hard no.
3. **"Nice to have"** — where you differentiate. If you have three of four, lead with those three.
4. **Stack callouts** — signals about internal systems. "Experience with Prometheus/Grafana" means the team owns observability; "experience with UPI or payment systems" means they are in the hot path.

Cross-reference the JD against your story bank (which you built in Module 04) and identify the one-to-two story slots that map most directly. That is your customisation surface.

---

## Grafana Labs

**What the company is.** Grafana Labs is an OSS-first remote company. The product line is the LGTM stack: Loki (logs), Grafana (dashboards), Tempo (traces), Mimir (metrics at scale). Revenue is from Grafana Cloud (hosted LGTM) and enterprise licenses. Their engineering blog and the GitHub repos are their public identity.

**What they test at SDE-2.**

| Round | Focus | Signal they want |
|-------|-------|-----------------|
| Take-home or pair coding | Real-world feature or debugging scenario, often touching metrics/logs/tracing concepts | Production thinking, not toy code |
| System design | Observability infrastructure (e.g., "design a multi-tenant metrics ingestion system") | You understand cardinality, retention, fanout |
| Behavioral / async round | Written async response to a scenario, or a structured culture-fit round | Written clarity, independent judgment |

The differentiated signal at Grafana is **product depth**. You are expected to have used Grafana, Prometheus, and Loki before walking in. If you run the SAP observability stack or have any LGTM exposure from your current role, that is a direct hit.

**Prep actions.**

- Run a Grafana + Prometheus + Loki stack locally (Docker Compose, one evening). Create a dashboard. Fire an alert. Read the alert rule syntax.
- Read the [Grafana blog](https://grafana.com/blog/) — focus on engineering posts about Mimir, Tempo, and Grafana 10+ architecture.
- Watch GrafanaCON talks on YouTube — the ones by their staff engineers on cardinality, exemplars, and continuous profiling signal what they care about internally.
- Browse open issues in [`grafana/grafana`](https://github.com/grafana/grafana) and [`grafana/mimir`](https://github.com/grafana/mimir). You do not need an open PR, but being able to say "I looked at issue #XXXX and understood the trade-off" is the kind of signal that lands.

**Remote/async tailoring.** Grafana is fully distributed. Their hiring process itself is often async: a written screen, a take-home, then video rounds. Your written communication is evaluated from your first email. Keep responses concise, structured, and on-time. In behavioral rounds, demonstrate that you work well without synchronous oversight — show examples of unblocking yourself, writing proposals instead of setting up meetings, and making documented decisions.

**Story slots.** Lead with observability-native stories. At SAP: the 100 GB/day LGTM pipeline is a direct hit. Frame it as "we had X cardinality problem, here is how I debugged it using the metrics layer, here is what I changed." If you do not have a Grafana story, the next best is any story about debugging production systems at scale using telemetry.

---

## Uber

**What the company is.** Uber is a global ride/delivery/freight marketplace operating at a scale that makes most "at scale" stories look like rounding errors: 100M+ rides/day, real-time matching, geospatial indexing at millisecond latency, global fault tolerance. Their India engineering office (Bengaluru) works on core platform, maps, and driver-side infrastructure.

**What they test at SDE-2.**

| Round | Focus | Signal they want |
|-------|-------|-----------------|
| Coding 1–2 | Typically hard algorithmic — graphs, DP, priority queues | Clean O(n log n) or better, explained clearly |
| System design | Real-time or large-scale systems — "design Uber Surge," "design a rate limiter for 50M RPS" | Trade-offs, not textbook answers |
| Behavioral | Scope, ownership, cross-team impact | Acting beyond your title |

The differentiated signal at Uber is **scale reasoning**. When you say "we handled 10k requests per second," the Uber interviewer is thinking "we handle 1M." They want to see that your mental model of a system includes the numbers — not that you guessed, but that you derived them and know where the bottlenecks appear.

**Prep actions.**

- Read the [Uber Engineering Blog](https://eng.uber.com/) — posts on Schemaless, H3 geospatial indexing, Peloton (job scheduler), Ringpop (distributed ring), and their observability stack are the canonical references.
- For system design: be fluent in consistent hashing, distributed rate limiting (token bucket + Redis Cluster), and geospatial indexing (H3 or geohash). For each concept, derive the numbers: at 50M RPS, how many Redis nodes? What is the memory footprint of 1M geohashes?
- Coding: Uber typically goes hard on graph problems (shortest path variants, topological sort, network flow) and priority queue problems. Practice these specifically — not randomly.

**Story tailoring.** Lead with stories about systems you made faster, more reliable, or more scalable — and always lead with the number. "Reduced p99 latency by 40%," "zero rollbacks across 18 months of weekly deploys," "identified a memory leak that was causing 10% more pods to OOM per day." If the story is about the SAP log pipeline: frame it as throughput, reliability, and zero-downtime. Those are Uber values.

---

## Atlassian

**What the company is.** Atlassian makes Jira, Confluence, Bitbucket, and Trello. They are values-driven to an unusual degree for a large company — their values are genuinely embedded in the interview process, not just the careers page. They run a "Team Anywhere" model (distributed/remote-first). The Bengaluru office is a full engineering site, not a satellite.

**What they test at SDE-2.**

| Round | Focus | Signal they want |
|-------|-------|-----------------|
| Values / behavioral | "Open company no bullshit," "Play as a team," "Don't #@!% the customer" | Stories that embody a specific value, not generic ones |
| Coding | Medium to Hard — clean code, testability, edge cases | Craft — readability and maintainability as much as correctness |
| System design | Cloud-native distributed systems (ACE — Atlassian Cloud Ecosystem) | Trade-off reasoning, SLA reasoning, operability |

The differentiated signal at Atlassian is **values alignment + craft**. They look for engineers who write code they are proud of and who actively make their teams better. "I fixed it and moved on" is a weak story. "I fixed it, wrote the postmortem, added the test, and mentored the person who introduced the bug" is the Atlassian story.

**Atlassian values and how to map your stories.**

| Value | What it means in an interview | Story angle |
|-------|------------------------------|------------|
| Open company, no bullshit | Transparency — you surfaced bad news early, you disagreed and committed | Dissent with evidence |
| Build with heart and balance | Sustainable engineering, long-term thinking | Choosing boring tech, writing the RFC before the code |
| Don't #@!% the customer | Customer obsession — you traced a complaint to a root cause in the system | Production incident → customer impact → fix → prevention |
| Play as a team | Across-team collaboration, giving credit | Stories involving multiple teams or mentoring |
| Be the change you seek | Initiative — you improved something you were not asked to | Unblocked a team by writing a missing tool, rewrote a shared doc |

**Prep actions.**

- Read the [Atlassian Engineering blog](https://www.atlassian.com/engineering) — they write about their infrastructure, incident culture, and developer tooling.
- Know their main products from a user and infrastructure perspective. "How would you design Jira's comment system for 1M concurrent users?" is a real category of question.
- Craft is tested in code review format in some loops — clean up your GitHub projects before applying.

---

## Razorpay / PhonePe

These two are grouped because the prep overlaps heavily: both are Indian fintech companies in the payments space, both are at scale (PhonePe: 500M+ registered users, Razorpay: 8M+ businesses), and both care deeply about correctness, idempotency, and regulatory compliance.

**What they test at SDE-2.**

| Round | Focus | Signal they want |
|-------|-------|-----------------|
| Coding | Graphs, DP, strings — Medium/Hard | Standard SDE-2 bar, clean code |
| System design | Payment flows, idempotency, double-spend prevention, settlement, reconciliation | Financial correctness, not just scale |
| Domain round (some loops) | UPI architecture, PCI-DSS, RBI regulations | You understand the constraints |
| Behavioral | Ownership in high-stakes production systems | Zero-bug mindset, on-call ownership |

The differentiated signal here is **payments domain depth**. You do not need to have worked at a payments company, but you need to understand why payments systems are harder than CRUD systems.

**Domain concepts to know.**

- **UPI (Unified Payments Interface):** the NPCI-operated real-time payment rail. Architecture: Payer PSP → NPCI switch → Payee PSP. VPA (Virtual Payment Address) resolution. Know what happens during a P2P transaction at each step.
- **Idempotency:** every payment API call must be safe to retry. Idempotency keys in the request header, idempotent database writes (INSERT IGNORE or ON CONFLICT DO NOTHING + check existing state). Know why idempotency is not the same as exactly-once delivery.
- **Double-entry bookkeeping:** every payment is a debit on one account and a credit on another. Ledger tables never have a balance column — balance is always derived. Know why.
- **Reconciliation:** daily batch job that compares your internal records against the payment network's records. Discrepancies = money differences. Know the failure modes: timing gaps, partial failures, network timeouts.
- **PCI-DSS:** never store raw card numbers. Tokenisation. The 12 requirements at a high level.

**Peak traffic in India:** Diwali, Dhanteras, IPL finals, salary day (1st/25th of month). Design for 10× normal peak. PhonePe went through 2.5 Bn transactions on Diwali 2023.

**Story tailoring.** If you do not have payments experience, frame your production reliability stories around correctness and safety: "we could not afford to double-count a log event because it fed billing." Any story with money, billing, or metering in it lands at a fintech interview. At SAP AI Core you are metering LLM usage — that is a billing-adjacent system.

---

## Microsoft

**What the company is.** Microsoft India (Hyderabad) is one of the largest engineering sites outside Redmond. Products range from Azure to Office to Xbox. At SDE-2 level they are looking for strong CS fundamentals, "growth mindset," and cross-group collaboration — the three themes that appear in every Microsoft loop regardless of team.

**What they test at SDE-2.**

| Round | Focus | Signal they want |
|-------|-------|-----------------|
| Coding 1–2 | Medium, occasionally Hard — standard patterns (trees, graphs, arrays, DP) | Clean, correct, communicated — not just fast |
| System design | Cloud-native, Azure-oriented if you are targeting Azure teams | Scalable, operable, cost-aware |
| Behavioral 1–2 | Microsoft Leadership Principles: "Model-Coach-Care", "Clarity-Energy-Succeed" | STAR with growth mindset framing |
| Manager / culture | Impact on the team, cross-group collaboration | "Am I a multiplier?" |

The differentiated signal at Microsoft is **fundamentals + growth mindset**. They do not expect domain depth the way Grafana does. They want to see that you learn fast, communicate clearly, and make the people around you better. The "learn it all, not know it all" framing is not just a Satya quote — it shows up in debrief notes.

**Microsoft Leadership Principles (the ones that matter in the loop).**

| Principle | Story angle |
|-----------|------------|
| Model-Coach-Care | Mentoring a junior, running a good 1-on-1, giving hard feedback kindly |
| Clarity: Create clarity in a world of ambiguity | You wrote the RFC, you defined the success criteria, you ran the alignment meeting |
| Energy: Generate energy in others | You lifted team morale during a hard sprint, ran knowledge sharing |
| Succeed: Deliver results in a sustained way | Shipped something significant and kept the quality bar |

**Azure context.** If you are applying to Azure (AI Platform, AKS, Azure Monitor), know Azure at least at the level of knowing how it compares to AWS: AKS vs EKS, Azure Monitor vs CloudWatch, Azure Functions vs Lambda. You do not need deep Azure certifications, but "I worked on Kubernetes in production and explored AKS for managed control planes" is far better than knowing only AWS terminology.

**Coding posture.** Microsoft interviewers explicitly look for communication and the ability to walk back from a wrong first approach. Starting with a brute force, naming the complexity, then improving is not a weakness — it is the expected pattern. A candidate who jumps to the optimal solution silently is scored lower than one who narrated the whole path.

---

## India loops vs international loops

```
India SDE-2 loop (typical)         International SDE-2 loop (typical)
──────────────────────────         ──────────────────────────────────
1. Recruiter screen (30 min)       1. Recruiter screen (30 min)
2. Phone/video coding (45-60 min)  2. Phone/video coding (45-60 min)
3. Onsite / virtual onsite:        3. Take-home (optional, 2-4h)
   - 2 coding rounds               4. Full virtual onsite:
   - 1 system design                  - 2-3 coding rounds
   - 1 behavioral/manager             - 1-2 system design
                                       - 1-2 behavioral
                                       - 1 manager / bar-raiser

Timeline: 2-4 weeks total          Timeline: 4-8 weeks total
```

**Key differences in the international loop:**
- Behavioral rounds are weighted more heavily and are evaluated by multiple interviewers who share notes. A single weak behavioral at FAANG-tier is more likely to fail the loop than a weak behavioral at a mid-size Indian company.
- The bar-raiser (Amazon) or "scaled" interviewer is looking specifically for reasons to reject. This is not adversarial — it is how they maintain the bar. The answer is not to be more aggressive; it is to have tighter, more specific stories.
- Leveling is tighter at international: being scoped as L4 vs L5 at Google affects your TC by $50-100K. Know what level you are targeting and calibrate your stories to that scope.

---

## Common mistakes

**One-size-fits-all stories.** Sending the exact same "I led the migration of X service to Kubernetes" story to Grafana Labs (where they want observability depth), Razorpay (where they want correctness/payments thinking), and Microsoft (where they want growth mindset framing) is recognisable to every experienced interviewer. The story may be true but the framing makes it sound like you Ctrl+C'd from a template.

**Ignoring the JD.** The single most common preparation mistake. The JD tells you what the team is struggling with. "Experience with high-throughput data pipelines" is not boilerplate — it is a signal that the team has a pipeline problem and wants someone who has solved one. If your experience maps to it, lead with that in your intro and in every story that touches it.

**Not using the product.** You should use Grafana before the Grafana interview. You should have made a payment via Razorpay's checkout.js and looked at their developer docs before a Razorpay interview. Not as due diligence — as a signal source. Using the product tells you what is hard about it, which is exactly what the engineers inside the company spend their time on.

**Calibrating stories to the wrong level.** At SDE-2 you need stories about scope that extends beyond your immediate task. "I implemented the feature" is SDE-1. "I designed the feature, handled the ambiguity in the requirements, made the right call between two technical approaches, and documented the trade-off so future engineers could revisit it" is SDE-2. Know the difference and check your stories against it.

**Researching the company once.** Research has a half-life. Reading the Uber Engineering Blog six months ago and nothing since means you do not know about Uber's Presto→Trino migration, their LLM integration work, or whatever is current. Spend 90 minutes of targeted reading in the week before the first round, not six months before.

---

## Checkpoint

You are ready to proceed when you can answer each of these without looking anything up:

1. What is the one round in the Grafana Labs loop that most candidates underestimate, and what makes it different from a typical coding interview?
2. Name two Uber Engineering Blog posts you have read and describe the core architectural trade-off in each.
3. Map one of your existing work stories to a specific Atlassian value with a concrete example.
4. Explain what "idempotency key" means in the context of a payments API and why omitting it makes a payments service unsafe.
5. What does "Model-Coach-Care" mean at Microsoft and what is a story from your work that demonstrates the "Coach" part specifically?
6. What is the structural difference between an India SDE-2 loop and an international SDE-2 loop, and how does that change your preparation?
7. Name two things in a JD that signal the team's current pain point rather than generic requirements.

➡ Next up: **The Offer & Negotiation** — because winning the loop is only half the game.
