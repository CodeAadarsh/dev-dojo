# Behavioral Interviews: STAR Stories with Quantified Impact

A Tier-1 interviewer reads the feedback doc: *"Candidate gave a story about teamwork but never clarified their own contribution. Impact described as 'things improved.' Would not pass bar."*

That candidate had the experience. They just couldn't tell it. The behavioral round at Grafana, Uber, Atlassian, Razorpay, and Microsoft evaluates whether you demonstrate the specific behaviors they hire for — and STAR is the only format that consistently works. This challenge makes you write and validate two stories before you're under the clock.

## The STAR Framework

| Component | What it answers | Common failure |
|-----------|-----------------|----------------|
| **Situation** | Where were you, what was the context, what was at stake? | Too long, too vague ("I was on a project") |
| **Task** | What were *you* specifically responsible for? | Conflated with Situation; missing ownership |
| **Action** | What did *you* personally do, step by step? | Says "we" throughout; no individual signal |
| **Result** | What changed because of your actions? Quantify it. | Qualitative only ("things got better") |

### "I" not "we"

Every Tier-1 company trains its interviewers to probe "we" answers: *"What specifically did you contribute?"* Save them the follow-up — use "I" throughout the Action section. "We shipped" tells them nothing about you. "I rewrote the retry logic, reduced DLQ depth by 80%, and presented the fix in the next sprint retro" tells them everything.

### The quantified result

A result without a number is an opinion. Interviewers calibrate against many candidates; a number makes your story falsifiable and memorable. If you don't have an exact figure, derive a defensible estimate: *"reduced on-call alerts from ~15/week to 2, roughly 75% reduction"* is far stronger than *"alerts went down."*

Good metrics for engineering stories:
- Latency/throughput change (p99 dropped from 800 ms to 120 ms)
- Error rate or incident frequency (on-call pages from 15/week to 2)
- Cost savings (reduced infra spend by ~$4K/month)
- Team velocity (cut release cycle from 2 weeks to 3 days)
- Scale handled (migrated 12 services, ~40 engineers unblocked)
- Time saved (automated process saved ~6 hours/week per engineer)

## Context

`setup.sh` plants a work directory:

```
~/.kube-dojo-work/04-behavioral-star/
└── stories.md    # template with two labeled story sections
```

## Prerequisites

Python 3 in `PATH`. No packages.

## Mission

Open `stories.md` and fill in **both** stories. Each must have:

1. A `## Story N:` heading (already in the template — do not rename them).
2. All four markers written verbatim: `**Situation:**`, `**Task:**`, `**Action:**`, `**Result:**`.
3. At least one number or metric in the `**Result:**` section — percentage, count, duration, currency, or similar.

### The two prompts

**Story 1 — A Conflict:** Describe a time you disagreed with a teammate, lead, or stakeholder. The disagreement should be real and professional. Show that you can hold a position with data and still maintain the relationship.

**Story 2 — A Failure:** Describe a project or decision that did not go as planned. Own it fully — no blame-shifting. Show what you learned and what changed as a result.

> Write for the interviewer who has seen 500 stories. Skip the throat-clearing. Start the Situation in sentence one.

## Debugging Your Stories

Before running the verifier, sanity-check your own stories:

**Common mistakes:**

| Mistake | Why it fails |
|---------|-------------|
| `**Situation:**` section runs for 8 sentences | You're setting context, not telling a story — cut to one paragraph |
| Action says "we investigated and fixed it" | No individual signal — name the exact steps *you* took |
| Result says "the team was happier" | Not quantifiable; interviewers cannot compare you to other candidates |
| Passive voice throughout | Makes it unclear who did what |
| Markers missing or renamed | The verifier will not find them — use exactly `**Situation:**` etc. |

**Self-check before verifying:**
- Can you read the story aloud in under 2 minutes?
- Does the Result section contain a number?
- Does "I" appear at least 3 times in the Action section?

## Verify

```bash
bash courses/course-35-sde2-interview-loop/challenges/04-behavioral-star/verify.sh
```

Both stories pass all checks → flag printed.
