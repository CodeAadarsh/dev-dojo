# Reliability Foundations: SLOs, Error Budgets & the Four Golden Signals

> **Module 01 · Course 02** — You already ship to Kubernetes in production. This course is about the discipline that keeps it *reliable at scale* without heroics. Before autoscaling, rollouts, or incident drills, you need a shared language for "how good is good enough." That language is SLOs, error budgets, and the golden signals. Get this wrong and every later decision — how aggressively to roll out, when to page, what to automate — is a guess.

Reliability is not "100% uptime." 100% is the wrong target: it's infinitely expensive, and your users can't tell the difference between 100% and 99.99% because their own network, DNS, and devices are less reliable than that. The SRE move is to pick a target *below* 100% on purpose, then spend the gap deliberately. This module is how you pick it and defend it.

---

## SLI → SLO → SLA — the chain, and why people conflate them

These three get used interchangeably in standups and it causes real damage. They are a chain, from measurement to promise to contract.

| Term | What it is | Who it's for | Example |
|------|-----------|--------------|---------|
| **SLI** | *Service Level Indicator* — a measured ratio of good events / valid events | Engineers | `successful_requests / valid_requests` over 5 min |
| **SLO** | *Service Level Objective* — the target an SLI must hold over a window | The team + its stakeholders | 99.9% of requests succeed over a rolling 28 days |
| **SLA** | *Service Level Agreement* — a contractual SLO with financial/legal consequences | Lawyers + customers | 99.5% or we credit 10% of the bill |

The ordering that matters:

```
   measure                promise                   contract
 ┌──────────┐  pick a   ┌──────────┐  wrap in    ┌──────────┐
 │   SLI    │─ target ─▶│   SLO    │─ penalty  ─▶│   SLA    │
 │ (a ratio)│           │(internal)│  (external) │ (legal)  │
 └──────────┘           └──────────┘             └──────────┘
   what you              what you                  what you
   can see               aim for                   owe money on
```

Two rules that separate people who've run this from people who've read about it:

- **Your SLA must be looser than your SLO.** If you contractually promise 99.9% and internally target 99.9%, you page and credit at the same instant. Target 99.95% internally, promise 99.9% externally — the gap is your margin before money is on the line.
- **A good SLI is a ratio of good events to valid events, not an average.** Averages hide the tail. "Average latency 80ms" is compatible with 5% of users seeing 4 seconds. Define the SLI as *the fraction of requests served under 300ms*, and the tail becomes visible.

> **The "valid events" trap.** Your denominator is *valid* requests, not *all* requests. A client sending malformed input and getting a 400 is not your reliability failing — don't let 4xx-from-bad-clients burn your budget. But a 400 your own buggy validation caused *is* your failure. Deciding what counts as "valid" is where most SLI definitions quietly go wrong.

---

## Error budgets — the number that ends arguments

An SLO of 99.9% over 28 days is also a *permission to fail* 0.1% of the time. That 0.1% is your **error budget**, and it's the most useful management tool SRE ever produced because it converts "should we ship the risky change?" from an opinion into arithmetic.

```
SLO = 99.9%  →  error budget = 0.1%  of a 28-day window

 28 days = 40,320 minutes
 budget  = 0.001 × 40,320 ≈ 40.3 minutes of "allowed unavailability" / window
```

A quick reference every SRE should have memorized — the "nines" and what they buy you per 30 days:

| SLO | Error budget | ≈ Downtime / 30 days | ≈ Downtime / year |
|-----|--------------|----------------------|-------------------|
| 99%     | 1%      | ~7.2 hours  | ~3.65 days  |
| 99.9%   | 0.1%    | ~43 minutes | ~8.76 hours |
| 99.95%  | 0.05%   | ~22 minutes | ~4.38 hours |
| 99.99%  | 0.01%   | ~4.3 minutes| ~52.6 minutes |
| 99.999% | 0.001%  | ~26 seconds | ~5.26 minutes |

How it's actually used:

- **Budget remaining → ship.** Feature teams get to deploy risky changes, run chaos experiments, and move fast *as long as the budget isn't exhausted*. The budget is theirs to spend.
- **Budget exhausted → freeze.** When the budget is gone, the policy (agreed in advance, in writing) is a feature freeze: only reliability work and rollbacks ship until the window rolls forward and the budget refills. No one argues in the moment because the rule was set when nobody was angry.

> **Why this works politically.** The error budget makes reliability a *shared* resource between the people who want to ship (product) and the people who want it to stay up (SRE). It replaces "you're being too cautious" vs. "you're being reckless" with a balance everyone can see. The hardest part is not the math — it's getting leadership to pre-commit to the freeze policy before it bites.

---

## Burn-rate alerting — page on the budget, not on the blip

Here's the mistake almost everyone makes first: they alert on "error rate > 1% for 5 minutes." That pages you at 3am for a transient blip that burned 0.0001% of your budget, and it *misses* a slow leak that quietly eats the whole thing over a week. Neither is actionable.

The modern approach alerts on **burn rate**: how fast you're spending the budget *relative to the rate that would exhaust it exactly at the end of the window.*

```
 burn rate = (observed error rate) / (SLO error rate)

   burn rate 1   → you'll spend exactly 100% of budget by window end (on-pace)
   burn rate 14.4→ you'll spend 100% of a 28-day budget in ~2 days
   burn rate 1440→ you'll spend 100% in ~28 minutes  (something is on fire)
```

The trick from the Google SRE workbook is **multi-window, multi-burn-rate** alerts: combine a fast burn over a short window with confirmation over a longer one, so you page hard on fast burns and ticket (don't page) on slow ones.

| Severity | Burn rate | Long window | Short window | Budget consumed to fire | Action |
|----------|-----------|-------------|--------------|-------------------------|--------|
| Page   | 14.4 | 1 hour  | 5 min  | 2% in 1h   | Wake someone up |
| Page   | 6    | 6 hours | 30 min | 5% in 6h   | Wake someone up |
| Ticket | 3    | 1 day   | 2 hours| 10% in 1d  | Investigate next business day |
| Ticket | 1    | 3 days  | 6 hours| 10% in 3d  | Investigate, low urgency |

The short-window condition is the *reset*: it stops the alert from firing long after the incident is over, because once errors stop, the short window recovers fast while the long window is still elevated.

```promql
# Fast-burn page: 14.4x burn confirmed over both a 1h and a 5m window.
(
  (1 - (sum(rate(http_requests_total{code!~"5.."}[1h])) / sum(rate(http_requests_total[1h])))) > (14.4 * 0.001)
  and
  (1 - (sum(rate(http_requests_total{code!~"5.."}[5m])) / sum(rate(http_requests_total[5m])))) > (14.4 * 0.001)
)
```

> `0.001` is `(1 - 0.999)` — the SLO's error budget as a fraction. Change the SLO, change this one constant. Keep the burn-rate thresholds and windows as named recording rules so a human can read the alert and know *why* it fired.

---

## The Four Golden Signals

If you can only instrument four things on a user-facing service, instrument these. They come from the Google SRE book and they're the backbone of every service dashboard worth having.

```
 ┌─────────────┬──────────────────────────────────────────────┐
 │  LATENCY    │ how long requests take — split SUCCESS vs FAIL │
 │  TRAFFIC    │ how much demand — req/s, connections, msgs/s   │
 │  ERRORS     │ rate of failing requests — explicit + implicit │
 │  SATURATION │ how "full" the system is — the constrained res │
 └─────────────┴──────────────────────────────────────────────┘
```

Each one has a subtlety that bites beginners:

- **Latency** — you *must* separate the latency of successful requests from failed ones. A fast 500 ("fail fast") can make your latency graph look *better* during an outage, which is exactly backwards. Track p50/p90/p99, never just the mean — the mean is a lie the tail tells.
- **Traffic** — this is your *demand* signal, and it's the context for everything else. 50 errors/sec is a catastrophe at 100 req/s and a rounding error at 1M req/s. It's also what your autoscaler and capacity plan key off of.
- **Errors** — count the *explicit* (HTTP 500s, exceptions) **and** the *implicit* (HTTP 200 with a wrong or empty body, requests that violated a latency SLO). The implicit ones are where the nasty, invisible outages live.
- **Saturation** — the utilization of your most-constrained resource (CPU, memory, a connection pool, disk IO, a queue depth). It's your *leading* indicator: latency and errors are what the user feels *after* saturation has already started climbing. In Kubernetes this is CPU/memory vs. requests/limits, and it's exactly what an HPA watches.

> **Mapping to Kubernetes.** Latency/traffic/errors come from your ingress or service mesh (nginx-ingress, Istio, Linkerd) or app instrumentation. Saturation comes from `kube-state-metrics` + the metrics pipeline (CPU/memory/throttling). Your LGTM stack at work is literally the plumbing for these four signals — Loki for the log-derived ones, Mimir/Prometheus for the rates, Tempo to drill from an error signal into the trace that caused it.

---

## RED vs USE — two lenses, use both

Golden signals are the canonical list; RED and USE are two popular, sharper framings that tell you *which* signals to reach for depending on *what* you're looking at.

```
        RED  — for REQUEST-DRIVEN things (services, APIs, endpoints)
     ┌──────────────────────────────────────────────┐
     │  Rate      — requests / second                │
     │  Errors    — failing requests / second        │
     │  Duration  — distribution of request latency  │
     └──────────────────────────────────────────────┘

        USE  — for RESOURCES (CPU, memory, disk, NICs, pools)
     ┌──────────────────────────────────────────────┐
     │  Utilization — % time the resource was busy   │
     │  Saturation  — queued work the resource can't  │
     │                service yet (run-queue, depth)  │
     │  Errors      — error events for that resource  │
     └──────────────────────────────────────────────┘
```

| | RED (Rate, Errors, Duration) | USE (Utilization, Saturation, Errors) |
|---|---|---|
| **Author** | Tom Wilkie (Grafana/Weaveworks) | Brendan Gregg (Netflix) |
| **Lens** | The *service's* behavior, user-facing | The *resource's* health, infra-facing |
| **Answers** | "Are my users having a good time?" | "Which resource is the bottleneck?" |
| **Per** | Each service / endpoint | Each resource (every CPU, every disk) |
| **Best for** | SLOs, dashboards, alerting on symptoms | Capacity planning, finding the constraint |

They're complementary, not competing. RED tells you *the users are in pain*; USE tells you *the connection pool is saturated and that's why*. A mature dashboard has a RED row at the top (symptoms, what you alert on) and USE panels below (causes, what you investigate with). **Alert on symptoms (RED), diagnose with causes (USE)** — paging on high CPU is noisy because high CPU is often *fine*; paging on user-facing errors is actionable.

---

## Toil & automation — the SRE's actual job

**Toil** is work that is manual, repetitive, automatable, tactical, devoid of enduring value, and scales linearly with service size. Restarting a stuck pod by hand every morning is toil. Writing the controller that restarts it is engineering.

The canonical rule: **SRE teams should cap toil at ~50% of their time.** The other half must go to engineering that *reduces future toil*. When toil creeps past 50%, the team slowly becomes an ops team that can never get ahead, because every new service adds linear manual load.

How to attack it, in order:

1. **Measure it.** You can't cap what you don't count. Tag incident/ops time as toil in your tracker.
2. **Eliminate, don't just automate.** The best fix is making the toil *impossible* (a readiness probe that makes the manual restart unnecessary) — automating a bad process just makes it faster.
3. **Then automate what remains.** A controller, an operator, a self-healing probe, a scheduled job. In Kubernetes, a huge amount of former toil is now declarative: HPAs replace "manually scale up for the sale," PDBs replace "babysit the node drain," `restartPolicy` + probes replace "ssh in and `kill -9`."

> **The toil smell test:** if you've done it twice by hand, you'll do it a hundred times. The second occurrence is the signal to automate, not the fiftieth. Autoscaling (next challenge) is the canonical example: manually scaling for load is pure toil; an HPA eliminates it.

---

## Blameless postmortems — the learning engine

An incident you don't learn from is an incident you'll have again. The postmortem is how an org converts pain into permanent improvement — but only if it's **blameless**.

Blameless does **not** mean "no accountability." It means the write-up assumes everyone acted reasonably with the information and tools they had, and asks *"what about the system let a reasonable person cause this?"* instead of *"who screwed up?"* The moment people fear being named, they hide information, and you lose the ability to learn.

A good postmortem has:

- **A timeline** — detection → diagnosis → mitigation → resolution, with timestamps. This exposes your real **MTTD** (time to detect) and **MTTR** (time to recover), which are often the biggest levers.
- **Impact** — quantified against the SLO: "burned 60% of the monthly error budget; ~12k users saw 503s for 18 minutes."
- **Root cause(s)** — plural, via the "5 whys" or a causal chain. Real incidents are almost never one cause; they're a chain where several guardrails all failed.
- **Action items** — each with an owner and a due date, each one a specific change (an alert, a test, an automation, a guardrail). Vague "be more careful" items are worthless.

> **The trigger rule:** decide *in advance* what automatically earns a postmortem — e.g. "any event that burns >20% of a monthly budget, any page outside business hours, any customer-reported outage." Removing the judgment call ("was this big enough to write up?") is what makes postmortems actually happen. A postmortem's action items should feed straight back into your error-budget work: that's the loop closing.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Define SLI, SLO, and SLA in one sentence each, and explain why the SLA must be looser than the SLO.
2. Compute the error budget in minutes for a 99.9% SLO over a 28-day window.
3. Explain why a burn-rate alert beats a static "error rate > 1% for 5 min" threshold, and what the short window in a multi-window alert is for.
4. Name the four golden signals and the one subtlety of each (hint: split latency by outcome; count implicit errors; saturation is the *leading* indicator).
5. Say when you'd reach for RED vs USE, and which one you alert on.
6. Give the ~50% toil cap and the "done it twice" rule, and name a Kubernetes primitive that eliminated a specific piece of toil.
7. Explain what "blameless" protects and why a pre-agreed postmortem trigger matters.

➡ Next up: the **Autoscale Under Load** challenge — you'll take a deployment that has CPU requests but no autoscaler (pure toil waiting to happen) and wire up a Horizontal Pod Autoscaler, then prove the spec with a verifier.
