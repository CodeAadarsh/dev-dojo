# Negotiation Scenario: The Competing Offer Window

A senior engineer you respect tells you: *"I accepted the first offer I got because I was scared of looking greedy. Three months later I found out the company I turned down to take it was ready to offer 12 LPA more. I never asked. I never used what I had."*

Negotiation is not about being pushy. It is about understanding your leverage window — it only exists while you have something the other party wants and before you have committed. Once you sign, leverage is gone. This challenge is a single concrete scenario. There is one best move. Reason through it.

## The Scenario

`setup.sh` plants the full scenario in `~/.kube-dojo-work/06-negotiation-scenario/`. Read `scenario.md` for the complete context. The short version:

---

You are an SDE-1 with 2.5 years of experience at a mid-tier product company, currently earning **18 LPA**. You have been interviewing.

**Offer in hand (Atlassian Bengaluru):**
- Total: 34 LPA (fixed 26L + variable 8L)
- Role: SDE-2
- Your recruiter already granted one 24-hour extension after you asked. The deadline is now **48 hours from now**.
- The recruiter said verbatim: *"This is our best offer for the band."*

**Competing process (Razorpay):**
- You are in the final interview round. A decision is expected in **5–7 business days**.
- You have no indication of the number yet, but the role aligns well and Razorpay's SDE-2 band is typically 38–44 LPA.

**Constraints you know:**
- You cannot share the exact Atlassian offer figure with Razorpay — NDAs are real. You can reveal that you have a competing offer and roughly where it lands.
- Asking Atlassian for another formal extension is high-risk: the recruiter already bent the rule once; a second ask signals weak intent and may result in rescinding.
- Your current employer does not know you are interviewing and is not a factor yet.

---

## The Options

Reason through each option. Then submit the flag for the one you believe is the best move.

| Option | Move | Flag to submit |
|--------|------|---------------|
| A | Accept the Atlassian offer now — bird in hand | `KUBE{accept_atlassian_immediately}` |
| B | Reveal to Razorpay that you have a competing offer at ~34 LPA and ask them to expedite their decision, while requesting a 48-hour hold from Atlassian via email (not a formal extension) | `KUBE{reveal_offer_compress_timeline}` |
| C | Push Atlassian to go above band by claiming you have a higher competing offer | `KUBE{bluff_above_band}` |
| D | Decline Atlassian and wait for Razorpay's full 5–7 day timeline | `KUBE{decline_atlassian_wait}` |

## Reasoning framework

Work through these dimensions before you decide:

**What is your leverage?**  
You have a real, written offer. That is the strongest leverage an engineer has in a negotiation — not a vague "other companies are interested" but a concrete number with a deadline.

**Who is time-pressured?**  
Atlassian has already bent once; they want you to sign. Razorpay is in a process they could conclude faster if they chose to — interviewers and recruiters respond to external time pressure.

**What is the cost of each option if wrong?**  
- If A is wrong: you signed before knowing Razorpay's number. You left money on the table, permanently, with no information.
- If B is wrong (Razorpay does not expedite): you still have the Atlassian offer (if the hold request worked), no bridges burned.
- If C is wrong: recruiter calls the bluff or rescinds. Real offer gone.
- If D is wrong: Razorpay declines or delays further. Real offer gone, nothing in hand.

**What is the asymmetry?**  
Good negotiation moves have asymmetric upside: if they work you gain significantly; if they fail you lose little. Which option has that property?

## How to claim the flag

Submit the `KUBE{...}` string for the option you believe is correct. Only one of the four matches the `flag.sha256` stored in this challenge. The solution explains the reasoning in full.

## Checkpoint

Before checking the solution, write down one sentence for each option explaining why it is better or worse than the others. The act of forcing a written comparison is the skill — in a real negotiation you have seconds to reason through this.
