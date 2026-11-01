# The Offer & Negotiation

> **Module 06 · Course 35** — You get the call. "We'd like to extend an offer." Then: "Before I go over the details, can you share your current compensation?" This is the most dangerous sentence in the entire hiring process — not because it is hostile, but because the answer, whatever you say, immediately becomes the ceiling of your offer.

Most engineers spend three months preparing for the interview and thirty seconds thinking about the negotiation. The result is that they accept the first number, leave 10-30% on the table, and find out six months later what their colleagues earn.

This module is the negotiation playbook: comp structure, levels, what is negotiable, the scripts that work, and the mistakes that are career-expensive.

---

## Compensation structure

Every offer has components. Understanding each one is prerequisite to negotiating intelligently.

```
Total Compensation (TC) = Base + Bonus + Equity
                                     │          │
                              annual bonus    RSU vesting
                              (10-20% base)   (4yr cliff-vest or monthly)
```

**Base salary:** Fixed monthly cash. This is the number most people negotiate on first, but it is not always the highest-leverage lever.

**Annual bonus:** Typically 10-20% of base. Usually conditional on two factors: your individual performance rating AND the company's financial performance. A 15% bonus at a company in a bad year can pay out at 50% of target. Read the bonus plan before signing — specifically whether it is "discretionary" (HR can pay whatever they feel like) or "formulaic" (there is a published multiplier table).

**Equity / RSUs:** At public companies, Restricted Stock Units. You are granted X shares that vest over 4 years. At many large companies (Microsoft, Atlassian, Uber), the vesting schedule is:
- Cliff: some portion unlocks at year 1 (typically 25%)
- Monthly or quarterly vesting after cliff for years 2-4

At Indian startups (Razorpay, PhonePe pre-IPO), equity is usually **ESOPs (Employee Stock Option Plans)**. Options, not RSUs — you have the *right* to buy shares at the strike price. The strike price is set at grant time. If the company's valuation goes up, your options are worth the spread. If it stays flat or declines, your options are worthless. ESOPs come with an exercise window: typically you have 90 days after leaving to exercise (buy the shares) or you forfeit them.

**Signing bonus:** One-time payment at joining, sometimes split across year 1. The most negotiable single number in most offers, especially when you are leaving unvested equity at your current company.

---

## Levels and bands

Companies will not exceed their salary band for a level. Before negotiating base, confirm you are being leveled correctly.

**Indian SDE-2 level equivalents (2025-2026 approximate ranges, total CTC):**

| Company | Level name | Approx band |
|---------|------------|-------------|
| Microsoft Hyderabad | SDE-II (L62) | ₹28–45 LPA |
| Atlassian Bengaluru | L5 | ₹32–52 LPA |
| Uber Bengaluru | L4 | ₹30–55 LPA |
| Razorpay | SDE-2 | ₹22–40 LPA |
| PhonePe | SDE-2 | ₹24–42 LPA |
| Grafana Labs (remote/India) | Senior Engineer IC2 | $120–160K USD |

> These are approximate public data aggregates. The actual range shifts with market cycles, your leverage, and which team is hiring. Use levels.fyi and blind for live data — but treat every individual data point as noisy. Look at the distribution, not the outlier.

**The level negotiation.** If you are operating at SDE-3 scope (handling ambiguous problems, owning a subsystem, influencing cross-team decisions) but they have leveled you as SDE-2, there is a window to make the case for SDE-3 — specifically on evidence. This is harder to get than a salary bump and requires a concrete argument: "In my current role I led a six-month project with three engineers and two cross-team dependencies. That matches the scope definition in your SDE-3 criteria." Without specific evidence, this conversation fails.

**International level equivalents:**

| Company | SDE-2 equiv | TC range (USD, 2025-2026) |
|---------|-------------|---------------------------|
| Google | L5 | $280–420K TC |
| Meta | E5 | $300–480K TC |
| Amazon | SDE-2 | $200–280K TC |
| Microsoft | SDE-2 | $200–280K TC |
| Uber (US) | L4 | $230–320K TC |
| Atlassian (US) | L5 | $220–300K TC |

TC at US FAANG is not base salary — it is base + bonus + annual RSU vesting. A $250K TC might be $175K base + $25K bonus + $50K RSUs vesting that year. When comparing offers across companies, always convert everything to annual TC and use a single table.

---

## The reveal-your-number trap

When a recruiter or HR asks "what is your current CTC?" or "what are your salary expectations?", they are not making conversation. Any number you give anchors the negotiation.

**How anchoring works:** You say "I am currently at ₹18 LPA." The recruiter's first draft offer is now ₹21-22 LPA — a number that feels like a raise to you but is 30% below what they would have offered someone who disclosed nothing.

**What to say instead:**

> "I'd prefer to focus on the role and what's the right number for this position based on your band and my experience. I'm targeting the market rate for SDE-2 in Bengaluru, which my research puts at [₹30-40 LPA range]. Is that in line with what you're working with?"

Reframe from "what you earn now" to "what the role is worth." You are not obligated to disclose your current comp in India (unlike in some US states where the law works differently; several US states have laws prohibiting employers from asking salary history at all).

If they push hard ("we need a number to proceed"): give a range where the bottom is your real minimum.

**For US/international applications:** Salary history questions are illegal in California, New York, Massachusetts, and several other states. Even where they are legal, you can decline: "I prefer not to share salary history — I'm happy to discuss expectations."

---

## What is negotiable

| Component | Typical negotiation room | Notes |
|-----------|-------------------------|-------|
| Base salary | 5–20% above first offer | Harder above band; possible with competing offer |
| Signing bonus | Often most flexible | Use to cover unvested equity you are leaving behind |
| RSU grant size | Sometimes 10-20% | Needs a competing offer with a larger equity grant to push |
| Start date | Almost always flexible | Useful for you; rarely costs them anything |
| Level/title | Occasionally | Requires concrete evidence of higher-scope work |
| Remote work | Company-dependent | Confirm in the offer letter, not verbally |

**What is not negotiable:**
- The salary band itself (they will not bend the band — they might bump the level, which is a different conversation)
- Benefits, health insurance, PF/NPS contributions (standardised)
- ESOP/RSU vesting schedule (company-wide policy)

---

## Competing offers — the highest-leverage tool

A competing offer is the only true leverage in a negotiation. "I am worth more" is an opinion. "Company X has offered me ₹38 LPA" is a fact that creates deadline pressure.

**The script for using a competing offer:**

> "I'm very excited about [company] — it's my top choice based on [specific reason]. I do have another offer I need to respond to by [date]. They've offered [₹X or $X]. Is there any flexibility on [the specific component — base / signing / RSUs]?"

Rules for this conversation:
1. Have the offer in writing before you use it in negotiation. Do not bluff. Bluffs collapse and destroy the relationship.
2. Be specific about the component you want moved, not vague. "Can you do better?" is a weak ask. "Can you match the base?" or "Can you close the gap with a signing bonus?" is specific.
3. Express genuine enthusiasm for the company you are negotiating with. This is not manipulation — it is relevant information. They are more likely to stretch for a candidate who genuinely wants to be there.
4. Be willing to accept the answer. If they say "this is our best and final," believe them. You can still accept or decline.

**Timing:** Negotiate before you accept. Once you verbally accept, the negotiation is closed. "Can I have until [date] to review the offer?" — always ask for 5-7 days. This is normal and expected. A company that gives you 24 hours to accept is signalling something you should pay attention to.

---

## The full negotiation flow

```
Verbal offer call
       │
       ▼
"Thank you, I'm excited. Can I have until [date] to review the written offer?"
       │
       ▼
Receive written offer → read every line (base, bonus target %, equity units + vesting, signing, benefits)
       │
       ├── Happy with everything? → Accept with written confirmation
       │
       └── Want to negotiate?
              │
              ▼
       Call (not email) the recruiter
       "I've reviewed the offer and I'm very excited. [Specific reason why this company.]
        I was hoping we could discuss [one specific component].
        My research shows [market data / competing offer]. Is there any flexibility?"
              │
              ├── Yes → Confirm new number in writing before accepting
              └── No → Decide: accept or decline. Thank them either way.
```

**Negotiate by phone or video, not email, for the main ask.** Email is fine to confirm what was verbally agreed. Email for the negotiation itself strips tone, creates ambiguity, and tends to make both sides more rigid.

---

## India vs international — the equity dimension

At an Indian company at SDE-2 level, equity (ESOPs) is often a small component of TC. ₹2-4L face value of options over four years, with uncertain liquidity. For career stage planning: treat Indian startup ESOPs as asymmetric upside (lottery ticket), not as income.

At US-listed or US-benchmarked companies (Microsoft, Uber, Atlassian), RSUs are real, liquid value on a schedule. A $50K/yr RSU grant at a large-cap company is essentially deferred salary. Model it into your total comp seriously.

**The ESOP exercise trap.** Many Indian SDE-2s walk out of a startup with ESOPs they have never exercised, then miss the 90-day exercise window after leaving and forfeit everything. Know your exercise window before you resign, and factor the exercise cost into your exit decision. If your options are underwater (strike > current share price), there is nothing to lose. If they are in-the-money, the exercise cost is real cash you need to plan for.

---

## Common mistakes

**Accepting the first offer.** Almost every first offer has room. The recruiter's job is to get you to sign at the lowest number you will accept. The number they give you first is not the number at the top of their range. Failing to ask is leaving money on the table — and unlike most mistakes, it compounds: your next salary negotiation is anchored to this one.

**Revealing current comp.** Anchors the negotiation at the wrong starting point. There is no scenario where disclosing your current ₹18 LPA helps you — it can only set a ceiling that is below your market value. Decline politely, redirect to market rate.

**Negotiating by email badly.** "Hi, I wanted to see if there's any flexibility on the offer" followed by a silence and then "I was thinking maybe 5-10% more?" over three email threads is the worst negotiation pattern. It signals uncertainty, makes the recruiter's job harder, and often lands in "no." Call them. State the specific number. Wait for the response.

**Negotiating multiple components simultaneously.** "I wanted more base AND more signing AND more RSUs AND earlier start" in one email is a signal that you have not prioritised what actually matters to you. It also gives the recruiter room to say "we moved on equity" and call it done. Pick the one component that moves your TC the most and lead with that.

**Letting the counteroffer from your current employer delay you.** "We'll match it" from your current company is a retention tool, not a promotion. Statistics on counter-offer employees are bad: most leave within 12 months anyway, but now they have burned the political capital of having accepted an offer elsewhere. If you are accepting a new job, the decision was not about the money. A counter-offer rarely changes the underlying reasons you were looking.

**Not getting it in writing.** Verbal agreements about signing bonuses, level adjustments, or remote work arrangements that are not in the offer letter do not exist legally. Be friendly about it: "Can you confirm the [adjusted number / start date / remote arrangement] in the offer letter before I sign?" This is normal. Any recruiter who pushes back on written confirmation is a warning sign.

---

## Checkpoint

You are ready to proceed when you can answer each of these without looking anything up:

1. What is the difference between an RSU and an ESOP, and why does that matter when comparing an offer from Microsoft versus a Series-C Indian startup?
2. A company's first offer is ₹28 LPA. You have a competing offer for ₹34 LPA. Write out the exact script you would use on the call with the first recruiter.
3. What is the ESOP 90-day exercise window, and what is the failure mode if you do not plan for it?
4. You are asked "what is your current CTC?" What do you say?
5. Name the one negotiation lever that is almost always the most flexible and why.
6. Why should you negotiate by phone rather than email for the main ask?
7. What does "TC" mean in the context of a US tech offer, and how is it different from "base salary"?

➡ Next up: **Study & Mock Plan** — the 8-12 week system that gets you to offer day.
