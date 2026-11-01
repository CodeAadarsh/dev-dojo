#!/usr/bin/env bash
# Plants the negotiation scenario files into the work directory.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="06-negotiation-scenario"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── scenario.md — the full written brief ─────────────────────────────────────
cat > "$WORK/scenario.md" << 'MDEOF'
# Negotiation Scenario — The Competing Offer Window

## Your situation

- **Background:** SDE-1, 2.5 years experience, current CTC 18 LPA, mid-tier
  product company. You have been job-hunting for three months.

- **Offer in hand — Atlassian Bengaluru (SDE-2):**
  - Total compensation: **34 LPA** (fixed 26L + variable 8L, no ESOP, standard
    ESOP vesting offer is pending additional negotiation for a later band)
  - The recruiter already gave you a 24-hour extension last week when you asked.
  - The new deadline is **48 hours from now** (end of business, day after tomorrow).
  - Recruiter email: *"We've done our best for the SDE-2 band. Looking forward
    to your response by EOD Thursday."*

- **Competing process — Razorpay (SDE-2 equivalent):**
  - You completed the final-round panel yesterday. Three interviewers, all
    positive signals from the recruiter ("the panel liked you a lot").
  - Formal decision expected in 5–7 business days (their standard process).
  - Razorpay SDE-2 band: 38–44 LPA based on public levels.fyi data.
  - You have no written offer yet.

## Constraints

1. You cannot legally share exact offer figures (NDA with Atlassian). You can
   reveal: "I have a competing written offer and am being asked to decide in 48
   hours." The approximate range ("mid 30s LPA") is generally considered safe
   as a framing, not a disclosure.
2. Asking Atlassian for a second formal extension is high-risk — the recruiter
   already bent the rule. An informal email ("I would appreciate a brief
   acknowledgement that I can have until end of week") carries less risk than
   calling and asking for another extension.
3. Atlassian's "best offer for the band" statement is real but not absolute.
   However, without a competing number at a *higher* figure, pushing above band
   has no grounding — it reads as a bluff.
4. Declining Atlassian without a Razorpay offer in hand is a pure gamble on
   timing and outcome.

## The four options

| Option | Move |
|--------|------|
| A | Accept Atlassian now |
| B | Reveal competing offer to Razorpay, request expedited decision; send Atlassian an informal hold email |
| C | Tell Atlassian you have a higher competing offer and push above band |
| D | Decline Atlassian and wait for Razorpay's standard timeline |

## Your analysis

<!-- Write one sentence per option: why is it better or worse? -->

Option A:

Option B:

Option C:

Option D:

My choice and why:
MDEOF

# ── negotiation-checklist.md — a decision aid ────────────────────────────────
cat > "$WORK/negotiation-checklist.md" << 'MDEOF'
# Negotiation Decision Checklist

Use this before any offer decision to pressure-test your reasoning.

## Leverage audit

- [ ] Do I have a written offer (the strongest leverage)?
- [ ] Does the other party know I have a competing offer?
- [ ] Is there a real deadline creating time pressure?
- [ ] Am I replaceable in this timeline (can they find someone else)?

## Asymmetry check for each option

For each option, answer: *"If this fails, what do I lose? If it succeeds, what do I gain?"*

A good move has large upside and limited downside.

| Option | If it works → | If it fails → | Net asymmetry |
|--------|--------------|--------------|---------------|
|        |              |              |               |

## Timing principle

Leverage is a function of time and alternatives. Once you sign, leverage is zero.
Once you decline, leverage is zero. The window to use leverage is NOW — while
you have a written offer and the competing party still needs to decide.

## Communication templates

**To Razorpay (recruiter email):**
> "Hi [name], I wanted to reach out because I am in an advanced stage with
> another company and have a deadline coming up in the next 48 hours. Given
> how well the final round went, Razorpay is my first choice and I would love
> to resolve both processes together. Is there any possibility of an expedited
> timeline on your end?"

**To Atlassian (informal hold, not a formal extension request):**
> "Hi [recruiter name], thank you for the offer. I am very excited about the
> role. I am in the final stages with one other company and expect to have full
> clarity in the next 48–72 hours. I would appreciate any flexibility you can
> offer. I'll confirm by [specific date] at the latest."

Note: this is not asking for another formal extension. It is communicating a
specific date and showing enthusiasm. Lower risk than a direct "can you extend?"
MDEOF

echo
echo "Work directory : $WORK"
echo
echo "Files:"
echo "  scenario.md              — full scenario details and your analysis template"
echo "  negotiation-checklist.md — decision framework and communication templates"
echo
echo "Task           : read scenario.md, reason through the four options, and"
echo "                 submit the KUBE{...} flag for the best move."
echo "                 (See brief.md for the option-to-flag mapping.)"
echo
echo "Solution       : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/solution.md"
echo "                 (reveals the reasoning and the flag for the correct choice)"
