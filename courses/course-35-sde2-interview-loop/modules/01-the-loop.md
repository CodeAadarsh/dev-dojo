# The SDE-2 Loop, Decoded

> **Module 01 · Course 35** — Most candidates fail not because they can't code but because they misread what the loop is measuring. Each round is a different signal. Conflate them and you optimize for the wrong thing — grinding LeetCode when the next round is a behavioral screen, or polishing STAR stories when you're about to get a deque question.

This module is a map. Once you know what each room in the house is for, you stop wandering.

---

## The rounds and what each one signals

A Tier-1 SDE-2 loop typically looks like this:

```
OA (take-home) → Phone Screen (1×45 min) → Onsite (4–5× 45–60 min)
                                              ├─ Coding #1
                                              ├─ Coding #2
                                              ├─ System Design
                                              ├─ Behavioral / Bar-Raiser
                                              └─ (Hiring-manager chat — some loops)
```

Not every company runs all five onsite slots in this order. Grafana Labs and Atlassian tend to front-load a technical screen before the full onsite. Uber and Microsoft run four or five rounds on a single virtual day. Razorpay and PhonePe compress to three rounds but hold the bar-raiser equivalent as the final slot. The structure varies; what each slot *measures* is consistent.

### Online Assessment

Signal: **can you write correct code under time pressure, unassisted?**

The OA is a floor check, not a ceiling check. Pass rate for top companies is 30–60% — most candidates don't clear it not because the problems are hard but because of time management and off-by-one errors. Treat it as a timed sprint, not a thorough design exercise. You get no credit for a half-finished O(n log n) solution over a complete O(n²) one that passes all test cases.

What the OA does *not* signal: your system design judgment, communication, or senior-scope thinking. Nobody reads your variable names.

### Phone Screen

Signal: **can you solve a medium-difficulty problem while narrating your thinking clearly, with a real engineer listening?**

The interviewer is deciding one thing: *is it worth the team's time to fly / Zoom this person through five rounds?* They will cut you loose after 15 minutes if you go silent. Your code matters less than your reasoning process.

One medium problem, occasionally two eases. Expect 5–10 minutes of setup and clarification, 25–30 minutes of coding, 5–10 minutes of complexity and edge cases, then "any questions for me?" You should have two genuine questions ready.

### Onsite: Coding rounds (×2)

Signal: **pattern recognition, correctness under observation, communication discipline.**

These are the two rounds that look like LeetCode but are not actually LeetCode. The interviewer is watching:

- Do you clarify before coding?
- Do you explain your approach before implementing?
- Do you test your own code, or wait to be told it's wrong?
- Do you recognize which pattern applies, or do you thrash?
- Do you handle hints gracefully, or freeze up?

One coding round is almost always a medium-difficulty problem. The second is medium-to-hard. At SDE-2 level, the expectation is a working, tested solution with correct complexity analysis for at least the first, and a working or nearly-working solution with strong approach reasoning for the second.

### Onsite: System Design

Signal: **can you drive an open-ended, ambiguous technical conversation to a defensible conclusion at appropriate depth?**

This is the round that most clearly distinguishes SDE-2 from SDE-1. The problem statement is deliberately under-specified. Requiring the interviewer to hand you the requirements is a red flag — at SDE-2, you should be able to generate reasonable constraints yourself, state your assumptions explicitly, and build from there. Full breakdown in Module 03.

### Onsite: Behavioral / Bar-Raiser

Signal: **ownership, impact, growth, and culture fit — with proof.**

Every claim you make must be grounded in a specific, past, real situation. "I generally communicate well" is not evidence. "In Q3 I was on a service with three oncall escalations a week; I wrote an RCA template, drove two incident reviews, and we hit zero SEV-2s for the next two months" is evidence. The bar-raiser (common at Amazon, borrowed in spirit elsewhere) is specifically looking for the cases where you *didn't* behave as expected and what you did about it.

---

## The leveling rubric

This is the frame the debrief uses. When interviewers disagree on hire/no-hire, they resolve it here.

| Dimension | SDE-1 | SDE-2 | SDE-3 |
|-----------|-------|-------|-------|
| **Scope** | Task / story | Feature / component | Service / org initiative |
| **Ambiguity** | Needs clear spec to start | Generates reasonable constraints; works with partial info | Identifies the right problem before being told |
| **Ownership** | Completes assigned work reliably | Drives work end-to-end; flags blockers; owns quality | Accountable for team-level outcomes; pulls in stakeholders |
| **Coding** | Correct solutions to well-defined problems | Efficient, clean, handles edge cases without prompting | Reviews as a bar-setter; spots subtle concurrency / correctness issues |
| **Design** | Can implement a given design | Can produce a reasonable design for a bounded system | Cross-system design; organizational and operational impact |
| **Communication** | Clear on status and blockers | Proactive, structured, adapts to audience | Sets direction, aligns teams, drives consensus |

The rubric is not a strict checklist — interviewers pattern-match holistically. But the signal they're hunting for in a SDE-2 loop is: **does this person need a well-defined spec to operate, or do they generate the spec themselves?**

> At SAP, the clearest signal I saw in code reviews that separated SDE-1 and SDE-2 behavior: SDE-1s open a PR and wait. SDE-2s open a PR, add context about *why* this design was chosen over the alternatives they considered, and preemptively respond to the three review comments they know are coming. The interviews are measuring the same axis.

---

## How decisions are made

After the last round, every interviewer submits a written debrief: a hire/no-hire signal, a leveling signal (SDE-1 / SDE-2 / SDE-3), and evidence for each claim. The hiring committee — or, at smaller companies, the hiring manager — reads the debriefs *before* the team calibration call.

Key mechanics:

- **A single hard "no hire" from any interviewer can block.** It doesn't always, but the person who says "no hire" will need to defend it in calibration. If their reasoning is solid, the committee will respect it. This is why one bad round can kill an otherwise strong packet.
- **"Strong hire" dilutes if the evidence is thin.** "Great energy, communicated well" with no specifics is weak. "Recognized the monotonic deque pattern within 8 minutes, wrote a clean O(n) solution, caught the empty array edge case unprompted, explained time complexity accurately" is strong.
- **The bar-raiser is independent of the hiring team.** They are not trying to fill a headcount; they are protecting the hiring bar. They have veto power in Amazon-style loops and strong influence elsewhere. If your behavioral stories are vague, they will probe hard.
- **Leveling happens in the debrief, not the offer stage.** If three out of four interviewers signal SDE-2 and one signals SDE-1, the committee will likely offer SDE-2 but note the uncertainty. This affects your starting band.

> **One thing almost nobody tells you:** the debrief happens fast — often within 24 hours of your last round. Interviewers are going off memory + notes. Your job, in every round, is to make it easy for the interviewer to write a specific, evidence-heavy debrief note about you. Concrete signals — "solved in 22 minutes, O(n) space, caught the k=1 edge case" — stick. "Seemed smart" doesn't.

---

## Common mistakes

**Optimizing for code quality when the round is measuring communication.**

Silent, fast, correct code fails the coding round if the interviewer cannot follow your reasoning. They are not your compiler. At a Tier-1, an O(n log n) solution narrated clearly with correct complexity analysis beats an O(n) solution written in total silence. You will get another chance to add the optimization once your approach is on the board.

**Under-leveling yourself in the design round.**

The most common self-inflicted wound. The interviewer asks "design a URL shortener" and the candidate builds a correct system but never mentions sharding, never discusses read vs write ratios, never articulates why they chose a hash over a counter, and wraps up in 20 minutes. An SDE-2 drives the conversation deeper. You should not wait to be asked "what happens at 10× load?" — you should raise it.

**Treating the behavioral round as filler.**

The behavioral round is a round. Companies that use a bar-raiser structure weight it equally to a coding slot. Candidates who coast through it with "I always try to communicate well" are leaving signal on the table. Prepare three to five ownership stories with metrics the way you prepare your top-five LeetCode patterns.

**Conflating "passed" with "hired at the right level."**

You can pass the loop and get leveled down. If your coding solutions needed heavy hints, or your design stayed shallow, or your behavioral stories were all team-level ("we shipped it"), you may receive an SDE-1 offer or a "not at this time" for SDE-2. The goal is not to clear the bar — it's to demonstrate SDE-2 behaviors in every round, consistently.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. Name the five typical onsite rounds and the primary signal each one measures.
2. State what distinguishes SDE-2 from SDE-1 on the "ambiguity" and "scope" dimensions.
3. Explain why a single "no hire" can block an otherwise positive packet.
4. Describe what the bar-raiser is checking that a standard technical interviewer is not.
5. Explain why silent, correct code fails the coding round at a Tier-1.
6. State two things you should do after every round that make the interviewer's debrief note stronger.

➡ Next: **The Coding Round** — the communication loop, the 15-pattern toolkit, and why your first instinct to jump to code is the one thing guaranteed to hurt you.
