# The System Design Round

> **Module 03 · Course 35** — Every candidate brings a list of components. The interviewer already knows the components. What they're looking for is the conversation *between* the components — the constraints that forced the choices, the trade-offs you consciously made, and the operational realities you thought about before they asked. That's the gap between an SDE-1 who drew a box diagram and an SDE-2 who designed a system.

This module assumes you have Course 14's estimation and design framework. Here we focus on the interview-room execution: how to drive the conversation, how to make trade-offs visible, and what "the right depth" actually looks like at SDE-2 level.

---

## The framework, recapped

Course 14 gives the full walkthrough. The compact version for this module:

```
1. REQUIREMENTS (5 min)   — functional + non-functional; establish scope
2. ESTIMATION  (5 min)    — traffic, storage, bandwidth; anchors all downstream decisions
3. API / DATA MODEL (5 min) — external contract + core entities
4. HIGH-LEVEL DESIGN (10 min) — the main flow, the key components
5. DEEP DIVE (15 min)     — drill into the two or three hardest parts
6. WRAP-UP (5 min)        — operational concerns, trade-offs summary, what you'd do with more time
```

The failure mode in the round is not misallocating a few minutes between steps. It's skipping requirements and estimation entirely and jumping to the diagram. Don't.

---

## Driving the conversation

The interviewer will not ask you a series of structured sub-questions. They will say "design Twitter's feed" and then wait.

Your opening is a rights-establishment move:

> "Before I get into the design, I want to make sure I'm solving the right problem. Let me spend a few minutes on requirements and constraints, then we'll align on scope before I draw anything."

This signals that you operate the way a senior engineer does — not by immediately producing output, but by first confirming you're producing the right output.

### Generating requirements yourself

An SDE-2 generates reasonable constraints from context. You do not need to ask "what are the NFRs?" — you propose them and ask for corrections.

```
"I'll assume this is read-heavy — feeds are consumed far more than they're written.
 Rough ratio: 100:1 reads to writes. That changes the architecture significantly.
 Is that the right mental model, or is write volume more even?"
```

The interviewer responds. Now you have a constraint. More importantly, you've demonstrated you can reason from first principles about load characteristics — which is exactly what an SDE-2 does on day one of a new project.

Required constraints to pin before drawing:
- Scale: DAU, writes/sec, reads/sec
- Latency SLA: p99 read, p99 write
- Consistency requirement: eventual OK? or strong?
- Durability: can we lose a write? (almost always no)
- Geography: single-region or multi-region? (keep it single unless told otherwise)

### Pacing the whiteboard

Write the main data flow as you narrate it — not before, not after. The whiteboard is your shared scratchpad, not a polished artifact.

```
Client → API Gateway → Feed Service → Fanout → Feed Cache → Client
                              ↓
                         Post Store (write path)
```

As you draw each box, say why it's there. "I'm putting a cache in front of the feed read path because feed reads are the hot path, and the data is stable enough for a TTL of 30 seconds." If you draw a box without explaining it, the interviewer is writing "dropped component, no justification" in their debrief.

---

## Articulating trade-offs — the skill the round is actually testing

Most candidates list what their system does. The round is testing whether you understand what your system *doesn't* do, and whether you chose that deliberately.

Every significant design decision is a trade-off. Make them explicit:

| Decision | Trade-off you're making |
|----------|------------------------|
| Fanout on write (push model) | Lower read latency, higher write amplification — fine if follower count is bounded; breaks at celebrity accounts |
| Fanout on read (pull model) | Lower write amplification, higher read latency — fine for small follower counts; breaks at scale with no cache |
| Hybrid (push to most, pull for celebs) | Correct for Twitter-scale, but adds operational complexity — two code paths, two cache invalidation strategies |
| Single-region DB | Simpler, cheaper, lower latency within region — poor disaster recovery |
| Read replica lag | Eventual consistency accepted — cheap reads; users may see stale feed for up to Xms |

You don't need to mention every trade-off. You need to mention the two or three that *drive* the architecture. If you've chosen a push model for feed delivery, you must acknowledge write amplification and say how you handle the celebrity problem. If you don't, the interviewer will ask, and "I hadn't thought about that" is a leveling-down signal.

> At SAP AI Core, the highest-signal design conversations I've been in weren't about who had the most comprehensive diagram. They were about who could say "we chose X over Y because at our write rate, Y's O(fanout) cost would saturate the message broker in under 6 months — we validated this with a back-of-envelope on the whiteboard." The estimation made the trade-off real.

---

## Depth vs breadth — what SDE-2 looks like

The most common mistake in the design round is treating it like a breadth test — covering every component at a surface level. The round is primarily a depth test. The interviewer wants to see you go *deep* on the hard parts.

### SDE-2 profile: one system, done well

An SDE-2 is expected to:
- Design one bounded system — a service, a subsystem — with appropriate depth on the 2–3 hardest subproblems.
- Know the canonical solution for standard problems (caching, pagination, rate limiting) without needing to derive them from scratch.
- Make trade-offs visible and tie them back to the requirements you established.
- Identify operational concerns: what breaks first at 10× load? Where is the single point of failure? What does the oncall runbook need?

An SDE-2 is **not** expected to:
- Design the full org's platform strategy.
- Articulate cross-service data consistency across five teams' schemas.
- Design for multi-region active-active by default (it will come up as a depth question if the interviewer wants it).

If you spend the first 25 minutes producing an exhaustive box diagram with 14 services and never go deep on any of them, you will land at SDE-1 level in the debrief — "broad but shallow."

### SDE-3 profile: cross-system + org impact

For context: an SDE-3 is expected to identify the right problem before being told (e.g., "the real bottleneck isn't the feed service — it's the notification fanout that's fighting for the same Kafka partitions"), and to reason about org-level decisions: build vs buy, platform migration costs, how the design shapes the team's operational burden for the next 3 years.

If you find yourself reaching for SDE-3 territory — great. It's better to demonstrate upward. But if you're trading depth for breadth to cover the SDE-3 scope, you've made the wrong trade.

---

## The deep dive — picking the right subproblem

After the high-level design is on the board, the interviewer will say "let's go deeper on X." Sometimes they pick. If they don't, you should. Pick the subproblem that:

1. Is actually hard (not "and then the API gateway routes to the service").
2. Has real trade-offs you can articulate.
3. You know well enough to go three levels deep.

Good candidates for deep dive in a feed system: the fanout strategy, the cache invalidation approach, the pagination cursor design, the rate-limiting scheme.

Go three levels deep:

```
Level 1: "I'd use a cursor-based pagination scheme rather than offset."
Level 2: "Offset breaks on concurrent inserts because row N shifts — cursor doesn't.
          The cursor is the last-seen post ID, encoded as an opaque token to the client."
Level 3: "The query is: SELECT * FROM posts WHERE id < :cursor ORDER BY id DESC LIMIT 20.
          Index on id (already the PK). For multi-shard, the cursor needs to encode
          both the shard ID and the post ID — otherwise cross-shard merge is O(shards × page)."
```

That is SDE-2 depth. Each level of the conversation reveals a new constraint you've already thought about.

---

## Whiteboard discipline

Four mechanics that separate the composed from the chaotic:

**Label your arrows.** An arrow with no label is ambiguous. "Is that HTTP? gRPC? Kafka? A DB call?" If you're not labeling, the interviewer is guessing.

**Write numbers near every component that matters.** "100k writes/sec here, so this single Postgres instance won't hold — needs sharding or a write buffer." The numbers you derived in the estimation step should be visible and referenced.

**Don't erase — cross out.** When you revise a decision mid-design, draw a line through the old box and explain why. "I initially had the read path hitting the DB directly — after thinking about the 100k reads/sec number I'm adding a Redis layer here." Showing the revision is a positive signal; it demonstrates thinking over time, not a static answer.

**Time-box yourself out loud.** "I have about 10 minutes left — I want to spend it on the cache invalidation strategy and then do a quick operational walkthrough. Is that the right priority?" This keeps both of you aligned and signals the self-management discipline the interviewer is assessing.

---

## Common mistakes

**No requirements, no estimation.**

You go straight to the diagram. Five minutes in, the interviewer asks "what's the write rate?" and you don't know. Every downstream component you've drawn is now unsupported. The design is a picture, not an engineering decision. Interviewers debrief this as "no structured approach — SDE-1."

**Component-dropping.**

You mention "and we'd add a message queue here" and then immediately move on. Dropped. The interviewer notes it. "Why a message queue? What are you decoupling? What guarantees does it need? At what write volume does it become necessary?" If you mention a component, you own it. If you don't know why it's there, don't draw it.

**No trade-off talk.**

You present one design, as if it is the only design. "I'd use Cassandra for the post store." Why? Over what alternatives? What does Cassandra give you that Postgres doesn't, and what does it cost? An SDE-2 who designs in a vacuum — without articulating what they're optimizing for — signals they cannot navigate ambiguous technical decisions on a real team.

**Over-engineering for breadth.**

Twelve services, three message queues, two caches, cross-region replication, and a CDN — and you're 40 minutes in with 15 minutes left. You've covered everything at surface level, gone deep on nothing, and spent no time on operational concerns. The interviewer's debrief: "Broad but shallow. Did not demonstrate depth on any single component. SDE-1 signal."

**Under-driving.**

Waiting for the interviewer to ask the next question. "Uh, I think that's the design?" at minute 30. The design round is open-ended by design. You are supposed to fill the 45 minutes with deliberate, structured depth. If the interviewer is steering you, you're not driving.

---

## Checkpoint

You're ready for the design challenges when you can, without looking anything up:

1. State the six steps of the design framework and the time budget for each.
2. Describe the opening move you make when the interviewer says "design Twitter's feed" and waits.
3. Name two NFRs you derive yourself before asking the interviewer, and explain why you derive rather than ask.
4. Explain the push vs pull trade-off in a social feed and state the condition under which each breaks.
5. Describe what "three levels deep" on cursor-based pagination looks like.
6. State the specific behavior that causes a debrief to say "broad but shallow."
7. Explain why you cross out rather than erase on the whiteboard.
8. Describe what SDE-2 depth looks like vs SDE-3, and why conflating them costs you the round.

➡ Next: **Behavioral & Leadership Principles** — STAR structure, ownership stories with metrics, and how to prepare for the round most engineers treat as filler.
