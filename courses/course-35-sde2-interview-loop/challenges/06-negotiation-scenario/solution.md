# Solution — Negotiation Scenario: The Competing Offer Window

The correct answer is **Option B**. The flag is `KUBE{reveal_offer_compress_timeline}`.

## Why B is correct

### The leverage window

You hold the single most powerful negotiation asset an engineer can have: a **real, written offer from a company the other side respects, with a live deadline**. This asset expires the moment you sign Atlassian or decline them. Option B is the only move that uses this asset before it expires.

The mechanics of Option B:
1. Email Razorpay's recruiter: *"I have a competing written offer and a deadline in 48 hours. Razorpay is my first choice. Is there any path to expediting your decision?"*
2. Send Atlassian a professional, non-confrontational hold note naming a specific date: *"I'll confirm by [date, 48–72 h out]. I remain very enthusiastic about the role."* This is not a second extension request — it is a courtesy date that gives Atlassian something concrete and lowers rescind risk.

Result: Razorpay either expedites (you now have a competitive comparison) or tells you they cannot (you still have Atlassian). No bridges burned.

### Why A fails

Accepting Atlassian immediately removes all leverage before you have information. If Razorpay's offer comes in at 42 LPA, you have permanently accepted 34 LPA — an 8 LPA gap that compounds over your career (raises, future offers, ESOPs are all anchored to current CTC). Option A is not *wrong* as a life choice; it is wrong as a *move* because you surrender information-gathering prematurely.

### Why C fails

The recruiter said "this is our best offer for the band." Claiming you have a higher competing offer when you do not (Razorpay has not sent a number yet) is a bluff. Recruiters triangulate offers. If Atlassian calls the bluff — "great, take the other offer then" — your written offer is at risk. Even if they don't rescind, you have burned goodwill with a hiring manager you will work with. Never bluff on a number you do not have.

### Why D fails

Declining a real 34 LPA offer to wait 5–7 days for a process that could still end in a no-offer or a delayed offer is the worst risk profile. If Razorpay delays or declines, you have nothing. You gave up a real offer for an uncertain one without using the offer as leverage first.

## The asymmetry test

| Option | Upside if it works | Downside if it fails |
|--------|--------------------|----------------------|
| A | Bird in hand (34L secured) | Forfeited 8L+ gap with Razorpay permanently |
| **B** | **Both options on the table; pick the best** | **Razorpay can't expedite → still have Atlassian** |
| C | Possible 2–4L bump above band | Offer rescinded; start over |
| D | Potentially higher offer at Razorpay | Nothing in hand; back to square one |

Option B has the most favorable asymmetry: the upside is full information and a possibly better offer; the downside is the status quo (you still have Atlassian). That is the hallmark of a good move.

## The communication that makes B work

**To Razorpay:**

> Subject: Final round follow-up — timeline question
>
> Hi [name],
>
> Thank you for the final round — I came away genuinely excited about the team
> and the scope. I want to be transparent: I have a competing written offer with
> a decision deadline in the next 48 hours. Razorpay is my first preference and
> I'd love to be able to evaluate both together.
>
> Is there any possibility of accelerating your timeline? Even an indication of
> the expected offer range would help me make the right decision.
>
> Happy to jump on a call if that helps.

**To Atlassian (hold note, not an extension request):**

> Hi [recruiter],
>
> Thank you again for the offer — I'm very excited about the SDE-2 role. I'm
> wrapping up one other process and expect to have full clarity by [date].
> I'll confirm definitively by then. Looking forward to it.

The Atlassian note does not ask for anything. It gives a specific date and expresses enthusiasm. Recruiters prefer a dated commitment over silence. This is not a second extension request — it is professional communication.

## What this teaches beyond one scenario

1. **Leverage is time-bounded.** Every day after you have a written offer without using it is a day of leverage you cannot recover.
2. **Real competing offers are not bluffs.** You never need to exaggerate. The truth — "I have an offer at 34L with a 48-hour deadline" — is already powerful.
3. **Expediting a process is not rude.** Recruiters are time-pressured too. A clear, professional ask with a stated reason almost always gets a faster response.
4. **The goal is information, not confrontation.** B does not force anyone into a corner. It creates the conditions where you can make a fully-informed decision instead of a fear-driven one.

## Comp structure notes (India context)

When evaluating the two offers, look beyond fixed salary:

| Component | Atlassian (34L total) | Razorpay (estimated 40–44L) |
|-----------|----------------------|----------------------------|
| Fixed | 26L | ~30–34L |
| Variable | 8L (payout ~85–90% typically) | ~10L |
| ESOP | Negligible at SDE-2 start | Meaningful if Razorpay IPO trajectory holds |
| Joining bonus | Ask — common in competing offer situations | Ask |

A joining bonus at Atlassian is a reasonable ask once you reveal the competing process: *"Is there flexibility on a joining bonus given the competing offer?"* This is separate from going above band — joining bonuses are a different budget line.
