# Study & Mock Plan

> **Module 07 · Course 35** — The engineer who spends twelve weeks grinding LeetCode Hard problems and walks into the behavioral round unprepared is not an edge case — it is the modal candidate. This module is the counter-plan: a structured 8-12 week system that covers coding, design, behavioral, and mocks simultaneously, with a pipeline of applications running alongside it.

You are working full-time at SAP. That means approximately 2-3 hours on weekdays and 4-6 hours on weekends — roughly 20-25 hours per week at full-effort. This plan is built for that constraint. If you have more time, compress it; if you have less, extend it.

---

## The four tracks

Every week, you are working in four parallel tracks. None of them can be deferred until "after" another one.

```
Week  1  2  3  4  5  6  7  8  9  10 11 12
      ┌────────────────────────────────────────┐
  DSA │ ██ ██ ██ ██ ██ ██ ██ ░░ ░░ ░░ ░░ ░░  │ heavy → maintenance
      ├────────────────────────────────────────┤
  Sys │ ░░ ░░ ██ ██ ██ ██ ██ ██ ░░ ░░ ░░ ░░  │ starts week 3, heavy mid
      ├────────────────────────────────────────┤
  Beh │ ░░ ░░ ░░ ██ ██ ██ ░░ ░░ ░░ ░░ ░░ ░░  │ stories first, then refresh
      ├────────────────────────────────────────┤
 Mock │ ░░ ░░ ░░ ░░ ██ ██ ██ ██ ██ ██ ██ ██  │ starts week 5, never stops
      └────────────────────────────────────────┘
      ░░ = active but lighter   ██ = primary focus
```

---

## Phase 1 — Audit & baseline (Weeks 1-2)

Before studying anything, measure what you already know. This sounds obvious and is routinely skipped.

**Coding audit:** Do 5 problems across 5 patterns (arrays, trees, graphs, DP, heaps) at Medium level. Do not look anything up. Time yourself. Score yourself 0-3 on each: 0 = could not start, 1 = brute force only, 2 = optimal but slow, 3 = clean and fast. You now have a baseline.

**System design audit:** Take one question you have seen before ("design a URL shortener" is fine for baseline) and write out your answer in 45 minutes. No looking things up. Then compare against a reference solution. Score the gap on five axes: capacity estimation, API design, component selection, trade-offs articulated, operational concerns.

**Behavioral audit:** Write down 5 stories from your work history using STAR (situation, task, action, result). Time the verbal delivery: it should be 90 seconds to 3 minutes. If you go over 4 minutes you are not STAR-shaped yet — you are narrating.

The audit tells you where the gaps are. The rest of the plan is filling those gaps, not working from a template.

---

## Phase 2 — Coding: patterns, not random problems (Weeks 1-7)

The mistake is treating LeetCode as a random training set. Problems are not random — they cluster into patterns, and the patterns at SDE-2 level are knowable in advance.

**The twelve patterns that cover 80% of SDE-2 coding rounds:**

| Pattern | Key indicator | Representative problems |
|---------|--------------|------------------------|
| Sliding window | "contiguous subarray / substring" | Max sum subarray, min window substring |
| Two pointers | "sorted array, find pair/triplet" | 3Sum, container with most water |
| Binary search | "sorted, find boundary, minimize/maximize" | Search in rotated array, koko eating bananas |
| DFS / backtracking | "enumerate all paths, combinations" | Word search, permutations, N-queens |
| BFS / level-order | "shortest path, K steps" | Word ladder, rotten oranges |
| Topological sort | "dependencies, ordering" | Course schedule, alien dictionary |
| Dynamic programming 1D | "optimal substructure, single sequence" | Coin change, house robber, jump game |
| Dynamic programming 2D | "two sequences, grids" | Edit distance, LCS, unique paths |
| Heap / priority queue | "K largest/smallest, streaming" | Top K frequent, merge K sorted lists |
| Monotonic stack | "next greater, span, histogram" | Daily temperatures, largest rectangle |
| Union-find | "connected components, cycle detection" | Number of islands (union-find variant), redundant connection |
| Trie | "prefix matching, autocomplete" | Word search II, implement trie |

**The weekly coding rhythm:**

- 2-3 problems per weekday (30-45 min total, timed)
- 4-6 problems on weekend (1 pattern deep-dive per weekend)
- One "revisit session" per week: redo problems you marked "struggled" from the week before

**Spaced repetition for patterns, not solutions.** The goal is pattern recognition, not memorising answers. When you finish a problem correctly, the question to ask is "what was the trigger that told me to use this pattern?" Write that down. In 3 days, revisit the trigger and a different problem from the same pattern. This is the Anki cycle: not the problem and its solution, but the problem type and its recogniser.

**Hard problems and when to do them.** At SDE-2, 90% of problems you will see in a real loop are Medium. Do Hard problems when: (a) you want to stress-test a pattern you feel comfortable with, or (b) you are targeting specific companies known for hard problems (Uber, Google). Do not grind Hard in week 2 to signal effort — it is low signal-to-noise for SDE-2 prep.

**After week 7:** Shift from learning to maintenance. 3-4 problems per week, rotating across patterns. The goal is not to get better — it is to not regress.

---

## Phase 3 — System design depth (Weeks 3-8)

**The reference text.** Read *Designing Data-Intensive Applications* by Martin Kleppmann. Not skim — read and annotate. Chapters 1, 2, 5, 6, 7, 8, 9, 11, 12 are the ones that come up most in interviews. Budget 4 weeks of weekend reading.

**The design practice template.** Every design session (2 per week from week 5 onward) follows this structure, timed:

```
[5 min]  Clarify + scope: what is in, what is explicitly out, what are the non-functional requirements (scale, latency, durability, consistency)
[5 min]  Capacity estimation: derive writes/sec, storage/year, read:write ratio
[5 min]  API design: REST or event-driven, key endpoints
[15 min] High-level architecture: components, data flow, where data lives
[10 min] Deep dive: the ONE hardest component (e.g., the write path, the real-time component, the consistency model)
[5 min]  Trade-offs: what you would do differently at 10× scale, what you explicitly punted on and why
```

45 minutes total. If you are going over, you are scope-creeping. The interviewer will redirect — practice redirecting yourself first.

**The question bank for practice (do all of these, in order of complexity):**

1. Design a URL shortener (baseline: read/write split, hashing, caching)
2. Design a rate limiter (token bucket vs sliding window log vs sliding window counter)
3. Design Twitter's feed (fanout on write vs fanout on read)
4. Design a payment system (idempotency, exactly-once, settlement)
5. Design a distributed job scheduler (at-least-once delivery, cron semantics, dead-letter)
6. Design a metrics ingestion pipeline (Grafana-style: high cardinality, retention tiers, query engine)
7. Design a ride-matching system (geospatial indexing, real-time matching, supply/demand)

For each one: do it yourself first (timed), then read Uber/Grafana/Netflix engineering blog posts on how they actually did it, then note the 3 biggest ways your design was wrong or naive.

---

## Phase 4 — Behavioral stories (Weeks 4-6)

Behavioral rounds fail more SDE-2 candidates than coding rounds do. This is the track that gets the least prep time and has the highest per-hour return on investment after week 1 of study.

**Build a story bank of 6-8 stories.** Each story should be reusable across multiple question types by adjusting the emphasis. The key stories to have:

| Story type | The thing it needs to show |
|-----------|--------------------------|
| Delivered something hard | Scope, complexity, your specific contribution |
| Disagreed with a decision | How you raised it, what happened, what you learned |
| Fixed something broken in production | Urgency, systematic diagnosis, prevention |
| Mentored or unblocked someone | You made someone else better |
| Took ownership of an ambiguous problem | You defined the problem and the solution |
| Failed and learned | Honest, specific failure + concrete change in behavior |

For SAP context: the 100 GB/day LGTM pipeline is "delivered something hard" + "fixed something broken." Zero rollbacks across N months is "ownership." The LLM integration work is "took ownership of ambiguous problem." You have real stories — the work is shaping them into STAR structure.

**STAR format for SDE-2.** The trap is spending too long on Situation and too little on Action and Result.

```
Situation:  1-2 sentences. Context, why it mattered. Stop.
Task:       1 sentence. What you were responsible for specifically.
Action:     3-5 sentences. What YOU did, what decisions YOU made, why.
Result:     2-3 sentences. Quantified outcome. What changed permanently.
```

Total: 90 seconds to 2.5 minutes when delivered verbally. Practice out loud — not in your head, not in writing. Record yourself on your phone and listen back. You will hear filler words, vague quantifiers ("a lot of"), and the places where you drift into "we" instead of "I." Fix those.

**Refreshing stories after week 6.** You do not need to study new stories — you need to practice delivery. One story per week, verbal, timed, recorded.

---

## Mocks: the irreplaceable component (Weeks 5-12)

Reading about interviews is not practicing interviews. This distinction sounds obvious. Most people still skip mocks and are surprised when they freeze under a real clock.

**Types of mocks, in order of value:**

1. **Peer mocks (highest value).** Find one or two people also preparing for SDE-2 loops. One 45-minute session per week each way: you interview them, they interview you. You each get a coding round and a behavioral round over two sessions. This is free and forces you to be the interviewer — which teaches you what actually matters in an answer.

2. **Pramp (free, accessible).** [Pramp](https://www.pramp.com/) matches you with a peer for a structured 45-minute session. Scheduling can be unpredictable, but at 1-2 sessions per week it is a meaningful supplement. Use their system design rooms when available.

3. **Interviewing.io (paid for premium, free for some sessions).** Anonymous mocks with engineers from FAANG companies. More expensive but the feedback is the closest thing to the real loop. Worth 2-3 sessions at a critical juncture (e.g., 2 weeks before your first onsite).

4. **Self-mock (low cost, uncomfortable, useful).** Pick a problem you have never seen. Set a 30-minute timer. Open your IDE. Narrate your thinking out loud as you type. Record it. Watch it back once. You will find the exact moment where you go silent, and silence in a real interview is what you are trying to fix.

**Mock evaluation criteria.** After every mock, score yourself and have your peer score you on:

| Dimension | What you are looking for |
|-----------|--------------------------|
| Clarification | Did you ask the right scope questions before coding? |
| Approach verbalization | Did you explain your approach before writing a line? |
| Complexity analysis | Did you call out time and space complexity unprompted? |
| Edge cases | Did you identify them before running the tests? |
| Communication under pressure | Did you narrate when you were stuck, or go silent? |
| Recover from wrong approach | Did you pivot cleanly or spiral? |

---

## Tracking weak areas

Do not just log "solved / unsolved." Log the failure mode.

Maintain a prep log (a plain markdown file or Notion page) with this structure for every session:

```
Date: 2026-11-03
Problem / Topic: Merge K sorted lists (Heap)
Time: 28 min
Result: Optimal, but forgot to handle empty lists initially
Failure mode: Edge case (empty input) — missed in initial approach
Fix: Add "what are the edge cases?" to my starting checklist
Communication: Good, narrated well
Next review: 2026-11-10
```

Review your failure mode log once per week on Sundays. The goal is to shrink the list of recurring failure modes. "Missed edge cases" appearing in week 7 after appearing in week 1 means you have not fixed it — it means you have been practicing getting to optimal solutions and skipping the edge case pass. Fix the process, not just the symptom.

---

## Managing the application pipeline

Prep and applications run in parallel from week 3 onward. Do not wait until you feel "ready" — the pipeline has its own timeline.

**The staggering principle.** Apply to 3-5 companies simultaneously, staggered by 2 weeks so onsite rounds do not overlap. Apply to lower-priority companies first: if you are more excited about Grafana than Razorpay, apply to Razorpay first. Use the lower-stakes loops to derust on real interviews.

**The pipeline spreadsheet.** A minimal tracker:

| Company | Role | Applied | Status | Next action | Deadline |
|---------|------|---------|--------|-------------|----------|
| Razorpay | SDE-2 Backend | 2026-11-10 | Phone screen | Prep system design | 2026-11-18 |
| Grafana | Senior Engineer | 2026-11-15 | Take-home | Complete take-home | 2026-11-22 |

Update it within 24 hours of every interaction. A pipeline that is not tracked is a pipeline that generates deadline surprises.

**Post-round debrief.** Within 24 hours of every round, write a 5-bullet debrief: what went well, what went poorly, what question you were asked that you did not handle well, what you would do differently. Do this while the memory is fresh. At the end of each week, review your debriefs and update your weak-areas log.

**The timing leverage.** If you have two companies at different stages, it is acceptable (and normal) to ask the faster-moving company for a brief delay while you get the second company to a comparable stage. "I'm very interested and have a conflicting commitment on [date] — is [date+5] possible for the final round?" Recruiters use this as a signal that you are in demand. Use it once per company, not repeatedly.

---

## Interview-day logistics

The things that are entirely in your control and entirely ignored until the morning of.

**Remote rounds:**
- Test your video and audio 30 minutes before the round, not 5 minutes before. Know which device is your microphone. Know how to switch.
- Have water on the desk. No coffee that you will need to refill.
- Close every application except the coding environment and video. Notifications appearing mid-round are both distracting and a professionalism signal.
- Confirm your coding environment before the round: do you have the language version they expect? Can you run code locally? Is the IDE they use different from yours?

**Onsite rounds:**
- Arrive 15-20 minutes early. Not to go in early — to not be rushed. Sit in the lobby, breathe, review your stories.
- Bring a charger if you are using your laptop. Bring nothing else.
- In a whiteboard round: use the full board (do not write small in one corner), narrate, and write your edge cases in the corner before writing a single line of code.

**Universal:**
- Do not rearrange your preparation the evening before. Review your story bank, review the company-specific module, sleep.
- "I don't know" said immediately and followed by a structured exploration is better than a wrong confident answer. Interviewers remember the pivot more than the initial miss.
- At the start of any coding round: repeat the problem back in your own words before touching the keyboard. This is the single most underused technique in coding interviews and it catches a majority of the "I solved the wrong problem" outcomes.

---

## Common mistakes

**Grinding only LeetCode.** The behavioral and system design rounds fail candidates at the same or higher rate than coding — especially at SDE-2 where behavioral scope is explicitly evaluated. A 12-week plan that is 90% LeetCode is a plan that is optimised for the wrong failure mode.

**No mocks.** "I'll start mocks in the last two weeks." Two weeks of mocks = maybe 4 sessions. You are still derusing in session 4. Start mocks in week 5. Run them until offer day.

**No behavioral prep.** "I'll handle it in the moment." Behavioral questions require practiced answers. You cannot improvise a specific STAR story under 45-second time pressure while simultaneously tracking whether you are at the right level of detail. The stories have to be rehearsed, not memorised verbatim — rehearsed meaning you have told them out loud at least 5 times.

**Burning out at week 4.** This is the most predictable failure in a long prep run. The first two weeks feel productive. Week 3-4 is where progress plateaus (you already know the patterns and the next level requires harder reps) and motivation drops. Plan for it: schedule a full rest weekend at week 4. No LeetCode, no design, no behavioral. One day of active rest changes the trajectory of the remaining 8 weeks.

**Not tracking applications.** Three applications sent six weeks ago, no follow-up, no record of what happened. The pipeline runs on process, not memory. Track everything in one place, update within 24 hours, and never let a deadline come as a surprise.

**Starting with your dream company.** The Grafana interview should not be your first live interview in six months. Apply to a lower-stakes company first, run the whole loop, debrief every round, and fix the gaps before the loop you care most about.

**Comparing your week 2 to someone else's week 10.** Blind and Levels.fyi are useful for salary data and useless for prep anxiety management. Some fraction of the people posting "I solved 400 LC in 2 months" are exaggerating; all of them have a different baseline and a different target company. Run your own plan.

---

## Checkpoint

You are ready to close this module when you can answer each of these without looking anything up:

1. Name the twelve coding patterns and for each one, give one problem that is a clean example of it.
2. What is the 45-minute system design session template, broken down by time allocation?
3. What is the STAR format breakdown for SDE-2, and what is the most common mistake in how candidates use each section?
4. Name three types of mocks, ordered by value, and explain why peer mocks rank higher than Pramp for most candidates.
5. What goes in a post-round debrief, and why does it need to happen within 24 hours?
6. What is the "staggering principle" for managing a multi-company application pipeline, and what is the failure mode if you ignore it?
7. What is the most predictable week for motivation collapse in a 12-week prep run, and how do you plan for it?

---

## Full 12-week overview

| Week | Coding focus | System design | Behavioral | Mocks | Applications |
|------|-------------|---------------|-----------|-------|-------------|
| 1 | Audit + sliding window, two pointers | — | Audit: write 5 stories | — | — |
| 2 | Binary search, DFS/backtracking | — | Shape stories into STAR | — | Research 6-8 companies |
| 3 | BFS, topological sort | Read DDIA ch. 1-2, 5 | Refine timing | — | Apply to 2 practice companies |
| 4 | DP 1D, DP 2D | Read DDIA ch. 6-7; design URL shortener | Record & review delivery | — | Apply to 2 more |
| 5 | Heap, monotonic stack | Design rate limiter, Twitter feed | Refresh top 3 stories | 2 peer mocks | First phone screens |
| 6 | Union-find, trie | Read DDIA ch. 8-9; design payment system | Refresh remaining stories | 2 peer + 1 Pramp | Onsite prep for practice company |
| 7 | Weak area revisit pass | Design distributed scheduler | — | 2 peer + 1 Pramp | Debrief practice loops |
| 8 | Maintenance (3-4/wk) | Design metrics pipeline | — | 2 peer + 1 Pramp | Apply to priority companies |
| 9 | Maintenance | Design ride-matching system | Story refresh | 2 peer + 1 interviewing.io | Priority phone screens |
| 10 | Maintenance | Trade-offs deep-dive (your 3 weakest designs) | — | 2 peer + 1 Pramp | Priority onsites |
| 11 | Maintenance | Company-specific designs (target companies) | Company-specific story tailoring | 2 peer | Priority onsites |
| 12 | Light maintenance | Review, not new content | Final delivery practice | 1-2 mocks for warm-up | Negotiate |

This is not a schedule to follow mechanically — it is a map of what to prioritise when. Compress the early phases if your baseline is higher. Extend the mock phase if your verbal delivery is weak. The one thing that should not change: mocks start no later than week 5 and run every week until offer day.

➡ You have completed the course content. Go run the challenges.
