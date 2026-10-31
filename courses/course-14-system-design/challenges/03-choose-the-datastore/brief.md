# Choose the Datastore

A candidate finishes their system design with: *"I'd use PostgreSQL for everything."* The interviewer smiles. Not wrong, exactly — but a sign of someone who hasn't thought carefully about access patterns. Knowing when PostgreSQL is right, when Redis wins, and when neither is the correct starting point is the difference between a design that *could* work and one that is obviously correct.

## Context

`setup.sh` creates a work directory with two files:

```
~/.kube-dojo-work/03-choose-the-datastore/
├── scenarios.md    # three scenarios with access patterns and scale targets
└── answer_keys.json  # maps scenario-3 answers to flag strings
```

## The three scenarios

Read `scenarios.md`. Three engineering teams each have a concrete data problem. Each scenario names **three candidate datastores**. For scenarios 1 and 2, one of the three is clearly the best fit — understanding why is part of the learning. For **scenario 3 (the target scenario)**, exactly one choice is correct for the stated access pattern and scale, and that choice's entry in `answer_keys.json` holds the real flag.

## Mission

1. Run `setup.sh` to create the work directory.
2. Read `scenarios.md` and reason through each scenario.
3. For **scenario 3**, decide which of the three datastores is correct.
4. Open `answer_keys.json` and find the flag string mapped to your chosen datastore.
5. Submit the flag in the platform.

The wrong answers hold syntactically valid-looking but incorrect flag strings — they will fail validation. Only the correct reasoning leads to the correct flag.

## What makes a strong answer

You should be able to articulate:
- **Why the wrong choices fail** for the specific access pattern (not just "X is better")
- **What primitive** in the correct datastore makes it the right fit (e.g. "sorted set with O(log N) rank update")
- **The failure mode** if you chose wrong at production scale

The brief does not tell you the answer — it gives you three paths. Follow the access pattern to its logical conclusion.

## Extraction paths

There are two ways to find the flag once you know the answer:
1. Open `answer_keys.json` directly and look up your choice for scenario 3.
2. Read `scenarios.md` — the scenario descriptions contain enough context to derive the answer without any external reference.

Submit the flag string exactly as written in `answer_keys.json` (it starts with `KUBE{`).
