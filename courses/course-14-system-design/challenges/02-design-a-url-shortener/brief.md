# Design a URL Shortener

Your team's tech lead drops a Slack message: *"Interviewing at [redacted] on Friday. Sent them a URL shortener design doc as a take-home. Can you review it before I submit?"* You open the doc. The "Data Model" section is a single bullet: "store long URL somewhere." The "Scaling" section is blank. The ID generation strategy is "maybe MD5?"

URL shortener is the canonical warm-up design interview question — it is small enough to fit on a whiteboard and rich enough to expose every gap: ID generation collisions, read-heavy vs write-heavy traffic patterns, redirect consistency, hot-key handling in caches, and database choice. If you can not design this one cold, the harder designs will go sideways.

## Context

`setup.sh` creates a work directory with a starter template:

```
~/.kube-dojo-work/02-design-a-url-shortener/
└── design.md    # your design document — fill every section
```

## Prerequisites

None — this is a text-only document challenge. A text editor is sufficient.

## Mission

Write `design.md` in the work directory. It must contain all five level-2 sections, and the Data Model section must describe a sound short-code ID generation strategy.

### Required sections

| Section heading | What a strong answer covers |
|-----------------|----------------------------|
| `## Requirements` | Functional (shorten, redirect, expiry, custom slugs?) and non-functional (latency SLA, availability, scale target: DAU or QPS) |
| `## Capacity` | Writes/sec, reads/sec (assume 100:1 read:write ratio), storage per year, bandwidth — derive from your scale target |
| `## API` | At minimum: `POST /shorten` (request + response shape), `GET /{code}` (redirect); include status codes |
| `## Data Model` | Table schema or document shape; which database and why; **how short codes are generated** (base62 encoding of a counter, random hash truncation, or UUID-based — pick one and defend it) |
| `## Scaling` | Cache layer (what you cache, why 301 vs 302, cache invalidation on expiry), horizontal read scaling, hot-key mitigation, write bottleneck at the ID generator |

### ID scheme requirement

`verify.sh` checks that your design mentions at least one of:

- **base62** — encode a monotone counter as a base-62 string (digits + upper + lowercase)
- **counter** — a distributed counter (e.g. Redis INCR, a dedicated DB sequence) as the basis for short codes
- **hash** — a hash (MD5/SHA truncated, or murmurhash) with collision detection

You must name one of these terms. "Some random scheme" or "UUID" without further explanation will fail the check.

## Why ID generation is the crux

The choice of ID scheme determines:
- **Collision probability** — MD5-truncated to 7 chars: 62^7 ≈ 3.5T combinations — with 100M URLs/day birthday problem puts collision probability at ~1% after ~2M URLs. That is unacceptable without re-roll logic.
- **Predictability** — a monotone counter exposes your total URL count to anyone who shortens two URLs in a row. Acceptable for internal tooling; not for a public service.
- **Sequentiality** — sequential IDs are cache-friendly for read paths but expose enumeration attacks. Random IDs are not.
- **Coordination** — a centralized counter is a write bottleneck above ~50K inserts/sec. At that point you shard the counter space (snowflake IDs, UUID v7 sorted).

Name your choice, state the tradeoff, and explain why it fits the scale you declared in Requirements.

## Verify

```bash
bash courses/course-14-system-design/challenges/02-design-a-url-shortener/verify.sh
```

All five headings present + ID scheme mentioned → flag printed.
